from datetime import date, datetime, timezone
from typing import Literal, Optional
from uuid import uuid4

from beanie import Document
from pymongo import ASCENDING, IndexModel
from pydantic import BaseModel, Field

from lib.types import Ingredient, IngredientRecipe, Recipe, RecipeJob, RecipeMetadata


class IngredientDocument(Document, Ingredient):
    embedding: list[float]
    category: Optional[str] = None

    class Settings:
        name = "ingredients"


class RecipeDocument(Document, Recipe, RecipeMetadata):
    ingredients: list[IngredientRecipe]
    rating: Optional[int] = None
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))

    class Settings:
        name = "recipes"
        # Import looks a recipe up by source_url on every request to avoid
        # re-importing the same page. Not unique: every hand-made recipe has
        # source_url unset, and a unique index would collide on the second one.
        indexes = ["source_url"]


class ItemSource(BaseModel):
    recipe_id: Optional[str] = None
    # None for an ingredient the recipe never quantified ("salt, to taste").
    # It still earns a source so the item survives until every recipe using it
    # is removed from the list.
    amount: Optional[float] = None


class ListItem(BaseModel):
    id: str = Field(default_factory=lambda: str(uuid4()))
    name: str
    amount: Optional[float] = None
    unit: Optional[str] = None
    category: str = Field(default="Other")
    checked: bool = False
    sources: list[ItemSource] = []


class PlanDay(BaseModel):
    date: date
    recipe_id: Optional[str] = None
    # "out" means no dinner to cook that night, e.g. eating out.
    status: Literal["open", "out"] = "open"
    origin: Literal["user", "calendar", "chef"] = "user"


class ListDocument(Document):
    name: str
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    recipes: list[str] = []
    # The meals on this list that have been cooked, a subset of `recipes`.
    # Only a person (or Chef asked by one) sets it; nothing moves or hides
    # because a meal was cooked.
    cooked: list[str] = []
    items: list[ListItem] = []
    # A week list has seven consecutive days from week_start. A list with no
    # week_start is a plain list. Every day's recipe_id is also in `recipes`;
    # recipes with no day are the week's any-day meals.
    week_start: Optional[date] = None
    days: list[PlanDay] = []

    class Settings:
        name = "lists"


DEFAULT_CATEGORIES = [
    {"name": "Fresh Produce", "order": 0},
    {"name": "Meat & Fish", "order": 1},
    {"name": "Dairy & Eggs", "order": 2},
    {"name": "Bakery", "order": 3},
    {"name": "Pantry & Dry Goods", "order": 4},
    {"name": "Frozen", "order": 5},
    {"name": "Drinks", "order": 6},
    {"name": "Household", "order": 7},
    {"name": "Other", "order": 8},
]


class CategoryConfig(BaseModel):
    name: str
    order: int


class UserSettingsDocument(Document):
    categories: list[CategoryConfig] = Field(
        default_factory=lambda: [CategoryConfig(**c) for c in DEFAULT_CATEGORIES]
    )
    # 0 is Monday. Saturday by default: the week runs from one shop to the next.
    week_start_weekday: int = 5
    # When Chef plans the coming week on its own (chef/run.py), in UK time.
    # Sunday at 08:00 by default; 0 is Monday.
    weekly_plan: bool = True
    weekly_plan_weekday: int = 6
    weekly_plan_hour: int = 8

    class Settings:
        name = "user_settings"


class SuggestionDocument(Document):
    """A Discover card: an idea that is not a recipe yet.

    Kept apart from RecipeDocument so the feed can be filled by anything that
    produces a title and a reason (the suggest endpoint now, an agent doing
    web searches later) without the UI changing. Saving one turns it into a
    recipe in the background and records the result in `recipe_id`.
    """

    title: str
    description: Optional[str] = None
    reason: Optional[str] = None
    image_url: Optional[str] = None
    source_url: Optional[str] = None
    source_name: Optional[str] = None
    total_minutes: Optional[int] = None
    section: Optional[str] = None
    # new -> saving -> saved, or failed; dismissed is "Not for me" (a taste
    # signal); cleared is hidden by Clear and says nothing about taste.
    status: str = "new"
    origin: str = "suggest"
    recipe_id: Optional[str] = None
    error: Optional[str] = None
    # When the latest save was started. The task doing it lives in the
    # server's memory, so a read decides from this whether it can still be
    # running. It also names that save: a save ends a card only while the card
    # still carries the start it was given.
    saving_since: Optional[datetime] = None
    # A new idea from a week plan (origin "week") lands on this day of its
    # list once saved. Those cards are not shown in the feed.
    plan_day: Optional[date] = None
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))

    class Settings:
        name = "suggestions"


class RecipeJobDocument(Document, RecipeJob):
    """A recipe being made in the background, under a key the client chose.

    The key is the document's `_id`, so Mongo itself refuses a second job for
    it: two starts that race end in one document and one `DuplicateKeyError`.

    The task that does the work lives in the server's memory, and a server
    that is killed loses it without ending the job. Nothing here is trusted to
    say "working" for ever: a read decides whether a job has been working too
    long. Mongo deletes a job a day after it was started.
    """

    id: str

    class Settings:
        name = "recipe_jobs"
        indexes = [
            IndexModel([("created_at", ASCENDING)], expireAfterSeconds=24 * 60 * 60),
        ]


class ChefActionStep(BaseModel):
    """One document a Chef action changed, as it was before and after.

    `before` is None for a document the action created, `after` None for one
    it deleted. Both are what a fresh read of the document returned, so Undo
    can tell whether anything has changed it since.
    """

    collection: str
    doc_id: str
    before: Optional[dict] = None
    after: Optional[dict] = None


class ChefActionDocument(Document):
    """A change Chef made in chat, kept so the person can Undo it.

    Chef acts without asking first (docs/PRD_CHEF.md); this is what makes that
    safe. Mongo deletes an action a week after it was made.
    """

    chat_id: Optional[str] = None
    summary: str
    steps: list[ChefActionStep]
    undone_at: Optional[datetime] = None
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))

    class Settings:
        name = "chef_actions"
        indexes = [
            IndexModel([("created_at", ASCENDING)], expireAfterSeconds=7 * 24 * 60 * 60),
        ]


class MealLogDocument(Document):
    """A dinner that was cooked: one row each time Cook is finished.

    The key is chosen by the client, so finishing Cook and then rating it
    write the same row however often either is sent.
    """

    id: str
    recipe_id: str
    cooked_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    # The "How was it?" answer, kept per cook.
    rating: Optional[int] = None

    class Settings:
        name = "meal_log"
        indexes = [IndexModel([("cooked_at", ASCENDING)])]


Stance = Literal["never", "avoid", "prefer", "more", "less"]


class PreferenceDocument(Document):
    """Something Chef knows about the household's taste.

    Told preferences are what they said and change only when they say so.
    Inferred ones are rewritten as a whole from what they cook, rate and
    dismiss (chef/memory.py). A told one wins over an inferred one on the same
    subject. Forgetting sets `retired_at`, so a forgotten inference stays
    forgotten when the set is rewritten.
    """

    subject: str
    stance: Stance
    # Shown to them: "You said so on 18 Oct", "Rated 4 curries 5 stars".
    evidence: str
    source: Literal["told", "inferred"]
    # The subject, normalised: one row per subject and source.
    key: str
    strength: float = 1.0
    retired_at: Optional[datetime] = None
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))

    class Settings:
        name = "preferences"
        indexes = [IndexModel([("source", ASCENDING), ("key", ASCENDING)], unique=True)]


class PlannedMeal(BaseModel):
    """One dinner in a week plan: a recipe they have, or a new idea."""

    day: date
    title: str
    # One line of why, shown on the card.
    reason: str
    # From their recipes...
    recipe_id: Optional[str] = None
    # ...or a new idea, made into a recipe when the list is made.
    description: Optional[str] = None
    source_url: Optional[str] = None
    # The card saving the idea, once the list is made.
    suggestion_id: Optional[str] = None


class WeekPlanDocument(Document):
    """A week of dinners Chef proposes. Nothing changes until they make the list.

    One per week: planning again replaces it (docs/PRD_CHEF.md, phase 6).
    """

    week_of: date
    note: str
    meals: list[PlannedMeal]
    # new -> made (list_id set), or skipped ("Not this week", which teaches Chef nothing).
    status: Literal["new", "made", "skipped"] = "new"
    list_id: Optional[str] = None
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))

    class Settings:
        name = "week_plans"
        indexes = [IndexModel([("week_of", ASCENDING)], unique=True)]
