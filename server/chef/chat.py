"""Chef in chat: an agent that can do anything the person can in Omlete.

Every tool that changes data goes through services/, like the routes, and
records what it changed so the person can Undo it (chef/actions.py). Chef acts
straight away and never asks first; Undo is what makes that safe
(docs/PRD_CHEF.md). tests/test_chef_parity.py fails when a route changes data
and no tool here does the same.
"""

import functools
import re
from dataclasses import dataclass, field
from datetime import date
from uuid import uuid4

from beanie import PydanticObjectId
from bson.errors import InvalidId
from fastapi import HTTPException
from pydantic_ai import Agent, RunContext
from pydantic_ai.builtin_tools import WebSearchTool
from pydantic_ai.messages import BinaryContent, ModelRequest, UserPromptPart

from chef.actions import Change
from data_models import (
    CategoryConfig,
    ListDocument,
    MealLogDocument,
    PreferenceDocument,
    RecipeDocument,
    Stance,
    UserSettingsDocument,
)
from lib.types import (
    CategoriesUpdateRequest,
    CategoryConfigRequest,
    IngredientRecipe,
    ItemUpdateRequest,
)
from services import lists, memory, recipes, settings
from services.errors import AlreadyImported
from services.recipes import RecipeImage


@dataclass
class ChatDeps:
    chat_id: str | None = None
    # Where the person is in the app, so "this list" needs no name.
    path: str | None = None
    list_id: str | None = None
    recipe_id: str | None = None
    # Photos attached to the latest message, for create_recipe_from_photos.
    photos: list[RecipeImage] = field(default_factory=list)


_ROUTE_IDS = [
    (re.compile(r"^/(?:list|shop)/([0-9a-f]{24})"), "list_id"),
    (re.compile(r"^/(?:recipe|cook)/([0-9a-f]{24})"), "recipe_id"),
]


def deps_for(chat_id: str | None, page: object, messages: list) -> ChatDeps:
    """ChatDeps from a chat request: its id, the page it was sent from and its messages.

    `page` is `{"path": "/list/<id>"}` as the client sends it. The ids come
    from the path here, so the web and iOS only have to send where they are.
    """
    deps = ChatDeps(chat_id=chat_id)
    if isinstance(page, dict) and isinstance(page.get("path"), str):
        deps.path = page["path"]
        for pattern, name in _ROUTE_IDS:
            if m := pattern.match(deps.path):
                setattr(deps, name, m.group(1))
    last = messages[-1] if messages else None
    if isinstance(last, ModelRequest):
        for part in last.parts:
            if isinstance(part, UserPromptPart) and not isinstance(part.content, str):
                deps.photos += [
                    RecipeImage(c.media_type, c.data)
                    for c in part.content
                    if isinstance(c, BinaryContent) and c.is_image
                ]
    return deps


agent = Agent(
    "anthropic:claude-sonnet-5-5",
    deps_type=ChatDeps,
    builtin_tools=[WebSearchTool(max_uses=5)],
    model_settings={
        "max_tokens": 4096,
        # One change at a time: the services read a list, change it and save it
        # whole, so two changes to one list at once would lose one.
        "parallel_tool_calls": False,
        # A declined request is retried on the model Anthropic recommends.
        "anthropic_betas": ["server-side-fallback-2026-07-01"],
        "extra_body": {"fallbacks": "default"},
    },
    instructions=(
        "You are Chef, the cooking helper inside Omlete, an app that turns recipes "
        "into shopping lists and walks people through cooking. You can read and "
        "change their recipes, shopping lists and aisle order, and search the web.\n"
        "When they ask for something, do it straight away with your tools. Don't ask "
        "them to confirm: every change you make shows them an Undo. Ask a question "
        "only when you can't tell what they mean.\n"
        "When they tell you something lasting about their taste (\"no mushrooms\", "
        "\"more fish\"), keep it with remember. Go by what you know about them, and "
        "never suggest or add a recipe that names something they said never to.\n"
        "To add a recipe from the web, search, choose a page with a real recipe on "
        "it, and import it with import_recipe. Use create_recipe for a dish described "
        "in words, and create_recipe_from_photos when they attach photos of one.\n"
        "When you change a recipe's ingredients, rewrite its method in the same "
        "update_recipe call so the two agree: a new ingredient gets prepared and "
        "added at the right step, a removed one leaves every step, and amounts "
        "written in the steps match the new amounts.\n"
        "Reply in a sentence or two of plain text, like a person would. Don't list "
        "ids, and don't repeat what's on screen unless they ask."
    ),
)


@agent.instructions
async def _where_they_are(ctx: RunContext[ChatDeps]) -> str:
    lines = [f"Today is {date.today():%A %d %B %Y}."]
    if ctx.deps.path:
        lines.append(f"They are on the {ctx.deps.path} screen.")
    if ctx.deps.list_id:
        lst = await ListDocument.get(PydanticObjectId(ctx.deps.list_id))
        if lst:
            lines.append(f'"This list" is their list "{lst.name}" (id {lst.id}).')
    if ctx.deps.recipe_id:
        recipe = await RecipeDocument.get(PydanticObjectId(ctx.deps.recipe_id))
        if recipe:
            lines.append(f'"This recipe" is "{recipe.title}" (id {recipe.id}).')
    if ctx.deps.photos:
        lines.append(f"They attached {len(ctx.deps.photos)} photo(s) to this message.")
    if known := memory.prompt_text(await memory.active()):
        lines.append(known)
    return " ".join(lines)


def _reported(tool):
    """Give the model a service's refusal as a result it can act on."""

    @functools.wraps(tool)
    async def run(*args, **kwargs):
        try:
            return await tool(*args, **kwargs)
        except HTTPException as exc:
            return {"error": exc.detail}
        except InvalidId:
            return {"error": "No such id"}

    return run


def _oid(value: str) -> PydanticObjectId:
    return PydanticObjectId(value)


async def _done(ctx: RunContext[ChatDeps], change: Change, summary: str, **extra) -> dict:
    undo = await change.record(summary, ctx.deps.chat_id)
    return {"done": summary, "undo": undo, **extra}


def _list_view(lst: ListDocument) -> dict:
    return {
        "id": str(lst.id),
        "name": lst.name,
        "recipe_ids": lst.recipes,
        "week_start": lst.week_start.isoformat() if lst.week_start else None,
        "days": [
            {"date": d.date.isoformat(), "recipe_id": d.recipe_id, "eating_out": d.status == "out"}
            for d in lst.days
        ],
        "items": [
            {
                "id": i.id,
                "name": i.name,
                "amount": i.amount,
                "unit": i.unit,
                "aisle": i.category,
                "checked": i.checked,
                "from_recipes": len([s for s in i.sources if s.recipe_id]),
            }
            for i in lst.items
        ],
    }


def _recipe_view(r: RecipeDocument) -> dict:
    return {
        "id": str(r.id),
        "title": r.title,
        "rating": r.rating,
        "servings": r.servings,
        "total_minutes": r.total_minutes,
        "source_url": r.source_url,
        "ingredients": [
            {"index": n, **i.model_dump(exclude_none=True)} for n, i in enumerate(r.ingredients)
        ],
        "instructions": r.instructions,
    }


# --- Reading ---


@agent.tool
@_reported
async def find_recipes(ctx: RunContext[ChatDeps], query: str | None = None) -> list[dict]:
    """Their saved recipes, newest first, optionally only titles containing `query`."""
    found = await RecipeDocument.find_all().sort("-created_at").to_list()
    if query:
        found = [r for r in found if query.lower() in r.title.lower()]
    return [
        {"id": str(r.id), "title": r.title, "rating": r.rating, "total_minutes": r.total_minutes}
        for r in found[:50]
    ]


@agent.tool
@_reported
async def get_recipe(ctx: RunContext[ChatDeps], recipe_id: str) -> dict:
    """One recipe in full: ingredients (with their index) and steps."""
    return _recipe_view(await recipes.get(_oid(recipe_id)))


@agent.tool
@_reported
async def find_lists(ctx: RunContext[ChatDeps]) -> list[dict]:
    """Their shopping lists, newest first, with counts and the meals on each."""
    return await lists.summaries()


@agent.tool
@_reported
async def get_list(ctx: RunContext[ChatDeps], list_id: str) -> dict:
    """One shopping list with every item on it."""
    return _list_view(await lists.get(_oid(list_id)))


@agent.tool
@_reported
async def get_aisles(ctx: RunContext[ChatDeps]) -> list[str]:
    """Their aisles, in the order they walk the shop."""
    return await settings.category_names()


# --- Recipes ---


@agent.tool
@_reported
async def create_recipe(ctx: RunContext[ChatDeps], description: str) -> dict:
    """Write and save a new recipe from a description, e.g. "a quick weeknight dal for four"."""
    recipe = await recipes.generate(description)
    change = Change()
    change.creating(RecipeDocument, recipe.id)
    return await _done(ctx, change, f"Added {recipe.title} to your recipes", recipe_id=str(recipe.id))


@agent.tool
@_reported
async def create_recipe_from_photos(ctx: RunContext[ChatDeps]) -> dict:
    """Save the recipe in the photos attached to this message, as one recipe."""
    if not ctx.deps.photos:
        return {"error": "No photos are attached to this message"}
    recipe = await recipes.from_images(ctx.deps.photos)
    change = Change()
    change.creating(RecipeDocument, recipe.id)
    return await _done(ctx, change, f"Added {recipe.title} to your recipes", recipe_id=str(recipe.id))


@agent.tool
@_reported
async def import_recipe(ctx: RunContext[ChatDeps], url: str, changes: str | None = None) -> dict:
    """Save the recipe on a web page. `changes` adapts it on the way in, e.g. "make it vegetarian"."""
    try:
        recipe = await recipes.import_url(url, changes)
    except AlreadyImported as exc:
        return {"already_saved": True, "recipe_id": exc.recipe_id}
    change = Change()
    change.creating(RecipeDocument, recipe.id)
    return await _done(ctx, change, f"Added {recipe.title} to your recipes", recipe_id=str(recipe.id))


@agent.tool
@_reported
async def rate_recipe(ctx: RunContext[ChatDeps], recipe_id: str, stars: int) -> dict:
    """Rate a recipe from 1 to 5 stars."""
    if not 1 <= stars <= 5:
        return {"error": "Stars go from 1 to 5"}
    change = Change()
    await change.touching(RecipeDocument, recipe_id)
    recipe = await recipes.rate(_oid(recipe_id), stars)
    return await _done(ctx, change, f"Rated {recipe.title} {stars} stars")


@agent.tool
@_reported
async def update_recipe(
    ctx: RunContext[ChatDeps],
    recipe_id: str,
    title: str | None = None,
    instructions: list[str] | None = None,
    ingredients: list[IngredientRecipe] | None = None,
) -> dict:
    """Change a recipe. Anything left out stays as it is; `ingredients` and `instructions` replace the whole list.

    Changing `ingredients` needs `instructions` too: the method, rewritten so its
    steps use, prepare and give the amounts of exactly these ingredients.
    """
    if ingredients is not None and instructions is None:
        return {
            "error": "Send instructions with ingredients: the method rewritten to match the new ingredients and amounts."
        }
    current = await recipes.get(_oid(recipe_id))
    change = Change()
    await change.touching(RecipeDocument, recipe_id)
    recipe = await recipes.update(
        current.id,
        title if title is not None else current.title,
        instructions if instructions is not None else current.instructions,
        ingredients if ingredients is not None else current.ingredients,
    )
    return await _done(ctx, change, f"Updated {recipe.title}")


@agent.tool
@_reported
async def delete_recipe(ctx: RunContext[ChatDeps], recipe_id: str) -> dict:
    """Delete a recipe from their recipes."""
    recipe = await recipes.get(_oid(recipe_id))
    change = Change()
    await change.touching(RecipeDocument, recipe_id)
    await recipes.delete(recipe.id)
    return await _done(ctx, change, f"Deleted {recipe.title}")


@agent.tool
@_reported
async def set_ingredient_on_lists(
    ctx: RunContext[ChatDeps], recipe_id: str, ingredient_index: int, on_lists: bool
) -> dict:
    """Choose whether one of a recipe's ingredients goes on shopping lists (false for things they always have)."""
    change = Change()
    await change.touching(RecipeDocument, recipe_id)
    await recipes.set_excluded(_oid(recipe_id), ingredient_index, not on_lists)
    recipe = await recipes.get(_oid(recipe_id))
    name = recipe.ingredients[ingredient_index].name
    verb = "Will put" if on_lists else "Won't put"
    return await _done(ctx, change, f"{verb} {name} on lists from {recipe.title}")


# --- Lists ---


@agent.tool
@_reported
async def create_list(
    ctx: RunContext[ChatDeps], name: str | None = None, week_start: date | None = None
) -> dict:
    """Start a new, empty shopping list. Without a name it is named for today.

    With `week_start` it is a week plan: seven days from that date, each of
    which can hold a dinner (see plan_day).
    """
    lst = await lists.create(week_start)
    if name:
        lst = await lists.rename(lst.id, name)
    change = Change()
    change.creating(ListDocument, lst.id)
    return await _done(ctx, change, f"Started a list, {lst.name}", list_id=str(lst.id))


@agent.tool
@_reported
async def rename_list(ctx: RunContext[ChatDeps], list_id: str, name: str) -> dict:
    """Rename a shopping list."""
    change = Change()
    await change.touching(ListDocument, list_id)
    await lists.rename(_oid(list_id), name)
    return await _done(ctx, change, f"Renamed the list to {name}")


@agent.tool
@_reported
async def delete_list(ctx: RunContext[ChatDeps], list_id: str) -> dict:
    """Delete a shopping list."""
    lst = await lists.get(_oid(list_id))
    change = Change()
    await change.touching(ListDocument, list_id)
    await lists.delete(lst.id)
    return await _done(ctx, change, f"Deleted {lst.name}")


@agent.tool
@_reported
async def duplicate_list(ctx: RunContext[ChatDeps], list_id: str) -> dict:
    """Copy a list into a new one named for today, with everything unticked."""
    new = await lists.duplicate(_oid(list_id))
    change = Change()
    change.creating(ListDocument, new.id)
    return await _done(ctx, change, f"Copied the list to {new.name}", list_id=str(new.id))


@agent.tool
@_reported
async def add_recipe_to_list(ctx: RunContext[ChatDeps], list_id: str, recipe_id: str) -> dict:
    """Put a recipe's ingredients on a shopping list."""
    change = Change()
    await change.touching(ListDocument, list_id)
    lst = await lists.add_recipe(_oid(list_id), recipe_id)
    recipe = await recipes.get(_oid(recipe_id))
    return await _done(ctx, change, f"Put {recipe.title} on {lst.name}")


@agent.tool
@_reported
async def remove_recipe_from_list(ctx: RunContext[ChatDeps], list_id: str, recipe_id: str) -> dict:
    """Take a meal off a list, with the items only it put there."""
    change = Change()
    await change.touching(ListDocument, list_id)
    lst = await lists.remove_recipe(_oid(list_id), recipe_id)
    recipe = await RecipeDocument.get(_oid(recipe_id))
    title = recipe.title if recipe else "that meal"
    return await _done(ctx, change, f"Took {title} off {lst.name}")


@agent.tool
@_reported
async def add_item(
    ctx: RunContext[ChatDeps],
    list_id: str,
    name: str,
    amount: float | None = None,
    unit: str | None = None,
    aisle: str | None = None,
) -> dict:
    """Add one thing to a shopping list. Leave `aisle` out to have it filed for them."""
    change = Change()
    await change.touching(ListDocument, list_id)
    item = await lists.add_item(
        _oid(list_id), name, amount, unit, aisle or await settings.categorize(name)
    )
    return await _done(ctx, change, f"Added {item.name}", item_id=item.id)


@agent.tool
@_reported
async def update_item(
    ctx: RunContext[ChatDeps], list_id: str, item_id: str, changes: ItemUpdateRequest
) -> dict:
    """Change an item on a list: tick it (`checked`), rename it, or change its amount, unit or aisle (`category`).

    Only the fields given change; an amount or unit given as null is cleared.
    """
    change = Change()
    await change.touching(ListDocument, list_id)
    item = await lists.update_item(_oid(list_id), item_id, changes)
    if changes.model_fields_set == {"checked"}:
        summary = f"{'Ticked' if item.checked else 'Unticked'} {item.name}"
    else:
        summary = f"Changed {item.name}"
    return await _done(ctx, change, summary)


@agent.tool
@_reported
async def reorder_items(
    ctx: RunContext[ChatDeps], list_id: str, aisle: str, item_ids: list[str]
) -> dict:
    """Put the items in one aisle of a list in this order."""
    change = Change()
    await change.touching(ListDocument, list_id)
    await lists.reorder_items(_oid(list_id), aisle, item_ids)
    return await _done(ctx, change, f"Reordered {aisle}")


@agent.tool
@_reported
async def delete_item(ctx: RunContext[ChatDeps], list_id: str, item_id: str) -> dict:
    """Take one item off a shopping list."""
    lst = await lists.get(_oid(list_id))
    name = next((i.name for i in lst.items if i.id == item_id), "that item")
    change = Change()
    await change.touching(ListDocument, list_id)
    await lists.delete_item(lst.id, item_id)
    return await _done(ctx, change, f"Removed {name}")


@agent.tool
@_reported
async def plan_day(
    ctx: RunContext[ChatDeps],
    list_id: str,
    day: date,
    recipe_id: str | None = None,
    eating_out: bool = False,
) -> dict:
    """Set one day of a week plan: the dinner to cook (its ingredients go on the list),
    or eating_out for no cooking that night. With neither, the day is cleared and its
    recipe stays on the list as an any-day meal."""
    change = Change()
    await change.touching(ListDocument, list_id)
    await lists.set_day(_oid(list_id), day, recipe_id, "out" if eating_out else "open")
    if eating_out:
        summary = f"Marked {day:%A} as eating out"
    elif recipe_id:
        recipe = await recipes.get(_oid(recipe_id))
        summary = f"Planned {recipe.title} for {day:%A}"
    else:
        summary = f"Cleared {day:%A}"
    return await _done(ctx, change, summary)


# --- Settings ---


_WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]


@agent.tool
@_reported
async def set_week_start(ctx: RunContext[ChatDeps], weekday: int) -> dict:
    """Choose the day their planning week starts on, 0 for Monday to 6 for Sunday."""
    if not 0 <= weekday <= 6:
        return {"error": "weekday goes from 0 (Monday) to 6 (Sunday)"}
    current = await settings.get_or_create()
    change = Change()
    await change.touching(UserSettingsDocument, current.id)
    await settings.set_week_start_weekday(weekday)
    return await _done(ctx, change, f"Your week now starts on {_WEEKDAYS[weekday]}")


@agent.tool
@_reported
async def set_aisles(ctx: RunContext[ChatDeps], aisles: list[str]) -> dict:
    """Replace their aisles with these, in the order they walk the shop."""
    current = await settings.get_or_create()
    change = Change()
    await change.touching(UserSettingsDocument, current.id)
    # Through the request model, so names are cleaned the way the route cleans them.
    body = CategoriesUpdateRequest(
        categories=[CategoryConfigRequest(name=a, order=n) for n, a in enumerate(aisles)]
    )
    await settings.set_categories(
        [CategoryConfig(name=c.name, order=c.order) for c in body.categories]
    )
    return await _done(ctx, change, "Changed your aisles")


# --- Memory ---


_STANCE_SAID = {
    "never": "Never {}",
    "avoid": "Avoid {}",
    "less": "Less {}",
    "more": "More {}",
    "prefer": "You like {}",
}


@agent.tool
@_reported
async def remember(ctx: RunContext[ChatDeps], subject: str, stance: Stance) -> dict:
    """Keep a lasting preference they told you, like "no mushrooms" (never) or "more fish" (more).

    `never` is a hard rule: nothing naming the subject is ever suggested.
    `avoid` and `less` steer away, `prefer` and `more` steer towards. Saying
    it again about the same subject replaces what was there.
    """
    existing = await PreferenceDocument.find_one(
        PreferenceDocument.source == "told", PreferenceDocument.key == memory.key_for(subject)
    )
    change = Change()
    if existing:
        await change.touching(PreferenceDocument, existing.id)
    pref = await memory.remember(subject, stance)
    if not existing:
        change.creating(PreferenceDocument, pref.id)
    return await _done(ctx, change, _STANCE_SAID[stance].format(pref.subject))


@agent.tool
@_reported
async def forget(ctx: RunContext[ChatDeps], subject: str) -> dict:
    """Forget what you know about a subject, whether they told you or you noticed it."""
    pref = await memory.find(subject)
    if not pref:
        return {"error": f"Nothing remembered about {subject}"}
    change = Change()
    await change.touching(PreferenceDocument, pref.id)
    await memory.set_forgotten(pref.id, True)
    return await _done(ctx, change, f"Forgot {pref.subject}")


@agent.tool
@_reported
async def log_meal(ctx: RunContext[ChatDeps], recipe_id: str, stars: int | None = None) -> dict:
    """Record that they cooked one of their recipes, as finishing Cook does, with an optional 1 to 5 star rating of how it went."""
    if stars is not None and not 1 <= stars <= 5:
        return {"error": "Stars go from 1 to 5"}
    meal = await memory.log_meal(str(uuid4()), recipe_id, stars)
    change = Change()
    change.creating(MealLogDocument, meal.id)
    recipe = await recipes.get(_oid(recipe_id))
    return await _done(ctx, change, f"Noted you cooked {recipe.title}")
