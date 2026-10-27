import os
from uuid import uuid4

import httpx
import pytest
from beanie import init_beanie
from mongomock_motor import AsyncMongoMockClient
from motor.motor_asyncio import AsyncIOMotorClient

import main
from data_models import (
    IngredientDocument,
    ListDocument,
    RecipeDocument,
    SuggestionDocument,
    UserSettingsDocument,
)
from lib.types import IngredientRecipe

# In-memory Mongo by default. Set PLAN_TEST_DB_URI to run against a real one,
# e.g. mongodb://127.0.0.1:27019/?directConnection=true
REAL_DB_URI = os.environ.get("PLAN_TEST_DB_URI")

WEEK = "2026-10-17"  # a Saturday
TUESDAY = "2026-10-20"


@pytest.fixture
async def api():
    client = AsyncIOMotorClient(REAL_DB_URI) if REAL_DB_URI else AsyncMongoMockClient()
    db_name = f"plan_days_{uuid4().hex}"
    await init_beanie(
        database=client[db_name],
        document_models=[
            IngredientDocument,
            RecipeDocument,
            ListDocument,
            UserSettingsDocument,
            SuggestionDocument,
        ],
    )
    transport = httpx.ASGITransport(app=main.app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test/api") as http:
        yield http
    if REAL_DB_URI:
        await client.drop_database(db_name)
    client.close()


async def make_recipe(title: str, *ingredients: str, cuisine: str | None = None) -> str:
    recipe = RecipeDocument(
        title=title,
        instructions=["Cook it."],
        ingredients=[IngredientRecipe(name=n, unit="g", amount=100) for n in ingredients],
        cuisine=cuisine,
    )
    await recipe.insert()
    return str(recipe.id)


async def make_week(api: httpx.AsyncClient, week_start: str = WEEK) -> str:
    res = await api.post("/lists/", json={"week_start": week_start})
    assert res.status_code == 200
    return res.json()["id"]


async def put_day(api, list_id, day, recipe_id=None, status="open"):
    return await api.put(
        f"/lists/{list_id}/days/{day}", json={"recipe_id": recipe_id, "status": status}
    )


def day_of(body: dict, day: str) -> dict:
    return next(d for d in body["days"] if d["date"] == day)


def assert_days_on_list(body: dict) -> None:
    planned = {d["recipe_id"] for d in body["days"] if d["recipe_id"]}
    assert planned <= set(body["recipes"])


async def test_post_without_body_makes_a_plain_list(api):
    res = await api.post("/lists/")
    assert res.status_code == 200
    created = res.json()
    assert created["week_start"] is None
    assert created["days"] == []
    assert not created["name"].startswith("Week of")

    detail = (await api.get(f"/lists/{created['id']}")).json()
    assert detail["week_start"] is None
    assert detail["days"] == []
    assert detail["recipes"] == []
    assert detail["items"] == []


async def test_post_with_week_start_makes_seven_open_days(api):
    res = await api.post("/lists/", json={"week_start": WEEK})
    assert res.status_code == 200
    created = res.json()
    assert created["name"] == "Week of Sat 17 Oct"

    detail = (await api.get(f"/lists/{created['id']}")).json()
    assert detail["week_start"] == WEEK
    assert [d["date"] for d in detail["days"]] == [f"2026-10-{n}" for n in range(17, 24)]
    assert all(
        d == {"date": d["date"], "recipe_id": None, "status": "open", "origin": "user", "quick": False}
        for d in detail["days"]
    )

    summary = next(row for row in (await api.get("/lists/")).json() if row["id"] == created["id"])
    assert summary["week_start"] == WEEK
    assert len(summary["days"]) == 7


async def test_set_clear_and_reset_a_day(api):
    list_id = await make_week(api)
    curry = await make_recipe("Curry", "chickpeas", "spinach")
    pasta = await make_recipe("Pasta", "penne")

    res = await put_day(api, list_id, TUESDAY, curry)
    assert res.status_code == 200
    body = res.json()
    assert day_of(body, TUESDAY)["recipe_id"] == curry
    assert body["recipes"] == [curry]
    assert {i["name"] for i in body["items"]} == {"chickpeas", "spinach"}
    assert_days_on_list(body)
    assert (await api.get(f"/lists/{list_id}")).json() == body

    body = (await put_day(api, list_id, TUESDAY, None)).json()
    assert day_of(body, TUESDAY) == {
        "date": TUESDAY, "recipe_id": None, "status": "open", "origin": "user", "quick": False,
    }
    # Cleared, but still on the list as an any-day meal.
    assert body["recipes"] == [curry]
    assert {i["name"] for i in body["items"]} == {"chickpeas", "spinach"}
    assert_days_on_list(body)

    body = (await put_day(api, list_id, TUESDAY, pasta)).json()
    assert day_of(body, TUESDAY)["recipe_id"] == pasta
    assert body["recipes"] == [curry, pasta]
    assert {i["name"] for i in body["items"]} == {"chickpeas", "spinach", "penne"}
    assert_days_on_list(body)


async def test_a_recipe_already_on_the_list_is_not_added_again(api):
    list_id = await make_week(api)
    curry = await make_recipe("Curry", "chickpeas")
    await api.post(f"/lists/{list_id}/recipes", json={"recipe_id": curry})

    body = (await put_day(api, list_id, TUESDAY, curry)).json()
    assert body["recipes"] == [curry]
    assert [(i["name"], i["amount"]) for i in body["items"]] == [("chickpeas", 100)]


async def test_repeated_put_is_idempotent(api):
    list_id = await make_week(api)
    curry = await make_recipe("Curry", "chickpeas")

    first = (await put_day(api, list_id, TUESDAY, curry)).json()
    await put_day(api, list_id, TUESDAY, curry)
    third = (await put_day(api, list_id, TUESDAY, curry)).json()

    assert third == first
    assert third["recipes"] == [curry]
    assert [(i["name"], i["amount"]) for i in third["items"]] == [("chickpeas", 100)]


async def test_status_follows_the_last_write(api):
    list_id = await make_week(api)
    curry = await make_recipe("Curry", "chickpeas")

    body = (await put_day(api, list_id, TUESDAY, None, "out")).json()
    assert day_of(body, TUESDAY)["status"] == "out"

    body = (await put_day(api, list_id, TUESDAY, curry, "open")).json()
    assert day_of(body, TUESDAY)["status"] == "open"
    assert day_of(body, TUESDAY)["recipe_id"] == curry


async def test_date_outside_the_week_is_422_and_changes_nothing(api):
    list_id = await make_week(api)
    curry = await make_recipe("Curry", "chickpeas")
    before = (await api.get(f"/lists/{list_id}")).json()

    for day in ("2026-10-16", "2026-10-24"):
        res = await put_day(api, list_id, day, curry)
        assert res.status_code == 422

    assert (await api.get(f"/lists/{list_id}")).json() == before


async def test_plain_list_rejects_day_writes_with_409(api):
    list_id = (await api.post("/lists/")).json()["id"]
    curry = await make_recipe("Curry", "chickpeas")
    before = (await api.get(f"/lists/{list_id}")).json()

    res = await put_day(api, list_id, TUESDAY, curry)
    assert res.status_code == 409
    assert (await api.get(f"/lists/{list_id}")).json() == before


async def test_unknown_list_or_recipe_is_404(api):
    list_id = await make_week(api)
    before = (await api.get(f"/lists/{list_id}")).json()

    assert (await put_day(api, "0" * 24, TUESDAY)).status_code == 404
    assert (await put_day(api, list_id, TUESDAY, "0" * 24)).status_code == 404
    assert (await put_day(api, list_id, TUESDAY, "not-an-id")).status_code == 404
    assert (await api.get(f"/lists/{list_id}")).json() == before


async def test_removing_a_recipe_clears_its_day(api):
    list_id = await make_week(api)
    curry = await make_recipe("Curry", "chickpeas")
    pasta = await make_recipe("Pasta", "penne")
    await put_day(api, list_id, TUESDAY, curry)
    await put_day(api, list_id, "2026-10-21", pasta)

    res = await api.delete(f"/lists/{list_id}/recipes/{curry}")
    assert res.status_code == 200

    body = (await api.get(f"/lists/{list_id}")).json()
    assert day_of(body, TUESDAY)["recipe_id"] is None
    assert day_of(body, "2026-10-21")["recipe_id"] == pasta
    assert body["recipes"] == [pasta]
    assert_days_on_list(body)


async def test_recipes_carry_last_planned_on_across_lists(api):
    curry = await make_recipe("Curry", "chickpeas", "spinach", cuisine="Indian")
    never = await make_recipe("Soup", "leeks")
    first = await make_week(api, "2026-10-17")
    second = await make_week(api, "2026-10-24")
    await put_day(api, second, "2026-10-26", curry)
    await put_day(api, first, "2026-10-18", curry)
    # A meal with no day does not count as planned.
    await api.post(f"/lists/{first}/recipes", json={"recipe_id": never})

    rows = {r["id"]: r for r in (await api.get("/recipes/")).json()}
    assert rows[curry]["last_planned_on"] == "2026-10-26"
    assert rows[curry]["ingredient_names"] == ["chickpeas", "spinach"]
    assert rows[curry]["cuisine"] == "Indian"
    assert rows[never]["last_planned_on"] is None
    assert rows[never]["cuisine"] is None

    await put_day(api, second, "2026-10-26", None)
    rows = {r["id"]: r for r in (await api.get("/recipes/")).json()}
    assert rows[curry]["last_planned_on"] == "2026-10-18"


async def test_plan_settings_round_trip(api):
    defaults = {"week_start_weekday": 5, "variety_days": 3}
    assert (await api.get("/settings/plan")).json() == defaults

    res = await api.put("/settings/plan", json={"week_start_weekday": 0})
    assert res.json() == {**defaults, "week_start_weekday": 0}
    # Either setting can be sent alone; the other keeps its value.
    res = await api.put("/settings/plan", json={"variety_days": 5})
    assert res.json() == {"week_start_weekday": 0, "variety_days": 5}
    assert (await api.get("/settings/plan")).json() == {"week_start_weekday": 0, "variety_days": 5}

    assert (await api.put("/settings/plan", json={"week_start_weekday": 7})).status_code == 422
    assert (await api.put("/settings/plan", json={"variety_days": 0})).status_code == 422
    assert (await api.get("/settings/plan")).json() == {"week_start_weekday": 0, "variety_days": 5}


async def test_a_quick_night_outlasts_its_meal(api):
    list_id = await make_week(api)
    curry = await make_recipe("Curry", "chickpeas")
    res = await api.put(f"/lists/{list_id}/days/{TUESDAY}", json={"recipe_id": None, "quick": True})
    assert day_of(res.json(), TUESDAY)["quick"] is True

    # A client that doesn't send quick, like the iOS app today, leaves it alone.
    body = (await put_day(api, list_id, TUESDAY, curry)).json()
    assert day_of(body, TUESDAY) | {"quick": True} == day_of(body, TUESDAY)
    assert (await put_day(api, list_id, TUESDAY, None)).json()["days"][3]["quick"] is True

    res = await api.put(f"/lists/{list_id}/days/{TUESDAY}", json={"recipe_id": None, "quick": False})
    assert day_of(res.json(), TUESDAY)["quick"] is False


async def test_a_meal_wins_over_out(api):
    list_id = await make_week(api)
    curry = await make_recipe("Curry", "chickpeas")

    body = (await put_day(api, list_id, TUESDAY, curry, "out")).json()
    assert day_of(body, TUESDAY)["recipe_id"] == curry
    assert day_of(body, TUESDAY)["status"] == "open"
    assert day_of((await api.get(f"/lists/{list_id}")).json(), TUESDAY)["status"] == "open"


# mongomock does not implement arrayFilters.
@pytest.mark.skipif(not REAL_DB_URI, reason="needs PLAN_TEST_DB_URI")
async def test_deleting_a_recipe_clears_its_days_in_every_list(api):
    curry = await make_recipe("Curry", "chickpeas")
    pasta = await make_recipe("Pasta", "penne")
    first = await make_week(api, "2026-10-17")
    second = await make_week(api, "2026-10-24")
    await put_day(api, first, TUESDAY, curry)
    await put_day(api, first, "2026-10-21", curry)
    await put_day(api, first, "2026-10-22", pasta)
    await put_day(api, second, "2026-10-26", curry)
    await put_day(api, second, "2026-10-27", None, "out")

    assert (await api.delete(f"/recipes/{curry}")).status_code == 204

    one = (await api.get(f"/lists/{first}")).json()
    two = (await api.get(f"/lists/{second}")).json()
    assert day_of(one, TUESDAY)["recipe_id"] is None
    assert day_of(one, "2026-10-21")["recipe_id"] is None
    assert day_of(one, "2026-10-22")["recipe_id"] == pasta
    assert day_of(two, "2026-10-26")["recipe_id"] is None
    assert day_of(two, "2026-10-27")["status"] == "out"
    assert len(one["days"]) == len(two["days"]) == 7


async def test_list_routes_return_the_week(api):
    list_id = await make_week(api)
    curry = await make_recipe("Curry", "chickpeas")

    added = (await api.post(f"/lists/{list_id}/recipes", json={"recipe_id": curry})).json()
    assert added["week_start"] == WEEK
    assert len(added["days"]) == 7
    assert added["recipes"] == [curry]
    assert [i["name"] for i in added["items"]] == ["chickpeas"]

    await put_day(api, list_id, TUESDAY, curry)
    renamed = (await api.patch(f"/lists/{list_id}", json={"name": "Dinners"})).json()
    assert renamed["id"] == list_id
    assert renamed["name"] == "Dinners"
    assert renamed["week_start"] == WEEK
    assert day_of(renamed, TUESDAY)["recipe_id"] == curry

    removed = (await api.delete(f"/lists/{list_id}/recipes/{curry}")).json()
    assert removed["id"] == list_id
    assert removed["recipes"] == []
    assert removed["items"] == []
    assert removed["week_start"] == WEEK
    assert day_of(removed, TUESDAY)["recipe_id"] is None
