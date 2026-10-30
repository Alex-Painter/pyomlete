"""Chef plans a week: the card, the rules it keeps, Make the list and its Undo.

The planner is a FunctionModel, so nothing reaches Anthropic; the database is
in memory, and a new idea's save is a mock (tests/test_suggestion_saves.py
covers saving).
"""

import asyncio
from datetime import date, datetime, time, timedelta, timezone
from unittest.mock import AsyncMock, patch
from uuid import uuid4

import pytest
from beanie import init_beanie
from httpx import ASGITransport, AsyncClient
from mongomock_motor import AsyncMongoMockClient
from pydantic_ai.messages import ModelMessage, ModelResponse, RetryPromptPart, ToolCallPart
from pydantic_ai.models.function import AgentInfo, FunctionModel

import main
from chef import run, week
from data_models import (
    ChefActionDocument,
    IngredientDocument,
    ListDocument,
    MealLogDocument,
    PreferenceDocument,
    RecipeDocument,
    SuggestionDocument,
    UserSettingsDocument,
    WeekPlanDocument,
)
from lib.types import IngredientRecipe
from services import lists, memory
from tests.test_chef_chat import calling, say


@pytest.fixture
async def api():
    client = AsyncMongoMockClient()
    await init_beanie(
        database=client["omlete_test"],
        document_models=[
            IngredientDocument,
            RecipeDocument,
            ListDocument,
            UserSettingsDocument,
            SuggestionDocument,
            ChefActionDocument,
            MealLogDocument,
            PreferenceDocument,
            WeekPlanDocument,
        ],
    )
    async with AsyncClient(transport=ASGITransport(app=main.app), base_url="http://t") as c:
        yield c


@pytest.fixture(autouse=True)
def saves():
    """A new idea's save, which here only records what it was asked."""
    start = AsyncMock()
    with patch.object(week, "start_save", start):
        yield start


async def a_recipe(title: str, rating: int | None = 5, ingredient: str = "rice") -> RecipeDocument:
    r = RecipeDocument(
        title=title,
        instructions=["Cook."],
        ingredients=[IngredientRecipe(name=ingredient, unit="g", amount=100, category="Pantry & Dry Goods")],
        rating=rating,
    )
    await r.insert()
    return r


def idea(day: int, title: str, **kw) -> dict:
    return {
        "day": day,
        "title": title,
        "reason": f"Because {title}",
        "description": f"A lovely {title}.",
        "source_url": f"https://example.com/{day}",
        **kw,
    }


def known(day: int, recipe: RecipeDocument) -> dict:
    return {"day": day, "recipe_id": str(recipe.id), "title": recipe.title, "reason": "You loved it"}


def planner(*answers: list[dict]):
    """A planner answering with these weeks in turn, keeping what it was sent back for."""
    seen: dict = {"retries": [], "prompt": None}

    async def respond(messages: list[ModelMessage], info: AgentInfo) -> ModelResponse:
        seen["prompt"] = seen["prompt"] or messages[0].parts[-1].content
        retries = [p for m in messages for p in m.parts if isinstance(p, RetryPromptPart)]
        seen["retries"] = [r.content for r in retries]
        meals = answers[min(len(retries), len(answers) - 1)]
        return ModelResponse(
            parts=[ToolCallPart(info.output_tools[0].name, {"note": "A good week.", "meals": meals})]
        )

    return week.agent.override(model=FunctionModel(respond)), seen


async def library(n: int = 3) -> list[RecipeDocument]:
    return [await a_recipe(t) for t in ["Dal", "Pho", "Tacos", "Risotto"][:n]]


def a_week(recipes: list[RecipeDocument]) -> list[dict]:
    return [known(0, recipes[0]), known(2, recipes[1]), known(4, recipes[2]), idea(1, "Laksa"), idea(5, "Bibimbap")]


# --- Planning ---


def test_the_week_planned_is_this_one_or_next_on_its_last_day():
    saturday = 5
    assert week.week_to_plan(date(2026, 10, 25), saturday) == date(2026, 10, 24)
    assert week.week_to_plan(date(2026, 10, 24), saturday) == date(2026, 10, 24)
    assert week.week_to_plan(date(2026, 10, 30), saturday) == date(2026, 10, 31)


async def test_plans_three_of_theirs_and_two_new_on_the_card(api):
    recipes = await library()
    model, seen = planner(a_week(recipes))
    with model:
        r = await api.post("/api/weeks/plan", json={})
    plan = r.json()
    assert [(m["title"], m["is_new"]) for m in plan["meals"]] == [
        ("Dal", False), ("Laksa", True), ("Pho", False), ("Tacos", False), ("Bibimbap", True),
    ]
    week_of = await week.current_week()
    assert plan["week_of"] == week_of.isoformat()
    assert plan["meals"][1]["day"] == (week_of + timedelta(days=1)).isoformat()
    assert "Dal, 5" in seen["prompt"]
    assert (await api.get("/api/weeks/current")).json()["id"] == plan["id"]


async def test_a_plan_waiting_is_kept_unless_asked_afresh(api):
    recipes = await library()
    model, _ = planner(a_week(recipes))
    with model:
        first = (await api.post("/api/weeks/plan", json={})).json()
        again = (await api.post("/api/weeks/plan", json={})).json()
        fresh = (await api.post("/api/weeks/plan", json={"fresh": True})).json()
    assert first["id"] == again["id"] == fresh["id"]
    assert await WeekPlanDocument.find_all().count() == 1


async def test_a_meal_had_lately_is_sent_back(api):
    recipes = await library(4)
    await memory.log_meal(str(uuid4()), str(recipes[0].id))
    model, seen = planner(a_week(recipes), a_week(recipes[1:]))
    with model:
        plan = (await api.post("/api/weeks/plan", json={})).json()
    assert seen["retries"] == ["They had Dal in the last 3 weeks. Choose another."]
    assert "Dal" not in [m["title"] for m in plan["meals"]]


async def test_a_never_is_sent_back_for_their_recipes_and_new_ideas(api):
    recipes = await library(3)
    shroom = await a_recipe("Stroganoff", ingredient="mushrooms")
    await memory.remember("mushroom", "never")
    bad_recipe = [known(0, shroom), *a_week(recipes)[1:]]
    bad_idea = [*a_week(recipes)[:3], idea(1, "Mushroom laksa"), idea(5, "Bibimbap")]
    model, seen = planner(bad_recipe, bad_idea, a_week(recipes))
    with model:
        await api.post("/api/weeks/plan", json={})
    assert seen["retries"] == [
        "Stroganoff has something they never eat. Choose another.",
        "Mushroom laksa has something they never eat. Choose another.",
    ]


async def test_with_few_recipes_the_rest_are_new(api):
    only = await a_recipe("Dal")
    meals = [known(0, only), *(idea(d, f"Idea {d}") for d in (1, 2, 3, 4))]
    model, seen = planner([known(0, only), idea(1, "Laksa")], meals)
    with model:
        plan = (await api.post("/api/weeks/plan", json={})).json()
    assert seen["retries"] == ["Plan exactly 5 dinners."]
    assert sum(m["is_new"] for m in plan["meals"]) == 4


# --- Make the list ---


async def test_make_the_list_puts_theirs_on_their_days_and_saves_the_new_ones(api, saves):
    recipes = await library()
    model, _ = planner(a_week(recipes))
    with model:
        plan = (await api.post("/api/weeks/plan", json={})).json()

    made = (await api.post(f"/api/weeks/{plan['id']}/make")).json()
    lst = await ListDocument.get(made["list_id"])
    planned = {d.date.isoformat(): (d.recipe_id, d.origin) for d in lst.days if d.recipe_id}
    assert planned == {
        m["day"]: (m["recipe_id"], "chef") for m in plan["meals"] if not m["is_new"]
    }
    cards = await SuggestionDocument.find_all().to_list()
    assert sorted((c.title, c.origin, c.plan_day.isoformat()) for c in cards) == sorted(
        (m["title"], "week", m["day"]) for m in plan["meals"] if m["is_new"]
    )
    assert sorted(call.args[0].title for call in saves.await_args_list) == ["Bibimbap", "Laksa"]
    assert {call.args[1] for call in saves.await_args_list} == {made["list_id"]}
    # The card is done, and the ideas stay out of Discover.
    assert (await api.get("/api/weeks/current")).json() is None
    assert (await api.get("/api/suggestions/")).json() == []
    assert all([await week.still_wanted(c) for c in cards])


async def test_undo_takes_the_list_away_and_brings_the_card_back(api):
    recipes = await library()
    model, _ = planner(a_week(recipes))
    with model:
        plan = (await api.post("/api/weeks/plan", json={})).json()
    made = (await api.post(f"/api/weeks/{plan['id']}/make")).json()

    r = await api.post(f"/api/chef/actions/{made['undo']}/undo")
    assert r.status_code == 200
    assert await ListDocument.get(made["list_id"]) is None
    assert (await api.get("/api/weeks/current")).json()["id"] == plan["id"]
    # An idea saved after the Undo goes on no list.
    assert not any([await week.still_wanted(c) for c in await SuggestionDocument.find_all().to_list()])


async def test_the_week_already_has_a_list_so_its_free_evenings_are_filled(api):
    recipes = await library()
    model, _ = planner(a_week(recipes))
    with model:
        plan = (await api.post("/api/weeks/plan", json={})).json()
    week_of = date.fromisoformat(plan["week_of"])
    mine = await a_recipe("Mine")
    existing = await lists.create(week_of)
    await lists.set_day(existing.id, week_of, str(mine.id))

    made = (await api.post(f"/api/weeks/{plan['id']}/make")).json()
    assert made["list_id"] == str(existing.id)
    lst = await ListDocument.get(existing.id)
    by_day = {d.date: d.recipe_id for d in lst.days}
    assert by_day[week_of] == str(mine.id)
    # Dal was for that evening, so it's on the list for any day.
    assert str(recipes[0].id) in lst.recipes

    await api.post(f"/api/chef/actions/{made['undo']}/undo")
    lst = await ListDocument.get(existing.id)
    assert lst.recipes == [str(mine.id)]


async def test_a_new_idea_not_yet_on_its_list_is_shown_until_it_lands(api):
    recipes = await library()
    model, _ = planner(a_week(recipes))
    with model:
        plan = (await api.post("/api/weeks/plan", json={})).json()
    made = (await api.post(f"/api/weeks/{plan['id']}/make")).json()
    laksa = await SuggestionDocument.find_one(SuggestionDocument.title == "Laksa")
    bibimbap = await SuggestionDocument.find_one(SuggestionDocument.title == "Bibimbap")
    await laksa.set({"status": "saving", "saving_since": datetime.now(timezone.utc)})
    await bibimbap.set({"status": "failed", "error": "The site did not respond"})

    ideas = (await api.get("/api/weeks/ideas")).json()
    assert [(i["title"], i["status"], i["list_id"]) for i in ideas] == [
        ("Laksa", "saving", made["list_id"]),
        ("Bibimbap", "failed", made["list_id"]),
    ]
    assert ideas[1]["day"] == plan["meals"][4]["day"]

    await laksa.set({"status": "saved"})
    await api.patch(f"/api/suggestions/{bibimbap.id}", json={"status": "cleared"})
    assert (await api.get("/api/weeks/ideas")).json() == []


async def test_ideas_are_not_shown_once_the_week_is_undone_or_over(api):
    recipes = await library()
    model, _ = planner(a_week(recipes))
    with model:
        plan = (await api.post("/api/weeks/plan", json={})).json()
    made = (await api.post(f"/api/weeks/{plan['id']}/make")).json()
    await SuggestionDocument.find_all().update({"$set": {"status": "failed"}})
    assert len((await api.get("/api/weeks/ideas")).json()) == 2

    await api.post(f"/api/chef/actions/{made['undo']}/undo")
    assert (await api.get("/api/weeks/ideas")).json() == []

    w = await WeekPlanDocument.get(plan["id"])
    await w.set({"status": "made", "week_of": date.today() - timedelta(days=7)})
    assert (await api.get("/api/weeks/ideas")).json() == []


async def test_a_week_made_cannot_be_made_twice(api):
    recipes = await library()
    model, _ = planner(a_week(recipes))
    with model:
        plan = (await api.post("/api/weeks/plan", json={})).json()
    await api.post(f"/api/weeks/{plan['id']}/make")
    assert (await api.post(f"/api/weeks/{plan['id']}/make")).status_code == 409


async def test_not_this_week_hides_the_card(api):
    recipes = await library()
    model, _ = planner(a_week(recipes))
    with model:
        plan = (await api.post("/api/weeks/plan", json={})).json()
    assert (await api.post(f"/api/weeks/{plan['id']}/skip")).status_code == 200
    assert (await api.get("/api/weeks/current")).json() is None
    assert await ListDocument.find_all().count() == 0


# --- In chat ---


async def test_chef_plans_the_week_and_makes_the_list(api):
    recipes = await library()
    model, _ = planner(a_week(recipes))
    with model:
        chat_model, seen = calling(("plan_week", {}))
        await say(api, chat_model, "plan my week")
    planned = seen["returns"][0]
    assert planned["done"].startswith("Planned the week of")
    assert [m["new_idea"] for m in planned["meals"]] == [False, True, False, False, True]

    chat_model, seen = calling(("make_week_list", {"plan_id": planned["plan_id"]}))
    await say(api, chat_model, "make the list")
    made = seen["returns"][0]
    assert made["done"].startswith("Made Week of")
    await api.post(f"/api/chef/actions/{made['undo']}/undo")
    assert await ListDocument.find_all().count() == 0


async def test_a_planner_that_keeps_breaking_the_rules_is_a_502(api):
    recipes = await library()
    model, _ = planner([known(0, recipes[0])])
    with model:
        r = await api.post("/api/weeks/plan", json={})
    assert r.status_code == 502
    assert await WeekPlanDocument.find_all().count() == 0


# --- The weekly run ---


def a_settings(**kw) -> UserSettingsDocument:
    return UserSettingsDocument(**kw)


def test_the_run_is_due_for_a_few_hours_after_the_chosen_hour():
    s = a_settings()  # Sunday 08:00, weeks from Saturday
    sunday = datetime(2026, 11, 1, 8, 5)
    assert run.due(sunday, s) == date(2026, 11, 7)
    assert run.due(sunday.replace(hour=11, minute=59), s) == date(2026, 11, 7)
    assert run.due(sunday.replace(hour=12), s) is None
    assert run.due(sunday.replace(hour=7, minute=59), s) is None
    assert run.due(datetime(2026, 11, 2, 8), s) is None
    assert run.due(sunday, a_settings(weekly_plan=False)) is None
    # On a week's first day, it plans the week starting that day.
    assert run.due(datetime(2026, 11, 2, 18), a_settings(weekly_plan_weekday=0, weekly_plan_hour=18, week_start_weekday=0)) == date(2026, 11, 2)


async def test_the_run_learns_then_plans_the_coming_week_once(api, monkeypatch):
    recipes = await library()
    distilled = AsyncMock()
    monkeypatch.setattr(run.chef_memory, "distil", distilled)
    model, _ = planner(a_week(recipes))
    sunday = datetime.combine(date.today() + timedelta(days=(6 - date.today().weekday()) % 7), time(8, 30))
    with model:
        plan = await run.weekly(sunday)
        again = await run.weekly(sunday.replace(hour=9))
    assert plan.week_of == week.next_week_from(sunday.date(), 5)
    assert again is None
    assert distilled.await_count == 1
    # Waiting on Home, even before its week begins.
    assert plan.week_of > await week.current_week()
    assert (await api.get("/api/weeks/current")).json()["id"] == str(plan.id)


async def test_the_run_leaves_a_week_already_seen_alone(api):
    recipes = await library()
    model, _ = planner(a_week(recipes))
    with model:
        plan = (await api.post("/api/weeks/plan", json={})).json()
        await api.post(f"/api/weeks/{plan['id']}/skip")
        week_of = date.fromisoformat(plan["week_of"])
        assert await run.weekly(datetime.combine(week_of, time(8)), force=True) is None
    assert await WeekPlanDocument.find_all().count() == 1


async def test_the_weekly_plan_time_is_a_setting_chef_can_change(api):
    r = await api.get("/api/settings/weekly-plan")
    assert r.json() == {"weekly_plan": True, "weekly_plan_weekday": 6, "weekly_plan_hour": 8}
    body = {"weekly_plan": True, "weekly_plan_weekday": 4, "weekly_plan_hour": 19}
    assert (await api.put("/api/settings/weekly-plan", json=body)).json() == body
    assert (await api.put("/api/settings/weekly-plan", json={**body, "weekly_plan_hour": 24})).status_code == 422

    chat_model, seen = calling(("set_weekly_plan", {"weekday": 6}))
    await say(api, chat_model, "plan on sundays instead")
    assert seen["returns"][0]["done"] == "Chef plans your week on Sundays at 19:00"
    await api.post(f"/api/chef/actions/{seen['returns'][0]['undo']}/undo")
    assert (await api.get("/api/settings/weekly-plan")).json() == body


async def test_the_server_runs_it_and_a_new_time_wakes_it(api, monkeypatch):
    weekly = AsyncMock(return_value=None)
    monkeypatch.setattr(run, "weekly", weekly)
    task = asyncio.create_task(run.keep_planning())
    try:
        for _ in range(5):
            await asyncio.sleep(0)
        assert weekly.await_count == 1
        await api.put(
            "/api/settings/weekly-plan",
            json={"weekly_plan": True, "weekly_plan_weekday": 2, "weekly_plan_hour": 7},
        )
        for _ in range(5):
            await asyncio.sleep(0)
        assert weekly.await_count == 2
    finally:
        task.cancel()


def test_the_next_run_is_a_week_after_the_last_chosen_time():
    s = a_settings()
    assert run.last_chosen(datetime(2026, 11, 1, 8), s) == datetime(2026, 11, 1, 8)
    assert run.last_chosen(datetime(2026, 11, 1, 7, 59), s) == datetime(2026, 10, 25, 8)
    assert run.last_chosen(datetime(2026, 11, 4, 12), s) + timedelta(days=7) == datetime(2026, 11, 8, 8)
