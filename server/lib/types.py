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
    amount: Optional[float] = Field(
        default=None,
        description="Leave unset when the source gives no quantity ('salt and pepper to taste'). Do not invent one.",
    )
    note: Optional[str] = Field(
        default=None,
        description="Preparation stripped from the name, e.g. 'finely chopped' for '2 onions, finely chopped'.",
    )
    group: Optional[str] = Field(
        default=None,
        description="The heading this ingredient sat under in the source, e.g. 'For the sauce'.",
    )
    category: str = Field(default="Other")
    excluded_from_list: bool = Field(default=False)


class IngredientModelResponse(IngredientRecipe):
    is_new: bool = Field(
        description="If the suggested ingredient was not found in the find_similar_ingredients tool call, set this to be true so we know to add it to the DB."
    )


class Recipe(BaseModel):
    title: str
    instructions: list[str]


class RecipeMetadata(BaseModel):
    """Provenance and timings that come from an imported page, not from a model.

    Deliberately kept off `Recipe` so none of it reaches the JSON schema we hand
    Claude. `image_url` and `source_url` in particular have exactly one honest
    value — whatever the source page published — and a model asked to fill them
    in will produce a plausible URL that points at nothing.

    Every field is optional, so recipes saved before this existed deserialise
    unchanged and no migration is needed.
    """

    servings: Optional[int] = None
    prep_minutes: Optional[int] = None
    cook_minutes: Optional[int] = None
    total_minutes: Optional[int] = None
    image_url: Optional[str] = None
    source_url: Optional[str] = None
    source_name: Optional[str] = None
    description: Optional[str] = None
    cuisine: Optional[str] = None


class RecipeModelResponse(Recipe):
    ingredients: list[IngredientModelResponse]


class ImportFromUrlRequest(BaseModel):
    url: str


class MealIdea(BaseModel):
    title: str
    description: str = Field(
        description="One short, appetising sentence describing the meal."
    )


class MealSuggestions(BaseModel):
    suggestions: list[MealIdea]


class SuggestMealsRequest(BaseModel):
    diet: Optional[str] = None
    ease: Optional[str] = None
    notes: Optional[str] = None
    exclude_titles: list[str] = Field(default_factory=list)


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


class ItemReorderRequest(BaseModel):
    category: str
    item_ids: list[str]


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
