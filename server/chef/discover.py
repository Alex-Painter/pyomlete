"""Chef's Discover feed: new dinner ideas from the household's taste.

Chef is the suggestions agent (docs/DESIGN.md). It runs on Pydantic AI so the
same agent can later take tools, a chat and a weekly schedule
(see docs/PRD_CHEF.md).
"""

from beanie import PydanticObjectId
from pydantic_ai import Agent, NativeOutput

from chef import memory as chef_memory
from data_models import ListDocument, RecipeDocument, SuggestionDocument
from lib.types import SuggestedMeals, SuggestionRefreshRequest
from services import memory

agent = Agent(
    "anthropic:claude-opus-4-5",
    output_type=NativeOutput(SuggestedMeals),
    model_settings={"max_tokens": 2048},
)


async def taste_profile() -> str:
    """What we know about this household's taste, as prompt text.

    Every signal the UI collects ends up here: what they told Chef and what it
    inferred (services/memory.py), star ratings (including the "How was it?"
    at the end of Cook), what they cooked lately, "Not for me" on Discover
    cards, and what's on the latest shopping list.
    """
    lines: list[str] = []
    if known := memory.prompt_text(await memory.active()):
        lines.append(known)
    rated = await RecipeDocument.find(RecipeDocument.rating != None).to_list()  # noqa: E711
    liked = [f"{r.title} ({r.rating} stars)" for r in rated if (r.rating or 0) >= 4]
    disliked = [f"{r.title} ({r.rating} stars)" for r in rated if (r.rating or 0) <= 2]
    if liked:
        lines.append("They loved: " + "; ".join(liked[:15]) + ".")
    if disliked:
        lines.append("They didn't enjoy: " + "; ".join(disliked[:10]) + ".")

    meals = await memory.recent_meals(weeks=3)
    if meals:
        ids = {PydanticObjectId(m.recipe_id) for m in meals}
        cooked = await RecipeDocument.find({"_id": {"$in": list(ids)}}).to_list()
        lines.append("They cooked lately: " + "; ".join(r.title for r in cooked) + ".")

    dismissed = (
        await SuggestionDocument.find(SuggestionDocument.status == "dismissed")
        .sort("-created_at")
        .limit(20)
        .to_list()
    )
    if dismissed:
        lines.append(
            "They said 'not for me' to: " + "; ".join(d.title for d in dismissed) + "."
        )

    latest = await ListDocument.find_all().sort("-created_at").limit(1).to_list()
    if latest:
        on_list = [i.name for i in latest[0].items if not i.checked][:30]
        if on_list:
            lines.append("On their current shopping list: " + ", ".join(on_list) + ".")

    return " ".join(lines) or "No taste signals yet."


async def refresh(req: SuggestionRefreshRequest) -> list[SuggestionDocument]:
    """Ask Chef for six new ideas and add them to the feed.

    The inferred preferences are distilled first, so they are fresh for the
    prompt and in Settings. Until the weekly run (docs/PRD_CHEF.md, phase 7)
    this is where they are learned. A card naming something they said never
    to is dropped: that rule is code's to keep, not the model's.
    """
    await chef_memory.distil()
    constraints: list[str] = []
    if req.diet and req.diet.lower() != "any":
        constraints.append(f"Dietary preference: {req.diet}.")
    if req.ease and req.ease.lower() != "any":
        constraints.append(f"Effort level: {req.ease} to cook.")
    if req.notes and req.notes.strip():
        constraints.append(f"Additional notes from the user: {req.notes.strip()}")

    library = await RecipeDocument.find_all().to_list()
    shown = await SuggestionDocument.find_all().sort("-created_at").limit(60).to_list()
    avoid = [r.title for r in library] + [s.title for s in shown]

    prompt = (
        "You are a professional chef helping a home cook discover new things to make. "
        "Suggest 6 distinct dinner ideas: two 'For this week', two 'Under 30 minutes' "
        "and two 'Something new' that stretch their usual cooking. For each, give a "
        "short title, one appetising sentence, a rough total time in minutes, and a "
        "reason it suits them that a person would find specific and true, grounded in "
        f"the signals below.\n\nTaste signals: {await taste_profile()}\n"
        f"Constraints: {' '.join(constraints) or 'None.'}\n"
        + (f"Do NOT suggest any of these, they already have or saw them: {'; '.join(avoid[:80])}.\n" if avoid else "")
        + "Output the ideas in the given JSON format."
    )

    result = await agent.run(prompt)
    never = [p for p in await memory.active() if p.stance == "never"]
    docs = [
        SuggestionDocument(
            title=i.title,
            description=i.description,
            reason=i.reason,
            total_minutes=i.total_minutes,
            section=i.section,
            origin="suggest",
        )
        for i in result.output.suggestions
        if not memory.names_any(f"{i.title} {i.description}", never)
    ]
    # One at a time so each document gets its id back for the response.
    for d in docs:
        await d.insert()
    return docs
