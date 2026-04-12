from datetime import datetime, timezone
from typing import Optional
from uuid import uuid4

from beanie import Document
from pydantic import BaseModel, Field

from lib.types import Ingredient, IngredientRecipe, Recipe


class IngredientDocument(Document, Ingredient):
    embedding: list[float]
    category: Optional[str] = None

    class Settings:
        name = "ingredients"


class RecipeDocument(Document, Recipe):
    ingredients: list[IngredientRecipe]
    rating: Optional[int] = None
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))

    class Settings:
        name = "recipes"


class ItemSource(BaseModel):
    recipe_id: Optional[str] = None
    amount: float


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
