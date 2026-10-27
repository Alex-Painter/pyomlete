from datetime import date, datetime, timezone
from typing import Literal, Optional

from pydantic import BaseModel, Field, field_validator


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
    # Free text typed alongside the link, e.g. "but use quorn mince". Applied
    # to the imported recipe before it's saved.
    changes: Optional[str] = None


RecipeJobKind = Literal["link", "describe", "photos"]
RecipeJobStatus = Literal["working", "saved", "already_imported", "failed"]
# The first three are a link's 400, 404 and 502 from import-from-url.
RecipeJobFailure = Literal[
    "link_blocked", "no_recipe_on_page", "site_did_not_respond", "other"
]


class RecipeJob(BaseModel):
    """One recipe being made off the request path, and how it ended.

    `recipe_id` is set when the status is saved or already_imported, and
    `failure` when it is failed.
    """

    kind: RecipeJobKind
    status: RecipeJobStatus = "working"
    recipe_id: Optional[str] = None
    failure: Optional[RecipeJobFailure] = None
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))


class RecipeJobEnd(BaseModel):
    """How a job ended: the three fields of `RecipeJob` that its ending writes."""

    status: RecipeJobStatus
    recipe_id: Optional[str] = None
    failure: Optional[RecipeJobFailure] = None


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
    # Optional client-chosen id. The list screen shows a new item before the
    # server answers, and a phone in a shop with no signal queues the add; a
    # stable id lets the retry land once instead of twice.
    id: Optional[str] = None
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


class ListCreateRequest(BaseModel):
    week_start: Optional[date] = None


class DayUpdateRequest(BaseModel):
    recipe_id: Optional[str] = None
    status: Literal["open", "out"] = "open"


class PlanSettingsRequest(BaseModel):
    # 0 is Monday, 6 is Sunday, as in date.weekday().
    week_start_weekday: int = Field(ge=0, le=6)


class WeeklyPlanSettings(BaseModel):
    """When Chef plans the coming week on its own, in UK time."""

    weekly_plan: bool
    # 0 is Monday, 6 is Sunday.
    weekly_plan_weekday: int = Field(ge=0, le=6)
    weekly_plan_hour: int = Field(ge=0, le=23)


class CategoryConfigRequest(BaseModel):
    name: str
    order: int


class CategoriesUpdateRequest(BaseModel):
    categories: list[CategoryConfigRequest]

    @field_validator("categories")
    @classmethod
    def _clean(cls, categories: list[CategoryConfigRequest]) -> list[CategoryConfigRequest]:
        """Trim each name, drop the empty ones and any that repeats an earlier one
        whatever its case. Lists group by name, so two aisles with one name are one
        aisle listed twice. Cleaned and not refused: a client sends its whole list
        and none of them expects a 422. Each aisle kept keeps the order it came with."""
        seen: set[str] = set()
        kept = []
        for category in categories:
            name = category.name.strip()
            # casefold, not lower: "Straße" and "STRASSE" are one name.
            folded = name.casefold()
            if not name or folded in seen:
                continue
            seen.add(folded)
            kept.append(CategoryConfigRequest(name=name, order=category.order))
        return kept


class CategorizeRequest(BaseModel):
    name: str


class CategorizeResponse(BaseModel):
    category: str


# --- Discover suggestions ---


class SuggestedMeal(BaseModel):
    """One idea as the model returns it for the Discover feed."""

    title: str
    description: str = Field(
        description="One short, appetising sentence describing the meal."
    )
    reason: str = Field(
        description="Why this suits this household, in under 12 words, e.g. 'Because you rated Shakshuka 4 stars' or 'Uses the spinach on your list'."
    )
    total_minutes: int = Field(description="Rough total cooking time in minutes.")
    section: str = Field(
        description="One of: 'For this week', 'Under 30 minutes', 'Something new'."
    )


class SuggestedMeals(BaseModel):
    suggestions: list[SuggestedMeal]


class SuggestionCreate(BaseModel):
    """A suggestion record from any producer: the suggest endpoint today, a
    web-searching agent later. Only title is required."""

    title: str
    description: Optional[str] = None
    reason: Optional[str] = None
    image_url: Optional[str] = None
    source_url: Optional[str] = None
    source_name: Optional[str] = None
    total_minutes: Optional[int] = None
    section: Optional[str] = None
    origin: str = "agent"


class SuggestionsCreateRequest(BaseModel):
    suggestions: list[SuggestionCreate]


class SuggestionRefreshRequest(BaseModel):
    diet: Optional[str] = None
    ease: Optional[str] = None
    notes: Optional[str] = None


class SuggestionStatusUpdate(BaseModel):
    status: str = Field(pattern="^(new|dismissed|cleared)$")


class SuggestionsClearRequest(BaseModel):
    # None clears every visible card; a list clears just those (what the
    # person saw when they tapped Clear, so newer cards survive).
    ids: Optional[list[str]] = None
    # Home's Clear on the phone: only cards nobody has acted on. Without it a
    # card saved or failed elsewhere since the phone last read it would go too.
    only_new: bool = False


class SuggestionSaveRequest(BaseModel):
    # Also put the recipe on this list once it exists.
    list_id: Optional[str] = None


class MealLogRequest(BaseModel):
    recipe_id: str
    rating: Optional[int] = Field(default=None, ge=1, le=5)


class PreferenceRequest(BaseModel):
    subject: str = Field(min_length=1, max_length=80)
    stance: Literal["never", "avoid", "prefer", "more", "less"]


class PreferenceUpdate(BaseModel):
    forgotten: bool


class WeekPlanRequest(BaseModel):
    # Plan again even though a plan is waiting.
    fresh: bool = False
