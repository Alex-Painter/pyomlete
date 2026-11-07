"""The Anthropic client, the models Omlete uses, and what they need from callers.

Every model is on the 5.5 family. Three things about it shape the calls:

- They think by default (Opus 5.5 can't be told not to), and thinking counts
  toward `max_tokens`. So caps leave room for it, and a reply is read from its
  text block, not `content[0]`, which can be a thinking block.
- Opus 5.5 and Sonnet 5.5 reject a forced tool call (`tool_choice` any/tool),
  which is how pydantic-ai asks for tool output. Structured answers come back
  through `output_config.format` instead (NativeOutput in pydantic-ai).
- Effort defaults to medium on Opus and Haiku 5.5. Calls set it explicitly.
"""

from dataclasses import replace

from anthropic import AsyncAnthropic
from anthropic.types.beta import BetaMessage
from dotenv import load_dotenv
from pydantic_ai.models.anthropic import AnthropicModel
from pydantic_ai.profiles.anthropic import anthropic_model_profile

load_dotenv()

async_claude = AsyncAnthropic()

OPUS = "claude-opus-5-5"
SONNET = "claude-sonnet-5-5"
HAIKU = "claude-haiku-5-5"


def answer_text(message: BetaMessage) -> str:
    """The reply's text: its last text block, or "" when it ran out before one."""
    return next((b.text for b in reversed(message.content) if b.type == "text"), "")


def agent_model(name: str) -> AnthropicModel:
    """A pydantic-ai model for `name`, told what the 5.5 family can do.

    The installed pydantic-ai only lists 4.x models as taking a JSON schema
    output, adaptive thinking and effort, so for 5.5 it would refuse
    NativeOutput and send a `budget_tokens` thinking config, which 5.5 rejects.
    """
    profile = replace(
        anthropic_model_profile(name),
        supports_json_schema_output=True,
        anthropic_supports_adaptive_thinking=True,
        anthropic_supports_effort=True,
    )
    return AnthropicModel(name, profile=profile)
