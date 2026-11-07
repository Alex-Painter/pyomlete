"""The 5.5 models: replies read past thinking, and pydantic-ai knows what they take."""

import json
from types import SimpleNamespace

import httpx
import pytest

from pydantic_ai import Agent, NativeOutput
from pydantic_ai.exceptions import ModelHTTPError

from lib.claude import HAIKU, OPUS, SONNET, agent_model, answer_text


def block(type_: str, **fields) -> SimpleNamespace:
    return SimpleNamespace(type=type_, **fields)


class TestAnswerText:
    def test_reads_past_a_thinking_block(self):
        message = SimpleNamespace(content=[block("thinking", thinking=""), block("text", text="Dairy")])
        assert answer_text(message) == "Dairy"

    def test_takes_the_last_text_after_tool_calls(self):
        message = SimpleNamespace(content=[
            block("text", text="Looking that up."),
            block("thinking", thinking=""),
            block("text", text='{"title": "Soup"}'),
        ])
        assert answer_text(message) == '{"title": "Soup"}'

    def test_empty_when_thinking_used_every_token(self):
        message = SimpleNamespace(content=[block("thinking", thinking="")])
        assert answer_text(message) == ""


class TestAgentModel:
    def test_every_model_is_on_5_5(self):
        assert (OPUS, SONNET, HAIKU) == ("claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5")

    def test_profile_takes_json_schema_output_adaptive_thinking_and_effort(self):
        profile = agent_model(OPUS).profile
        assert profile.supports_json_schema_output
        assert profile.anthropic_supports_adaptive_thinking
        assert profile.anthropic_supports_effort

    def test_chef_agents_use_5_5_models(self):
        from chef import chat, discover, memory, week

        assert discover.agent.model.model_name == OPUS
        assert week.agent.model.model_name == OPUS
        assert chat.agent.model.model_name == SONNET
        assert memory.agent.model.model_name == HAIKU

    async def test_opus_request_is_one_5_5_accepts(self):
        """No forced tool call, no thinking budget, and the schema in output_config."""
        sent: list[dict] = []

        def capture(request: httpx.Request) -> httpx.Response:
            sent.append(json.loads(request.content))
            return httpx.Response(400, json={"type": "error", "error": {"type": "invalid_request_error", "message": "stop"}})

        model = agent_model(OPUS)
        model.client._client = httpx.AsyncClient(transport=httpx.MockTransport(capture))
        agent = Agent(
            model,
            output_type=NativeOutput(list[str]),
            model_settings={"max_tokens": 16000, "anthropic_effort": "medium"},
        )
        with pytest.raises(ModelHTTPError):
            await agent.run("hi")

        body = sent[0]
        assert body.get("tool_choice", {}).get("type") not in ("any", "tool")
        assert "thinking" not in body
        assert body["output_config"]["format"]["type"] == "json_schema"
        assert body["output_config"]["effort"] == "medium"
