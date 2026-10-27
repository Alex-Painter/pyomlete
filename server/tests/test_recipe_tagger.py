"""Recipes are tagged with what they're built on, after saving and never during it."""

import json
from unittest.mock import AsyncMock, MagicMock

import httpx
import pytest
from beanie import init_beanie
from mongomock_motor import AsyncMongoMockClient

import main
from data_models import IngredientDocument, ListDocument, RecipeDocument, UserSettingsDocument
from lib.types import IngredientRecipe
from recipe_tagger import MODEL, tag_and_store, tag_recipe
from scripts.backfill_tags import backfill

PASTA = {
    "base": "pasta", "main": "veggie", "mood": "comforting", "cuisine": "italian",
    "traits": {"oily_fish": False, "red_meat": False, "veg_led": True, "legumes": False},
}


def answers(*payloads) -> MagicMock:
    """An AsyncAnthropic stand-in that answers each call with the next payload."""
    def message(payload):
        m = MagicMock()
        m.content = [MagicMock(text=payload if isinstance(payload, str) else json.dumps(payload))]
        m.usage = MagicMock(input_tokens=420, output_tokens=60)
        return m

    client = MagicMock()
    client.messages.create = AsyncMock(side_effect=[message(p) for p in payloads])
    return client


@pytest.fixture
async def db():
    client = AsyncMongoMockClient()
    await init_beanie(
        database=client["tags"],
        document_models=[IngredientDocument, RecipeDocument, ListDocument, UserSettingsDocument],
    )
    yield
    client.close()


async def recipe(title="Spinach pasta", *ingredients, tags=None) -> RecipeDocument:
    doc = RecipeDocument(
        title=title,
        instructions=["Boil the pasta.", "Wilt the spinach."],
        ingredients=[IngredientRecipe(name=n, unit="g", amount=100) for n in ingredients or ("pasta", "spinach")],
        tags=tags,
    )
    await doc.insert()
    return doc


async def test_tags_come_back_validated(db):
    client = answers(PASTA)
    tags = await tag_recipe(await recipe(), client)
    assert tags.base == "pasta" and tags.main == "veggie" and tags.traits.veg_led
    kwargs = client.messages.create.call_args.kwargs
    assert kwargs["model"] == MODEL
    assert kwargs["output_config"]["format"]["type"] == "json_schema"


async def test_an_answer_outside_the_sets_is_retried_once(db):
    client = answers({**PASTA, "base": "quinoa"}, PASTA)
    tags = await tag_recipe(await recipe(), client)
    assert tags.base == "pasta"
    assert client.messages.create.await_count == 2


async def test_two_bad_answers_leave_the_recipe_untagged(db):
    doc = await recipe()
    client = answers("not json", {**PASTA, "main": "tofu"})
    assert await tag_and_store(doc.id, client) is False
    assert (await RecipeDocument.get(doc.id)).tags is None


async def test_storing_tags_keeps_an_edit_made_meanwhile(db):
    doc = await recipe()
    stale = await RecipeDocument.get(doc.id)
    doc.title = "Spinach and ricotta pasta"
    await doc.save()
    assert await tag_and_store(stale.id, answers(PASTA)) is True
    stored = await RecipeDocument.get(doc.id)
    assert stored.title == "Spinach and ricotta pasta"
    assert stored.tags.base == "pasta"


async def test_backfill_tags_only_what_needs_it(db):
    await recipe("A")
    await recipe("B")
    await recipe("C", tags=PASTA)
    client = answers(PASTA, PASTA)
    assert await backfill(client) == (2, 1, 0)
    # A second run, or one after a crash, has nothing left to do.
    assert await backfill(answers()) == (0, 3, 0)
    assert await backfill(answers(PASTA, PASTA, PASTA), force=True) == (3, 0, 0)


async def test_saving_and_editing_tag_in_the_background(db, no_background_tagging):
    transport = httpx.ASGITransport(app=main.app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test/api") as api:
        doc = await recipe()
        body = {
            "title": "Tofu pasta",
            "instructions": ["Cook."],
            "ingredients": [{"name": "tofu", "unit": "g", "amount": 200}],
        }
        assert (await api.put(f"/recipes/{doc.id}", json=body)).status_code == 200
        assert no_background_tagging == [doc.id]

        await RecipeDocument.find_one(RecipeDocument.id == doc.id).update({"$set": {"tags": PASTA}})
        rows = (await api.get("/recipes/")).json()
        assert rows[0]["tags"]["base"] == "pasta"
