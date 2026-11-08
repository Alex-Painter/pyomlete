"""PostHog stays off without a key; once on, failures and runs reach it."""

import logging
from datetime import date, datetime, time, timedelta
from unittest.mock import AsyncMock, MagicMock

import pytest
from beanie import init_beanie
from mongomock_motor import AsyncMongoMockClient

from chef import run
from data_models import UserSettingsDocument, WeekPlanDocument
from lib import analytics


@pytest.fixture
def posthog(monkeypatch):
    """A stand-in client, installed as init() would, with the log handler."""
    client = MagicMock()
    monkeypatch.setattr(analytics, "_client", client)
    handler = analytics._ErrorsToPostHog(client)
    logging.getLogger().addHandler(handler)
    yield client
    logging.getLogger().removeHandler(handler)


def test_without_a_key_nothing_is_sent(monkeypatch):
    monkeypatch.delenv("POSTHOG_API_KEY", raising=False)
    monkeypatch.setattr(analytics, "_client", None)
    analytics.init()
    assert not analytics.enabled()
    analytics.capture("recipe created")  # A no-op, not an error.


def test_a_logged_exception_goes_to_error_tracking(posthog):
    try:
        raise RuntimeError("Voyage said 403")
    except RuntimeError:
        logging.getLogger("recipe_tagger").exception("tagging failed")
    logging.getLogger("x").warning("only a warning")
    logging.getLogger("x").error("no traceback here")
    sent = posthog.capture_exception.call_args_list
    assert len(sent) == 2
    assert str(sent[0].args[0]) == "Voyage said 403"
    assert sent[0].kwargs["properties"]["logger"] == "recipe_tagger"
    assert str(sent[1].args[0]) == "no traceback here"


def test_capture_never_raises(posthog):
    posthog.capture.side_effect = RuntimeError("network")
    analytics.capture("list created", week=True)


async def test_the_weekly_run_reports_how_it_went(posthog, monkeypatch):
    monkeypatch.setattr(run.chef_memory, "distil", AsyncMock())
    await init_beanie(
        database=AsyncMongoMockClient()["omlete_test"],
        document_models=[UserSettingsDocument, WeekPlanDocument],
    )
    monkeypatch.setattr(run.week, "plan", AsyncMock(side_effect=RuntimeError("Voyage said 403")))
    sunday = datetime.combine(date.today() + timedelta(days=(6 - date.today().weekday()) % 7), time(8, 30))
    with pytest.raises(RuntimeError):
        await run.weekly(sunday)
    event, = [c for c in posthog.capture.call_args_list if c.args[0] == "weekly run"]
    assert event.kwargs["properties"]["outcome"] == "failed"

    monkeypatch.setattr(run.week, "plan", AsyncMock(return_value=(MagicMock(), None)))
    await run.weekly(sunday)
    last = [c for c in posthog.capture.call_args_list if c.args[0] == "weekly run"][-1]
    assert last.kwargs["properties"]["outcome"] == "planned"
