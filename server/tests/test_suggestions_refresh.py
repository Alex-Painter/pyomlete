import json
from datetime import datetime, timedelta, timezone

import pytest
from beanie import init_beanie
from mongomock_motor import AsyncMongoMockClient
from pydantic_ai.messages import ModelMessage, ModelResponse, TextPart, UserPromptPart
from pydantic_ai.models.function import AgentInfo, FunctionModel

import main
from chef import discover
from data_models import ListDocument, ListItem, RecipeDocument, SuggestionDocument
from lib.types import SuggestionRefreshRequest

IDEAS = [
    {
        "title": f"Idea {i}",
        "description": f"Tasty idea {i}.",
        "reason": f"Because of {i}",
        "total_minutes": 20 + i,
        "section": section,
    }
    for i, section in enumerate(
        ["For this week"] * 2 + ["Under 30 minutes"] * 2 + ["Something new"] * 2
    )
]

EXPECTED_PROMPT = (
    "You are a professional chef helping a home cook discover new things to make. "
    "Suggest 6 distinct dinner ideas: two 'For this week', two 'Under 30 minutes' "
    "and two 'Something new' that stretch their usual cooking. For each, give a "
    "short title, one appetising sentence, a rough total time in minutes, and a "
    "reason it suits them that a person would find specific and true, grounded in "
    "the signals below.\n\n"
    "Taste signals: They loved: Shakshuka (5 stars). They didn't enjoy: Liver (1 stars). "
    "They said 'not for me' to: Tripe. "
    "On their current shopping list: spinach, feta.\n"
    "Constraints: Dietary preference: vegetarian. Effort level: easy to cook. "
    "Additional notes from the user: no mushrooms\n"
    "Do NOT suggest any of these, they already have or saw them: "
    "Shakshuka; Liver; Plain toast; Old card; Tripe.\n"
    "Output the ideas in the given JSON format."
)


@pytest.fixture
async def db():
    client = AsyncMongoMockClient()
    await init_beanie(
        database=client["omlete_test"],
        document_models=[RecipeDocument, ListDocument, SuggestionDocument],
    )
    yield


async def seed():
    now = datetime.now(timezone.utc)
    for title, rating in [("Shakshuka", 5), ("Liver", 1), ("Plain toast", 3)]:
        await RecipeDocument(title=title, instructions=[], ingredients=[], rating=rating).insert()
    await SuggestionDocument(title="Tripe", status="dismissed", created_at=now - timedelta(days=2)).insert()
    await SuggestionDocument(title="Old card", created_at=now - timedelta(days=1)).insert()
    await ListDocument(
        name="This week",
        items=[
            ListItem(name="spinach"),
            ListItem(name="feta"),
            ListItem(name="bread", checked=True),
        ],
    ).insert()


def fake_claude(seen: list[str]):
    async def respond(messages: list[ModelMessage], info: AgentInfo) -> ModelResponse:
        seen.extend(
            p.content for m in messages for p in m.parts if isinstance(p, UserPromptPart)
        )
        return ModelResponse(parts=[TextPart(json.dumps({"suggestions": IDEAS}))])

    return discover.agent.override(model=FunctionModel(respond))


async def test_refresh_builds_the_prompt_from_taste_signals_and_stores_six_cards(db):
    await seed()
    seen: list[str] = []
    with fake_claude(seen):
        cards = await main.refresh_suggestions(
            SuggestionRefreshRequest(diet="vegetarian", ease="easy", notes=" no mushrooms ")
        )

    assert seen == [EXPECTED_PROMPT]
    assert [(c["title"], c["section"], c["origin"], c["status"]) for c in cards] == [
        (i["title"], i["section"], "suggest", "new") for i in IDEAS
    ]
    stored = [await SuggestionDocument.get(c["id"]) for c in cards]
    assert [s.title for s in stored] == [i["title"] for i in IDEAS]


async def test_refresh_with_no_signals_or_constraints(db):
    seen: list[str] = []
    with fake_claude(seen):
        await main.refresh_suggestions(SuggestionRefreshRequest(diet="Any"))

    assert "Taste signals: No taste signals yet.\nConstraints: None.\n" in seen[0]
    assert "Do NOT suggest" not in seen[0]
