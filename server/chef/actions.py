"""What Chef changed in chat, and Undo for it.

A tool reads each document it is about to change, makes the change through
services/, and records the document as it was and as it now is. Undo puts
back what was there, but only while nothing else has changed the document
since: undoing over someone's later edit would lose it without a word.
"""

from datetime import datetime, timezone

from beanie import Document, PydanticObjectId

from data_models import (
    ChefActionDocument,
    ChefActionStep,
    ListDocument,
    MealLogDocument,
    PreferenceDocument,
    RecipeDocument,
    UserSettingsDocument,
    WeekPlanDocument,
)
from services.errors import Conflict, NotFound

# Every document type a Chef tool can change, by collection name.
MODELS: dict[str, type[Document]] = {
    m.Settings.name: m
    for m in (
        RecipeDocument,
        ListDocument,
        UserSettingsDocument,
        PreferenceDocument,
        MealLogDocument,
        WeekPlanDocument,
    )
}


def _dump(doc: Document) -> dict:
    return doc.model_dump(mode="json", exclude={"revision_id"})


def _id(model: type[Document], doc_id: str | PydanticObjectId) -> str | PydanticObjectId:
    # A meal is keyed by the client's string; the rest by ObjectId.
    return str(doc_id) if model.model_fields["id"].annotation is str else PydanticObjectId(doc_id)


async def state(model: type[Document], doc_id: str | PydanticObjectId) -> dict | None:
    doc = await model.get(_id(model, doc_id))
    return None if doc is None else _dump(doc)


class Change:
    """The documents one tool call is about to change."""

    def __init__(self) -> None:
        self._before: list[tuple[type[Document], str, dict | None]] = []

    async def touching(self, model: type[Document], doc_id: str | PydanticObjectId) -> None:
        """Call before changing a document that exists."""
        self._before.append((model, str(doc_id), await state(model, doc_id)))

    def creating(self, model: type[Document], doc_id: str | PydanticObjectId) -> None:
        """Call after creating a document."""
        self._before.append((model, str(doc_id), None))

    async def record(self, summary: str, chat_id: str | None) -> str:
        steps = [
            ChefActionStep(
                collection=model.Settings.name,
                doc_id=doc_id,
                before=before,
                after=await state(model, doc_id),
            )
            for model, doc_id, before in self._before
        ]
        action = ChefActionDocument(chat_id=chat_id, summary=summary, steps=steps)
        await action.insert()
        return str(action.id)


async def undo(action_id: PydanticObjectId) -> ChefActionDocument:
    action = await ChefActionDocument.get(action_id)
    if not action:
        raise NotFound("Nothing to undo")
    if action.undone_at:
        return action

    for step in action.steps:
        if await state(MODELS[step.collection], step.doc_id) != step.after:
            raise Conflict("That has changed since, so it can't be undone")

    for step in reversed(action.steps):
        model = MODELS[step.collection]
        if step.before is None:
            doc = await model.get(_id(model, step.doc_id))
            if doc:
                await doc.delete()
        else:
            await model.model_validate(step.before).save()

    action.undone_at = datetime.now(timezone.utc)
    await action.save()
    return action
