"""Chef plans a week: five dinners on a card, and one tap makes the list.

The plan only proposes. Making the list is the tap, and it can be undone like
any change Chef makes (chef/actions.py). A good week mixes known and new:
three dinners from their recipes, rated well and not had lately, and two new
ideas found on the web. Code, not the model, holds the rules a week must keep,
and sends a plan that breaks one back with the reason (docs/PRD_CHEF.md).
"""

from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone

from beanie import PydanticObjectId
from pydantic import BaseModel, Field
from pydantic_ai import Agent, ModelRetry, RunContext
from pydantic_ai.exceptions import UnexpectedModelBehavior
from pydantic_ai.builtin_tools import WebSearchTool

from chef.actions import Change
from data_models import (
    ListDocument,
    PlannedMeal,
    PreferenceDocument,
    RecipeDocument,
    SuggestionDocument,
    WeekPlanDocument,
)
from services import lists, memory, settings
from services.errors import Conflict, NotFound, Unreachable

DINNERS = 5
FROM_LIBRARY = 3
# A recipe cooked or planned this recently isn't offered again.
NOT_AGAIN_FOR = timedelta(weeks=3)

# How a new idea's card is saved, with the list it goes on. main.py sets it,
# so a week's ideas save exactly as a Discover card does.
start_save: Callable[[SuggestionDocument, str], Awaitable[None]] | None = None


def week_to_plan(today: date, weekday: int) -> date:
    """The week a plan is for: this one, or next week on its last day (client/src/lib/week.ts)."""
    current = today - timedelta(days=(today.weekday() - weekday) % 7)
    return current + timedelta(days=7) if (today - current).days == 6 else current


def next_week_from(today: date, weekday: int) -> date:
    """The first week to start on or after `today`: the one the weekly run plans."""
    return today + timedelta(days=(weekday - today.weekday()) % 7)


async def current_week() -> date:
    return week_to_plan(date.today(), (await settings.get_or_create()).week_start_weekday)


async def waiting() -> WeekPlanDocument | None:
    """The plan waiting for a tap: this week's, or the coming week's once the run has planned it."""
    return await WeekPlanDocument.find_one(
        WeekPlanDocument.status == "new",
        WeekPlanDocument.week_of >= await current_week(),
        sort=[("week_of", -1)],
    )


class DraftMeal(BaseModel):
    day: int = Field(ge=0, le=6, description="Day of the week, 0 for its first day")
    recipe_id: str | None = Field(None, description="For one of their recipes, its id. Leave out for a new idea.")
    title: str
    reason: str = Field(description="Why this one, in under 12 words, specific and true")
    description: str | None = Field(None, description="For a new idea, one appetising sentence")
    source_url: str | None = Field(None, description="For a new idea, the page with its recipe")


class WeekDraft(BaseModel):
    note: str = Field(description="One line on the week as a whole, like a friend would say it")
    meals: list[DraftMeal]


@dataclass
class WeekDeps:
    library: dict[str, RecipeDocument]
    # Cooked or planned lately, by recipe id.
    lately: set[str]
    never: list[PreferenceDocument]
    from_library: int


agent = Agent(
    "anthropic:claude-opus-5-5",
    deps_type=WeekDeps,
    output_type=WeekDraft,
    builtin_tools=[WebSearchTool(max_uses=6)],
    # Each broken rule is sent back once; a few chances before giving up.
    output_retries=3,
    model_settings={"max_tokens": 4096},
)


@agent.tool
async def search_library(ctx: RunContext[WeekDeps], query: str) -> list[dict]:
    """Their recipes whose title or ingredients mention `query`."""
    q = query.lower()
    return [
        _library_row(r, ctx.deps)
        for r in ctx.deps.library.values()
        if q in r.title.lower() or any(q in i.name.lower() for i in r.ingredients)
    ][:20]


def _library_row(r: RecipeDocument, deps: WeekDeps) -> dict:
    return {
        "id": str(r.id),
        "title": r.title,
        "rating": r.rating,
        "total_minutes": r.total_minutes,
        "had_lately": str(r.id) in deps.lately,
    }


def _names_never(recipe: RecipeDocument, never: list[PreferenceDocument]) -> bool:
    text = " ".join([recipe.title, *(i.name for i in recipe.ingredients)])
    return memory.names_any(text, never)


@agent.output_validator
async def _keeps_the_rules(ctx: RunContext[WeekDeps], draft: WeekDraft) -> WeekDraft:
    deps = ctx.deps
    if len(draft.meals) != DINNERS:
        raise ModelRetry(f"Plan exactly {DINNERS} dinners.")
    if len({m.day for m in draft.meals}) != DINNERS:
        raise ModelRetry("Put each dinner on a different day.")
    known = [m for m in draft.meals if m.recipe_id]
    if len(known) != deps.from_library:
        raise ModelRetry(f"Take exactly {deps.from_library} dinners from their recipes and make the rest new ideas.")
    titles = {r.title.lower() for r in deps.library.values()}
    for m in draft.meals:
        if m.recipe_id:
            recipe = deps.library.get(m.recipe_id)
            if recipe is None:
                raise ModelRetry(f"{m.recipe_id} is not one of their recipes.")
            if m.recipe_id in deps.lately:
                raise ModelRetry(f"They had {recipe.title} in the last 3 weeks. Choose another.")
            if _names_never(recipe, deps.never):
                raise ModelRetry(f"{recipe.title} has something they never eat. Choose another.")
        else:
            if memory.names_any(f"{m.title} {m.description or ''}", deps.never):
                raise ModelRetry(f"{m.title} has something they never eat. Choose another.")
            if m.title.lower() in titles:
                raise ModelRetry(f"{m.title} is already one of their recipes, so it isn't new.")
    return draft


async def _deps() -> WeekDeps:
    library = {str(r.id): r for r in await RecipeDocument.find_all().to_list()}
    lately = {m.recipe_id for m in await memory.recent_meals(weeks=NOT_AGAIN_FOR.days // 7)}
    cutoff = (date.today() - NOT_AGAIN_FOR).isoformat()
    lately |= {rid for rid, day in (await lists.last_planned_on()).items() if day >= cutoff}
    never = [p for p in await memory.active() if p.stance == "never"]
    eligible = [
        r for rid, r in library.items() if rid not in lately and not _names_never(r, never)
    ]
    return WeekDeps(
        library=library,
        lately=lately,
        never=never,
        from_library=min(FROM_LIBRARY, len(eligible)),
    )


def _prompt(deps: WeekDeps, week_of: date, known: str) -> str:
    candidates = sorted(
        (
            r for rid, r in deps.library.items()
            if rid not in deps.lately and not _names_never(r, deps.never)
        ),
        key=lambda r: -(r.rating or 0),
    )[:25]
    days = ", ".join(f"{n} {week_of + timedelta(days=n):%A}" for n in range(7))
    lines = [
        f"Plan {DINNERS} dinners for a household's week starting {week_of:%A %d %B}. "
        f"The days are numbered {days}; leave two evenings free.",
        f"Take {deps.from_library} from their own recipes, favouring ones they rated "
        f"highly, and make the other {DINNERS - deps.from_library} new ideas they don't "
        "have, each with a real recipe page you found on the web.",
        "Make the week varied: different proteins and cuisines, and quicker dinners "
        "early in the week.",
        f"What you know about them: {known or 'Nothing yet.'}",
    ]
    if candidates:
        lines.append(
            "Their recipes not had lately (id: title, rating): "
            + "; ".join(f"{r.id}: {r.title}, {r.rating or 'unrated'}" for r in candidates)
            + ". search_library finds others."
        )
    return "\n".join(lines)


async def plan(
    fresh: bool = False, chat_id: str | None = None, week_of: date | None = None
) -> tuple[WeekPlanDocument, str | None]:
    """Propose a week, or return the proposal already waiting unless `fresh`.

    The week is `week_of`, or the one a waiting plan is for (the weekly run may
    have planned next week), or this one. Answers the plan and, when this call
    made or replaced it, the Undo id.
    """
    if week_of is None:
        pending = await waiting()
        week_of = pending.week_of if pending else await current_week()
    existing = await WeekPlanDocument.find_one(WeekPlanDocument.week_of == week_of)
    if existing and existing.status == "new" and not fresh:
        return existing, None

    deps = await _deps()
    try:
        result = await agent.run(
            _prompt(deps, week_of, memory.prompt_text(await memory.active())), deps=deps
        )
    except UnexpectedModelBehavior as exc:
        raise Unreachable("Chef couldn't plan a week that keeps your rules. Try again.") from exc
    draft = result.output
    meals = [
        PlannedMeal(
            day=week_of + timedelta(days=m.day),
            title=deps.library[m.recipe_id].title if m.recipe_id else m.title.strip(),
            reason=m.reason.strip(),
            recipe_id=m.recipe_id,
            description=None if m.recipe_id else m.description,
            source_url=None if m.recipe_id else m.source_url,
        )
        for m in sorted(draft.meals, key=lambda m: m.day)
    ]

    change = Change()
    if existing:
        await change.touching(WeekPlanDocument, existing.id)
        existing.note, existing.meals = draft.note.strip(), meals
        existing.status, existing.list_id = "new", None
        existing.created_at = datetime.now(timezone.utc)
        await existing.save()
        week = existing
    else:
        week = WeekPlanDocument(week_of=week_of, note=draft.note.strip(), meals=meals)
        await week.insert()
        change.creating(WeekPlanDocument, week.id)
    return week, await change.record(f"Planned the week of {week_of:%-d %b}", chat_id)


async def get(plan_id) -> WeekPlanDocument:
    week = await WeekPlanDocument.get(plan_id)
    if not week:
        raise NotFound("Week plan not found")
    return week


async def make_list(plan_id, chat_id: str | None = None) -> tuple[ListDocument, str]:
    """Turn a plan into the week's list, and answer it with the Undo id.

    Their recipes go on their days at once, on the week's list if it already
    has one. New ideas are saved in the background, as a Discover card is,
    and land on their day when ready.
    """
    week = await get(plan_id)
    if week.status != "new":
        raise Conflict("This week has already been made into a list or skipped")

    change = Change()
    lst = await ListDocument.find_one(ListDocument.week_start == week.week_of)
    if lst:
        await change.touching(ListDocument, lst.id)
    else:
        lst = await lists.create(week.week_of)
        change.creating(ListDocument, lst.id)
    await change.touching(WeekPlanDocument, week.id)

    ideas: list[SuggestionDocument] = []
    for meal in week.meals:
        if meal.recipe_id:
            recipe = await RecipeDocument.get(PydanticObjectId(meal.recipe_id))
            if recipe:
                await lists.place_recipe(lst.id, recipe, meal.day)
        else:
            card = SuggestionDocument(
                title=meal.title,
                description=meal.description,
                reason=meal.reason,
                source_url=meal.source_url,
                origin="week",
                plan_day=meal.day,
            )
            await card.insert()
            meal.suggestion_id = str(card.id)
            ideas.append(card)

    week.status, week.list_id = "made", str(lst.id)
    await week.save()
    undo = await change.record(f"Made the list for the week of {week.week_of:%-d %b}", chat_id)
    # After recording, so Undo covers the list and the plan. A save that lands
    # after an Undo finds the plan no longer made and leaves the list alone.
    if start_save:
        for card in ideas:
            await start_save(card, str(lst.id))
    return await lists.get(lst.id), undo


async def skip(plan_id, chat_id: str | None = None) -> str:
    """Not this week: hide the card. It teaches Chef nothing."""
    week = await get(plan_id)
    change = Change()
    await change.touching(WeekPlanDocument, week.id)
    week.status = "skipped"
    await week.save()
    return await change.record(f"Skipped the week of {week.week_of:%-d %b}", chat_id)


async def ideas_not_on_their_list() -> list[tuple[SuggestionDocument, WeekPlanDocument]]:
    """New ideas from made weeks not yet over that have not reached their list.

    Saving, or failed: Make the list has gone, so this is where a failed save
    is seen and tried again. Each comes with its plan, for the list it goes on.
    """
    plans = await WeekPlanDocument.find(
        WeekPlanDocument.status == "made",
        WeekPlanDocument.week_of > date.today() - timedelta(days=7),
    ).to_list()
    plan_of = {m.suggestion_id: p for p in plans for m in p.meals if m.suggestion_id}
    cards = await SuggestionDocument.find(
        {"_id": {"$in": [PydanticObjectId(i) for i in plan_of]}, "status": {"$in": ["new", "saving", "failed"]}}
    ).sort("plan_day").to_list()
    return [(c, plan_of[str(c.id)]) for c in cards]


async def still_wanted(card: SuggestionDocument) -> bool:
    """Whether a week idea's recipe should still go on the list: its plan is still made."""
    return (
        await WeekPlanDocument.find_one(
            {"status": "made", "meals.suggestion_id": str(card.id)}
        )
        is not None
    )
