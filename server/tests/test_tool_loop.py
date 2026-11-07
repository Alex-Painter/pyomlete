"""Recipe tool loops stop instead of spending tokens.

These drive the real Anthropic tool runner against a fake API, so they check
what the SDK does with a failing tool, not what we hope it does.
"""

import json

import httpx
import pytest
from anthropic import AsyncAnthropic

import tools
from services.errors import Unavailable
from tools import MAX_TOOL_TURNS, find_similar_ingredients, run_until_done


def _message(stop_reason: str, content: list[dict]) -> dict:
    return {
        "id": "msg_test",
        "type": "message",
        "role": "assistant",
        "model": "claude-test",
        "content": content,
        "stop_reason": stop_reason,
        "stop_sequence": None,
        "usage": {"input_tokens": 1, "output_tokens": 1},
    }


_LOOKUP = {
    "type": "tool_use",
    "id": "toolu_test",
    "name": "find_similar_ingredients",
    "input": {"ingredient_names": ["onion"]},
}


def _fake_api(responses: list[dict]) -> tuple[AsyncAnthropic, list]:
    """An AsyncAnthropic whose every call answers the next response, repeating the last."""
    calls: list = []

    def handle(request: httpx.Request) -> httpx.Response:
        calls.append(json.loads(request.content))
        return httpx.Response(200, json=responses[min(len(calls), len(responses)) - 1])

    client = AsyncAnthropic(
        api_key="test", http_client=httpx.AsyncClient(transport=httpx.MockTransport(handle))
    )
    return client, calls


def _runner(client: AsyncAnthropic):
    return client.beta.messages.tool_runner(
        model="claude-test",
        max_tokens=100,
        messages=[{"role": "user", "content": "a recipe"}],
        tools=[find_similar_ingredients],
        max_iterations=MAX_TOOL_TURNS,
    )


async def test_a_failing_lookup_stops_the_run_after_one_call(monkeypatch):
    async def broken(names):
        raise RuntimeError("Provided API key is invalid.")

    monkeypatch.setattr(tools._service, "find_similar", broken)
    client, calls = _fake_api([_message("tool_use", [_LOOKUP])])

    with pytest.raises(Unavailable):
        await run_until_done(_runner(client))

    assert len(calls) == 1


async def test_a_run_that_keeps_looking_up_stops_at_the_cap(monkeypatch):
    async def works(names):
        return []

    monkeypatch.setattr(tools._service, "find_similar", works)
    client, calls = _fake_api([_message("tool_use", [_LOOKUP])])

    with pytest.raises(Unavailable):
        await run_until_done(_runner(client))

    assert len(calls) == MAX_TOOL_TURNS


async def test_a_normal_run_returns_the_recipe(monkeypatch):
    async def works(names):
        return []

    monkeypatch.setattr(tools._service, "find_similar", works)
    client, calls = _fake_api([
        _message("tool_use", [_LOOKUP]),
        _message("end_turn", [{"type": "text", "text": "{}"}]),
    ])

    message = await run_until_done(_runner(client))

    assert message.content[0].text == "{}"
    assert len(calls) == 2
