import asyncio
import logging
from contextlib import asynccontextmanager
from datetime import date, datetime, timedelta, timezone
from typing import Awaitable, Callable
from uuid import UUID

from beanie import PydanticObjectId, UpdateResponse
from beanie.operators import In
from fastapi import APIRouter, FastAPI, HTTPException, Request, Response, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, ValidationError
from pydantic_ai.ui.vercel_ai import VercelAIAdapter
from pymongo.errors import DuplicateKeyError

from chef import actions as chef_actions
from chef import chat, discover, run, week
from data_models import (
    CategoryConfig,
    ListDocument,
    PreferenceDocument,
    RecipeDocument,
    RecipeJobDocument,
    SuggestionDocument,
    UserSettingsDocument,
    WeekPlanDocument,
)
from lib.db import get_motor_client, init_documents
from lib.types import (
    CategoriesUpdateRequest,
    CategorizeRequest,
    CategorizeResponse,
    DayUpdateRequest,
    ExcludeUpdateRequest,
    ImportFromUrlRequest,
    ItemCreateRequest,
    ItemReorderRequest,
    ItemUpdateRequest,
    ListCreateRequest,
    ListUpdateRequest,
    MealLogRequest,
    PlanSettingsRequest,
    PreferenceRequest,
    PreferenceUpdate,
    RatingUpdate,
    RecipeJobEnd,
    RecipeJobKind,
    RecipePrompt,
    RecipeUpdateRequest,
    SuggestionRefreshRequest,
    SuggestionSaveRequest,
    SuggestionStatusUpdate,
    SuggestionsClearRequest,
    SuggestionsCreateRequest,
    WeekPlanRequest,
    WeeklyPlanSettings,
)
from services import lists, memory, recipes, settings
from services.errors import AlreadyImported
from services.recipes import RecipeImage

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    client = get_motor_client()
    await init_documents(client)
    weekly_run = asyncio.create_task(run.keep_planning())
    yield
    weekly_run.cancel()
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
    images = [RecipeImage(f.content_type, await f.read()) for f in files]
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
    last_planned = await lists.last_planned_on()
    return [
        {
            "id": str(r.id),
            "title": r.title,
            "ingredient_count": len(r.ingredients),
            "ingredient_names": [i.name for i in r.ingredients],
            "cuisine": r.cuisine,
            "tags": r.tags.model_dump() if r.tags else None,
            "last_planned_on": last_planned.get(str(r.id)),
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
        "created_at": lst.created_at.isoformat() if lst.created_at else None,
        "recipes": lst.recipes,
        "cooked": lst.cooked,
        "items": [item.model_dump() for item in lst.items],
        **lists.week_out(lst),
    }


@router.get("/lists/")
async def get_lists():
    return await lists.summaries()


@router.post("/lists/")
async def create_list(body: ListCreateRequest | None = None):
    lst = await lists.create(body.week_start if body else None)
    return {
        "id": str(lst.id),
        "name": lst.name,
        "created_at": lst.created_at.isoformat(),
        **lists.week_out(lst),
    }


@router.get("/lists/{list_id}")
async def get_list(list_id: PydanticObjectId):
    return _list_out(await lists.get(list_id))


@router.patch("/lists/{list_id}")
async def update_list(list_id: PydanticObjectId, body: ListUpdateRequest):
    return _list_out(await lists.rename(list_id, body.name))


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


def _plan_settings_out(s: UserSettingsDocument) -> dict:
    return {"week_start_weekday": s.week_start_weekday, "variety_days": s.variety_days}


@router.get("/settings/plan")
async def get_plan_settings():
    return _plan_settings_out(await settings.get_or_create())


@router.put("/settings/plan")
async def update_plan_settings(body: PlanSettingsRequest):
    return _plan_settings_out(await settings.set_plan(body.week_start_weekday, body.variety_days))


def _weekly_plan_out(s: UserSettingsDocument) -> dict:
    return WeeklyPlanSettings(
        weekly_plan=s.weekly_plan,
        weekly_plan_weekday=s.weekly_plan_weekday,
        weekly_plan_hour=s.weekly_plan_hour,
    ).model_dump()


@router.get("/settings/weekly-plan")
async def get_weekly_plan_settings():
    """When Chef plans the coming week on its own, in UK time (chef/run.py)."""
    return _weekly_plan_out(await settings.get_or_create())


@router.put("/settings/weekly-plan")
async def update_weekly_plan_settings(body: WeeklyPlanSettings):
    saved = await settings.set_weekly_plan(body.weekly_plan, body.weekly_plan_weekday, body.weekly_plan_hour)
    run.reschedule()
    return _weekly_plan_out(saved)


# --- Week plans ---
# Chef proposes a week of dinners on a card; one tap makes the list, with Undo
# (docs/PRD_CHEF.md, phase 6). Nothing changes until that tap.


async def _week_out(w: WeekPlanDocument) -> dict:
    ids = [PydanticObjectId(m.recipe_id) for m in w.meals if m.recipe_id]
    found = {str(r.id): r for r in await RecipeDocument.find(In(RecipeDocument.id, ids)).to_list()}
    return {
        "id": str(w.id),
        "week_of": w.week_of.isoformat(),
        "note": w.note,
        "status": w.status,
        "list_id": w.list_id,
        "meals": [
            {
                "day": m.day.isoformat(),
                "title": m.title,
                "reason": m.reason,
                "recipe_id": m.recipe_id,
                "is_new": m.recipe_id is None,
                "image_url": found[m.recipe_id].image_url if m.recipe_id in found else None,
                "source_url": m.source_url,
            }
            for m in w.meals
        ],
    }


@router.get("/weeks/current")
async def current_week_plan():
    """The week Chef proposes, this one or the next, while it waits for a tap; null otherwise."""
    w = await week.waiting()
    return await _week_out(w) if w else None


@router.post("/weeks/plan")
async def plan_week(body: WeekPlanRequest):
    """Ask Chef for this week's dinners. Waits for the plan; one already waiting is returned unless `fresh`."""
    w, _ = await week.plan(fresh=body.fresh)
    return await _week_out(w)


@router.post("/weeks/{plan_id}/make")
async def make_week_list(plan_id: PydanticObjectId):
    """Make the week's list from the plan. `undo` is the id `POST /chef/actions/{id}/undo` takes."""
    lst, undo = await week.make_list(plan_id)
    return {"list_id": str(lst.id), "name": lst.name, "undo": undo}


@router.post("/weeks/{plan_id}/skip")
async def skip_week(plan_id: PydanticObjectId):
    """Not this week: hide the card, without it counting as a taste signal."""
    await week.skip(plan_id)
    return {"ok": True}


# --- Memory ---
# What Chef remembers (docs/PRD_CHEF.md, phase 4): a row for each dinner
# cooked, and the preferences shown in Settings under What Chef knows.


@router.put("/meals/{key}")
async def log_meal(key: UUID, body: MealLogRequest):
    """Finishing Cook records the dinner, and rating it after updates the same row."""
    meal = await memory.log_meal(str(key), body.recipe_id, body.rating)
    return {
        "id": meal.id,
        "recipe_id": meal.recipe_id,
        "cooked_at": meal.cooked_at.isoformat(),
        "rating": meal.rating,
    }


def _preference_out(p: PreferenceDocument) -> dict:
    return {
        "id": str(p.id),
        "subject": p.subject,
        "stance": p.stance,
        "evidence": p.evidence,
        "source": p.source,
        "forgotten": p.retired_at is not None,
    }


@router.get("/preferences")
async def list_preferences():
    """What Chef goes by: what they told it, then what it noticed that nothing they said overrides."""
    return [_preference_out(p) for p in await memory.active()]


@router.post("/preferences")
async def add_preference(body: PreferenceRequest):
    return _preference_out(await memory.remember(body.subject, body.stance))


@router.patch("/preferences/{pref_id}")
async def update_preference(pref_id: PydanticObjectId, body: PreferenceUpdate):
    """Forget a preference, or bring it back (Undo)."""
    return _preference_out(await memory.set_forgotten(pref_id, body.forgotten))


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


class CookedRequest(BaseModel):
    cooked: bool


@router.put("/lists/{list_id}/recipes/{recipe_id}/cooked")
async def set_recipe_cooked(list_id: PydanticObjectId, recipe_id: str, body: CookedRequest):
    return _list_out(await lists.set_cooked(list_id, recipe_id, body.cooked))


# --- Week days ---


@router.put("/lists/{list_id}/days/{day}")
async def update_day(list_id: PydanticObjectId, day: date, body: DayUpdateRequest):
    return _list_out(await lists.set_day(list_id, day, body.recipe_id, body.status, quick=body.quick))


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
# A week plan's new ideas are cards too, so they save the same way, but they
# belong to the week card and stay out of the feed and out of Clear.
WEEK_ORIGIN = "week"


@router.get("/suggestions/")
async def list_suggestions():
    suggestions = (
        await SuggestionDocument.find(
            {"status": {"$nin": list(HIDDEN_SUGGESTION_STATUSES)}, "origin": {"$ne": WEEK_ORIGIN}}
        )
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
    """Hide these cards (or every visible card) without counting it against them.

    A card whose save may be running is left: the card is that save's to end.
    With `only_new`, so is every card that has been acted on, a lost save included.
    """
    named = {"origin": {"$ne": WEEK_ORIGIN}}
    if body.ids is not None:
        named["_id"] = {"$in": [PydanticObjectId(i) for i in body.ids]}
    clearable = ["new"] if body.only_new else ["new", "saved", "failed"]
    result = await SuggestionDocument.find(
        {"status": {"$in": clearable}, **named}
    ).update({"$set": {"status": "cleared"}})
    cleared = getattr(result, "modified_count", 0)
    if not body.only_new:
        for s in await SuggestionDocument.find({"status": "saving", **named}).to_list():
            if not _save_may_be_running(s) and await _write_if_unchanged(s, {"status": "cleared"}):
                cleared += 1
    return {"cleared": cleared}


@router.patch("/suggestions/{suggestion_id}")
async def update_suggestion(suggestion_id: PydanticObjectId, body: SuggestionStatusUpdate):
    s = await _get_suggestion(suggestion_id)
    if body.status == "new" and _save_may_be_running(s):
        # Back to new would let a second save start beside the one running.
        raise HTTPException(status_code=409, detail="This card is being saved")
    # Only the status: writing the whole card back would undo a save that started or ended since the read.
    await SuggestionDocument.find_one({"_id": s.id}).update({"$set": {"status": body.status}})
    s.status = body.status
    return _suggestion_out(s)


async def _add_recipe_to_list_id(
    list_id: str, recipe: RecipeDocument, day: date | None = None
) -> None:
    await lists.place_recipe(PydanticObjectId(list_id), recipe, day)


async def _recipe_for(s: SuggestionDocument) -> RecipeDocument:
    """The card as a recipe: the one an earlier save made, imported from its link, or written from its title."""
    if s.recipe_id:
        # An earlier save got as far as the recipe. Making it again would be a second copy.
        made = await RecipeDocument.get(PydanticObjectId(s.recipe_id))
        if made:
            return made
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
        still_this_saves = await SuggestionDocument.find(
            {"_id": s.id, "status": s.status, "saving_since": s.saving_since}
        ).limit(1).to_list()
        if not still_this_saves:
            # Saved again, cleared or dismissed meanwhile, so its meal is not wanted on the list.
            logger.info("Suggestion %s was no longer this save's to end, so nothing was written", s.id)
            return
        try:
            if s.origin == WEEK_ORIGIN and not await week.still_wanted(s):
                # Its week's list was undone: the recipe is kept but goes on no list.
                logger.info("Suggestion %s: its week is no longer made, so the list is left alone", s.id)
            else:
                await asyncio.wait_for(
                    _add_recipe_to_list_id(list_id, recipe, s.plan_day), END_WRITE_TIMEOUT
                )
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

    claimed = await _start_suggestion_save(s, body.list_id)
    if claimed is None:
        # Another request got to the card between the read and the claim.
        return _suggestion_out(await _get_suggestion(suggestion_id))
    return _suggestion_out(claimed)


async def _start_suggestion_save(s: SuggestionDocument, list_id: str | None) -> SuggestionDocument | None:
    """Claim the card for a new save and start it, or None if another request got there first."""
    claimed = await _write_if_unchanged(
        s, {"status": "saving", "saving_since": datetime.now(timezone.utc), "error": None}
    )
    if claimed is not None:
        task = asyncio.create_task(_realise_suggestion(claimed, list_id))
        _suggestion_save_tasks.add(task)
        task.add_done_callback(_suggestion_save_tasks.discard)
    return claimed


week.start_save = _start_suggestion_save


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
        key, "link", lambda: recipes.import_url(body.url, body.changes), response, _link_refused
    )


@router.put("/recipe-jobs/{key}/describe", status_code=202)
async def start_describe_job(key: UUID, prompt: RecipePrompt, response: Response):
    """`POST /recipes/generate/` as the job with this key."""
    return await _start_recipe_job(key, "describe", lambda: recipes.generate(prompt.prompt), response)


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

    return await _start_recipe_job(key, "photos", lambda: recipes.from_images(images), response)


@router.get("/recipe-jobs/{key}")
async def get_recipe_job(key: UUID):
    """How a job stands: working, saved, already_imported or failed."""
    job = await RecipeJobDocument.get(str(key))
    if not job:
        raise HTTPException(status_code=404, detail="Recipe job not found")
    return _recipe_job_out(job)


# --- Chef chat ---


@router.post("/chef/chat")
async def chef_chat(request: Request):
    """Talk to Chef. The body is the AI SDK's chat request plus `page`, where the
    person is in the app; the reply streams back in the AI SDK's format."""
    try:
        adapter = await VercelAIAdapter.from_request(request, agent=chat.agent)
    except ValidationError as exc:
        return Response(content=exc.json(), media_type="application/json", status_code=422)
    run_input = adapter.run_input
    deps = chat.deps_for(run_input.id, (run_input.model_extra or {}).get("page"), adapter.messages)
    return adapter.streaming_response(adapter.run_stream(deps=deps))


@router.post("/chef/actions/{action_id}/undo")
async def undo_chef_action(action_id: PydanticObjectId):
    """Put back what one of Chef's changes changed. 409 when something else
    has changed it since."""
    action = await chef_actions.undo(action_id)
    # It may have put back the weekly plan's time.
    run.reschedule()
    return {"id": str(action.id), "summary": action.summary, "undone": True}


app.include_router(router)
