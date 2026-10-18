"""What Chef remembers: the meals cooked, and the household's preferences.

Routes and Chef's tools both change memory through here. The inferred
preferences are rewritten by chef/memory.py, which only writes through
`replace_inferred`.
"""

import re
from datetime import datetime, timedelta, timezone

from beanie import PydanticObjectId

from data_models import MealLogDocument, PreferenceDocument, RecipeDocument, Stance
from services.errors import Invalid, NotFound

# Said in the prompt, in the order they matter.
STANCE_WORDS = {
    "never": "Never",
    "avoid": "Avoid",
    "less": "Less",
    "more": "More",
    "prefer": "Likes",
}


def key_for(subject: str) -> str:
    """One key per subject however it is written: "Mushrooms " and "mushroom" match."""
    words = re.sub(r"\s+", " ", subject.strip().lower()).split(" ")
    words[-1] = _singular(words[-1])
    return " ".join(words)


def _singular(word: str) -> str:
    if len(word) > 4 and word.endswith("oes"):
        return word[:-2]
    if len(word) > 3 and word.endswith("s") and not word.endswith("ss"):
        return word[:-1]
    return word


# --- Meals ---


async def log_meal(key: str, recipe_id: str, rating: int | None = None) -> MealLogDocument:
    """Record a cooked dinner under the client's key. Sending it again changes only the rating."""
    if not await RecipeDocument.get(PydanticObjectId(recipe_id)):
        raise NotFound("Recipe not found")
    meal = await MealLogDocument.get(key)
    if meal is None:
        meal = MealLogDocument(id=key, recipe_id=recipe_id, rating=rating)
        await meal.insert()
    elif rating is not None and meal.rating != rating:
        meal.rating = rating
        await meal.save()
    return meal


async def recent_meals(weeks: int = 12) -> list[MealLogDocument]:
    since = datetime.now(timezone.utc) - timedelta(weeks=weeks)
    return await MealLogDocument.find(MealLogDocument.cooked_at >= since).sort("-cooked_at").to_list()


# --- Preferences ---


async def remember(subject: str, stance: Stance) -> PreferenceDocument:
    """Keep something they told Chef. Saying it again about the same subject replaces it."""
    subject = re.sub(r"\s+", " ", subject.strip())
    if not subject:
        raise Invalid("Say what the preference is about")
    key = key_for(subject)
    evidence = f"You said so on {datetime.now(timezone.utc):%-d %b}"
    pref = await PreferenceDocument.find_one(
        PreferenceDocument.source == "told", PreferenceDocument.key == key
    )
    if pref is None:
        pref = PreferenceDocument(
            subject=subject, stance=stance, evidence=evidence, source="told", key=key
        )
        await pref.insert()
    else:
        pref.subject, pref.stance, pref.evidence, pref.retired_at = subject, stance, evidence, None
        await pref.save()
    return pref


async def get(pref_id: PydanticObjectId) -> PreferenceDocument:
    pref = await PreferenceDocument.get(pref_id)
    if not pref:
        raise NotFound("Preference not found")
    return pref


async def set_forgotten(pref_id: PydanticObjectId, forgotten: bool) -> PreferenceDocument:
    pref = await get(pref_id)
    pref.retired_at = datetime.now(timezone.utc) if forgotten else None
    await pref.save()
    return pref


async def find(subject: str) -> PreferenceDocument | None:
    """The preference Chef holds about a subject: the told one if there is one."""
    key = key_for(subject)
    for pref in await active():
        if pref.key == key:
            return pref
    return None


async def active() -> list[PreferenceDocument]:
    """What Chef goes by: told first, then the inferred ones no told one overrides."""
    prefs = await PreferenceDocument.find(PreferenceDocument.retired_at == None).to_list()  # noqa: E711
    told = sorted((p for p in prefs if p.source == "told"), key=lambda p: p.created_at)
    told_keys = {p.key for p in told}
    inferred = sorted(
        (p for p in prefs if p.source == "inferred" and p.key not in told_keys),
        key=lambda p: -p.strength,
    )
    return told + inferred


async def replace_inferred(found: list[PreferenceDocument]) -> None:
    """Make the inferred set exactly `found`, keeping what they forgot forgotten.

    Rewriting rather than adding means running it twice, or again after a
    crash halfway, ends in the same rows.
    """
    by_key = {p.key: p for p in found}
    current = await PreferenceDocument.find(PreferenceDocument.source == "inferred").to_list()
    for old in current:
        new = by_key.pop(old.key, None)
        if new is None:
            if old.retired_at is None:
                await old.delete()
            continue
        old.subject, old.stance, old.evidence, old.strength = (
            new.subject, new.stance, new.evidence, new.strength
        )
        await old.save()
    for new in by_key.values():
        await new.insert()


def prompt_text(prefs: list[PreferenceDocument]) -> str:
    """The preferences as a sentence or two for a prompt."""
    told = [p for p in prefs if p.source == "told"]
    inferred = [p for p in prefs if p.source == "inferred"]
    lines = []
    if told:
        lines.append(
            "They told you: " + "; ".join(f"{STANCE_WORDS[p.stance]} {p.subject}" for p in told) + "."
        )
    if inferred:
        lines.append(
            "You've noticed: "
            + "; ".join(f"{STANCE_WORDS[p.stance]} {p.subject} ({p.evidence})" for p in inferred)
            + "."
        )
    return " ".join(lines)


def names_any(text: str, prefs: list[PreferenceDocument]) -> bool:
    """Whether `text` names the subject of any of these, plural or not."""
    for p in prefs:
        words = p.key.split(" ")
        pattern = r"\b" + r"\s+".join(map(re.escape, words)) + r"(?:e?s)?\b"
        if re.search(pattern, text, re.IGNORECASE):
            return True
    return False
