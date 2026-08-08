"""Turn free-text ingredient lines into structured ingredients.

This is stage 2 of the URL import pipeline described in docs/PRD_URL_IMPORT.md.
`recipe_import.scrape()` hands back lines exactly as the source page wrote them
— ``"2 onions, finely chopped"`` — because recipe-scrapers ships no ingredient
parser. This module splits those into name / amount / unit and canonicalises the
names against our vocabulary.

It runs on Haiku rather than Opus. This is a parsing task over text we already
have, not a generation task: the model is never asked to invent an ingredient,
only to cut a line into fields, so the cheap model is the right one and the
blast radius of a bad answer is a mis-split line rather than a made-up recipe.
"""

from typing import Optional

from anthropic import AsyncAnthropic, transform_schema
from pydantic import BaseModel, Field, TypeAdapter

from lib.types import IngredientModelResponse
from recipe_import import IngredientGroup
from tools import find_similar_ingredients

MODEL = "claude-haiku-4-5-20251001"
_MAX_TOKENS = 4096


class StructuredIngredients(BaseModel):
    """Wrapper so the model returns an object rather than a bare array."""

    ingredients: list[IngredientModelResponse] = Field(
        description="One entry per input line, in the order the lines were given."
    )


_schema = transform_schema(TypeAdapter(StructuredIngredients).json_schema())


def _format_lines(
    lines: list[str], groups: list[IngredientGroup] | None
) -> str:
    """Render the ingredient lines for the prompt, keeping any headings.

    Groups are used when the page published them and they actually cover the
    lines; otherwise the flat list is authoritative. Sites are inconsistent
    enough about ingredient_groups() that trusting it blindly would silently
    drop ingredients.
    """
    if groups:
        grouped = [line for g in groups for line in g.ingredients]
        if sorted(grouped) == sorted(lines):
            blocks = []
            for group in groups:
                heading = group.purpose or "(no heading)"
                body = "\n".join(f"- {line}" for line in group.ingredients)
                blocks.append(f"{heading}\n{body}")
            return "\n\n".join(blocks)

    return "\n".join(f"- {line}" for line in lines)


def _build_prompt(
    lines: list[str], categories_str: str, groups: list[IngredientGroup] | None
) -> str:
    return f"""Split each of these recipe ingredient lines into structured fields. They were copied verbatim from a recipe page.

{_format_lines(lines, groups)}

Rules:
- Return exactly one entry per line, in the same order. Never merge or drop a line.
- `name` is the ingredient alone, singular where natural: "2 onions, finely chopped" -> "onions".
- `note` holds any preparation you stripped off the name: "finely chopped". Leave it unset if there is none.
- `amount` is the numeric quantity. Convert fractions and ranges to a single number ("1 1/2" -> 1.5, "2-3" -> 2.5). If the line gives no quantity ("salt and pepper to taste", "a splash of olive oil"), leave `amount` unset — do not invent one.
- `unit` is the measure the amount is in ("g", "tbsp", "ml"). For things counted rather than measured ("2 onions"), use an empty string.
- `group` is the heading the line sat under, if it was given one above. Use an empty heading of "(no heading)" as unset.
- You must call find_similar_ingredients with every name you produce. When it returns a match, use the matched name and unit verbatim instead of yours and set is_new=false — this is how we avoid storing "spring onions" and "scallions" as two different things.
- For each NEW ingredient (is_new=true), assign a category from this list: [{categories_str}]. For existing ingredients matched via the tool, leave the category as 'Other' — the system will use the cached category.

Output in the given JSON format."""


async def structure_ingredients(
    lines: list[str],
    categories_str: str,
    client: AsyncAnthropic,
    groups: Optional[list[IngredientGroup]] = None,
) -> list[IngredientModelResponse]:
    """Parse free-text ingredient lines into structured, canonicalised entries.

    Returns an empty list for empty input without calling the model.
    """
    if not lines:
        return []

    runner = client.beta.messages.tool_runner(
        model=MODEL,
        max_tokens=_MAX_TOKENS,
        messages=[{
            "role": "user",
            "content": _build_prompt(lines, categories_str, groups),
        }],
        tools=[find_similar_ingredients],
        stream=True,
        output_config={"format": {"type": "json_schema", "schema": _schema}},
    )

    final_message = await runner.until_done()
    parsed = StructuredIngredients.model_validate_json(final_message.content[0].text)
    return parsed.ingredients
