import json

from anthropic import beta_async_tool

from ingredient_service import IngredientService
from services.errors import Unavailable

_service = IngredientService()

# Model calls one recipe run may make. A run is a lookup or two and then the
# recipe, so this leaves room to spare. The cap is for a run that loops: on
# 1 Nov 2026 a broken lookup sent Opus round about 430 times in 13 minutes and
# spent $47 on one import.
MAX_TOOL_TURNS = 8


class _LookupFailed(BaseException):
    """The ingredient lookup broke, so the run must stop.

    A BaseException because the Anthropic tool runner turns every Exception a
    tool raises into an error result the model then retries, and retrying a
    lookup whose key or database is down only spends tokens.
    """


@beta_async_tool
async def find_similar_ingredients(ingredient_names: list[str]) -> str:
    """Search the vector database for existing ingredients. You must use this after you have created a recipe to check if an ingredient you suggested already exists in the database in some semantically similar form.

    Args:
      ingredient_names: a list of suggested ingredients to search for to see if semantically similar ones exist in the DB already
    Returns:
      A dict mapping the original ingredient name to a list of semantically similar ingredients with similarity scores.
    """
    try:
        matches = await _service.find_similar(ingredient_names)
    except Exception as exc:
        raise _LookupFailed() from exc
    return json.dumps([m.model_dump() for m in matches])


async def run_until_done(runner):
    """Run a recipe tool loop to its final message, or fail without retrying.

    Every runner built with find_similar_ingredients goes through here, with
    max_iterations=MAX_TOOL_TURNS.
    """
    try:
        message = await runner.until_done()
    except _LookupFailed as exc:
        raise Unavailable("The ingredient lookup failed, so the recipe was not made.") from exc.__cause__
    if message.stop_reason == "tool_use":
        raise Unavailable("The recipe took too many steps, so it was stopped.")
    return message
