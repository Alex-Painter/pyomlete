import json
from unittest.mock import AsyncMock, MagicMock

import pytest

from ingredient_structurer import (
    MODEL,
    StructuredIngredients,
    _build_prompt,
    _format_lines,
    structure_ingredients,
)
from recipe_import import IngredientGroup


def make_client(payload: dict) -> MagicMock:
    """An AsyncAnthropic stand-in whose runner returns `payload` as JSON."""
    message = MagicMock()
    message.content = [MagicMock(text=json.dumps(payload))]

    runner = MagicMock()
    runner.until_done = AsyncMock(return_value=message)

    client = MagicMock()
    client.beta.messages.tool_runner = MagicMock(return_value=runner)
    return client


def ingredient(**overrides) -> dict:
    base = {"name": "onions", "unit": "", "amount": 2.0, "is_new": True}
    base.update(overrides)
    return base


class TestStructureIngredients:
    async def test_returns_empty_without_calling_the_model(self):
        client = make_client({"ingredients": []})

        result = await structure_ingredients([], "Fresh Produce", client)

        assert result == []
        client.beta.messages.tool_runner.assert_not_called()

    async def test_parses_structured_ingredients(self):
        client = make_client({
            "ingredients": [
                ingredient(name="onions", amount=2.0, unit="", note="finely chopped"),
                ingredient(name="beef mince", amount=500.0, unit="g"),
            ]
        })

        result = await structure_ingredients(
            ["2 onions, finely chopped", "500g beef mince"], "Fresh Produce", client
        )

        assert [i.name for i in result] == ["onions", "beef mince"]
        assert result[0].note == "finely chopped"
        assert result[1].amount == 500.0
        assert result[1].unit == "g"

    async def test_unquantified_ingredient_keeps_amount_unset(self):
        client = make_client({
            "ingredients": [ingredient(name="salt", unit="", amount=None)]
        })

        result = await structure_ingredients(
            ["salt and pepper to taste"], "Pantry & Dry Goods", client
        )

        assert result[0].amount is None

    async def test_runs_on_haiku(self):
        client = make_client({"ingredients": [ingredient()]})

        await structure_ingredients(["2 onions"], "Fresh Produce", client)

        kwargs = client.beta.messages.tool_runner.call_args.kwargs
        assert kwargs["model"] == MODEL
        assert "haiku" in MODEL

    async def test_offers_the_similarity_tool(self):
        client = make_client({"ingredients": [ingredient()]})

        await structure_ingredients(["2 onions"], "Fresh Produce", client)

        kwargs = client.beta.messages.tool_runner.call_args.kwargs
        assert len(kwargs["tools"]) == 1

    async def test_rejects_a_malformed_model_response(self):
        client = make_client({"wrong_key": []})

        with pytest.raises(Exception):
            await structure_ingredients(["2 onions"], "Fresh Produce", client)


class TestFormatLines:
    def test_flat_list_when_no_groups(self):
        rendered = _format_lines(["2 onions", "500g beef mince"], None)

        assert rendered == "- 2 onions\n- 500g beef mince"

    def test_keeps_group_headings(self):
        groups = [
            IngredientGroup(purpose="For the sauce", ingredients=["2 onions"]),
            IngredientGroup(purpose="For the topping", ingredients=["50g cheese"]),
        ]

        rendered = _format_lines(["2 onions", "50g cheese"], groups)

        assert "For the sauce\n- 2 onions" in rendered
        assert "For the topping\n- 50g cheese" in rendered

    def test_labels_an_unnamed_group(self):
        groups = [IngredientGroup(purpose=None, ingredients=["2 onions"])]

        rendered = _format_lines(["2 onions"], groups)

        assert "(no heading)" in rendered

    def test_falls_back_to_the_flat_list_when_groups_lose_ingredients(self):
        """Groups that don't cover every line are not trustworthy.

        Some sites publish partial ingredient_groups. Rendering those would
        silently drop whatever they left out, so the flat list wins.
        """
        groups = [IngredientGroup(purpose="For the sauce", ingredients=["2 onions"])]

        rendered = _format_lines(["2 onions", "500g beef mince"], groups)

        assert "500g beef mince" in rendered
        assert "For the sauce" not in rendered


class TestBuildPrompt:
    def test_includes_the_categories(self):
        prompt = _build_prompt(["2 onions"], "Fresh Produce, Bakery", None)

        assert "[Fresh Produce, Bakery]" in prompt

    def test_tells_the_model_not_to_invent_amounts(self):
        prompt = _build_prompt(["salt to taste"], "Other", None)

        assert "do not invent one" in prompt


class TestSchema:
    def test_ingredients_wrapper_validates(self):
        parsed = StructuredIngredients.model_validate(
            {"ingredients": [ingredient()]}
        )

        assert parsed.ingredients[0].name == "onions"
        assert parsed.ingredients[0].category == "Other"
        assert parsed.ingredients[0].excluded_from_list is False
