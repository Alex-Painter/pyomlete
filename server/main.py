import asyncio
from contextlib import asynccontextmanager

from beanie import PydanticObjectId, init_beanie
from fastapi import APIRouter, FastAPI, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from chef import discover
from data_models import (
    CategoryConfig,
    IngredientDocument,
    ListDocument,
    RecipeDocument,
    SuggestionDocument,
    UserSettingsDocument,
)
from lib.db import get_motor_client
from lib.types import (
    CategoriesUpdateRequest,
    CategorizeRequest,
    CategorizeResponse,
    ExcludeUpdateRequest,
    ImportFromUrlRequest,
    ItemCreateRequest,
    ItemReorderRequest,
    ItemUpdateRequest,
    ListUpdateRequest,
    RatingUpdate,
    RecipePrompt,
    RecipeUpdateRequest,
    SuggestionRefreshRequest,
    SuggestionSaveRequest,
    SuggestionStatusUpdate,
    SuggestionsClearRequest,
    SuggestionsCreateRequest,
)
from services import lists, recipes, settings
from services.errors import AlreadyImported


@asynccontextmanager
async def lifespan(app: FastAPI):
    client = get_motor_client()
    await init_beanie(
        database=client["omlete"],
        document_models=[
            IngredientDocument,
            RecipeDocument,
            ListDocument,
            UserSettingsDocument,
            SuggestionDocument,
        ],
    )
    yield
    client.close()


app = FastAPI(lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    # Both spellings of the Vite dev origin. 127.0.0.1 is what the verify
    # skill uses, because localhost can resolve to ::1 and hit another listener.
    allow_origins=["http://localhost:5173", "http://127.0.0.1:5173"],
    allow_origin_regex=r"https://.*\.up\.railway\.app",
    allow_methods=["*"],
    allow_headers=["*"],
)
router = APIRouter(prefix="/api")

# The routes only shape requests and responses. What they do lives in
# services/, which Chef's tools call too.


@router.post("/recipes/generate/")
async def create_recipe(prompt: RecipePrompt):
    return await recipes.generate(prompt.prompt)


@router.post("/recipes/extract-from-images/")
async def extract_recipes_from_images(files: list[UploadFile], group_sizes: list[int] | None = None):
    """Extract recipes from grouped images.

    files: all image files, flattened
    group_sizes: list of ints indicating how many files belong to each recipe group.
                 e.g. [2, 1] means first 2 files = recipe 1, next 1 file = recipe 2.
                 If omitted, each file is treated as a separate recipe (backward compatible).
    """
    images = [(await f.read(), f.content_type) for f in files]
    # Backward compatible: without group sizes each file is one recipe
    sizes = group_sizes or [1] * len(images)
    results = []
    offset = 0
    for size in sizes:
        results.append(await recipes.from_images(images[offset:offset + size]))
        offset += size
    return results


@router.post("/recipes/import-from-url/")
async def import_recipe_from_url(body: ImportFromUrlRequest):
    return await recipes.import_url(body.url, body.changes)


@router.get("/recipes/")
async def list_recipes():
    found = await RecipeDocument.find_all().sort("-created_at").to_list()
    return [
        {
            "id": str(r.id),
            "title": r.title,
            "ingredient_count": len(r.ingredients),
            "rating": r.rating,
            # Enough for a card without shipping the whole document.
            "image_url": r.image_url,
            "total_minutes": r.total_minutes,
            "servings": r.servings,
            "source_name": r.source_name,
            "created_at": r.created_at.isoformat() if r.created_at else None,
        }
        for r in found
    ]


@router.get("/recipes/{recipe_id}")
async def get_recipe(recipe_id: PydanticObjectId):
    return await recipes.get(recipe_id)


@router.patch("/recipes/{recipe_id}/rating")
async def update_rating(recipe_id: PydanticObjectId, body: RatingUpdate):
    recipe = await recipes.rate(recipe_id, body.rating)
    return {"id": str(recipe.id), "rating": recipe.rating}


@router.put("/recipes/{recipe_id}")
async def update_recipe(recipe_id: PydanticObjectId, body: RecipeUpdateRequest):
    return await recipes.update(recipe_id, body.title, body.instructions, body.ingredients)


@router.delete("/recipes/{recipe_id}", status_code=204)
async def delete_recipe(recipe_id: PydanticObjectId):
    await recipes.delete(recipe_id)


@router.patch("/recipes/{recipe_id}/ingredients/{ingredient_index}/exclude")
async def toggle_ingredient_exclude(
    recipe_id: PydanticObjectId, ingredient_index: int, body: ExcludeUpdateRequest
):
    await recipes.set_excluded(recipe_id, ingredient_index, body.excluded)
    return {"index": ingredient_index, "excluded_from_list": body.excluded}


@router.get("/units")
async def get_units():
    return await recipes.units()


# --- Lists ---


def _list_out(lst: ListDocument) -> dict:
    return {
        "id": str(lst.id),
        "name": lst.name,
        "recipes": lst.recipes,
        "items": [item.model_dump() for item in lst.items],
    }


@router.get("/lists/")
async def get_lists():
    return await lists.summaries()


@router.post("/lists/")
async def create_list():
    lst = await lists.create()
    return {"id": str(lst.id), "name": lst.name, "created_at": lst.created_at.isoformat()}


@router.get("/lists/{list_id}")
async def get_list(list_id: PydanticObjectId):
    lst = await lists.get(list_id)
    return {
        "id": str(lst.id),
        "name": lst.name,
        "created_at": lst.created_at.isoformat() if lst.created_at else None,
        "recipes": lst.recipes,
        "items": [item.model_dump() for item in lst.items],
    }


@router.patch("/lists/{list_id}")
async def update_list(list_id: PydanticObjectId, body: ListUpdateRequest):
    lst = await lists.rename(list_id, body.name)
    return {"id": str(lst.id), "name": lst.name}


@router.delete("/lists/{list_id}")
async def delete_list(list_id: PydanticObjectId):
    await lists.delete(list_id)
    return {"ok": True}


@router.post("/lists/{list_id}/duplicate")
async def duplicate_list(list_id: PydanticObjectId):
    new_lst = await lists.duplicate(list_id)
    return {"id": str(new_lst.id), "name": new_lst.name, "created_at": new_lst.created_at.isoformat()}


# --- Settings ---


@router.get("/settings/categories")
async def get_categories():
    current = await settings.get_or_create()
    return [c.model_dump() for c in current.categories]


@router.put("/settings/categories")
async def update_categories(body: CategoriesUpdateRequest):
    saved = await settings.set_categories(
        [CategoryConfig(name=c.name, order=c.order) for c in body.categories]
    )
    return [c.model_dump() for c in saved]


# --- Categorization ---


@router.post("/categorize", response_model=CategorizeResponse)
async def categorize_item(body: CategorizeRequest):
    return CategorizeResponse(category=await settings.categorize(body.name))


# --- List Recipes ---


class AddRecipeRequest(BaseModel):
    recipe_id: str


@router.post("/lists/{list_id}/recipes")
async def add_recipe_to_list(list_id: PydanticObjectId, body: AddRecipeRequest):
    return _list_out(await lists.add_recipe(list_id, body.recipe_id))


@router.delete("/lists/{list_id}/recipes/{recipe_id}")
async def remove_recipe_from_list(list_id: PydanticObjectId, recipe_id: str):
    return _list_out(await lists.remove_recipe(list_id, recipe_id))


# --- List Items ---


@router.post("/lists/{list_id}/items")
async def add_item(list_id: PydanticObjectId, body: ItemCreateRequest):
    item = await lists.add_item(
        list_id, body.name, body.amount, body.unit, body.category, body.id
    )
    return item.model_dump()


@router.put("/lists/{list_id}/items/reorder")
async def reorder_items(list_id: PydanticObjectId, body: ItemReorderRequest):
    lst = await lists.reorder_items(list_id, body.category, body.item_ids)
    return {"items": [item.model_dump() for item in lst.items]}


@router.patch("/lists/{list_id}/items/{item_id}")
async def update_item(list_id: PydanticObjectId, item_id: str, body: ItemUpdateRequest):
    return (await lists.update_item(list_id, item_id, body)).model_dump()


@router.delete("/lists/{list_id}/items/{item_id}")
async def delete_item(list_id: PydanticObjectId, item_id: str):
    await lists.delete_item(list_id, item_id)
    return {"ok": True}


# --- Discover suggestions ---
# Omlete's driving principle is "eat better and reduce cognitive load"
# (docs/PRINCIPLES.md). Suggestions are the "variety comes to you" half: an
# agent (or /refresh) drops cards here from the user's taste, so finding
# something new to cook takes no searching.
#
# A suggestion is a card, not a recipe: a title, a reason it suits you, and
# optionally a photo and a source link. Anything can produce them. Today
# POST /suggestions/refresh asks Claude using your ratings and lists; later a
# web-searching agent can POST /suggestions/ with the same shape and the
# Discover screen won't need to change.

# Strong references so background saves aren't garbage-collected mid-flight.
_background_tasks: set[asyncio.Task] = set()


def _suggestion_out(s: SuggestionDocument) -> dict:
    return {
        "id": str(s.id),
        "title": s.title,
        "description": s.description,
        "reason": s.reason,
        "image_url": s.image_url,
        "source_url": s.source_url,
        "source_name": s.source_name,
        "total_minutes": s.total_minutes,
        "section": s.section,
        "status": s.status,
        "origin": s.origin,
        "recipe_id": s.recipe_id,
        "error": s.error,
        "created_at": s.created_at.isoformat() if s.created_at else None,
    }


async def _get_suggestion(suggestion_id: PydanticObjectId) -> SuggestionDocument:
    s = await SuggestionDocument.get(suggestion_id)
    if not s:
        raise HTTPException(status_code=404, detail="Suggestion not found")
    return s


# "dismissed" is "Not for me", a taste signal Chef learns from. "cleared" is
# just tidying the feed: hidden, but it says nothing about what you like.
HIDDEN_SUGGESTION_STATUSES = ("dismissed", "cleared")


@router.get("/suggestions/")
async def list_suggestions():
    suggestions = (
        await SuggestionDocument.find({"status": {"$nin": list(HIDDEN_SUGGESTION_STATUSES)}})
        .sort("-created_at")
        .limit(60)
        .to_list()
    )
    return [_suggestion_out(s) for s in suggestions]


@router.post("/suggestions/")
async def create_suggestions(body: SuggestionsCreateRequest):
    """Ingest suggestion records from any producer, such as an agent."""
    docs = [SuggestionDocument(**s.model_dump()) for s in body.suggestions]
    # One at a time so each document gets its id back for the response.
    for d in docs:
        await d.insert()
    return [_suggestion_out(d) for d in docs]


@router.post("/suggestions/refresh")
async def refresh_suggestions(req: SuggestionRefreshRequest):
    return [_suggestion_out(d) for d in await discover.refresh(req)]


@router.post("/suggestions/clear")
async def clear_suggestions(body: SuggestionsClearRequest):
    """Hide these cards (or every visible card) without counting it against them."""
    query: dict = {"status": {"$in": ["new", "saved", "failed"]}}
    if body.ids is not None:
        query["_id"] = {"$in": [PydanticObjectId(i) for i in body.ids]}
    result = await SuggestionDocument.find(query).update({"$set": {"status": "cleared"}})
    return {"cleared": getattr(result, "modified_count", 0)}


@router.patch("/suggestions/{suggestion_id}")
async def update_suggestion(suggestion_id: PydanticObjectId, body: SuggestionStatusUpdate):
    s = await _get_suggestion(suggestion_id)
    s.status = body.status
    await s.save()
    return _suggestion_out(s)


async def _add_recipe_to_list_id(list_id: str, recipe: RecipeDocument) -> None:
    lst = await ListDocument.get(PydanticObjectId(list_id))
    if lst and str(recipe.id) not in lst.recipes:
        await lists.put_recipe(lst, recipe)


async def _realise_suggestion(suggestion_id: PydanticObjectId, list_id: str | None) -> None:
    """Turn a suggestion into a saved recipe, off the request path."""
    s = await SuggestionDocument.get(suggestion_id)
    if not s:
        return
    try:
        recipe: RecipeDocument | None = None
        if s.source_url:
            try:
                recipe = await recipes.import_url(s.source_url)
            except AlreadyImported as exc:
                recipe = await RecipeDocument.get(PydanticObjectId(exc.recipe_id))
        else:
            recipe = await recipes.generate(
                f"Create a recipe for: {s.title}. {s.description or ''}".strip()
            )
        if recipe is None:
            raise RuntimeError("No recipe came back")

        s.recipe_id = str(recipe.id)
        s.status = "saved"
        s.error = None
        await s.save()
        if list_id:
            await _add_recipe_to_list_id(list_id, recipe)
    except Exception as exc:  # surfaced on the card, so the user can retry
        s.status = "failed"
        s.error = (exc.detail if isinstance(exc, HTTPException) else str(exc))
        s.error = str(s.error)[:200]
        await s.save()


@router.post("/suggestions/{suggestion_id}/save")
async def save_suggestion(suggestion_id: PydanticObjectId, body: SuggestionSaveRequest):
    """Save a card as a recipe. Returns at once; the recipe fills in after.

    With `list_id`, the recipe also goes on that list once it exists.
    """
    s = await _get_suggestion(suggestion_id)

    if s.status == "saved" and s.recipe_id:
        if body.list_id:
            recipe = await RecipeDocument.get(PydanticObjectId(s.recipe_id))
            if recipe:
                await _add_recipe_to_list_id(body.list_id, recipe)
        return _suggestion_out(s)

    if s.status != "saving":
        s.status = "saving"
        s.error = None
        await s.save()
        task = asyncio.create_task(_realise_suggestion(s.id, body.list_id))
        _background_tasks.add(task)
        task.add_done_callback(_background_tasks.discard)
    return _suggestion_out(s)


app.include_router(router)
