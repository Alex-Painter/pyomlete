"""PostHog: error tracking and product events, so failures and usage are seen.

Off unless `POSTHOG_API_KEY` is set, so local runs and tests send nothing.
Once on, it sends:

- errors: an unhandled error in a request (the ASGI middleware), and every
  `logger.exception` / `logger.error` (`_ErrorsToPostHog`). Logging is how the
  background work (recipe jobs, tagging, embeddings, suggestion saves, the
  weekly run) says it failed when no request is waiting on it, and asyncio
  logs an exception nobody awaited the same way;
- events: `capture()` from the services, such as `recipe created` or
  `weekly run`, for what the household does and what Chef does for them.

There are no accounts, so everything is sent as one person, the household.
"""

import logging
import os
from typing import Any

from posthog import Posthog
from posthog.integrations.asgi import PosthogASGIMiddleware

HOUSEHOLD = "household"
DEFAULT_HOST = "https://eu.i.posthog.com"

logger = logging.getLogger(__name__)
_client: Posthog | None = None


class _ErrorsToPostHog(logging.Handler):
    """Sends log records at ERROR and above to PostHog error tracking."""

    def __init__(self, client: Posthog):
        super().__init__(level=logging.ERROR)
        self.client = client

    def emit(self, record: logging.LogRecord) -> None:
        # PostHog's own logger reports its delivery failures; don't loop on them.
        if record.name.startswith("posthog"):
            return
        try:
            exc = record.exc_info[1] if record.exc_info else None
            self.client.capture_exception(
                exc if exc is not None else Exception(record.getMessage()),
                distinct_id=HOUSEHOLD,
                properties={"logger": record.name, "message": record.getMessage()},
            )
        except Exception:
            self.handleError(record)


def enabled() -> bool:
    return _client is not None


def init() -> None:
    """Start sending if a key is set. Safe to call more than once."""
    global _client
    key = os.environ.get("POSTHOG_API_KEY")
    if _client is not None or not key:
        return
    _client = Posthog(
        key,
        host=os.environ.get("POSTHOG_HOST") or DEFAULT_HOST,
        # Uncaught errors outside a request: in threads, or at startup.
        enable_exception_autocapture=True,
        super_properties={
            "environment": os.environ.get("RAILWAY_ENVIRONMENT_NAME") or "development",
            "release": os.environ.get("RAILWAY_GIT_COMMIT_SHA"),
            "service": "omlete-api",
        },
    )
    logging.getLogger().addHandler(_ErrorsToPostHog(_client))


def add_middleware(app) -> None:
    """Report errors a request doesn't handle. Nothing is added when off."""
    if _client is not None:
        app.add_middleware(PosthogASGIMiddleware, client=_client, capture_exceptions=True)


def capture(event: str, **properties: Any) -> None:
    """Record something the household or Chef did. Never raises."""
    if _client is None:
        return
    try:
        _client.capture(event, distinct_id=HOUSEHOLD, properties=properties)
    except Exception:
        logger.warning("PostHog capture of %s failed", event, exc_info=True)


def shutdown() -> None:
    """Send what is queued before the process ends."""
    if _client is not None:
        _client.flush()
