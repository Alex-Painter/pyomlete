"""Tag a recipe with what it is built on: base, main, mood, cuisine and traits.

The week's fit score (client/src/lib/fitScore.ts) reads these to keep a week
varied: pasta on Monday sinks other pasta until Friday. Tagging runs on Haiku
after a recipe is saved, never in the save itself, so a slow or failed model
call costs a recipe its tags and nothing else. A recipe without tags still
ranks, on rating and history alone.
"""

import asyncio
import logging

from anthropic import AsyncAnthropic, transform_schema
from beanie import PydanticObjectId
from pydantic import TypeAdapter, ValidationError

from data_models import RecipeDocument, RecipeTags

logger = logging.getLogger(__name__)

MODEL = "claude-haiku-5-5"
# Enough of the method to tell a stir-fry from a stew, and keeps a tag under
# about 1,000 input tokens.
_METHOD_CHARS = 1500

_schema = transform_schema(TypeAdapter(RecipeTags).json_schema())

# Background tag runs, kept so they aren't collected before they finish.
_running: set[asyncio.Task] = set()


def _prompt(recipe: RecipeDocument) -> str:
    ingredients = "\n".join(f"- {i.name}" for i in recipe.ingredients)
    method = " ".join(recipe.instructions)[:_METHOD_CHARS]
    return f"""Tag this dinner recipe for a weekly meal planner that keeps the week varied.

Title: {recipe.title}
Ingredients:
{ingredients}
Method: {method}

- base: the starch the dinner is built on. "none" when there isn't one (a salad, a curry served alone, a frittata).
- main: the main protein. "veggie" for vegetables, eggs or cheese; "beans" for beans, lentils, chickpeas or tofu.
- mood: "comforting" (warm, hearty), "fresh" (light, bright) or "different" (unusual for a weeknight).
- cuisine: the family it belongs to. Thai and Vietnamese are both "south_east_asian".
- traits: oily_fish (salmon, mackerel, sardines, trout), red_meat (beef, lamb, pork, venison), veg_led (vegetables are most of the plate), legumes (beans, lentils, chickpeas)."""


async def tag_recipe(recipe: RecipeDocument, client: AsyncAnthropic) -> RecipeTags | None:
    """Ask Haiku for the recipe's tags. One retry on an answer outside the sets, then None."""
    for attempt in (1, 2):
        response = await client.messages.create(
            model=MODEL,
            max_tokens=300,
            messages=[{"role": "user", "content": _prompt(recipe)}],
            output_config={"format": {"type": "json_schema", "schema": _schema}},
        )
        usage = getattr(response, "usage", None)
        if usage is not None:
            logger.info(
                "tagged %s: %s input, %s output tokens",
                recipe.id, usage.input_tokens, usage.output_tokens,
            )
        try:
            return RecipeTags.model_validate_json(response.content[0].text)
        except (ValidationError, IndexError, AttributeError) as exc:
            logger.warning("tags for %s rejected on attempt %d: %s", recipe.id, attempt, exc)
    return None


async def tag_and_store(recipe_id: PydanticObjectId, client: AsyncAnthropic) -> bool:
    """Tag one recipe and write only its `tags`, so an edit made meanwhile isn't overwritten."""
    recipe = await RecipeDocument.get(recipe_id)
    if recipe is None:
        return False
    tags = await tag_recipe(recipe, client)
    if tags is None:
        return False
    await RecipeDocument.find_one(RecipeDocument.id == recipe_id).update(
        {"$set": {"tags": tags.model_dump()}}
    )
    return True


def tag_later(recipe_id: PydanticObjectId) -> None:
    """Tag a recipe in the background. A failure is logged and the recipe keeps no tags."""
    from lib.claude import async_claude

    async def run():
        try:
            await tag_and_store(recipe_id, async_claude)
        except Exception:
            logger.exception("tagging %s failed", recipe_id)

    task = asyncio.create_task(run())
    _running.add(task)
    task.add_done_callback(_running.discard)
