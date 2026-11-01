"""Error reporting to Sentry, so a failure reaches someone instead of only the logs.

Off unless `SENTRY_DSN` is set, so local runs and tests send nothing. Once on,
it reports:

- an unhandled error in a request, and any 5xx answer (FastAPI integration);
- every `logger.exception` and `logger.error`, which is how the background
  work (recipe jobs, tagging, embeddings, suggestion saves, the weekly run)
  says it failed when no request is waiting on it;
- an error that escapes a fire-and-forget asyncio task;
- the weekly run as a cron monitor (`weekly_monitor`), so a week that is never
  planned alerts even when nothing raises.
"""

import os

import sentry_sdk
from sentry_sdk.integrations.asyncio import enable_asyncio_integration
from sentry_sdk.integrations.logging import LoggingIntegration

WEEKLY_MONITOR = "weekly-plan"


def enabled() -> bool:
    return bool(os.environ.get("SENTRY_DSN"))


def init() -> None:
    """Start reporting if a DSN is set. Safe to call more than once."""
    dsn = os.environ.get("SENTRY_DSN")
    if not dsn:
        return
    sentry_sdk.init(
        dsn=dsn,
        environment=os.environ.get("SENTRY_ENVIRONMENT")
        or os.environ.get("RAILWAY_ENVIRONMENT_NAME")
        or "development",
        release=os.environ.get("RAILWAY_GIT_COMMIT_SHA"),
        # Errors only by default; performance tracing is opt-in.
        traces_sample_rate=float(os.environ.get("SENTRY_TRACES_SAMPLE_RATE") or 0),
        # No accounts, but requests carry recipes and photos: keep bodies out.
        send_default_pii=False,
        max_request_body_size="never",
        integrations=[
            # Warnings stay breadcrumbs; errors and exceptions become issues.
            LoggingIntegration(event_level="ERROR"),
        ],
    )


def watch_tasks() -> None:
    """Report errors that escape asyncio tasks. Call from inside the running loop.

    The asyncio integration patches the running loop, and `init` runs at import,
    before uvicorn has one, so the lifespan calls this.
    """
    if enabled():
        enable_asyncio_integration()


def weekly_monitor_config(weekday: int, hour: int, margin_minutes: int) -> dict:
    """The weekly run's schedule as Sentry wants it, from the household's settings.

    `weekday` is Python's (Monday is 0); cron counts from Sunday.
    """
    return {
        "schedule": {"type": "crontab", "value": f"0 {hour} * * {(weekday + 1) % 7}"},
        "timezone": "Europe/London",
        # A run may happen this late after the chosen hour (chef.run.CATCH_UP).
        "checkin_margin": margin_minutes,
        "max_runtime": 30,
        # One failed week is worth hearing about.
        "failure_issue_threshold": 1,
        "recovery_threshold": 1,
    }
