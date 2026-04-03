from datetime import datetime, timezone
from typing import Optional

from beanie import Document
from pydantic import Field

from lib.types import Ingredient, IngredientRecipe, Recipe


class IngredientDocument(Document, Ingredient):
    embedding: list[float]

    class Settings:
        name = "ingredients"


class RecipeDocument(Document, Recipe):
    ingredients: list[IngredientRecipe]
    rating: Optional[int] = None
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))

    class Settings:
        name = "recipes"
