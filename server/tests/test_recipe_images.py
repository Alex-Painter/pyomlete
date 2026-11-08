"""Generate image: a photo made for a recipe is saved, served and becomes its picture."""

import base64

import pytest

import services.images as images
from data_models import RecipeDocument, RecipeImageDocument
from tests.test_plan_days import make_recipe

JPEG = b"\xff\xd8\xff\xe0fake-jpeg"


@pytest.fixture
async def api():
    import httpx
    from beanie import init_beanie
    from mongomock_motor import AsyncMongoMockClient

    import main
    from data_models import IngredientDocument, ListDocument, SuggestionDocument, UserSettingsDocument

    client = AsyncMongoMockClient()
    await init_beanie(
        database=client["recipe_images"],
        document_models=[
            IngredientDocument,
            RecipeDocument,
            ListDocument,
            UserSettingsDocument,
            SuggestionDocument,
            RecipeImageDocument,
        ],
    )
    transport = httpx.ASGITransport(app=main.app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test/api") as http:
        yield http
    client.close()


@pytest.fixture
def fal(monkeypatch):
    """Stand in for fal: record the prompt, hand back a data URI like sync_mode does."""
    monkeypatch.setenv("FAL_KEY", "test-fal-key")
    asked: list[str] = []

    async def fake_ask(prompt: str):
        asked.append(prompt)
        return JPEG, "image/jpeg"

    monkeypatch.setattr(images, "_ask_model", fake_ask)
    return asked


async def test_generate_saves_and_serves_the_photo(api, fal):
    curry = await make_recipe("Chickpea curry", "chickpeas", "spinach")

    res = await api.post(f"/recipes/{curry}/image")
    assert res.status_code == 200
    url = res.json()["image_url"]
    assert url.startswith("/api/recipe-images/")

    # The prompt names the dish and what's in it.
    assert "Chickpea curry" in fal[0] and "spinach" in fal[0]

    recipe = (await api.get(f"/recipes/{curry}")).json()
    assert recipe["image_url"] == url

    got = await api.get(url.removeprefix("/api"))
    assert got.status_code == 200
    assert got.content == JPEG
    assert got.headers["content-type"] == "image/jpeg"
    assert "immutable" in got.headers["cache-control"]


async def test_a_new_photo_replaces_the_old_one_and_keeps_it(api, fal):
    curry = await make_recipe("Curry", "chickpeas")
    first = (await api.post(f"/recipes/{curry}/image")).json()["image_url"]
    second = (await api.post(f"/recipes/{curry}/image")).json()["image_url"]
    assert first != second
    assert (await api.get(f"/recipes/{curry}")).json()["image_url"] == second
    # The old one is still served, so Undo can put it back.
    assert (await api.get(first.removeprefix("/api"))).status_code == 200


async def test_without_a_key_it_says_so_and_changes_nothing(api, monkeypatch):
    monkeypatch.delenv("FAL_KEY", raising=False)
    curry = await make_recipe("Curry", "chickpeas")
    res = await api.post(f"/recipes/{curry}/image")
    assert res.status_code == 503
    assert "FAL_KEY" in res.json()["detail"]
    assert (await api.get(f"/recipes/{curry}")).json()["image_url"] is None


async def test_a_failed_model_call_is_a_503_and_keeps_the_old_picture(api, monkeypatch):
    monkeypatch.setenv("FAL_KEY", "test-fal-key")

    async def broken(prompt: str):
        raise RuntimeError("fal answered 500")

    monkeypatch.setattr(images, "_ask_model", broken)
    recipe = RecipeDocument(title="Curry", instructions=["Cook."], ingredients=[], image_url="https://x/y.jpg")
    await recipe.insert()
    res = await api.post(f"/recipes/{recipe.id}/image")
    assert res.status_code == 503
    assert (await api.get(f"/recipes/{recipe.id}")).json()["image_url"] == "https://x/y.jpg"


async def test_unknown_recipe_and_image_are_404(api, fal):
    missing = "0123456789abcdef01234567"
    assert (await api.post(f"/recipes/{missing}/image")).status_code == 404
    assert (await api.get(f"/recipe-images/{missing}")).status_code == 404


async def test_fal_data_uri_and_link_answers_are_both_read(monkeypatch):
    """`_ask_model` reads the image whether fal inlines it or links to it."""
    import httpx

    monkeypatch.setenv("FAL_KEY", "k")
    inline = "data:image/jpeg;base64," + base64.b64encode(JPEG).decode()
    seen: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.host == "fal.run":
            seen["auth"] = request.headers["authorization"]
            seen["path"] = request.url.path
            url = inline if seen.get("mode") == "inline" else "https://v3.fal.media/x.png"
            return httpx.Response(200, json={"images": [{"url": url}]})
        return httpx.Response(200, content=b"png-bytes", headers={"content-type": "image/png"})

    real = httpx.AsyncClient

    def patched(*args, **kwargs):
        kwargs["transport"] = httpx.MockTransport(handler)
        return real(*args, **kwargs)

    monkeypatch.setattr(images.httpx, "AsyncClient", patched)

    seen["mode"] = "inline"
    assert await images._ask_model("p") == (JPEG, "image/jpeg")
    assert seen["auth"] == "Key k"
    assert seen["path"] == f"/{images.DEFAULT_MODEL}"

    seen["mode"] = "link"
    assert await images._ask_model("p") == (b"png-bytes", "image/png")
