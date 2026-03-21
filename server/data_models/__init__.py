from beanie import Document

from lib.types import Ingredient, IngredientRecipe, Recipe


class IngredientDocument(Document, Ingredient):
    embedding: list[float]

    class Settings:
        name = "ingredients"


class RecipeDocument(Document, Recipe):
    ingredients: list[IngredientRecipe]

    class Settings:
        name = "recipes"
