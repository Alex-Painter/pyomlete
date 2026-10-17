from datetime import datetime, timezone
from typing import Optional
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


class ListDocument(Document):
    name: str
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    recipes: list[str] = []
    items: list[ListItem] = []

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
