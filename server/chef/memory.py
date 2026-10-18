"""Distil: what Chef infers about the household's taste from what they do.

Plain code gathers the signals (meals cooked, ratings, "Not for me", what
keeps going on their lists) and Haiku reads them into a few preferences, each
with the evidence shown in Settings. The whole inferred set is rewritten each
time, so a second run, or one after a crash, ends in the same rows.
"""

from collections import Counter
from typing import Literal

from beanie import PydanticObjectId
from pydantic import BaseModel, Field
from pydantic_ai import Agent

from data_models import ListDocument, PreferenceDocument, RecipeDocument, SuggestionDocument
from services import memory


class Inferred(BaseModel):
    subject: str = Field(description="What it's about, in a few words: 'oily fish', 'quick weeknight dinners'")
    # Only they can make something a rule, so an inference is never "never".
    stance: Literal["avoid", "prefer", "more", "less"]
    evidence: str = Field(
        description="One short line, shown to them, saying what it's based on: "
        "'Rated 4 curries 5 stars', 'Cooked salmon 3 times since August'"
    )
    strength: float = Field(ge=0, le=1, description="How sure you are, 0 to 1")


class InferredSet(BaseModel):
    preferences: list[Inferred]


agent = Agent(
    "anthropic:claude-haiku-5-5",
    output_type=InferredSet,
    model_settings={"max_tokens": 1024},
)


async def signals() -> str:
    """Everything distil reads, as prompt text. Empty when there is nothing yet."""
    lines: list[str] = []

    meals = await memory.recent_meals()
    if meals:
        titles = {
            str(r.id): r.title
            for r in await RecipeDocument.find(
                {"_id": {"$in": [PydanticObjectId(m.recipe_id) for m in meals]}}
            ).to_list()
        }
        cooked = Counter(titles.get(m.recipe_id, "a deleted recipe") for m in meals)
        lines.append(
            "Cooked in the last 12 weeks: "
            + "; ".join(f"{t} ({n}x)" if n > 1 else t for t, n in cooked.most_common(30))
            + "."
        )

    rated = await RecipeDocument.find(RecipeDocument.rating != None).to_list()  # noqa: E711
    if rated:
        lines.append(
            "Their ratings: " + "; ".join(f"{r.title} {r.rating}/5" for r in rated[:40]) + "."
        )

    dismissed = (
        await SuggestionDocument.find(SuggestionDocument.status == "dismissed")
        .sort("-created_at")
        .limit(30)
        .to_list()
    )
    if dismissed:
        lines.append("They said 'not for me' to: " + "; ".join(d.title for d in dismissed) + ".")

    recent_lists = await ListDocument.find_all().sort("-created_at").limit(8).to_list()
    if len(recent_lists) > 1:
        bought = Counter(
            key for lst in recent_lists for key in {memory.key_for(i.name) for i in lst.items}
        )
        regular = [name for name, n in bought.most_common(20) if n > 1]
        if regular:
            lines.append(
                f"On several of their last {len(recent_lists)} shopping lists: " + ", ".join(regular) + "."
            )

    return " ".join(lines)


async def distil() -> list[PreferenceDocument]:
    """Rewrite the inferred preferences from the signals, and return them."""
    seen = await signals()
    found: list[PreferenceDocument] = []
    if seen:
        told = [p for p in await memory.active() if p.source == "told"]
        result = await agent.run(
            "Here is what a household does in a cooking app. Find up to 6 lasting "
            "preferences about what they like to eat or cook, each clearly backed by "
            "the signals. Skip anything weak or one-off, and anything they told us "
            "already. Write the evidence as a short line they will read, in plain "
            "words, with no star symbols.\n\n"
            f"Signals: {seen}\n"
            + (f"Already told: {memory.prompt_text(told)}\n" if told else "")
        )
        for p in result.output.preferences:
            key = memory.key_for(p.subject)
            if key and key not in {f.key for f in found}:
                found.append(
                    PreferenceDocument(
                        subject=p.subject.strip(),
                        stance=p.stance,
                        evidence=p.evidence.strip(),
                        source="inferred",
                        key=key,
                        strength=p.strength,
                    )
                )
    await memory.replace_inferred(found)
    return found
