"""Chef's memory: meals cooked, told and inferred preferences, and distil.

The models are FunctionModels, so nothing reaches Anthropic; the database is
in memory.
"""

from uuid import uuid4

import pytest
from beanie import init_beanie
from httpx import ASGITransport, AsyncClient
from mongomock_motor import AsyncMongoMockClient
from pydantic_ai.messages import ModelMessage, ModelResponse, ToolCallPart, UserPromptPart
from pydantic_ai.models.function import AgentInfo, FunctionModel

import main
from chef import memory as chef_memory
from data_models import (
    ChefActionDocument,
    ListDocument,
    MealLogDocument,
    PreferenceDocument,
    RecipeDocument,
    SuggestionDocument,
    UserSettingsDocument,
)
from services import memory
from tests.test_chef_chat import calling, say


@pytest.fixture
async def api():
    client = AsyncMongoMockClient()
    await init_beanie(
        database=client["omlete_test"],
        document_models=[
            RecipeDocument,
            ListDocument,
            UserSettingsDocument,
            SuggestionDocument,
            ChefActionDocument,
            MealLogDocument,
            PreferenceDocument,
        ],
    )
    async with AsyncClient(transport=ASGITransport(app=main.app), base_url="http://t") as c:
        yield c


async def a_recipe(title="Salmon traybake", rating=None) -> RecipeDocument:
    r = RecipeDocument(title=title, instructions=["Cook."], ingredients=[], rating=rating)
    await r.insert()
    return r


def inferring(*prefs: dict):
    """Distil's model, answering with these preferences and keeping the prompt it saw."""
    seen: list[str] = []

    async def respond(messages: list[ModelMessage], info: AgentInfo) -> ModelResponse:
        seen.extend(p.content for m in messages for p in m.parts if isinstance(p, UserPromptPart))
        return ModelResponse(
            parts=[ToolCallPart(info.output_tools[0].name, {"preferences": list(prefs)})]
        )

    return chef_memory.agent.override(model=FunctionModel(respond)), seen


FISH = {"subject": "Oily fish", "stance": "more", "evidence": "Cooked salmon 3 times", "strength": 0.8}
QUICK = {"subject": "quick dinners", "stance": "prefer", "evidence": "Most are under 30 min", "strength": 0.5}


def rows(prefs):
    return sorted((p.source, p.key, p.stance, p.retired_at is not None) for p in prefs)


# --- Meals ---


async def test_finishing_cook_and_rating_after_write_one_meal(api):
    recipe = await a_recipe()
    key = str(uuid4())
    r = await api.put(f"/api/meals/{key}", json={"recipe_id": str(recipe.id)})
    assert r.status_code == 200 and r.json()["rating"] is None
    r = await api.put(f"/api/meals/{key}", json={"recipe_id": str(recipe.id), "rating": 4})
    assert r.json()["rating"] == 4
    meals = await MealLogDocument.find_all().to_list()
    assert [(m.id, m.rating) for m in meals] == [(key, 4)]


async def test_a_meal_of_no_recipe_is_a_404(api):
    r = await api.put(f"/api/meals/{uuid4()}", json={"recipe_id": "5f0000000000000000000000"})
    assert r.status_code == 404


# --- Preferences ---


async def test_told_preferences_are_shown_and_saying_again_replaces(api):
    await api.post("/api/preferences", json={"subject": "Mushrooms", "stance": "avoid"})
    r = await api.post("/api/preferences", json={"subject": " mushroom ", "stance": "never"})
    assert r.json()["stance"] == "never"
    shown = (await api.get("/api/preferences")).json()
    assert [(p["subject"], p["stance"], p["source"]) for p in shown] == [("mushroom", "never", "told")]
    assert shown[0]["evidence"].startswith("You said so on ")


async def test_forgetting_hides_it_and_undo_brings_it_back(api):
    pref = (await api.post("/api/preferences", json={"subject": "fish", "stance": "more"})).json()
    r = await api.patch(f"/api/preferences/{pref['id']}", json={"forgotten": True})
    assert r.json()["forgotten"] is True
    assert (await api.get("/api/preferences")).json() == []
    await api.patch(f"/api/preferences/{pref['id']}", json={"forgotten": False})
    assert [p["subject"] for p in (await api.get("/api/preferences")).json()] == ["fish"]


async def test_a_told_preference_wins_over_an_inferred_one(api):
    await a_recipe(rating=5)
    model, _ = inferring(FISH, QUICK)
    with model:
        await chef_memory.distil()
    await memory.remember("oily fish", "less")
    shown = (await api.get("/api/preferences")).json()
    assert [(p["subject"], p["stance"], p["source"]) for p in shown] == [
        ("oily fish", "less", "told"),
        ("quick dinners", "prefer", "inferred"),
    ]


# --- Distil ---


async def test_distil_twice_leaves_the_same_rows(api):
    await a_recipe(rating=5)
    model, _ = inferring(FISH, QUICK)
    with model:
        await chef_memory.distil()
        first = rows(await PreferenceDocument.find_all().to_list())
        await chef_memory.distil()
    assert rows(await PreferenceDocument.find_all().to_list()) == first
    assert len(first) == 2


async def test_distil_drops_what_it_no_longer_sees_but_keeps_what_was_forgotten(api):
    await a_recipe(rating=5)
    model, _ = inferring(FISH, QUICK)
    with model:
        await chef_memory.distil()
    fish = await PreferenceDocument.find_one(PreferenceDocument.key == "oily fish")
    await memory.set_forgotten(fish.id, True)

    model, _ = inferring(FISH)
    with model:
        await chef_memory.distil()
    assert rows(await PreferenceDocument.find_all().to_list()) == [("inferred", "oily fish", "more", True)]


async def test_distil_reads_meals_ratings_and_told_preferences(api):
    salmon = await a_recipe(rating=5)
    for _ in range(3):
        await memory.log_meal(str(uuid4()), str(salmon.id))
    await memory.remember("mushrooms", "never")
    model, seen = inferring()
    with model:
        await chef_memory.distil()
    assert "Cooked in the last 12 weeks: Salmon traybake (3x)." in seen[0]
    assert "Their ratings: Salmon traybake 5/5." in seen[0]
    assert "Already told: They told you: Never mushrooms." in seen[0]


async def test_with_nothing_to_go_on_distil_asks_no_one(api):
    model, seen = inferring(FISH)
    with model:
        assert await chef_memory.distil() == []
    assert seen == []


def test_subjects_match_plural_or_not():
    never = [PreferenceDocument(subject="Mushrooms", stance="never", evidence="", source="told", key=memory.key_for("Mushrooms"))]
    assert memory.names_any("Creamy mushroom risotto", never)
    assert memory.names_any("Garlic MUSHROOMS on toast", never)
    assert not memory.names_any("Mush peas", never)
    assert memory.key_for("Tomatoes") == memory.key_for("tomato")


# --- In chat ---


async def test_chef_remembers_and_undo_forgets(api):
    model, seen = calling(("remember", {"subject": "mushrooms", "stance": "never"}))
    await say(api, model, "no mushrooms ever")
    assert seen["returns"][0]["done"] == "Never mushrooms"
    assert [p.subject for p in await memory.active()] == ["mushrooms"]

    await api.post(f"/api/chef/actions/{seen['returns'][0]['undo']}/undo")
    assert await memory.active() == []


async def test_saying_it_again_in_chat_undoes_back_to_what_it_was(api):
    await memory.remember("fish", "more")
    model, seen = calling(("remember", {"subject": "fish", "stance": "less"}))
    await say(api, model, "actually less fish")
    await api.post(f"/api/chef/actions/{seen['returns'][0]['undo']}/undo")
    assert [(p.subject, p.stance) for p in await memory.active()] == [("fish", "more")]


async def test_chef_forgets_an_inference_and_knows_what_it_knows(api):
    await a_recipe(rating=5)
    model, _ = inferring(FISH)
    with model:
        await chef_memory.distil()

    model, seen = calling()
    await say(api, model, "what do you know about me?")
    assert "You've noticed: More Oily fish (Cooked salmon 3 times)." in seen["instructions"]

    model, seen = calling(("forget", {"subject": "oily fish"}))
    await say(api, model, "I'm not that into fish")
    assert seen["returns"][0]["done"] == "Forgot Oily fish"
    assert await memory.active() == []

    model, seen = calling(("forget", {"subject": "kale"}))
    await say(api, model, "forget kale")
    assert seen["returns"][0] == {"error": "Nothing remembered about kale"}


async def test_chef_logs_a_meal_and_undo_takes_it_away(api):
    recipe = await a_recipe()
    model, seen = calling(("log_meal", {"recipe_id": str(recipe.id), "stars": 4}))
    await say(api, model, "we had the salmon last night, it was good")
    assert seen["returns"][0]["done"] == "Noted you cooked Salmon traybake"
    assert [m.rating for m in await MealLogDocument.find_all().to_list()] == [4]

    await api.post(f"/api/chef/actions/{seen['returns'][0]['undo']}/undo")
    assert await MealLogDocument.find_all().count() == 0
