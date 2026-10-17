"""Recipes: making, importing, editing and deleting them.

Shared by the routes and by Chef's tools, so neither has to go through the
other. Errors are typed HTTPExceptions: a route passes them straight through,
and a tool reads the type.
"""

import asyncio
import base64
from typing import NamedTuple
from urllib.parse import urlparse, urlunparse

from anthropic import transform_schema
from beanie import PydanticObjectId
from beanie.operators import In
from bs4 import BeautifulSoup
from pydantic import TypeAdapter

from data_models import IngredientDocument, RecipeDocument
from ingredient_structurer import structure_ingredients
from lib.claude import async_claude
from lib.db import vo
from lib.types import IngredientRecipe, RecipeMetadata, RecipeModelResponse
from recipe_import import BlockedURL, FetchFailed, ScrapedRecipe, fetch_page, scrape
from services.errors import AlreadyImported, Invalid, NotFound, Unreachable
from services.settings import category_names
from tools import find_similar_ingredients

recipeSchema = TypeAdapter(RecipeModelResponse).json_schema()
recipeSchema = transform_schema(recipeSchema)


async def save(
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


async def generate(prompt: str) -> RecipeDocument:
    """Write a recipe from a description or a list of ingredients."""
    categories_str = ", ".join(await category_names())
    system_message = {
        "role": "user",
        "content": f"You are a helpful recipe generation assistant. You act as a professional chef helping users turn leftover ingredients into a simple recipe with clear step-by-step instructions. Include ingredient amounts directly in the instruction steps (e.g. 'add the 500g pasta' not just 'add the pasta'). Once you've created a recipe, you must use the find_similar_ingredients tool to match your ingredients with ones from the database, if they exist and have a similarity value over .90. For each NEW ingredient (is_new=true), assign a category from this list: [{categories_str}]. For existing ingredients matched via the tool, you may leave the category as 'Other' — the system will use the cached category. Output the recipe in the given output format.",
    }

    runner = async_claude.beta.messages.tool_runner(
        model="claude-opus-4-5",
        max_tokens=2048,
        messages=[system_message, {"role": "user", "content": prompt}],
        tools=[find_similar_ingredients],
        stream=True,
        output_config={"format": {"type": "json_schema", "schema": recipeSchema}},
    )

    final_message = await runner.until_done()
    recipe = RecipeModelResponse.model_validate_json(final_message.content[0].text)
    return await save(recipe)


class RecipeImage(NamedTuple):
    """An uploaded photo, read into memory: an upload is gone once its request ends."""

    media_type: str | None
    data: bytes


async def from_images(images: list[RecipeImage]) -> RecipeDocument:
    """Read one recipe from photos of it."""
    categories_str = ", ".join(await category_names())
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
    return await save(recipe)


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


async def import_url(url: str, changes: str | None = None) -> RecipeDocument:
    """Import a recipe from a public web page.

    Two stages: scrape the page for structured data (free), then structure the
    free-text ingredient lines with Haiku. Pages that publish nothing readable
    fall back to Opus over the page text. Any `changes` typed alongside the
    link are applied last, by Opus.
    """
    url = _canonical_url(url)
    changes = (changes or "").strip()

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
        raise AlreadyImported(str(existing.id))

    try:
        html = await fetch_page(url)
    except BlockedURL as exc:
        raise Invalid(str(exc)) from exc
    except FetchFailed as exc:
        raise Unreachable(str(exc)) from exc

    categories_str = ", ".join(await category_names())

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
            raise NotFound("No recipe found on that page.")
        # Nothing was published to read, so provenance is all we can honestly
        # record — no image, no times, no servings.
        metadata = RecipeMetadata(source_url=url, source_name=urlparse(url).hostname)

    if changes:
        recipe = await _apply_changes(recipe, changes, categories_str)

    return await save(recipe, metadata)


async def get(recipe_id: PydanticObjectId) -> RecipeDocument:
    recipe = await RecipeDocument.get(recipe_id)
    if not recipe:
        raise NotFound("Recipe not found")
    return recipe


async def rate(recipe_id: PydanticObjectId, rating: int) -> RecipeDocument:
    recipe = await get(recipe_id)
    recipe.rating = rating
    await recipe.save()
    return recipe


async def update(
    recipe_id: PydanticObjectId,
    title: str,
    instructions: list[str],
    ingredients: list[IngredientRecipe],
) -> RecipeDocument:
    """Replace a recipe's title, steps and ingredients."""
    recipe = await get(recipe_id)

    old_names = {i.name.lower() for i in recipe.ingredients}
    recipe.title = title
    recipe.instructions = instructions
    recipe.ingredients = ingredients
    await recipe.save()

    # Fire-and-forget: embed any new ingredient names
    new_ingredients = [i for i in ingredients if i.name.lower() not in old_names]
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


async def delete(recipe_id: PydanticObjectId) -> None:
    await (await get(recipe_id)).delete()


async def set_excluded(recipe_id: PydanticObjectId, index: int, excluded: bool) -> None:
    """Keep one ingredient off (or put it back on) shopping lists."""
    recipe = await get(recipe_id)
    if index < 0 or index >= len(recipe.ingredients):
        raise NotFound("Ingredient not found")
    recipe.ingredients[index].excluded_from_list = excluded
    await recipe.save()


async def units() -> list[str]:
    pipeline = [
        {"$unwind": "$ingredients"},
        {"$group": {"_id": {"$toLower": "$ingredients.unit"}}},
        {"$sort": {"_id": 1}},
    ]
    results = await RecipeDocument.aggregate(pipeline).to_list()
    units = [r["_id"] for r in results if r["_id"]]
    return units
