from typing import Optional

from pydantic import BaseModel, Field


class RecipePrompt(BaseModel):
    prompt: str


class Ingredient(BaseModel):
    name: str
    unit: str = Field(
        examples=["grams", "teaspoon", "tablespoon", "teaspoons", "tablespoons", "ml"]
    )


class IngredientRecipe(BaseModel):
    name: str
    unit: str = Field(
        examples=["grams", "teaspoon", "tablespoon", "teaspoons", "tablespoons", "ml"]
    )
    amount: float
    category: str = Field(default="Other")
    excluded_from_list: bool = Field(default=False)


class IngredientModelResponse(IngredientRecipe):
    is_new: bool = Field(
        description="If the suggested ingredient was not found in the find_similar_ingredients tool call, set this to be true so we know to add it to the DB."
    )


class Recipe(BaseModel):
    title: str
    instructions: list[str]


class RecipeModelResponse(Recipe):
    ingredients: list[IngredientModelResponse]


class SimilarIngredient(BaseModel):
    name: str
    score: float


class Match(BaseModel):
    name: str
    score: float
    unit: str


class QueryMatch(BaseModel):
    query: str
    matches: list[Match]


class SimilarIngredients(BaseModel):
    list[QueryMatch]


class RatingUpdate(BaseModel):
    rating: int = Field(ge=1, le=5)


class RecipeUpdateRequest(BaseModel):
    title: str
    instructions: list[str]
    ingredients: list[IngredientRecipe]


class ExcludeUpdateRequest(BaseModel):
    excluded: bool


class ItemCreateRequest(BaseModel):
    name: str
    amount: Optional[float] = None
    unit: Optional[str] = None
    category: str = "Other"


class ItemUpdateRequest(BaseModel):
    name: Optional[str] = None
    amount: Optional[float] = None
    unit: Optional[str] = None
    category: Optional[str] = None
    checked: Optional[bool] = None


class ListUpdateRequest(BaseModel):
    name: Optional[str] = None


class CategoryConfigRequest(BaseModel):
    name: str
    order: int


class CategoriesUpdateRequest(BaseModel):
    categories: list[CategoryConfigRequest]


class CategorizeRequest(BaseModel):
    name: str


class CategorizeResponse(BaseModel):
    category: str
