"""The HTTP contract of the recipe, list and settings routes.

Runs the real app over an in-memory database, so a change to how the routes
reach their logic cannot quietly change a status code or a response body.
"""

from unittest.mock import MagicMock, patch

import pytest
from beanie import init_beanie
from httpx import ASGITransport, AsyncClient
from mongomock_motor import AsyncMongoMockClient

import main
from data_models import (
    IngredientDocument,
    ListDocument,
    RecipeDocument,
    SuggestionDocument,
    UserSettingsDocument,
)
from lib.types import IngredientRecipe

MISSING = "5f0000000000000000000000"


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
        ],
    )
    async with AsyncClient(transport=ASGITransport(app=main.app), base_url="http://t") as c:
        yield c


async def make_recipe(title="Dal", **kw) -> RecipeDocument:
    r = RecipeDocument(
        title=title,
        instructions=["Cook."],
        ingredients=[
            IngredientRecipe(name="lentils", unit="g", amount=200, category="Pantry & Dry Goods"),
            IngredientRecipe(name="onion", unit="", amount=1, category="Fresh Produce"),
            IngredientRecipe(name="salt", unit="", amount=None, excluded_from_list=True),
        ],
        **kw,
    )
    await r.insert()
    return r


def strip_ids(items: list[dict]) -> list[dict]:
    return [{k: v for k, v in i.items() if k != "id"} for i in items]


async def test_list_lifecycle(api):
    created = (await api.post("/api/lists/")).json()
    lid = created["id"]
    assert set(created) == {"id", "name", "created_at"}

    r = await api.patch(f"/api/lists/{lid}", json={"name": "Week 1"})
    assert r.json() == {"id": lid, "name": "Week 1"}

    dal = await make_recipe()
    soup = await make_recipe("Soup")
    r = await api.post(f"/api/lists/{lid}/recipes", json={"recipe_id": str(dal.id)})
    assert r.status_code == 200
    r = await api.post(f"/api/lists/{lid}/recipes", json={"recipe_id": str(soup.id)})
    body = r.json()
    assert body["recipes"] == [str(dal.id), str(soup.id)]
    assert strip_ids(body["items"]) == [
        {"name": "lentils", "amount": 400.0, "unit": "g", "category": "Pantry & Dry Goods",
         "checked": False, "sources": [{"recipe_id": str(dal.id), "amount": 200.0},
                                       {"recipe_id": str(soup.id), "amount": 200.0}]},
        {"name": "onion", "amount": 2.0, "unit": "", "category": "Fresh Produce",
         "checked": False, "sources": [{"recipe_id": str(dal.id), "amount": 1.0},
                                       {"recipe_id": str(soup.id), "amount": 1.0}]},
    ]

    r = await api.post(f"/api/lists/{lid}/recipes", json={"recipe_id": str(dal.id)})
    assert (r.status_code, r.json()) == (400, {"detail": "Recipe already on this list"})

    r = await api.post(f"/api/lists/{lid}/items", json={"id": "milk-1", "name": "milk", "amount": 2, "unit": "l"})
    assert r.json()["id"] == "milk-1"
    again = await api.post(f"/api/lists/{lid}/items", json={"id": "milk-1", "name": "milk", "amount": 2, "unit": "l"})
    assert again.json() == r.json()

    r = await api.patch(f"/api/lists/{lid}/items/milk-1", json={"checked": True, "amount": None})
    assert (r.json()["checked"], r.json()["amount"]) == (True, None)

    lst = (await api.get(f"/api/lists/{lid}")).json()
    ids = [i["id"] for i in lst["items"]]
    r = await api.put(
        f"/api/lists/{lid}/items/reorder",
        json={"category": "Fresh Produce", "item_ids": [ids[1]]},
    )
    assert [i["id"] for i in r.json()["items"]] == ids

    r = await api.delete(f"/api/lists/{lid}/recipes/{dal.id}")
    assert [(i["name"], i["amount"]) for i in r.json()["items"]] == [
        ("lentils", 200.0), ("onion", 1.0), ("milk", 2.0)
    ]
    r = await api.delete(f"/api/lists/{lid}/recipes/{dal.id}")
    assert (r.status_code, r.json()) == (404, {"detail": "Recipe not on this list"})

    r = await api.delete(f"/api/lists/{lid}/items/milk-1")
    assert r.json() == {"ok": True}
    r = await api.delete(f"/api/lists/{lid}/items/milk-1")
    assert (r.status_code, r.json()) == (404, {"detail": "Item not found"})
    r = await api.patch(f"/api/lists/{lid}/items/nope", json={"checked": True})
    assert (r.status_code, r.json()) == (404, {"detail": "Item not found"})

    copy = (await api.post(f"/api/lists/{lid}/duplicate")).json()
    copied = (await api.get(f"/api/lists/{copy['id']}")).json()
    assert copied["recipes"] == [str(soup.id)]
    assert [i["checked"] for i in copied["items"]] == [False, False]

    summaries = (await api.get("/api/lists/")).json()
    assert {s["id"]: (s["item_count"], s["recipes"]) for s in summaries} == {
        lid: (2, [{"id": str(soup.id), "title": "Soup"}]),
        copy["id"]: (2, [{"id": str(soup.id), "title": "Soup"}]),
    }

    assert (await api.delete(f"/api/lists/{lid}")).json() == {"ok": True}
    r = await api.get(f"/api/lists/{lid}")
    assert (r.status_code, r.json()) == (404, {"detail": "List not found"})


@pytest.mark.parametrize(
    "method,path,body",
    [
        ("get", "/api/lists/{m}", None),
        ("patch", "/api/lists/{m}", {"name": "x"}),
        ("delete", "/api/lists/{m}", None),
        ("post", "/api/lists/{m}/duplicate", None),
        ("post", "/api/lists/{m}/recipes", {"recipe_id": "{m}"}),
        ("delete", "/api/lists/{m}/recipes/{m}", None),
        ("post", "/api/lists/{m}/items", {"name": "x"}),
        ("put", "/api/lists/{m}/items/reorder", {"category": "x", "item_ids": []}),
        ("patch", "/api/lists/{m}/items/x", {"checked": True}),
        ("delete", "/api/lists/{m}/items/x", None),
    ],
)
async def test_missing_list_is_404(api, method, path, body):
    kwargs = {"json": {k: v.format(m=MISSING) if isinstance(v, str) else v for k, v in body.items()}} if body else {}
    r = await api.request(method.upper(), path.format(m=MISSING), **kwargs)
    assert (r.status_code, r.json()) == (404, {"detail": "List not found"})


async def test_add_missing_recipe_to_list_is_404(api):
    lid = (await api.post("/api/lists/")).json()["id"]
    r = await api.post(f"/api/lists/{lid}/recipes", json={"recipe_id": MISSING})
    assert (r.status_code, r.json()) == (404, {"detail": "Recipe not found"})


async def test_recipe_routes(api):
    dal = await make_recipe(servings=4)
    rid = str(dal.id)

    listed = (await api.get("/api/recipes/")).json()
    assert [(r["id"], r["title"], r["ingredient_count"], r["servings"]) for r in listed] == [
        (rid, "Dal", 3, 4)
    ]
    assert (await api.get(f"/api/recipes/{rid}")).json()["title"] == "Dal"

    r = await api.patch(f"/api/recipes/{rid}/rating", json={"rating": 5})
    assert r.json() == {"id": rid, "rating": 5}

    r = await api.patch(f"/api/recipes/{rid}/ingredients/1/exclude", json={"excluded": True})
    assert r.json() == {"index": 1, "excluded_from_list": True}
    r = await api.patch(f"/api/recipes/{rid}/ingredients/9/exclude", json={"excluded": True})
    assert (r.status_code, r.json()) == (404, {"detail": "Ingredient not found"})

    vo = MagicMock()
    vo.embed.return_value.embeddings = [[0.0]]
    with patch.object(main, "vo", vo):
        r = await api.put(
            f"/api/recipes/{rid}",
            json={
                "title": "Red dal",
                "instructions": ["Rinse.", "Simmer."],
                "ingredients": [{"name": "red lentils", "unit": "g", "amount": 250}],
            },
        )
        await main.asyncio.sleep(0)
    body = r.json()
    assert (body["title"], body["instructions"], body["rating"]) == ("Red dal", ["Rinse.", "Simmer."], 5)
    assert [i["name"] for i in body["ingredients"]] == ["red lentils"]

    assert (await api.get("/api/units")).json() == ["g"]

    r = await api.delete(f"/api/recipes/{rid}")
    assert r.status_code == 204
    for method, path, kw in [
        ("GET", f"/api/recipes/{rid}", {}),
        ("PATCH", f"/api/recipes/{rid}/rating", {"json": {"rating": 3}}),
        ("PUT", f"/api/recipes/{rid}", {"json": {"title": "x", "instructions": [], "ingredients": []}}),
        ("DELETE", f"/api/recipes/{rid}", {}),
        ("PATCH", f"/api/recipes/{rid}/ingredients/0/exclude", {"json": {"excluded": True}}),
    ]:
        r = await api.request(method, path, **kw)
        assert (r.status_code, r.json()) == (404, {"detail": "Recipe not found"}), path


async def test_categories(api):
    got = (await api.get("/api/settings/categories")).json()
    assert got[0] == {"name": "Fresh Produce", "order": 0}
    new = [{"name": "Veg", "order": 0}, {"name": "Other", "order": 1}]
    assert (await api.put("/api/settings/categories", json={"categories": new})).json() == new
    assert (await api.get("/api/settings/categories")).json() == new


async def test_save_of_a_saved_card_puts_its_recipe_on_the_list(api):
    dal = await make_recipe()
    card = SuggestionDocument(title="Dal", status="saved", recipe_id=str(dal.id))
    await card.insert()
    lid = (await api.post("/api/lists/")).json()["id"]

    r = await api.post(f"/api/suggestions/{card.id}/save", json={"list_id": lid})
    assert r.json()["status"] == "saved"
    assert (await api.get(f"/api/lists/{lid}")).json()["recipes"] == [str(dal.id)]
