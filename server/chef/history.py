"""Chef's past conversations, so closing the sidebar or starting a new chat
loses nothing (docs/DESIGN.md).

The server writes each chat when Chef finishes a reply: the messages the
client sent, then the reply. Writing it here rather than from the client
means a chat is kept whichever app it came from.
"""

from datetime import datetime, timezone

from beanie import PydanticObjectId
from bson.errors import InvalidId
from pydantic import BaseModel, Field
from pydantic_ai.messages import ModelMessage, ModelRequest, ModelResponse, TextPart, ToolCallPart, ToolReturnPart
from pydantic_ai.ui.vercel_ai.request_types import UIMessage
from pydantic_core import to_jsonable_python

from data_models import ChefActionDocument, ChefChatDocument

TITLE_LENGTH = 80


class ChefChatSummary(BaseModel):
    """A chat in the history list: what it was about and when."""

    id: str = Field(alias="_id")
    title: str
    updated_at: datetime


def _stored(message: UIMessage) -> dict:
    """A message the client sent, as kept: photos keep their place, not their bytes."""
    m = message.model_dump(mode="json", by_alias=True, exclude_none=True)
    for part in m["parts"]:
        if part.get("type") == "file" and str(part.get("url", "")).startswith("data:"):
            part["url"] = ""
    return m


def reply_parts(new_messages: list[ModelMessage]) -> list[dict]:
    """Chef's reply in the shape the client sends it back: its text, and each
    of our tools with what it returned. Web searches and thinking are left
    out, as the client leaves them out (client/src/lib/chef.ts)."""
    returns = {
        p.tool_call_id: p
        for m in new_messages
        if isinstance(m, ModelRequest)
        for p in m.parts
        if isinstance(p, ToolReturnPart)
    }
    parts: list[dict] = []
    for m in new_messages:
        if not isinstance(m, ModelResponse):
            continue
        for p in m.parts:
            if isinstance(p, TextPart) and p.content:
                parts.append({"type": "text", "text": p.content})
            elif isinstance(p, ToolCallPart) and (ret := returns.get(p.tool_call_id)):
                parts.append({
                    "type": f"tool-{p.tool_name}",
                    "toolCallId": p.tool_call_id,
                    "state": "output-available",
                    "input": p.args_as_dict(),
                    "output": to_jsonable_python(ret.content),
                })
    return parts


def _title(messages: list[dict]) -> str:
    for m in messages:
        if m.get("role") != "user":
            continue
        text = " ".join(p.get("text", "") for p in m["parts"] if p.get("type") == "text").strip()
        if text:
            return text if len(text) <= TITLE_LENGTH else text[: TITLE_LENGTH - 1].rstrip() + "…"
        return "Photos"
    return "Chat"


async def save(chat_id: str, sent: list[UIMessage], new_messages: list[ModelMessage], reply_id: str) -> None:
    """Keep the chat as it now stands. Each message carries the whole chat,
    so this replaces what was kept before."""
    messages = [_stored(m) for m in sent]
    if parts := reply_parts(new_messages):
        messages.append({"id": reply_id, "role": "assistant", "parts": parts})
    now = datetime.now(timezone.utc)
    chat = await ChefChatDocument.get(chat_id)
    if chat:
        chat.messages = messages
        chat.updated_at = now
        await chat.save()
    else:
        await ChefChatDocument(
            id=chat_id, title=_title(messages), messages=messages, created_at=now, updated_at=now
        ).insert()


async def recent(limit: int = 50) -> list[ChefChatSummary]:
    """The latest chats, newest first, without their messages."""
    return (
        await ChefChatDocument.find_all()
        .sort(-ChefChatDocument.updated_at)
        .limit(limit)
        .project(ChefChatSummary)
        .to_list()
    )


def _undo_ids(messages: list[dict]) -> list[str]:
    return [
        out["undo"]
        for m in messages
        for p in m.get("parts", [])
        if isinstance(out := p.get("output"), dict) and isinstance(out.get("undo"), str)
    ]


async def undo_state(messages: list[dict]) -> tuple[list[str], list[str]]:
    """Which of the chat's changes can still be undone, and which were.

    Mongo drops an action a week after it was made, so an older change can
    no longer be undone and is neither.
    """
    ids = []
    for i in _undo_ids(messages):
        try:
            ids.append(PydanticObjectId(i))
        except InvalidId:
            pass
    actions = await ChefActionDocument.find({"_id": {"$in": ids}}).to_list() if ids else []
    undoable = [str(a.id) for a in actions if a.undone_at is None]
    undone = [str(a.id) for a in actions if a.undone_at is not None]
    return undoable, undone
