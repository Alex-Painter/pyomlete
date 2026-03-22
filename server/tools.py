import json

from anthropic import beta_async_tool

from ingredient_service import IngredientService

_service = IngredientService()


@beta_async_tool
async def find_similar_ingredients(ingredient_names: list[str]) -> str:
    """Search the vector database for existing ingredients. You must use this after you have created a recipe to check if an ingredient you suggested already exists in the database in some semantically similar form.

    Args:
      ingredient_names: a list of suggested ingredients to search for to see if semantically similar ones exist in the DB already
    Returns:
      A dict mapping the original ingredient name to a list of semantically similar ingredients with similarity scores.
    """
    matches = await _service.find_similar(ingredient_names)
    return json.dumps([m.model_dump() for m in matches])
