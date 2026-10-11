import asyncio
import base64
import logging
import re
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from typing import Awaitable, Callable, NamedTuple
from urllib.parse import urlparse, urlunparse
from uuid import UUID

from anthropic import AsyncAnthropic, transform_schema
from beanie import PydanticObjectId, UpdateResponse, init_beanie
from bs4 import BeautifulSoup
from dotenv import load_dotenv
from fastapi import APIRouter, FastAPI, HTTPException, Response, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, TypeAdapter
from pymongo.errors import DuplicateKeyError

from data_models import (
    IngredientDocument,
    ListDocument,
    RecipeDocument,
    RecipeJobDocument,
    SuggestionDocument,
    UserSettingsDocument,
)
from lib.db import get_motor_client, vo
from beanie.operators import In
from data_models import CategoryConfig, ItemSource, ListItem
from lib.types import (
    CategoriesUpdateRequest,
    CategorizeRequest,
    CategorizeResponse,
    ExcludeUpdateRequest,
    ImportFromUrlRequest,
    IngredientRecipe,
    ItemCreateRequest,
    ItemReorderRequest,
    ItemUpdateRequest,
    ListUpdateRequest,
    MealSuggestions,
    RatingUpdate,
    RecipeJobEnd,
    RecipeJobKind,
    RecipeMetadata,
    RecipeModelResponse,
    RecipePrompt,
    RecipeUpdateRequest,
    SuggestMealsRequest,
    SuggestedMeals,
    SuggestionRefreshRequest,
    SuggestionSaveRequest,
    SuggestionStatusUpdate,
    SuggestionsClearRequest,
    SuggestionsCreateRequest,
)
from ingredient_structurer import structure_ingredients
from recipe_import import BlockedURL, FetchFailed, ScrapedRecipe, fetch_page, scrape
from tools import find_similar_ingredients

load_dotenv()

logger = logging.getLogger(__name__)

async_claude = AsyncAnthropic()

recipeSchema = TypeAdapter(RecipeModelResponse).json_schema()
recipeSchema = transform_schema(recipeSchema)

suggestionsSchema = TypeAdapter(MealSuggestions).json_schema()
suggestionsSchema = transform_schema(suggestionsSchema)

suggestedMealsSchema = TypeAdapter(SuggestedMeals).json_schema()
suggestedMealsSchema = transform_schema(suggestedMealsSchema)


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
            RecipeJobDocument,
        ],
    )
    yield
    await _end_running_work()
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


async def _get_category_names() -> list[str]:
    settings = await _get_or_create_settings()
    return [c.name for c in sorted(settings.categories, key=lambda c: c.order)]


async def _save_recipe(
    recipe: RecipeModelResponse, metadata: RecipeMetadata | None = None
) -> RecipeDocument:
    new_ingredients = [i for i in recipe.ingredients if i.is_new]
    existing_ingredients = [i for i in recipe.ingredients if not i.is_new]

    if new_ingredients:
        vectors = vo.embed(
            texts=[i.name for i in new_ingredients], model="voyage-4", output_dimension=2048
        ).embeddings
        await IngredientDocument.insert_many([
            IngredientDocument(
                name=item.name, unit=item.unit, embedding=vectors[i],
                category=item.category,
            )
            for i, item in enumerate(new_ingredients)
        ])

    # Backfill categories for existing ingredients from the DB cache
    category_map = {}
    if existing_ingredients:
        names = [i.name for i in existing_ingredients]
        cached = await IngredientDocument.find(
            In(IngredientDocument.name, names)
        ).to_list()
        category_map = {doc.name.lower(): doc.category for doc in cached if doc.category}

    ingredients = []
    for i in recipe.ingredients:
        category = i.category
        if not i.is_new and category == "Other":
            category = category_map.get(i.name.lower(), "Other")
        ingredients.append(IngredientRecipe(
            name=i.name, unit=i.unit, amount=i.amount,
            note=i.note, group=i.group, category=category,
        ))

    db_recipe = RecipeDocument(
        title=recipe.title,
        instructions=recipe.instructions,
        ingredients=ingredients,
        **(metadata.model_dump() if metadata else {}),
    )
    await db_recipe.insert()
    return db_recipe


@router.post("/recipes/generate/")
async def create_recipe(prompt: RecipePrompt):
    category_names = await _get_category_names()
    categories_str = ", ".join(category_names)
    system_message = {
        "role": "user",
        "content": f"You are a helpful recipe generation assistant. You act as a professional chef helping users turn leftover ingredients into a simple recipe with clear step-by-step instructions. Include ingredient amounts directly in the instruction steps (e.g. 'add the 500g pasta' not just 'add the pasta'). Once you've created a recipe, you must use the find_similar_ingredients tool to match your ingredients with ones from the database, if they exist and have a similarity value over .90. For each NEW ingredient (is_new=true), assign a category from this list: [{categories_str}]. For existing ingredients matched via the tool, you may leave the category as 'Other' — the system will use the cached category. Output the recipe in the given output format.",
    }

    runner = async_claude.beta.messages.tool_runner(
        model="claude-opus-4-5",
        max_tokens=2048,
        messages=[system_message, {"role": "user", "content": prompt.prompt}],
        tools=[find_similar_ingredients],
        stream=True,
        output_config={"format": {"type": "json_schema", "schema": recipeSchema}},
    )

    final_message = await runner.until_done()
    recipe = RecipeModelResponse.model_validate_json(final_message.content[0].text)
    return await _save_recipe(recipe)


@router.post("/recipes/suggest/")
async def suggest_meals(req: SuggestMealsRequest) -> MealSuggestions:
    constraints: list[str] = []
    if req.diet and req.diet.lower() != "any":
        constraints.append(f"Dietary preference: {req.diet}.")
    if req.ease and req.ease.lower() != "any":
        constraints.append(f"Effort level: {req.ease} to cook.")
    if req.notes and req.notes.strip():
        constraints.append(f"Additional notes from the user: {req.notes.strip()}")
    constraints_str = (
        " ".join(constraints) if constraints else "No specific constraints."
    )

    avoid_str = ""
    if req.exclude_titles:
        avoid_str = (
            " Do NOT suggest any of these meals, the user already has them: "
            + "; ".join(req.exclude_titles)
            + "."
        )

    prompt = (
        "You are a professional chef helping a home cook decide what to make this week. "
        "Suggest 5 distinct, appealing dinner ideas. For each idea give a short title and "
        "a single appetising sentence describing it. Respect these constraints: "
        f"{constraints_str}{avoid_str} Output the ideas in the given JSON format."
    )

    message = await async_claude.beta.messages.create(
        model="claude-opus-4-5",
        max_tokens=1024,
        messages=[{"role": "user", "content": prompt}],
        output_config={"format": {"type": "json_schema", "schema": suggestionsSchema}},
    )

    return MealSuggestions.model_validate_json(message.content[0].text)


class RecipeImage(NamedTuple):
    """An uploaded photo, read into memory: an upload is gone once its request ends."""

    media_type: str | None
    data: bytes


async def _read_images(files: list[UploadFile]) -> list[RecipeImage]:
    return [RecipeImage(f.content_type, await f.read()) for f in files]


async def _extract_and_save(images: list[RecipeImage], categories_str: str) -> RecipeDocument:
    image_blocks = []
    for image in images:
        data = base64.standard_b64encode(image.data).decode("utf-8")
        image_blocks.append({
            "type": "image",
            "source": {"type": "base64", "media_type": image.media_type, "data": data},
        })
    image_word = "this image" if len(images) == 1 else "these images"
    runner = async_claude.beta.messages.tool_runner(
        model="claude-opus-4-5",
        max_tokens=2048,
        messages=[{
            "role": "user",
            "content": [
                *image_blocks,
                {
                    "type": "text",
                    "text": f"Extract the recipe from {image_word}. The images may show different parts of the same recipe (e.g. ingredients on one page, method on another). Combine them into a single complete recipe. Include ingredient amounts directly in the instruction steps (e.g. 'add the 500g pasta' not just 'add the pasta'). Use find_similar_ingredients to match ingredients against the database. For each NEW ingredient (is_new=true), assign a category from this list: [{categories_str}]. For existing ingredients matched via the tool, you may leave the category as 'Other'. Output the recipe in the given JSON format.",
                },
            ],
        }],
        tools=[find_similar_ingredients],
        stream=True,
        output_config={"format": {"type": "json_schema", "schema": recipeSchema}},
    )
    final_message = await runner.until_done()
    recipe = RecipeModelResponse.model_validate_json(final_message.content[0].text)
    return await _save_recipe(recipe)


@router.post("/recipes/extract-from-images/")
async def extract_recipes_from_images(files: list[UploadFile], group_sizes: list[int] | None = None):
    """Extract recipes from grouped images.

    files: all image files, flattened
    group_sizes: list of ints indicating how many files belong to each recipe group.
                 e.g. [2, 1] means first 2 files = recipe 1, next 1 file = recipe 2.
                 If omitted, each file is treated as a separate recipe (backward compatible).
    """
    category_names = await _get_category_names()
    categories_str = ", ".join(category_names)

    if group_sizes:
        # Split files into groups
        groups: list[list[UploadFile]] = []
        offset = 0
        for size in group_sizes:
            groups.append(files[offset:offset + size])
            offset += size
        results = []
        for group in groups:
            result = await _extract_and_save(await _read_images(group), categories_str)
            results.append(result)
        return results
    else:
        # Backward compatible: each file is one recipe
        results = []
        for f in files:
            result = await _extract_and_save(await _read_images([f]), categories_str)
            results.append(result)
        return results


# --- Import from URL ---

# Enough of a page to hold a recipe, short enough that a content farm's worth of
# comments doesn't turn the fallback into an expensive call.
_FALLBACK_TEXT_CHARS = 20000


def _canonical_url(raw: str) -> str:
    """Normalise a submitted URL so dedup doesn't miss obvious repeats.

    Only the fragment is dropped — it never changes what the server returns.
    Query strings are left alone because plenty of sites put the recipe id
    there, and stripping them would collapse distinct recipes into one.
    """
    parsed = urlparse(raw.strip())
    return urlunparse(parsed._replace(fragment=""))


def _page_text(html: str) -> str:
    """Reduce a page to readable text for the model fallback."""
    soup = BeautifulSoup(html, "html.parser")
    for tag in soup(["script", "style", "noscript"]):
        tag.decompose()
    lines = (line.strip() for line in soup.get_text("\n").splitlines())
    return "\n".join(line for line in lines if line)[:_FALLBACK_TEXT_CHARS]


async def _recipe_from_page_text(
    text: str, categories_str: str
) -> RecipeModelResponse | None:
    """Last resort for pages that publish no structured data.

    Returns None when the page has no recipe on it — the model is told to
    answer with an empty recipe rather than oblige us with an invented one.
    """
    runner = async_claude.beta.messages.tool_runner(
        model="claude-opus-4-5",
        max_tokens=2048,
        messages=[{
            "role": "user",
            "content": f"Below is the text of a web page. Extract the recipe from it verbatim — the instructions are the author's and must not be rewritten or embellished. Include ingredient amounts directly in the instruction steps (e.g. 'add the 500g pasta' not just 'add the pasta'). Use find_similar_ingredients to match ingredients against the database. For each NEW ingredient (is_new=true), assign a category from this list: [{categories_str}]. For existing ingredients matched via the tool, leave the category as 'Other'.\n\nIf this page does not contain a recipe, return empty values for title, instructions and ingredients rather than composing one.\n\n---\n{text}",
        }],
        tools=[find_similar_ingredients],
        stream=True,
        output_config={"format": {"type": "json_schema", "schema": recipeSchema}},
    )
    final_message = await runner.until_done()
    recipe = RecipeModelResponse.model_validate_json(final_message.content[0].text)

    if not recipe.title or not recipe.instructions or not recipe.ingredients:
        return None
    return recipe


async def _apply_changes(
    recipe: RecipeModelResponse, changes: str, categories_str: str
) -> RecipeModelResponse:
    """Adapt an imported recipe to what the user typed alongside the link.

    Unchanged ingredients keep their structured form, so only swapped or added
    ones go back through find_similar_ingredients.
    """
    runner = async_claude.beta.messages.tool_runner(
        model="claude-opus-4-5",
        max_tokens=4096,
        messages=[{
            "role": "user",
            "content": f"Here is a recipe as JSON. Apply the user's requested changes to it and return the whole adapted recipe in the same format.\n\n- Change only what the request needs: swap or add ingredients, adjust amounts, and rewrite only the instruction steps the change affects (e.g. cooking times for a substituted ingredient). Leave everything else word for word.\n- Copy unchanged ingredients exactly as given, including is_new and category.\n- For every ingredient you add or swap in, call find_similar_ingredients to match it against the database (similarity over .90). For each NEW one (is_new=true), assign a category from this list: [{categories_str}]. For matched ones, set the category to 'Other'.\n- Update the title only if the change makes it wrong (e.g. it names an ingredient you removed).\n- Keep ingredient amounts in the instruction steps.\n\nRequested changes: {changes}\n\nRecipe:\n{recipe.model_dump_json()}",
        }],
        tools=[find_similar_ingredients],
        stream=True,
        output_config={"format": {"type": "json_schema", "schema": recipeSchema}},
    )
    final_message = await runner.until_done()
    return RecipeModelResponse.model_validate_json(final_message.content[0].text)


def _metadata_from(scraped: ScrapedRecipe) -> RecipeMetadata:
    return RecipeMetadata(
        servings=scraped.servings,
        prep_minutes=scraped.prep_minutes,
        cook_minutes=scraped.cook_minutes,
        total_minutes=scraped.total_minutes,
        image_url=scraped.image_url,
        source_url=scraped.source_url,
        source_name=scraped.source_name,
        description=scraped.description,
        cuisine=scraped.cuisine,
    )


@router.post("/recipes/import-from-url/")
async def import_recipe_from_url(body: ImportFromUrlRequest):
    """Import a recipe from a public web page.

    Two stages: scrape the page for structured data (free), then structure the
    free-text ingredient lines with Haiku. Pages that publish nothing readable
    fall back to Opus over the page text. Any `changes` typed alongside the
    link are applied last, by Opus.
    """
    url = _canonical_url(body.url)
    changes = (body.changes or "").strip()

    # Cheapest check first — a re-import shouldn't cost a fetch or a token.
    # Two simultaneous imports of the same URL can both get past this; the
    # index is deliberately non-unique, so that races to a duplicate rather
    # than an error. Re-importing is rare and a duplicate is deletable.
    # An adapted import is a new variant, so it skips the check.
    existing = (
        None if changes
        else await RecipeDocument.find_one(RecipeDocument.source_url == url)
    )
    if existing:
        raise HTTPException(
            status_code=409,
            detail={
                "message": "That page has already been imported.",
                "recipe_id": str(existing.id),
            },
        )

    try:
        html = await fetch_page(url)
    except BlockedURL as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except FetchFailed as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    categories_str = ", ".join(await _get_category_names())

    scraped = scrape(html, url)
    if scraped:
        ingredients = await structure_ingredients(
            scraped.ingredients,
            categories_str,
            async_claude,
            groups=scraped.ingredient_groups,
        )
        recipe = RecipeModelResponse(
            title=scraped.title,
            instructions=scraped.instructions,
            ingredients=ingredients,
        )
        metadata = _metadata_from(scraped)
    else:
        recipe = await _recipe_from_page_text(_page_text(html), categories_str)
        if not recipe:
            raise HTTPException(
                status_code=404, detail="No recipe found on that page."
            )
        # Nothing was published to read, so provenance is all we can honestly
        # record — no image, no times, no servings.
        metadata = RecipeMetadata(source_url=url, source_name=urlparse(url).hostname)

    if changes:
        recipe = await _apply_changes(recipe, changes, categories_str)

    return await _save_recipe(recipe, metadata)


@router.get("/recipes/")
async def list_recipes():
    recipes = await RecipeDocument.find_all().sort("-created_at").to_list()
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
        for r in recipes
    ]


@router.get("/recipes/{recipe_id}")
async def get_recipe(recipe_id: PydanticObjectId):
    recipe = await RecipeDocument.get(recipe_id)
    if not recipe:
        raise HTTPException(status_code=404, detail="Recipe not found")
    return recipe


@router.patch("/recipes/{recipe_id}/rating")
async def update_rating(recipe_id: PydanticObjectId, body: RatingUpdate):
    recipe = await RecipeDocument.get(recipe_id)
    if not recipe:
        raise HTTPException(status_code=404, detail="Recipe not found")
    recipe.rating = body.rating
    await recipe.save()
    return {"id": str(recipe.id), "rating": recipe.rating}


@router.put("/recipes/{recipe_id}")
async def update_recipe(recipe_id: PydanticObjectId, body: RecipeUpdateRequest):
    recipe = await RecipeDocument.get(recipe_id)
    if not recipe:
        raise HTTPException(status_code=404, detail="Recipe not found")

    old_names = {i.name.lower() for i in recipe.ingredients}
    recipe.title = body.title
    recipe.instructions = body.instructions
    recipe.ingredients = body.ingredients
    await recipe.save()

    # Fire-and-forget: embed any new ingredient names
    new_ingredients = [i for i in body.ingredients if i.name.lower() not in old_names]
    if new_ingredients:
        async def _embed_new():
            try:
                vectors = vo.embed(
                    texts=[i.name for i in new_ingredients],
                    model="voyage-4",
                    output_dimension=2048,
                ).embeddings
                await IngredientDocument.insert_many([
                    IngredientDocument(
                        name=item.name, unit=item.unit, embedding=vectors[idx],
                        category=item.category,
                    )
                    for idx, item in enumerate(new_ingredients)
                ])
            except Exception:
                pass  # Best-effort background embedding
        asyncio.create_task(_embed_new())

    return recipe


@router.delete("/recipes/{recipe_id}", status_code=204)
async def delete_recipe(recipe_id: PydanticObjectId):
    recipe = await RecipeDocument.get(recipe_id)
    if not recipe:
        raise HTTPException(status_code=404, detail="Recipe not found")
    await recipe.delete()


@router.patch("/recipes/{recipe_id}/ingredients/{ingredient_index}/exclude")
async def toggle_ingredient_exclude(
    recipe_id: PydanticObjectId, ingredient_index: int, body: ExcludeUpdateRequest
):
    recipe = await RecipeDocument.get(recipe_id)
    if not recipe:
        raise HTTPException(status_code=404, detail="Recipe not found")
    if ingredient_index < 0 or ingredient_index >= len(recipe.ingredients):
        raise HTTPException(status_code=404, detail="Ingredient not found")
    recipe.ingredients[ingredient_index].excluded_from_list = body.excluded
    await recipe.save()
    return {"index": ingredient_index, "excluded_from_list": body.excluded}


@router.get("/units")
async def get_units():
    pipeline = [
        {"$unwind": "$ingredients"},
        {"$group": {"_id": {"$toLower": "$ingredients.unit"}}},
        {"$sort": {"_id": 1}},
    ]
    results = await RecipeDocument.aggregate(pipeline).to_list()
    units = [r["_id"] for r in results if r["_id"]]
    return units


# --- Lists ---


def _ordinal(n: int) -> str:
    if 11 <= n % 100 <= 13:
        suffix = "th"
    else:
        suffix = {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return f"{n}{suffix}"


def _auto_list_name() -> str:
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc)
    return f"{_ordinal(now.day)} {now.strftime('%B')}"


@router.get("/lists/")
async def get_lists():
    lists = await ListDocument.find_all().sort("-created_at").to_list()
    results = []
    for lst in lists:
        recipes_summary = []
        if lst.recipes:
            oids = [PydanticObjectId(rid) for rid in lst.recipes]
            recipes = await RecipeDocument.find(In(RecipeDocument.id, oids)).to_list()
            recipes_summary = [{"id": str(r.id), "title": r.title} for r in recipes]
        results.append({
            "id": str(lst.id),
            "name": lst.name,
            "created_at": lst.created_at.isoformat() if lst.created_at else None,
            "item_count": len(lst.items),
            "checked_count": sum(1 for item in lst.items if item.checked),
            "recipes": recipes_summary,
        })
    return results


@router.post("/lists/")
async def create_list():
    lst = ListDocument(name=_auto_list_name())
    await lst.insert()
    return {"id": str(lst.id), "name": lst.name, "created_at": lst.created_at.isoformat()}


@router.get("/lists/{list_id}")
async def get_list(list_id: PydanticObjectId):
    lst = await ListDocument.get(list_id)
    if not lst:
        raise HTTPException(status_code=404, detail="List not found")
    return {
        "id": str(lst.id),
        "name": lst.name,
        "created_at": lst.created_at.isoformat() if lst.created_at else None,
        "recipes": lst.recipes,
        "items": [item.model_dump() for item in lst.items],
    }


@router.patch("/lists/{list_id}")
async def update_list(list_id: PydanticObjectId, body: ListUpdateRequest):
    lst = await ListDocument.get(list_id)
    if not lst:
        raise HTTPException(status_code=404, detail="List not found")
    if body.name is not None:
        lst.name = body.name
    await lst.save()
    return {"id": str(lst.id), "name": lst.name}


@router.delete("/lists/{list_id}")
async def delete_list(list_id: PydanticObjectId):
    lst = await ListDocument.get(list_id)
    if not lst:
        raise HTTPException(status_code=404, detail="List not found")
    await lst.delete()
    return {"ok": True}


@router.post("/lists/{list_id}/duplicate")
async def duplicate_list(list_id: PydanticObjectId):
    lst = await ListDocument.get(list_id)
    if not lst:
        raise HTTPException(status_code=404, detail="List not found")
    new_items = [
        ListItem(
            name=item.name,
            amount=item.amount,
            unit=item.unit,
            category=item.category,
            checked=False,
            sources=item.sources,
        )
        for item in lst.items
    ]
    new_lst = ListDocument(
        name=_auto_list_name(),
        recipes=list(lst.recipes),
        items=new_items,
    )
    await new_lst.insert()
    return {"id": str(new_lst.id), "name": new_lst.name, "created_at": new_lst.created_at.isoformat()}


# --- Settings ---


async def _get_or_create_settings() -> UserSettingsDocument:
    settings = await UserSettingsDocument.find_one()
    if not settings:
        settings = UserSettingsDocument()
        await settings.insert()
    return settings


@router.get("/settings/categories")
async def get_categories():
    settings = await _get_or_create_settings()
    return [c.model_dump() for c in settings.categories]


@router.put("/settings/categories")
async def update_categories(body: CategoriesUpdateRequest):
    settings = await _get_or_create_settings()
    settings.categories = [CategoryConfig(name=c.name, order=c.order) for c in body.categories]
    await settings.save()
    return [c.model_dump() for c in settings.categories]


# --- Categorization ---


@router.post("/categorize", response_model=CategorizeResponse)
async def categorize_item(body: CategorizeRequest):
    # 1. Check IngredientDocument cache (case-insensitive)
    escaped_name = re.escape(body.name)
    cached = await IngredientDocument.find_one(
        {"name": {"$regex": f"^{escaped_name}$", "$options": "i"}}
    )
    if cached and cached.category:
        return CategorizeResponse(category=cached.category)

    # 2. Fall back to Claude Haiku
    category_names = await _get_category_names()
    categories_str = ", ".join(category_names)

    response = await async_claude.messages.create(
        model="claude-haiku-4-5-20251001",
        max_tokens=50,
        messages=[{
            "role": "user",
            "content": f"Categorize this shopping item into exactly one of these categories: [{categories_str}]. Item: \"{body.name}\". Reply with just the category name, nothing else.",
        }],
    )
    category = response.content[0].text.strip()

    # Validate against user's categories, fall back to "Other"
    if category not in category_names:
        category = "Other"

    # 3. Persist to IngredientDocument cache if it already exists
    # (New ingredients without embeddings are only created during recipe import)
    if cached:
        cached.category = category
        await cached.save()

    return CategorizeResponse(category=category)


# --- List Recipes ---


class AddRecipeRequest(BaseModel):
    recipe_id: str


def _total_amount(sources: list[ItemSource]) -> float | None:
    """Sum the quantified sources, ignoring the ones with no amount.

    An item can be contributed by one recipe that says "200g" and another that
    just says "olive oil". The honest total is 200g — not 200 plus an invented
    zero — and an item nothing quantifies stays unquantified.
    """
    amounts = [s.amount for s in sources if s.amount is not None]
    if not amounts:
        return None
    return round(sum(amounts), 2)


@router.post("/lists/{list_id}/recipes")
async def add_recipe_to_list(list_id: PydanticObjectId, body: AddRecipeRequest):
    lst = await ListDocument.get(list_id)
    if not lst:
        raise HTTPException(status_code=404, detail="List not found")

    recipe = await RecipeDocument.get(PydanticObjectId(body.recipe_id))
    if not recipe:
        raise HTTPException(status_code=404, detail="Recipe not found")

    # Avoid adding the same recipe twice
    if body.recipe_id in lst.recipes:
        raise HTTPException(status_code=400, detail="Recipe already on this list")

    await _add_recipe(lst, recipe)
    return {
        "id": str(lst.id),
        "name": lst.name,
        "recipes": lst.recipes,
        "items": [item.model_dump() for item in lst.items],
    }


async def _add_recipe(lst: ListDocument, recipe: RecipeDocument) -> None:
    """Put a recipe's ingredients on a list and save it."""
    recipe_id = str(recipe.id)
    lst.recipes.append(recipe_id)

    # Merge recipe ingredients into list items (skip excluded)
    for ing in recipe.ingredients:
        if ing.excluded_from_list:
            continue
        source = ItemSource(recipe_id=recipe_id, amount=ing.amount)
        # Find existing item with same name + unit (case-insensitive name, exact unit)
        matched = None
        for item in lst.items:
            if item.name.lower() == ing.name.lower() and item.unit == ing.unit:
                matched = item
                break

        if matched:
            matched.sources.append(source)
            matched.amount = _total_amount(matched.sources)
        else:
            lst.items.append(ListItem(
                name=ing.name,
                amount=ing.amount,
                unit=ing.unit,
                category=ing.category,
                sources=[source],
            ))

    await lst.save()


@router.delete("/lists/{list_id}/recipes/{recipe_id}")
async def remove_recipe_from_list(list_id: PydanticObjectId, recipe_id: str):
    lst = await ListDocument.get(list_id)
    if not lst:
        raise HTTPException(status_code=404, detail="List not found")

    if recipe_id not in lst.recipes:
        raise HTTPException(status_code=404, detail="Recipe not on this list")

    lst.recipes.remove(recipe_id)

    # Subtract recipe's contributions from items
    remaining_items = []
    for item in lst.items:
        item.sources = [s for s in item.sources if s.recipe_id != recipe_id]
        if item.sources:
            item.amount = _total_amount(item.sources)
            remaining_items.append(item)
        # Items with no remaining sources are dropped
    lst.items = remaining_items

    await lst.save()
    return {
        "id": str(lst.id),
        "name": lst.name,
        "recipes": lst.recipes,
        "items": [item.model_dump() for item in lst.items],
    }


# --- List Items ---


@router.post("/lists/{list_id}/items")
async def add_item(list_id: PydanticObjectId, body: ItemCreateRequest):
    lst = await ListDocument.get(list_id)
    if not lst:
        raise HTTPException(status_code=404, detail="List not found")
    if body.id:
        existing = next((i for i in lst.items if i.id == body.id), None)
        if existing:
            # A retried offline add. It already landed; don't add it twice.
            return existing.model_dump()
    item = ListItem(
        name=body.name,
        amount=body.amount,
        unit=body.unit,
        category=body.category,
        sources=[ItemSource(recipe_id=None, amount=body.amount)],
        **({"id": body.id} if body.id else {}),
    )
    lst.items.append(item)
    await lst.save()
    return item.model_dump()


@router.put("/lists/{list_id}/items/reorder")
async def reorder_items(list_id: PydanticObjectId, body: ItemReorderRequest):
    lst = await ListDocument.get(list_id)
    if not lst:
        raise HTTPException(status_code=404, detail="List not found")

    by_id = {item.id: item for item in lst.items}
    # Only reorder items that exist and belong to the given category.
    ordered = [
        by_id[item_id]
        for item_id in body.item_ids
        if item_id in by_id and by_id[item_id].category == body.category
    ]
    # The slots currently occupied by the reordered items stay put; we just
    # rewrite them in the new order, leaving everything else in place.
    reordered_ids = {item.id for item in ordered}
    slots = [idx for idx, item in enumerate(lst.items) if item.id in reordered_ids]
    for slot, item in zip(slots, ordered):
        lst.items[slot] = item

    await lst.save()
    return {"items": [item.model_dump() for item in lst.items]}


@router.patch("/lists/{list_id}/items/{item_id}")
async def update_item(list_id: PydanticObjectId, item_id: str, body: ItemUpdateRequest):
    lst = await ListDocument.get(list_id)
    if not lst:
        raise HTTPException(status_code=404, detail="List not found")
    for item in lst.items:
        if item.id == item_id:
            if body.name is not None:
                item.name = body.name
            # amount and unit can be cleared, so an explicit null counts.
            if "amount" in body.model_fields_set:
                item.amount = body.amount
            if "unit" in body.model_fields_set:
                item.unit = body.unit
            if body.category is not None:
                item.category = body.category
            if body.checked is not None:
                item.checked = body.checked
            await lst.save()
            return item.model_dump()
    raise HTTPException(status_code=404, detail="Item not found")


@router.delete("/lists/{list_id}/items/{item_id}")
async def delete_item(list_id: PydanticObjectId, item_id: str):
    lst = await ListDocument.get(list_id)
    if not lst:
        raise HTTPException(status_code=404, detail="List not found")
    original_len = len(lst.items)
    lst.items = [item for item in lst.items if item.id != item_id]
    if len(lst.items) == original_len:
        raise HTTPException(status_code=404, detail="Item not found")
    await lst.save()
    return {"ok": True}



# --- Background work ---
# A recipe job and a Discover card's save both make a recipe in a task that
# lives in this server's memory, with nobody waiting on a request. What bounds
# such work is here, above both: a limit on the making, a rule for work whose
# task was lost, a write of how it ended that outlasts a refusal and a
# shutdown, and shutdown ending what this instance is running.

# Longer than any honest making: the slowest is a link with changes, which is
# a page fetch and three model calls of a few thousand tokens. Work still
# running after this is cancelled, which bounds what it can spend. It does not
# promise that work ending failed saved nothing: a cancel that lands while the
# recipe's insert is on its way to Mongo leaves the recipe behind.
BACKGROUND_WORK_TIME_LIMIT = timedelta(minutes=5)
# The limit plus a minute to record how the work ended. Work still reading as
# under way after this lost its task, which is what a killed server does to
# it. Clients treat this as the longest a job or a save can be outstanding.
BACKGROUND_WORK_STALE_AFTER = BACKGROUND_WORK_TIME_LIMIT + timedelta(minutes=1)
# Seconds to wait before each try at writing how the work ended, and the
# longest this side waits on one try: 36 seconds if every try hangs. That
# bounds the waiting, not Mongo: a write given up on here can still land
# later, so work read as stale may yet turn saved.
END_WRITE_PAUSES = (0, 1, 5)
END_WRITE_TIMEOUT = 10


class _TimeLimitReached(Exception):
    """The making outran `BACKGROUND_WORK_TIME_LIMIT` and was cancelled."""


async def _within_time_limit[T](making: Awaitable[T]) -> T:
    """Awaits the making, cancelling it once the limit is up.

    A `TimeoutError` out of here came from inside the making (a page or a
    model that did not answer) and is that making's own failure.
    """
    limit = asyncio.timeout(BACKGROUND_WORK_TIME_LIMIT.total_seconds())
    try:
        async with limit:
            return await making
    except TimeoutError:
        if limit.expired():
            raise _TimeLimitReached from None
        raise


def _lost_its_task(started: datetime) -> bool:
    """Whether work that began then, and still reads as under way, has outlived any task doing it."""
    if started.tzinfo is None:
        # Mongo hands datetimes back without their zone; they were stored as UTC.
        started = started.replace(tzinfo=timezone.utc)
    return datetime.now(timezone.utc) - started > BACKGROUND_WORK_STALE_AFTER


async def _written(write: Callable[[], Awaitable[object]], what: str) -> bool:
    """Writes how background work ended, more than once if Mongo will not take it.

    If every try fails the work still reads as under way and is answered as
    failed once it is stale, whatever it really did. The log says which.
    """
    for pause in END_WRITE_PAUSES:
        await asyncio.sleep(pause)
        try:
            await asyncio.wait_for(write(), END_WRITE_TIMEOUT)
            return True
        except Exception:
            logger.exception("%s and that could not be written", what)
    return False


async def _through_shutdown(writing: Awaitable[None]) -> None:
    """Awaits a write that a cancel must not stop.

    Shutdown can arrive mid-write. What is being written is how the work
    really ended, so it is finished, not replaced.
    """
    write = asyncio.ensure_future(writing)
    try:
        await asyncio.shield(write)
    except asyncio.CancelledError:
        await write


async def _end_running_work() -> None:
    """Stops this instance's recipe jobs and card saves and waits for each to be written as failed.

    A deploy would otherwise leave them "working" or "saving" until they are
    stale. Only this instance's tasks: another instance's are still being made.
    """
    tasks = [*_recipe_job_tasks, *_suggestion_save_tasks]
    for task in tasks:
        task.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)


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

# Saving a card makes its recipe in a task that lives in this server's memory,
# under the bounds in "Background work" above. A save is one run of that task,
# and the card's `saving_since` names the run that owns the card: starting a
# save and recording how it ended are both writes that happen only if the
# card is still as the writer last knew it, so two requests cannot both start
# one, and a run cannot write over a card that was saved again, cleared or
# dismissed while it worked.
_suggestion_save_tasks: set[asyncio.Task] = set()

SAVE_INTERRUPTED = "The save was interrupted. Try again."
NOT_PUT_ON_THE_LIST = "The recipe was made, but it could not be added to your list. Try again."


def _save_may_be_running(s: SuggestionDocument) -> bool:
    """Whether a save of this card can still be under way.

    Not that one is: a killed server leaves the card saving with no task, and
    that is only known once the save has outlived any task. A card left saving
    by a server from before `saving_since` has none, and its save is lost.
    """
    return (
        s.status == "saving"
        and s.saving_since is not None
        and not _lost_its_task(s.saving_since)
    )


async def _write_if_unchanged(s: SuggestionDocument, change: dict) -> SuggestionDocument | None:
    """Changes the card only if no save of it has started or ended since `s` was read.

    One conditional update, so of several writers holding the same reading
    Mongo lets one through. Answers the card as written, or None if it had
    moved on and nothing was written.
    """
    return await SuggestionDocument.find_one(
        {"_id": s.id, "status": s.status, "saving_since": s.saving_since}
    ).update({"$set": change}, response_type=UpdateResponse.NEW_DOCUMENT)


def _suggestion_out(s: SuggestionDocument) -> dict:
    status, error = s.status, s.error
    if status == "saving" and not _save_may_be_running(s):
        # Decided when read, not written: see `_recipe_job_out`.
        status, error = "failed", SAVE_INTERRUPTED
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
        "status": status,
        "origin": s.origin,
        "recipe_id": s.recipe_id,
        "error": error,
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


async def _taste_profile() -> str:
    """What we know about this household's taste, as prompt text.

    Every signal the UI collects ends up here: star ratings (including the
    "How was it?" at the end of Cook), "Not for me" on Discover cards, and
    what's on the latest shopping list.
    """
    lines: list[str] = []
    rated = await RecipeDocument.find(RecipeDocument.rating != None).to_list()  # noqa: E711
    liked = [f"{r.title} ({r.rating} stars)" for r in rated if (r.rating or 0) >= 4]
    disliked = [f"{r.title} ({r.rating} stars)" for r in rated if (r.rating or 0) <= 2]
    if liked:
        lines.append("They loved: " + "; ".join(liked[:15]) + ".")
    if disliked:
        lines.append("They didn't enjoy: " + "; ".join(disliked[:10]) + ".")

    dismissed = (
        await SuggestionDocument.find(SuggestionDocument.status == "dismissed")
        .sort("-created_at")
        .limit(20)
        .to_list()
    )
    if dismissed:
        lines.append(
            "They said 'not for me' to: " + "; ".join(d.title for d in dismissed) + "."
        )

    latest = await ListDocument.find_all().sort("-created_at").limit(1).to_list()
    if latest:
        on_list = [i.name for i in latest[0].items if not i.checked][:30]
        if on_list:
            lines.append("On their current shopping list: " + ", ".join(on_list) + ".")

    return " ".join(lines) or "No taste signals yet."


@router.post("/suggestions/refresh")
async def refresh_suggestions(req: SuggestionRefreshRequest):
    constraints: list[str] = []
    if req.diet and req.diet.lower() != "any":
        constraints.append(f"Dietary preference: {req.diet}.")
    if req.ease and req.ease.lower() != "any":
        constraints.append(f"Effort level: {req.ease} to cook.")
    if req.notes and req.notes.strip():
        constraints.append(f"Additional notes from the user: {req.notes.strip()}")

    library = await RecipeDocument.find_all().to_list()
    shown = (
        await SuggestionDocument.find_all().sort("-created_at").limit(60).to_list()
    )
    avoid = [r.title for r in library] + [s.title for s in shown]

    prompt = (
        "You are a professional chef helping a home cook discover new things to make. "
        "Suggest 6 distinct dinner ideas: two 'For this week', two 'Under 30 minutes' "
        "and two 'Something new' that stretch their usual cooking. For each, give a "
        "short title, one appetising sentence, a rough total time in minutes, and a "
        "reason it suits them that a person would find specific and true, grounded in "
        f"the signals below.\n\nTaste signals: {await _taste_profile()}\n"
        f"Constraints: {' '.join(constraints) or 'None.'}\n"
        + (f"Do NOT suggest any of these, they already have or saw them: {'; '.join(avoid[:80])}.\n" if avoid else "")
        + "Output the ideas in the given JSON format."
    )

    message = await async_claude.beta.messages.create(
        model="claude-opus-4-5",
        max_tokens=2048,
        messages=[{"role": "user", "content": prompt}],
        output_config={"format": {"type": "json_schema", "schema": suggestedMealsSchema}},
    )
    ideas = SuggestedMeals.model_validate_json(message.content[0].text)
    docs = [
        SuggestionDocument(
            title=i.title,
            description=i.description,
            reason=i.reason,
            total_minutes=i.total_minutes,
            section=i.section,
            origin="suggest",
        )
        for i in ideas.suggestions
    ]
    # One at a time so each document gets its id back for the response.
    for d in docs:
        await d.insert()
    return [_suggestion_out(d) for d in docs]


@router.post("/suggestions/clear")
async def clear_suggestions(body: SuggestionsClearRequest):
    """Hide these cards (or every visible card) without counting it against them.

    A card whose save may be running is left: the card is that save's to end.
    """
    named = {} if body.ids is None else {"_id": {"$in": [PydanticObjectId(i) for i in body.ids]}}
    result = await SuggestionDocument.find(
        {"status": {"$in": ["new", "saved", "failed"]}, **named}
    ).update({"$set": {"status": "cleared"}})
    cleared = getattr(result, "modified_count", 0)
    for s in await SuggestionDocument.find({"status": "saving", **named}).to_list():
        if not _save_may_be_running(s) and await _write_if_unchanged(s, {"status": "cleared"}):
            cleared += 1
    return {"cleared": cleared}


@router.patch("/suggestions/{suggestion_id}")
async def update_suggestion(suggestion_id: PydanticObjectId, body: SuggestionStatusUpdate):
    s = await _get_suggestion(suggestion_id)
    # Only the status: writing the whole card back would undo a save that started or ended since the read.
    await SuggestionDocument.find_one({"_id": s.id}).update({"$set": {"status": body.status}})
    s.status = body.status
    return _suggestion_out(s)


async def _add_recipe_to_list_id(list_id: str, recipe: RecipeDocument) -> None:
    lst = await ListDocument.get(PydanticObjectId(list_id))
    if lst and str(recipe.id) not in lst.recipes:
        await _add_recipe(lst, recipe)


async def _recipe_for(s: SuggestionDocument) -> RecipeDocument:
    """The card as a recipe: the one an earlier save made, imported from its link, or written from its title."""
    if s.recipe_id:
        # An earlier save got as far as the recipe. Making it again would be a second copy.
        made = await RecipeDocument.get(PydanticObjectId(s.recipe_id))
        if made:
            return made
    if s.source_url:
        try:
            recipe = await import_recipe_from_url(ImportFromUrlRequest(url=s.source_url))
        except HTTPException as exc:
            if exc.status_code != 409:
                raise
            recipe = await RecipeDocument.get(PydanticObjectId(exc.detail["recipe_id"]))
    else:
        prompt = f"Create a recipe for: {s.title}. {s.description or ''}".strip()
        recipe = await create_recipe(RecipePrompt(prompt=prompt))
    if recipe is None:
        raise RuntimeError("No recipe came back")
    return recipe


async def _end_save(
    s: SuggestionDocument, end: dict, recipe: RecipeDocument | None, list_id: str | None
) -> None:
    """Puts the recipe on its list, then writes once how the save ended.

    In that order so that a card reading saved has its meal on the list, which
    is when clients fetch the list. This has to fit the minute between the
    time limit and the stale bound: `END_WRITE_TIMEOUT` for the list (10 s)
    and three tries at the write (36 s).
    """
    if recipe is not None and list_id:
        try:
            await asyncio.wait_for(_add_recipe_to_list_id(list_id, recipe), END_WRITE_TIMEOUT)
        except Exception:
            logger.exception("Suggestion %s: recipe %s could not be put on list %s", s.id, recipe.id, list_id)
            # Keeps the recipe, so saving the card again only has the list left to do.
            end = {"status": "failed", "recipe_id": str(recipe.id), "error": NOT_PUT_ON_THE_LIST}

    async def write() -> None:
        if await _write_if_unchanged(s, end) is None:
            logger.info("Suggestion %s was no longer this save's to end, so nothing was written", s.id)

    await _written(write, f"Suggestion {s.id} ended {end['status']} (recipe {end.get('recipe_id')})")


async def _realise_suggestion(s: SuggestionDocument, list_id: str | None) -> None:
    """Turn a suggestion into a saved recipe, off the request path.

    `s` is the card as this save claimed it, which is what its end is written against.
    """
    recipe: RecipeDocument | None = None
    try:
        recipe = await _within_time_limit(_recipe_for(s))
        end = {"status": "saved", "recipe_id": str(recipe.id), "error": None}
    except asyncio.CancelledError:
        # The server is shutting down, and waits for this save to be written off.
        end = {"status": "failed", "error": SAVE_INTERRUPTED}
    except _TimeLimitReached:
        logger.warning("Saving suggestion %s ran past its time limit", s.id)
        end = {"status": "failed", "error": SAVE_INTERRUPTED}
    except Exception as exc:  # surfaced on the card, so the user can retry
        error = str(exc.detail if isinstance(exc, HTTPException) else exc)[:200]
        end = {"status": "failed", "error": error}
    await _through_shutdown(_end_save(s, end, recipe, list_id))


@router.post("/suggestions/{suggestion_id}/save")
async def save_suggestion(suggestion_id: PydanticObjectId, body: SuggestionSaveRequest):
    """Save a card as a recipe. Returns at once; the recipe fills in after.

    With `list_id`, the recipe also goes on that list once it exists. A card
    already being saved is left to it; one whose save was lost is saved afresh.
    """
    s = await _get_suggestion(suggestion_id)

    if s.status == "saved" and s.recipe_id:
        if body.list_id:
            recipe = await RecipeDocument.get(PydanticObjectId(s.recipe_id))
            if recipe:
                await _add_recipe_to_list_id(body.list_id, recipe)
        return _suggestion_out(s)

    if _save_may_be_running(s):
        return _suggestion_out(s)

    claimed = await _write_if_unchanged(
        s, {"status": "saving", "saving_since": datetime.now(timezone.utc), "error": None}
    )
    if claimed is None:
        # Another request got to the card between the read and the claim.
        return _suggestion_out(await _get_suggestion(suggestion_id))
    task = asyncio.create_task(_realise_suggestion(claimed, body.list_id))
    _suggestion_save_tasks.add(task)
    task.add_done_callback(_suggestion_save_tasks.discard)
    return _suggestion_out(claimed)


# --- Recipe jobs ---
# Making a recipe waits on a model for a minute or more, and a phone that
# switches apps drops the request while the work carries on here. A job is the
# same work started without waiting, under a key the client mints before it
# sends anything. A start names its key, so sending it again (its answer was
# lost, or the app was killed) finds the job there and starts nothing. Each
# job calls the endpoint function a waiting client would have called, so the
# two cannot drift apart.

# Each job is a model call somebody pays for and nobody is waiting on, so only
# a few run at once. One household makes one recipe at a time. Counted from
# this instance's own tasks, so a job orphaned by a kill holds no place, and so
# the cap is per instance: two overlapping in a deploy can run this many each.
MAX_WORKING_RECIPE_JOBS = 4
# The iOS picker takes six photos and re-encodes each as a JPEG no longer than
# 2000 px. 5 MB is the most the model takes for one image.
MAX_JOB_PHOTOS = 6
MAX_JOB_PHOTO_BYTES = 5 * 1024 * 1024
# The image types the model reads, by what the upload says it is: the bytes are not inspected.
JOB_PHOTO_TYPES = {"image/jpeg", "image/png", "image/gif", "image/webp"}

_recipe_job_tasks: set[asyncio.Task] = set()
# Keys of starts that have passed the cap and not yet made their task.
_recipe_jobs_starting: set[str] = set()

_JOB_FAILED = RecipeJobEnd(status="failed", failure="other")

_LINK_FAILURES = {
    400: "link_blocked",
    404: "no_recipe_on_page",
    502: "site_did_not_respond",
}


def _refused(_exc: HTTPException) -> RecipeJobEnd:
    return _JOB_FAILED


def _link_refused(exc: HTTPException) -> RecipeJobEnd:
    """How import-from-url's refusals end a job: its 409 is a recipe, not a failure."""
    if exc.status_code == 409:
        return RecipeJobEnd(status="already_imported", recipe_id=exc.detail["recipe_id"])
    return RecipeJobEnd(
        status="failed", failure=_LINK_FAILURES.get(exc.status_code, "other")
    )


def _recipe_job_out(job: RecipeJobDocument) -> dict:
    status, failure = job.status, job.failure
    if status == "working" and _lost_its_task(job.created_at):
        status, failure = "failed", "other"
    return {
        "key": job.id,
        "kind": job.kind,
        "status": status,
        "recipe_id": job.recipe_id,
        "failure": failure,
    }


async def _record_end(job: RecipeJobDocument, end: RecipeJobEnd) -> None:
    job.status, job.recipe_id, job.failure = end.status, end.recipe_id, end.failure
    await _written(
        job.save, f"Recipe job {job.id} ended {end.status} (recipe {end.recipe_id})"
    )


async def _run_recipe_job(
    job: RecipeJobDocument,
    make: Callable[[], Awaitable[RecipeDocument]],
    refused: Callable[[HTTPException], RecipeJobEnd],
) -> None:
    try:
        recipe = await _within_time_limit(make())
        end = RecipeJobEnd(status="saved", recipe_id=str(recipe.id))
    except HTTPException as exc:
        end = refused(exc)
    except asyncio.CancelledError:
        # The server is shutting down, and waits for this job to be written off.
        end = _JOB_FAILED
    except _TimeLimitReached:
        # An expected ending and not a crash.
        logger.warning("Recipe job %s ran past its time limit", job.id)
        end = _JOB_FAILED
    except Exception:
        # Nobody is waiting on this request, so the log is the only trace.
        logger.exception("Recipe job %s failed", job.id)
        end = _JOB_FAILED
    await _through_shutdown(_record_end(job, end))


async def _start_recipe_job(
    key: UUID,
    kind: RecipeJobKind,
    make: Callable[[], Awaitable[RecipeDocument]],
    response: Response,
    refused: Callable[[HTTPException], RecipeJobEnd] = _refused,
) -> dict:
    """Starts the job with this key, or answers with the one already there.

    202 for a job this call started and 200 for one it found, whatever that
    job was started with: the key is the job.
    """
    name = str(key)
    job = await RecipeJobDocument.get(name)
    if job is None:
        # A start for this key that is already past the cap holds the place:
        # this one is a repeat, and falls through to find the job it makes.
        twin_is_starting = name in _recipe_jobs_starting
        # Checked and reserved with no await between, so a burst cannot pass the cap together.
        if (
            not twin_is_starting
            and len(_recipe_job_tasks) + len(_recipe_jobs_starting) >= MAX_WORKING_RECIPE_JOBS
        ):
            raise HTTPException(
                status_code=429,
                detail="Too many recipes are being made. Try again shortly.",
                headers={"Retry-After": "30"},
            )
        _recipe_jobs_starting.add(name)
        try:
            job = RecipeJobDocument(id=name, kind=kind)
            try:
                await job.insert()
            except DuplicateKeyError:
                # Another start with this key got in between the look and the insert.
                job = await RecipeJobDocument.get(name)
            else:
                task = asyncio.create_task(_run_recipe_job(job, make, refused))
                _recipe_job_tasks.add(task)
                task.add_done_callback(_recipe_job_tasks.discard)
                return _recipe_job_out(job)
        finally:
            if not twin_is_starting:
                _recipe_jobs_starting.discard(name)
        if job is None:
            # Refused by the index and then not there: answered as a fault, which a client tries again.
            raise HTTPException(status_code=503, detail="That recipe job could not be read. Try again.")
    response.status_code = 200
    return _recipe_job_out(job)


@router.put("/recipe-jobs/{key}/link", status_code=202)
async def start_link_job(key: UUID, body: ImportFromUrlRequest, response: Response):
    """`POST /recipes/import-from-url/` as the job with this key."""
    return await _start_recipe_job(
        key, "link", lambda: import_recipe_from_url(body), response, _link_refused
    )


@router.put("/recipe-jobs/{key}/describe", status_code=202)
async def start_describe_job(key: UUID, prompt: RecipePrompt, response: Response):
    """`POST /recipes/generate/` as the job with this key."""
    return await _start_recipe_job(key, "describe", lambda: create_recipe(prompt), response)


@router.put("/recipe-jobs/{key}/photos", status_code=202)
async def start_photos_job(key: UUID, files: list[UploadFile], response: Response):
    """One recipe read from every photo sent, as the job with this key.

    This is `POST /recipes/extract-from-images/` with a single group, since a
    job ends in one recipe.
    """
    too_much = HTTPException(
        status_code=413,
        detail=f"A recipe is read from up to {MAX_JOB_PHOTOS} photos of up to "
        f"{MAX_JOB_PHOTO_BYTES // (1024 * 1024)} MB each.",
    )
    if len(files) > MAX_JOB_PHOTOS:
        raise too_much
    not_photos = HTTPException(
        status_code=422, detail="Send at least one photo, each a JPEG, PNG, GIF or WebP."
    )
    if not files:
        raise not_photos
    images = []
    for file in files:
        data = await file.read(MAX_JOB_PHOTO_BYTES + 1)
        if len(data) > MAX_JOB_PHOTO_BYTES:
            raise too_much
        # Checked here, before a job exists: a model asked to read nothing invents a recipe.
        if not data or file.content_type not in JOB_PHOTO_TYPES:
            raise not_photos
        images.append(RecipeImage(file.content_type, data))

    async def make() -> RecipeDocument:
        categories_str = ", ".join(await _get_category_names())
        return await _extract_and_save(images, categories_str)

    return await _start_recipe_job(key, "photos", make, response)


@router.get("/recipe-jobs/{key}")
async def get_recipe_job(key: UUID):
    """How a job stands: working, saved, already_imported or failed."""
    job = await RecipeJobDocument.get(str(key))
    if not job:
        raise HTTPException(status_code=404, detail="Recipe job not found")
    return _recipe_job_out(job)


app.include_router(router)
