import asyncio
from datetime import datetime, timezone
from types import SimpleNamespace
from typing import ClassVar
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest
from beanie import PydanticObjectId
from pydantic import BaseModel, create_model

import main
from data_models import SuggestionDocument
from tests.test_recipe_jobs import RECIPE_ID, a_model, a_model_that_never_answers, saved_recipe

LIST_ID = "64b7f0c2a1b2c3d4e5f60799"

_OPERATORS = {
    "$in": lambda have, wanted: have in wanted,
    "$nin": lambda have, wanted: have not in wanted,
    # As Mongo compares: a missing or null field is not less than a date.
    "$lt": lambda have, bound: have is not None and have < bound,
}


def _matches(doc: dict, query: dict) -> bool:
    for key, wanted in query.items():
        if key == "$or":
            found = any(_matches(doc, option) for option in wanted)
        elif isinstance(wanted, dict):
            found = all(_OPERATORS[op](doc.get(key), arg) for op, arg in wanted.items())
        else:
            found = doc.get(key) == wanted
        if not found:
            return False
    return True


class _Found:
    def __init__(self, docs):
        self.docs = docs

    def sort(self, _key):
        return self

    def limit(self, _count):
        return self

    async def to_list(self):
        return [doc.model_copy() for doc in self.docs]

    async def update(self, change: dict):
        for doc in self.docs:
            for field, value in change["$set"].items():
                setattr(doc, field, value)
        return SimpleNamespace(modified_count=len(self.docs))


class _OverADict(BaseModel):
    """What the endpoints ask of a suggestion document, answered from a dict."""

    store: ClassVar[dict] = {}

    async def save(self):
        await asyncio.sleep(0)
        self.store[self.id] = self.model_copy()

    @classmethod
    async def get(cls, suggestion_id):
        await asyncio.sleep(0)
        found = cls.store.get(suggestion_id)
        return found and found.model_copy()

    @classmethod
    def find(cls, query: dict):
        return _Found([
            doc for doc in cls.store.values()
            if _matches({**doc.model_dump(exclude={"id"}), "_id": doc.id}, query)
        ])


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
    main._suggestion_save_tasks.clear()
    with patch.multiple(
        main,
        SuggestionDocument=FakeSuggestionDocument,
        RECIPE_JOB_WRITE_PAUSES=(0, 0, 0),
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
    return a_card(cards, "saving", saving_for=main.RECIPE_JOB_STALE_AFTER * 1.1)


def a_card_being_saved(cards: dict) -> str:
    return a_card(cards, "saving", saving_for=main.RECIPE_JOB_STALE_AFTER * 0.9)


def stored(cards: dict, card: str) -> FakeSuggestionDocument:
    return cards[PydanticObjectId(card)]


async def in_the_feed(api: httpx.AsyncClient, card: str) -> dict | None:
    feed = (await api.get("/api/suggestions/")).json()
    return next((c for c in feed if c["id"] == card), None)


def save(api: httpx.AsyncClient, card: str, list_id: str | None = None):
    return api.post(f"/api/suggestions/{card}/save", json={"list_id": list_id})


async def saves_have_ended() -> None:
    await asyncio.gather(*list(main._suggestion_save_tasks))


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

    async def test_a_save_onto_a_list_puts_the_recipe_there_when_it_lands(self, api, cards):
        card = a_card(cards)

        made = saved_recipe()

        with a_model(_save_recipe=made):
            await save(api, card, LIST_ID)
            await saves_have_ended()

        main._add_recipe_to_list_id.assert_awaited_once_with(LIST_ID, made.return_value)

    async def test_a_recipe_that_cannot_go_on_its_list_fails_the_card(self, api, cards):
        card = a_card(cards)
        main._add_recipe_to_list_id.side_effect = ConnectionError("mongo is away")

        with a_model():
            await save(api, card, LIST_ID)
            await saves_have_ended()
        after = await in_the_feed(api, card)

        assert (after["status"], after["error"]) == ("failed", "mongo is away")

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

    async def test_a_save_that_runs_past_the_time_limit_is_cancelled_and_fails(self, api, cards):
        card = a_card(cards)
        save_recipe = saved_recipe()

        with a_model(
            async_claude=a_model_that_never_answers(),
            _save_recipe=save_recipe,
            RECIPE_JOB_TIME_LIMIT=main.RECIPE_JOB_TIME_LIMIT * 0,
        ):
            await save(api, card)
            await saves_have_ended()
        after = await in_the_feed(api, card)

        assert (after["status"], after["error"]) == ("failed", main.SAVE_INTERRUPTED)
        assert stored(cards, card).status == "failed"
        save_recipe.assert_not_called()


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

        answer = await api.post("/api/suggestions/clear", json={"ids": [fresh, lost]})

        assert answer.json() == {"cleared": 1}
        assert stored(cards, lost).status == "cleared"
        assert (stored(cards, fresh).status, stored(cards, other).status) == ("saving", "saving")

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
        save_at_once = FakeSuggestionDocument.save

        async def save_slowly_once_made(self):
            if self.status == "saved":
                writing.set()
                await release.wait()
            await save_at_once(self)

        with a_model(), patch.object(FakeSuggestionDocument, "save", save_slowly_once_made):
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
