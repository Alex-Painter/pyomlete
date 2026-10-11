import asyncio
import logging
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from typing import ClassVar
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest
from beanie import PydanticObjectId
from pydantic import BaseModel, create_model

import main
from data_models import SuggestionDocument
from tests.test_recipe_jobs import (
    RECIPE_ID,
    SOUP,
    a_model,
    a_model_that_never_answers,
    model_answering,
    saved_recipe,
)

LIST_ID = "64b7f0c2a1b2c3d4e5f60799"



def _matches(doc: dict, query: dict) -> bool:
    """Equality, `$in` and `$nin`: all the endpoints ask Mongo to decide."""
    for key, wanted in query.items():
        have = doc.get(key)
        if not isinstance(wanted, dict):
            found = have == wanted
        elif "$in" in wanted:
            found = have in wanted["$in"]
        else:
            found = have not in wanted["$nin"]
        if not found:
            return False
    return True


class _Found:
    def __init__(self, model, query: dict):
        self.model, self.query = model, query

    def _docs(self):
        return [
            doc for doc in self.model.store.values()
            if _matches({**doc.model_dump(exclude={"id"}), "_id": doc.id}, self.query)
        ]

    def sort(self, _key):
        return self

    def limit(self, _count):
        return self

    async def to_list(self):
        await asyncio.sleep(0)
        return [doc.model_copy() for doc in self._docs()]

    async def update(self, change: dict, response_type=None):
        """Like Mongo, matches and writes in one step: nothing else runs between the two."""
        await self.model.before_write(change["$set"])
        docs = self._docs()
        if response_type is main.UpdateResponse.NEW_DOCUMENT:
            docs = docs[:1]
        for doc in docs:
            for field, value in change["$set"].items():
                setattr(doc, field, value)
            self.model.written.append((doc.id, doc.status))
        if response_type is main.UpdateResponse.NEW_DOCUMENT:
            return docs[0].model_copy() if docs else None
        return SimpleNamespace(modified_count=len(docs))


class _OverADict(BaseModel):
    """What the endpoints ask of a suggestion document, answered from a dict.

    Every call gives way first, so two requests at once interleave as they would over Mongo.
    """

    store: ClassVar[dict] = {}
    #: Every (card, status) a conditional or many-card update wrote, in order.
    written: ClassVar[list] = []

    @classmethod
    async def before_write(cls, _change: dict) -> None:
        await asyncio.sleep(0)

    @classmethod
    async def get(cls, suggestion_id):
        await asyncio.sleep(0)
        found = cls.store.get(suggestion_id)
        return found and found.model_copy()

    @classmethod
    def find(cls, query: dict):
        return _Found(cls, query)

    find_one = find


# `SuggestionDocument`'s own fields, so a field added there is here too.
FakeSuggestionDocument = create_model(
    "FakeSuggestionDocument",
    __base__=_OverADict,
    id=(PydanticObjectId, ...),
    **{
        name: (field.annotation, field)
        for name, field in SuggestionDocument.model_fields.items()
        if name not in ("id", "revision_id")
    },
)


@pytest.fixture(autouse=True)
def cards():
    FakeSuggestionDocument.store = {}
    FakeSuggestionDocument.written = []
    main._suggestion_save_tasks.clear()
    with patch.multiple(
        main,
        SuggestionDocument=FakeSuggestionDocument,
        END_WRITE_PAUSES=(0, 0, 0),
        _add_recipe_to_list_id=AsyncMock(),
    ):
        yield FakeSuggestionDocument.store


@pytest.fixture
async def api():
    transport = httpx.ASGITransport(app=main.app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        yield client


def a_card(cards: dict, status: str = "new", saving_for=None, **fields) -> str:
    """Puts a card in the feed. `saving_for` is how long ago its save began."""
    since = None if saving_for is None else datetime.now(timezone.utc) - saving_for
    card = FakeSuggestionDocument(
        id=PydanticObjectId(), title="Leek and potato soup", status=status, saving_since=since, **fields
    )
    cards[card.id] = card
    return str(card.id)


def a_card_whose_save_was_lost(cards: dict) -> str:
    return a_card(cards, "saving", saving_for=main.BACKGROUND_WORK_STALE_AFTER * 1.1)


def a_card_being_saved(cards: dict) -> str:
    return a_card(cards, "saving", saving_for=main.BACKGROUND_WORK_STALE_AFTER * 0.9)


def stored(cards: dict, card: str) -> FakeSuggestionDocument:
    return cards[PydanticObjectId(card)]


async def in_the_feed(api: httpx.AsyncClient, card: str) -> dict | None:
    feed = (await api.get("/api/suggestions/")).json()
    return next((c for c in feed if c["id"] == card), None)


def save(api: httpx.AsyncClient, card: str, list_id: str | None = None):
    return api.post(f"/api/suggestions/{card}/save", json={"list_id": list_id})


async def saves_have_ended() -> None:
    await asyncio.gather(*list(main._suggestion_save_tasks))


def a_model_that_waits(reached: asyncio.Event, release: asyncio.Event) -> MagicMock:
    """`async_claude`, answering with the soup once it is released."""
    claude = model_answering(SOUP)
    runner = claude.beta.messages.tool_runner.return_value
    answer = runner.until_done

    async def waits(*args, **kwargs):
        reached.set()
        await release.wait()
        return await answer(*args, **kwargs)

    runner.until_done = waits
    return claude


def the_library(*recipes) -> MagicMock:
    """`RecipeDocument`, holding these recipes."""
    by_id = {str(r.id): r for r in recipes}
    library = MagicMock()
    library.get = AsyncMock(side_effect=lambda recipe_id: by_id.get(str(recipe_id)))
    return library


def statuses_written(card: str) -> list[str]:
    return [status for doc, status in FakeSuggestionDocument.written if str(doc) == card]


class TestSavingACard:
    async def test_answers_saving_at_once_and_ends_saved_with_the_recipe(self, api, cards):
        card = a_card(cards)

        with a_model():
            answer = await save(api, card)
            await saves_have_ended()
        after = await in_the_feed(api, card)

        assert (answer.status_code, answer.json()["status"]) == (200, "saving")
        assert (after["status"], after["recipe_id"], after["error"]) == ("saved", RECIPE_ID, None)
        main._add_recipe_to_list_id.assert_not_called()

    async def test_a_save_that_fails_says_why_on_the_card(self, api, cards):
        card = a_card(cards)

        with a_model(RuntimeError("the model is away")):
            await save(api, card)
            await saves_have_ended()
        after = await in_the_feed(api, card)

        assert (after["status"], after["error"]) == ("failed", "the model is away")

    async def test_a_second_save_of_a_card_being_saved_starts_nothing(self, api, cards):
        card = a_card_being_saved(cards)
        save_recipe = saved_recipe()

        with a_model(_save_recipe=save_recipe):
            answer = await save(api, card)
            await saves_have_ended()

        assert answer.json()["status"] == "saving"
        assert not main._suggestion_save_tasks
        save_recipe.assert_not_called()
        assert stored(cards, card).status == "saving"

    @pytest.mark.parametrize("status", ["new", "failed"])
    async def test_two_saves_at_once_start_one(self, api, cards, status):
        card = a_card(cards, status)
        save_recipe = saved_recipe()

        with a_model(_save_recipe=save_recipe):
            answers = await asyncio.gather(save(api, card), save(api, card, LIST_ID))
            started = len(main._suggestion_save_tasks)
            await saves_have_ended()

        assert [a.json()["status"] for a in answers] == ["saving", "saving"]
        assert started == 1
        save_recipe.assert_awaited_once()
        assert statuses_written(card) == ["saving", "saved"]

    async def test_a_save_that_runs_past_the_time_limit_is_cancelled_and_fails(self, api, cards, caplog):
        card = a_card(cards)
        save_recipe = saved_recipe()

        with a_model(
            async_claude=a_model_that_never_answers(),
            _save_recipe=save_recipe,
            BACKGROUND_WORK_TIME_LIMIT=main.BACKGROUND_WORK_TIME_LIMIT * 0,
        ), caplog.at_level(logging.WARNING, logger="main"):
            await save(api, card)
            await saves_have_ended()
        after = await in_the_feed(api, card)

        assert (after["status"], after["error"]) == ("failed", main.SAVE_INTERRUPTED)
        assert stored(cards, card).status == "failed"
        assert "ran past its time limit" in caplog.text
        save_recipe.assert_not_called()

    async def test_a_timeout_inside_the_making_is_that_making_s_failure(self, api, cards, caplog):
        card = a_card(cards)

        with a_model(TimeoutError("the page did not answer")), caplog.at_level(logging.WARNING, logger="main"):
            await save(api, card)
            await saves_have_ended()
        after = await in_the_feed(api, card)

        assert (after["status"], after["error"]) == ("failed", "the page did not answer")
        assert "ran past its time limit" not in caplog.text


class TestASaveOntoAList:
    async def test_puts_the_recipe_there_before_the_card_says_saved(self, api, cards):
        card = a_card(cards)
        made = saved_recipe()
        main._add_recipe_to_list_id.side_effect = lambda *_: statuses_at_the_add.append(
            stored(cards, card).status
        )
        statuses_at_the_add: list[str] = []

        with a_model(_save_recipe=made):
            await save(api, card, LIST_ID)
            await saves_have_ended()

        main._add_recipe_to_list_id.assert_awaited_once_with(LIST_ID, made.return_value)
        assert statuses_at_the_add == ["saving"]
        assert statuses_written(card) == ["saving", "saved"]

    async def test_a_recipe_that_cannot_go_on_its_list_fails_the_card_and_keeps_the_recipe(self, api, cards):
        card = a_card(cards)
        main._add_recipe_to_list_id.side_effect = ConnectionError("mongo is away at 10.0.0.7:27017")

        with a_model():
            await save(api, card, LIST_ID)
            await saves_have_ended()
        after = await in_the_feed(api, card)

        assert (after["status"], after["error"]) == ("failed", main.NOT_PUT_ON_THE_LIST)
        assert after["recipe_id"] == RECIPE_ID
        assert statuses_written(card) == ["saving", "failed"]

    async def test_a_list_that_does_not_answer_fails_the_card_the_same_way(self, api, cards):
        card = a_card(cards)

        async def never_answers(*_):
            await asyncio.sleep(3600)

        main._add_recipe_to_list_id.side_effect = never_answers

        with a_model(END_WRITE_TIMEOUT=0.01):
            await save(api, card, LIST_ID)
            await saves_have_ended()
        after = await in_the_feed(api, card)

        assert (after["status"], after["error"]) == ("failed", main.NOT_PUT_ON_THE_LIST)
        assert statuses_written(card) == ["saving", "failed"]


class TestSavingACardThatAlreadyHasItsRecipe:
    """An earlier save made the recipe and did not end saved."""

    async def test_uses_that_recipe_and_does_only_what_is_left(self, api, cards):
        card = a_card(cards, "failed", recipe_id=RECIPE_ID, error=main.NOT_PUT_ON_THE_LIST)
        recipe = SimpleNamespace(id=RECIPE_ID)
        claude = model_answering(SOUP)
        save_recipe = saved_recipe()

        with a_model(async_claude=claude, _save_recipe=save_recipe, RecipeDocument=the_library(recipe)):
            await save(api, card, LIST_ID)
            await saves_have_ended()
        after = await in_the_feed(api, card)

        assert (after["status"], after["recipe_id"], after["error"]) == ("saved", RECIPE_ID, None)
        main._add_recipe_to_list_id.assert_awaited_once_with(LIST_ID, recipe)
        claude.beta.messages.tool_runner.assert_not_called()
        save_recipe.assert_not_called()

    async def test_makes_it_afresh_if_that_recipe_is_gone(self, api, cards):
        card = a_card(cards, "failed", recipe_id="64b7f0c2a1b2c3d4e5f60700")
        save_recipe = saved_recipe()

        with a_model(_save_recipe=save_recipe, RecipeDocument=the_library()):
            await save(api, card)
            await saves_have_ended()
        after = await in_the_feed(api, card)

        assert (after["status"], after["recipe_id"]) == ("saved", RECIPE_ID)
        save_recipe.assert_awaited_once()


async def _saved_again(_api, cards, card):
    stored(cards, card).saving_since = datetime.now(timezone.utc) + timedelta(seconds=1)


async def _cleared(api, _cards, card):
    await api.patch(f"/api/suggestions/{card}", json={"status": "cleared"})


async def _dismissed(api, _cards, card):
    await api.patch(f"/api/suggestions/{card}", json={"status": "dismissed"})


class TestASaveThatNoLongerOwnsItsCard:
    @pytest.mark.parametrize(
        "moved_on, left_as", [(_saved_again, "saving"), (_cleared, "cleared"), (_dismissed, "dismissed")]
    )
    async def test_writes_nothing_when_it_ends(self, api, cards, moved_on, left_as):
        card = a_card(cards)
        reached, release = asyncio.Event(), asyncio.Event()

        with a_model(async_claude=a_model_that_waits(reached, release)):
            await save(api, card, LIST_ID)
            await reached.wait()
            await moved_on(api, cards, card)
            before = stored(cards, card).model_copy()
            release.set()
            await saves_have_ended()

        assert stored(cards, card) == before
        assert (before.status, before.recipe_id) == (left_as, None)
        main._add_recipe_to_list_id.assert_not_called()

    async def test_cannot_be_put_back_to_new(self, api, cards):
        card = a_card_being_saved(cards)

        answer = await api.patch(f"/api/suggestions/{card}", json={"status": "new"})

        assert answer.status_code == 409
        assert stored(cards, card).status == "saving"

    async def test_a_failed_save_does_not_bring_a_dismissed_card_back(self, api, cards):
        card = a_card(cards)
        reached = asyncio.Event()

        with a_model(async_claude=a_model_that_never_answers(reached)):
            await save(api, card)
            await reached.wait()
            await _dismissed(api, cards, card)
            await main._end_running_work()

        assert stored(cards, card).status == "dismissed"
        assert await in_the_feed(api, card) is None


class TestASaveThatWasLost:
    """A restart loses the task and leaves the card saying saving."""

    async def test_reads_as_failed_once_it_is_past_the_bound(self, api, cards):
        fresh = a_card_being_saved(cards)
        lost = a_card_whose_save_was_lost(cards)
        # As Mongo returns it: the same instant with its zone dropped.
        stored(cards, lost).saving_since = stored(cards, lost).saving_since.replace(tzinfo=None)

        assert (await in_the_feed(api, fresh))["status"] == "saving"
        answer = await in_the_feed(api, lost)
        assert (answer["status"], answer["error"]) == ("failed", main.SAVE_INTERRUPTED)
        # Decided when read, not written: a task that does finish still has the last word.
        assert stored(cards, lost).status == "saving"

    async def test_a_card_left_saving_by_an_older_server_has_no_start_and_is_lost(self, api, cards):
        legacy = a_card(cards, "saving")

        assert (await in_the_feed(api, legacy))["status"] == "failed"

    async def test_saving_it_again_starts_the_work_afresh(self, api, cards):
        lost = a_card_whose_save_was_lost(cards)
        before = datetime.now(timezone.utc)

        with a_model():
            answer = await save(api, lost, LIST_ID)
            restarted = stored(cards, lost).model_copy()
            await saves_have_ended()
        after = await in_the_feed(api, lost)

        assert (answer.json()["status"], answer.json()["error"]) == ("saving", None)
        assert (restarted.status, restarted.saving_since >= before) == ("saving", True)
        assert (after["status"], after["recipe_id"]) == ("saved", RECIPE_ID)
        main._add_recipe_to_list_id.assert_awaited_once()

    async def test_two_saves_of_it_at_once_start_one(self, api, cards):
        lost = a_card_whose_save_was_lost(cards)
        save_recipe = saved_recipe()

        with a_model(_save_recipe=save_recipe):
            await asyncio.gather(save(api, lost), save(api, lost))
            started = len(main._suggestion_save_tasks)
            await saves_have_ended()

        assert started == 1
        save_recipe.assert_awaited_once()

    async def test_clear_takes_it_and_leaves_a_card_being_saved(self, api, cards):
        fresh = a_card_being_saved(cards)
        lost = a_card_whose_save_was_lost(cards)
        legacy = a_card(cards, "saving")
        new = a_card(cards)

        answer = await api.post("/api/suggestions/clear", json={})
        feed = [c["id"] for c in (await api.get("/api/suggestions/")).json()]

        assert answer.json() == {"cleared": 3}
        assert feed == [fresh]
        assert {stored(cards, c).status for c in (lost, legacy, new)} == {"cleared"}

    async def test_clear_by_id_takes_only_the_cards_named(self, api, cards):
        fresh = a_card_being_saved(cards)
        lost = a_card_whose_save_was_lost(cards)
        other = a_card_whose_save_was_lost(cards)
        new = a_card(cards)

        answer = await api.post("/api/suggestions/clear", json={"ids": [fresh, lost]})

        assert answer.json() == {"cleared": 1}
        assert stored(cards, lost).status == "cleared"
        assert [stored(cards, c).status for c in (fresh, other, new)] == ["saving", "saving", "new"]

    async def test_clear_decides_by_the_rule_the_feed_reads_by(self, api, cards):
        fed_as_failed = a_card_being_saved(cards)
        fed_as_saving = a_card_whose_save_was_lost(cards)

        with patch.object(main, "_save_may_be_running", lambda s: str(s.id) == fed_as_saving):
            feed = {c["id"]: c["status"] for c in (await api.get("/api/suggestions/")).json()}
            answer = await api.post("/api/suggestions/clear", json={})

        assert feed == {fed_as_failed: "failed", fed_as_saving: "saving"}
        assert answer.json() == {"cleared": 1}
        assert (stored(cards, fed_as_failed).status, stored(cards, fed_as_saving).status) == ("cleared", "saving")

    async def test_clear_leaves_one_saved_again_while_it_was_deciding(self, api, cards):
        lost = a_card_whose_save_was_lost(cards)

        async def saved_again_first(change: dict) -> None:
            if change == {"status": "cleared"} and stored(cards, lost).status == "saving":
                stored(cards, lost).saving_since = datetime.now(timezone.utc)

        with patch.object(FakeSuggestionDocument, "before_write", saved_again_first):
            answer = await api.post("/api/suggestions/clear", json={"ids": [lost]})

        assert answer.json() == {"cleared": 0}
        assert stored(cards, lost).status == "saving"

    async def test_not_for_me_takes_it_off_the_feed(self, api, cards):
        lost = a_card_whose_save_was_lost(cards)

        answer = await api.patch(f"/api/suggestions/{lost}", json={"status": "dismissed"})

        assert answer.json()["status"] == "dismissed"
        assert await in_the_feed(api, lost) is None


class TestShutdown:
    async def test_fails_the_saves_it_is_running_at_once(self, api, cards):
        card = a_card(cards)
        reached = asyncio.Event()
        save_recipe = saved_recipe()

        with a_model(async_claude=a_model_that_never_answers(reached), _save_recipe=save_recipe):
            await save(api, card)
            await reached.wait()
            await main._end_running_work()
        after = await in_the_feed(api, card)

        assert (after["status"], after["error"]) == ("failed", main.SAVE_INTERRUPTED)
        assert stored(cards, card).status == "failed"
        assert not main._suggestion_save_tasks
        save_recipe.assert_not_called()

    async def test_during_the_write_lets_a_saved_card_say_saved(self, api, cards):
        card = a_card(cards)
        writing = asyncio.Event()
        release = asyncio.Event()

        async def slowly_once_made(change: dict) -> None:
            if change.get("status") == "saved":
                writing.set()
                await release.wait()

        with a_model(), patch.object(FakeSuggestionDocument, "before_write", slowly_once_made):
            await save(api, card, LIST_ID)
            await writing.wait()
            ending = asyncio.create_task(main._end_running_work())
            await asyncio.sleep(0.01)
            still_waiting = not ending.done()
            release.set()
            await ending

        assert still_waiting
        assert (stored(cards, card).status, stored(cards, card).recipe_id) == ("saved", RECIPE_ID)
        main._add_recipe_to_list_id.assert_awaited_once()

    async def test_the_app_shutting_down_ends_its_saves(self, cards):
        card = a_card(cards)
        reached = asyncio.Event()

        with (
            a_model(async_claude=a_model_that_never_answers(reached)),
            patch.multiple(main, get_motor_client=MagicMock(), init_beanie=AsyncMock()),
        ):
            async with main.lifespan(main.app):
                transport = httpx.ASGITransport(app=main.app)
                async with httpx.AsyncClient(transport=transport, base_url="http://test") as api:
                    await save(api, card)
                await reached.wait()

        assert stored(cards, card).status == "failed"
