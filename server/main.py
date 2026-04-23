import asyncio
import base64
import re
from contextlib import asynccontextmanager

from anthropic import AsyncAnthropic, transform_schema
from beanie import PydanticObjectId, init_beanie
from dotenv import load_dotenv
from fastapi import APIRouter, FastAPI, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, TypeAdapter

from data_models import IngredientDocument, ListDocument, RecipeDocument, UserSettingsDocument
from lib.db import get_motor_client, vo
from beanie.operators import In
from data_models import CategoryConfig, ItemSource, ListItem
from lib.types import (
    CategoriesUpdateRequest,
    CategorizeRequest,
    CategorizeResponse,
    ExcludeUpdateRequest,
    IngredientRecipe,
    ItemCreateRequest,
    ItemUpdateRequest,
    ListUpdateRequest,
    RatingUpdate,
    RecipeModelResponse,
    RecipePrompt,
    RecipeUpdateRequest,
)
from tools import find_similar_ingredients

load_dotenv()

async_claude = AsyncAnthropic()

recipeSchema = TypeAdapter(RecipeModelResponse).json_schema()
recipeSchema = transform_schema(recipeSchema)


@asynccontextmanager
async def lifespan(app: FastAPI):
    client = get_motor_client()
    await init_beanie(
        database=client["omlete"],
        document_models=[IngredientDocument, RecipeDocument, ListDocument, UserSettingsDocument],
    )
    yield
    client.close()


app = FastAPI(lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173"],
    allow_origin_regex=r"https://.*\.up\.railway\.app",
    allow_methods=["*"],
    allow_headers=["*"],
)
router = APIRouter(prefix="/api")


async def _get_category_names() -> list[str]:
    settings = await _get_or_create_settings()
    return [c.name for c in sorted(settings.categories, key=lambda c: c.order)]


async def _save_recipe(recipe: RecipeModelResponse) -> RecipeDocument:
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
        ingredients.append(IngredientRecipe(name=i.name, unit=i.unit, amount=i.amount, category=category))

    db_recipe = RecipeDocument(
        title=recipe.title,
        instructions=recipe.instructions,
        ingredients=ingredients,
    )
    await db_recipe.insert()
    return db_recipe


@router.post("/recipes/generate/")
async def create_recipe(prompt: RecipePrompt):
    category_names = await _get_category_names()
    categories_str = ", ".join(category_names)
    system_message = {
        "role": "user",
        "content": f"You are a helpful recipe generation assistant. You act as a professional chef helping users turn leftover ingredients into a simple recipe with clear step-by-step instructions. Once you've created a recipe, you must use the find_similar_ingredients tool to match your ingredients with ones from the database, if they exist and have a similarity value over .90. For each NEW ingredient (is_new=true), assign a category from this list: [{categories_str}]. For existing ingredients matched via the tool, you may leave the category as 'Other' — the system will use the cached category. Output the recipe in the given output format.",
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


async def _extract_and_save(files: list[UploadFile], categories_str: str) -> RecipeDocument:
    image_blocks = []
    for file in files:
        data = base64.standard_b64encode(await file.read()).decode("utf-8")
        image_blocks.append({
            "type": "image",
            "source": {"type": "base64", "media_type": file.content_type, "data": data},
        })
    image_word = "this image" if len(files) == 1 else "these images"
    runner = async_claude.beta.messages.tool_runner(
        model="claude-opus-4-5",
        max_tokens=2048,
        messages=[{
            "role": "user",
            "content": [
                *image_blocks,
                {
                    "type": "text",
                    "text": f"Extract the recipe from {image_word}. The images may show different parts of the same recipe (e.g. ingredients on one page, method on another). Combine them into a single complete recipe. Use find_similar_ingredients to match ingredients against the database. For each NEW ingredient (is_new=true), assign a category from this list: [{categories_str}]. For existing ingredients matched via the tool, you may leave the category as 'Other'. Output the recipe in the given JSON format.",
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
            result = await _extract_and_save(group, categories_str)
            results.append(result)
        return results
    else:
        # Backward compatible: each file is one recipe
        results = []
        for f in files:
            result = await _extract_and_save([f], categories_str)
            results.append(result)
        return results


@router.get("/recipes/")
async def list_recipes():
    recipes = await RecipeDocument.find_all().sort("-created_at").to_list()
    return [
        {
            "id": str(r.id),
            "title": r.title,
            "ingredient_count": len(r.ingredients),
            "rating": r.rating,
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


def _auto_list_name() -> str:
    from datetime import datetime, timezone, timedelta
    now = datetime.now(timezone.utc)
    monday = now - timedelta(days=now.weekday())
    return f"Week of {monday.strftime('%b %d')}"


@router.get("/lists/")
async def get_lists():
    lists = await ListDocument.find_all().sort("-created_at").to_list()
    results = []
    for lst in lists:
        recipe_titles = []
        if lst.recipes:
            oids = [PydanticObjectId(rid) for rid in lst.recipes]
            recipes = await RecipeDocument.find(In(RecipeDocument.id, oids)).to_list()
            recipe_titles = [r.title for r in recipes]
        results.append({
            "id": str(lst.id),
            "name": lst.name,
            "created_at": lst.created_at.isoformat() if lst.created_at else None,
            "item_count": len(lst.items),
            "checked_count": sum(1 for item in lst.items if item.checked),
            "recipe_titles": recipe_titles,
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

    lst.recipes.append(body.recipe_id)

    # Merge recipe ingredients into list items (skip excluded)
    for ing in recipe.ingredients:
        if ing.excluded_from_list:
            continue
        source = ItemSource(recipe_id=body.recipe_id, amount=ing.amount)
        # Find existing item with same name + unit (case-insensitive name, exact unit)
        matched = None
        for item in lst.items:
            if item.name.lower() == ing.name.lower() and item.unit == ing.unit:
                matched = item
                break

        if matched:
            matched.sources.append(source)
            matched.amount = round(sum(s.amount for s in matched.sources), 2)
        else:
            lst.items.append(ListItem(
                name=ing.name,
                amount=ing.amount,
                unit=ing.unit,
                category=ing.category,
                sources=[source],
            ))

    await lst.save()
    return {
        "id": str(lst.id),
        "name": lst.name,
        "recipes": lst.recipes,
        "items": [item.model_dump() for item in lst.items],
    }


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
            item.amount = round(sum(s.amount for s in item.sources), 2)
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
    item = ListItem(
        name=body.name,
        amount=body.amount,
        unit=body.unit,
        category=body.category,
        sources=[ItemSource(recipe_id=None, amount=body.amount or 0)],
    )
    lst.items.append(item)
    await lst.save()
    return item.model_dump()


@router.patch("/lists/{list_id}/items/{item_id}")
async def update_item(list_id: PydanticObjectId, item_id: str, body: ItemUpdateRequest):
    lst = await ListDocument.get(list_id)
    if not lst:
        raise HTTPException(status_code=404, detail="List not found")
    for item in lst.items:
        if item.id == item_id:
            if body.name is not None:
                item.name = body.name
            if body.amount is not None:
                item.amount = body.amount
            if body.unit is not None:
                item.unit = body.unit
            if body.category is not None:
                item.category = body.category
            if body.checked is not None:
                item.checked = body.checked
            if "photo" in body.model_fields_set:
                item.photo = body.photo
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


app.include_router(router)
