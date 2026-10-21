"""A meal on a list can be marked cooked, and nothing else changes when it is."""

from tests.test_plan_days import api, make_recipe, make_week, put_day  # noqa: F401

TUESDAY = "2026-10-20"


async def put_cooked(api, list_id, recipe_id, cooked=True):
    return await api.put(f"/lists/{list_id}/recipes/{recipe_id}/cooked", json={"cooked": cooked})


async def test_mark_and_unmark_a_meal_cooked(api):
    list_id = await make_week(api)
    curry = await make_recipe("Curry", "chickpeas", "spinach")
    await put_day(api, list_id, TUESDAY, curry)
    before = (await api.get(f"/lists/{list_id}")).json()
    assert before["cooked"] == []

    res = await put_cooked(api, list_id, curry)
    assert res.status_code == 200
    body = res.json()
    assert body["cooked"] == [curry]
    # Cooking a meal moves nothing: its day, the meals and the items stay put.
    assert body["days"] == before["days"]
    assert body["recipes"] == before["recipes"]
    assert body["items"] == before["items"]

    # Marking again is not an error, and doesn't count twice.
    assert (await put_cooked(api, list_id, curry)).json()["cooked"] == [curry]

    summary = next(row for row in (await api.get("/lists/")).json() if row["id"] == list_id)
    assert summary["recipes"] == [{"id": curry, "title": "Curry", "cooked": True}]

    assert (await put_cooked(api, list_id, curry, False)).json()["cooked"] == []


async def test_only_a_meal_on_the_list_can_be_cooked(api):
    list_id = await make_week(api)
    curry = await make_recipe("Curry", "chickpeas")
    assert (await put_cooked(api, list_id, curry)).status_code == 404


async def test_removing_a_meal_forgets_it_was_cooked(api):
    list_id = await make_week(api)
    curry = await make_recipe("Curry", "chickpeas")
    await api.post(f"/lists/{list_id}/recipes", json={"recipe_id": curry})
    await put_cooked(api, list_id, curry)

    body = (await api.delete(f"/lists/{list_id}/recipes/{curry}")).json()
    assert body["cooked"] == []

    # Put back, it starts uncooked.
    body = (await api.post(f"/lists/{list_id}/recipes", json={"recipe_id": curry})).json()
    assert body["cooked"] == []


async def test_a_duplicate_starts_with_nothing_cooked(api):
    list_id = await make_week(api)
    curry = await make_recipe("Curry", "chickpeas")
    await api.post(f"/lists/{list_id}/recipes", json={"recipe_id": curry})
    await put_cooked(api, list_id, curry)

    copy = (await api.post(f"/lists/{list_id}/duplicate")).json()
    detail = (await api.get(f"/lists/{copy['id']}")).json()
    assert detail["recipes"] == [curry]
    assert detail["cooked"] == []
