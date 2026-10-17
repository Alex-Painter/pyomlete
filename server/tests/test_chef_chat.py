"""Chef in chat: its tools change data through services/, and each change can be undone.

The model is a FunctionModel that calls the tools a test names, so nothing
reaches Anthropic; the database is in memory.
"""

import json
from unittest.mock import AsyncMock, patch

import pytest
from beanie import init_beanie
from httpx import ASGITransport, AsyncClient
from mongomock_motor import AsyncMongoMockClient
from pydantic_ai.messages import ModelMessage, ModelRequest, ToolReturnPart
from pydantic_ai.models.function import AgentInfo, DeltaToolCall, FunctionModel

import main
from chef import chat
from data_models import (
    ChefActionDocument,
    IngredientDocument,
    ListDocument,
    ListItem,
    RecipeDocument,
    UserSettingsDocument,
)
from lib.types import IngredientRecipe


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
            ChefActionDocument,
        ],
    )
    async with AsyncClient(transport=ASGITransport(app=main.app), base_url="http://t") as c:
        yield c


def calling(*calls: tuple[str, dict], reply: str = "Done."):
    """A model that makes these tool calls, one turn each, then says `reply`.

    It records what each tool returned and the instructions it was given.
    """
    seen: dict = {"returns": [], "instructions": None}

    async def stream(messages: list[ModelMessage], info: AgentInfo):
        seen["instructions"] = info.instructions
        returns = [
            p for m in messages if isinstance(m, ModelRequest)
            for p in m.parts if isinstance(p, ToolReturnPart)
        ]
        seen["returns"] = [r.content for r in returns]
        if len(returns) < len(calls):
            name, args = calls[len(returns)]
            yield {0: DeltaToolCall(name=name, json_args=json.dumps(args))}
        else:
            yield reply

    return FunctionModel(stream_function=stream), seen


def chat_body(text: str, path: str | None = None, files: list[dict] | None = None) -> dict:
    body = {
        "trigger": "submit-message",
        "id": "chat-1",
        "messages": [{
            "id": "m1",
            "role": "user",
            "parts": [{"type": "text", "text": text}, *(files or [])],
        }],
    }
    if path:
        body["page"] = {"path": path}
    return body


def events(response) -> list[dict]:
    return [
        json.loads(line[6:])
        for line in response.text.splitlines()
        if line.startswith("data: {")
    ]


async def say(api, model, text, path=None, files=None):
    with chat.agent.override(model=model):
        r = await api.post("/api/chef/chat", json=chat_body(text, path, files))
    assert r.status_code == 200, r.text
    return events(r)


async def a_list(**kw) -> ListDocument:
    lst = ListDocument(name="Weekend", **kw)
    await lst.insert()
    return lst


async def a_recipe(title="Dal") -> RecipeDocument:
    r = RecipeDocument(
        title=title,
        instructions=["Cook."],
        ingredients=[IngredientRecipe(name="lentils", unit="g", amount=200, category="Pantry & Dry Goods")],
    )
    await r.insert()
    return r


async def test_reply_streams_in_the_ai_sdk_format(api):
    model, _ = calling(reply="Hello there.")
    sent = await say(api, model, "hi")
    text = "".join(e.get("delta", "") for e in sent if e["type"] == "text-delta")
    assert text == "Hello there."
    assert sent[0]["type"] == "start"


async def test_this_list_is_the_one_on_screen(api):
    lst = await a_list()
    model, seen = calling()
    await say(api, model, "what's on this?", path=f"/shop/{lst.id}")
    assert f'"This list" is their list "Weekend" (id {lst.id}).' in seen["instructions"]
    assert f"/shop/{lst.id}" in seen["instructions"]


async def test_adds_an_item_and_undo_takes_it_off(api):
    lst = await a_list()
    model, seen = calling(
        ("add_item", {"list_id": str(lst.id), "name": "Milk", "amount": 2, "unit": "l", "aisle": "Dairy & Eggs"}),
    )
    sent = await say(api, model, "add milk")

    result = seen["returns"][0]
    assert result["done"] == "Added Milk"
    # The client reads the Undo id from the tool's output in the stream.
    outputs = [e for e in sent if e["type"] == "tool-output-available"]
    assert outputs[0]["output"]["undo"] == result["undo"]
    assert [i.name for i in (await ListDocument.get(lst.id)).items] == ["Milk"]

    r = await api.post(f"/api/chef/actions/{result['undo']}/undo")
    assert r.status_code == 200
    assert r.json() == {"id": result["undo"], "summary": "Added Milk", "undone": True}
    assert (await ListDocument.get(lst.id)).items == []


async def test_undo_twice_changes_nothing_more(api):
    lst = await a_list()
    model, seen = calling(("rename_list", {"list_id": str(lst.id), "name": "Party"}))
    await say(api, model, "call it Party")
    undo = seen["returns"][0]["undo"]
    assert (await api.post(f"/api/chef/actions/{undo}/undo")).status_code == 200
    await lists_rename(lst, "Later")
    assert (await api.post(f"/api/chef/actions/{undo}/undo")).status_code == 200
    assert (await ListDocument.get(lst.id)).name == "Later"


async def lists_rename(lst: ListDocument, name: str) -> None:
    fresh = await ListDocument.get(lst.id)
    fresh.name = name
    await fresh.save()


async def test_undo_refuses_over_a_later_change(api):
    lst = await a_list()
    model, seen = calling(("rename_list", {"list_id": str(lst.id), "name": "Party"}))
    await say(api, model, "call it Party")
    await lists_rename(lst, "Mine")

    r = await api.post(f"/api/chef/actions/{seen['returns'][0]['undo']}/undo")
    assert r.status_code == 409
    assert (await ListDocument.get(lst.id)).name == "Mine"


async def test_undoing_a_delete_brings_the_list_back(api):
    lst = await a_list(items=[ListItem(name="Eggs", category="Dairy & Eggs")])
    model, seen = calling(("delete_list", {"list_id": str(lst.id)}))
    await say(api, model, "bin it")
    assert await ListDocument.get(lst.id) is None

    await api.post(f"/api/chef/actions/{seen['returns'][0]['undo']}/undo")
    back = await ListDocument.get(lst.id)
    assert back.name == "Weekend"
    assert [i.name for i in back.items] == ["Eggs"]


async def test_puts_a_recipe_on_a_list_and_undo_takes_it_off(api):
    lst = await a_list()
    recipe = await a_recipe()
    model, seen = calling(("add_recipe_to_list", {"list_id": str(lst.id), "recipe_id": str(recipe.id)}))
    await say(api, model, "put dal on it")
    assert seen["returns"][0]["done"] == "Put Dal on Weekend"
    assert (await ListDocument.get(lst.id)).recipes == [str(recipe.id)]

    await api.post(f"/api/chef/actions/{seen['returns'][0]['undo']}/undo")
    after = await ListDocument.get(lst.id)
    assert after.recipes == [] and after.items == []


async def test_undoing_a_new_recipe_deletes_it(api):
    made = await a_recipe("Quick dal")
    with patch.object(chat.recipes, "generate", AsyncMock(return_value=made)):
        model, seen = calling(("create_recipe", {"description": "a quick dal"}))
        await say(api, model, "make me a dal")
    result = seen["returns"][0]
    assert result["recipe_id"] == str(made.id)

    await api.post(f"/api/chef/actions/{result['undo']}/undo")
    assert await RecipeDocument.get(made.id) is None


async def test_import_of_a_saved_page_points_at_the_saved_recipe(api):
    from services.errors import AlreadyImported

    with patch.object(chat.recipes, "import_url", AsyncMock(side_effect=AlreadyImported("abc"))):
        model, seen = calling(("import_recipe", {"url": "https://example.com/dal"}))
        await say(api, model, "save this")
    assert seen["returns"][0] == {"already_saved": True, "recipe_id": "abc"}
    assert await ChefActionDocument.find_all().count() == 0


async def test_photos_on_the_message_reach_the_photo_tool(api):
    made = await a_recipe("Nan's soup")
    from_images = AsyncMock(return_value=made)
    photo = {"type": "file", "mediaType": "image/jpeg", "url": "data:image/jpeg;base64,aW1nMA=="}
    with patch.object(chat.recipes, "from_images", from_images):
        model, seen = calling(("create_recipe_from_photos", {}))
        await say(api, model, "save this recipe", files=[photo])
    assert from_images.await_args.args[0] == [("image/jpeg", b"img0")]
    assert "They attached 1 photo(s)" in seen["instructions"]


async def test_a_refusal_reaches_the_model_as_a_result(api):
    model, seen = calling(("get_list", {"list_id": "5f0000000000000000000000"}), ("get_list", {"list_id": "nope"}))
    await say(api, model, "show me")
    assert seen["returns"] == [{"error": "List not found"}, {"error": "No such id"}]


async def test_ticking_an_item_says_so(api):
    lst = await a_list(items=[ListItem(id="i1", name="Eggs")])
    model, seen = calling(("update_item", {"list_id": str(lst.id), "item_id": "i1", "changes": {"checked": True}}))
    await say(api, model, "got the eggs")
    assert seen["returns"][0]["done"] == "Ticked Eggs"
    assert (await ListDocument.get(lst.id)).items[0].checked


async def test_aisles_are_cleaned_like_the_route_cleans_them(api):
    model, seen = calling(("set_aisles", {"aisles": [" Veg ", "veg", "", "Bakery"]}))
    await say(api, model, "my aisles are veg then bakery")
    settings = await UserSettingsDocument.find_one()
    assert [(c.name, c.order) for c in settings.categories] == [("Veg", 0), ("Bakery", 3)]

    await api.post(f"/api/chef/actions/{seen['returns'][0]['undo']}/undo")
    settings = await UserSettingsDocument.find_one()
    assert settings.categories[0].name == "Fresh Produce"


async def test_a_bad_chat_body_is_a_422(api):
    r = await api.post("/api/chef/chat", json={"messages": "nope"})
    assert r.status_code == 422


async def test_undo_of_nothing_is_a_404(api):
    r = await api.post("/api/chef/actions/5f0000000000000000000000/undo")
    assert r.status_code == 404
