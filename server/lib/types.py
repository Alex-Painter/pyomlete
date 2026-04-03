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
