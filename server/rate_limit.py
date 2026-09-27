"""In-process rate limiting for the endpoints that cost money.

Every model-backed endpoint here is unauthenticated: anyone who can reach the
API can spend our Anthropic budget, and `/recipes/import-from-url/` will also
make the server fetch a URL of the caller's choosing. Neither is acceptable
without a cap.

Two profiles, because the endpoints are not alike:

* `enforce_paid` — recipe generation, image extraction, meal suggestions and
  URL import. Opus-priced, seconds per call, a handful per session in normal
  use. Tight per-client limit, plus a global ceiling.
* `enforce_cheap` — `/categorize`, which is a cache-backed 50-token Haiku call
  fired once per shopping item somebody types. Lumping it in with the above
  would lock a user out of their own shopping list halfway through writing it.
  Per-client only: a few thousand of these still costs less than one import,
  so they should not eat the global allowance either.

On the two limits in `enforce_paid`, the second is the one that protects the
wallet:

* **Per client** is keyed on the caller's IP, which behind Railway's proxy
  means trusting `X-Forwarded-For`. That header is caller-controlled, so
  anyone determined can rotate it and defeat this limit.
* **Global** caps paid requests across every caller, whatever they claim to
  be. Spoofing the per-client key does not get past it. The cost is that one
  abuser can exhaust the allowance for everybody — the right trade for a
  personal app, where a day of 429s beats an unbounded bill.

This is deliberately in-process. Counters reset on deploy and each instance
keeps its own, so the real ceiling is the global limit times the number of
running instances. For a single-instance personal app that is close enough;
if this ever runs on several instances and the limit has to be exact, it
needs shared storage (Redis) rather than a bigger dict.
"""

import os
import time
from collections import deque
from typing import Optional

from fastapi import HTTPException, Request


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


# Tunable without a code change, so a limit that turns out wrong in practice
# can be fixed from the Railway dashboard.
ENABLED = os.environ.get("RATE_LIMIT_ENABLED", "true").lower() != "false"
PAID_LIMIT = _env_int("RATE_LIMIT_PAID", 20)
PAID_WINDOW = _env_int("RATE_LIMIT_PAID_WINDOW", 300)
GLOBAL_LIMIT = _env_int("RATE_LIMIT_GLOBAL", 200)
GLOBAL_WINDOW = _env_int("RATE_LIMIT_GLOBAL_WINDOW", 3600)
CHEAP_LIMIT = _env_int("RATE_LIMIT_CHEAP", 120)
CHEAP_WINDOW = _env_int("RATE_LIMIT_CHEAP_WINDOW", 300)


class SlidingWindow:
    """Counts hits per key over a trailing window.

    A sliding window rather than fixed buckets: a fixed bucket lets someone
    spend the whole allowance at the end of one bucket and again at the start
    of the next, which is twice the intended rate across the boundary.
    """

    def __init__(self, limit: int, window_seconds: int) -> None:
        self.limit = limit
        self.window = window_seconds
        self._hits: dict[str, deque[float]] = {}

    def _prune(self, hits: deque[float], now: float) -> None:
        cutoff = now - self.window
        while hits and hits[0] <= cutoff:
            hits.popleft()

    def check(self, key: str, now: Optional[float] = None) -> Optional[int]:
        """Record a hit. Returns None if allowed, else seconds until retry.

        A rejected request is *not* recorded — otherwise a caller hammering the
        endpoint would keep pushing its own window forward and never recover.
        """
        now = time.monotonic() if now is None else now
        hits = self._hits.setdefault(key, deque())
        self._prune(hits, now)

        if len(hits) >= self.limit:
            # The oldest hit is the one that has to age out for a slot to open.
            return max(1, int(hits[0] + self.window - now) + 1)

        hits.append(now)
        return None

    def sweep(self, now: Optional[float] = None) -> None:
        """Drop keys with nothing left in the window.

        Without this the dict grows one entry per distinct IP forever, which
        is a slow leak on a long-running process.
        """
        now = time.monotonic() if now is None else now
        for key in list(self._hits):
            self._prune(self._hits[key], now)
            if not self._hits[key]:
                del self._hits[key]

    def reset(self) -> None:
        self._hits.clear()


_paid = SlidingWindow(PAID_LIMIT, PAID_WINDOW)
_global = SlidingWindow(GLOBAL_LIMIT, GLOBAL_WINDOW)
_cheap = SlidingWindow(CHEAP_LIMIT, CHEAP_WINDOW)

_GLOBAL_KEY = "all"
_SWEEP_EVERY = 500
_requests_seen = 0


def client_key(request: Request) -> str:
    """Best-effort identity for the caller.

    Railway terminates TLS and proxies, so `request.client.host` is the proxy
    and the original address is the first entry of `X-Forwarded-For`. That
    entry is caller-controlled and trivially spoofed — it is a courtesy key
    for honest clients, not a security boundary. The global limit is what
    holds when someone lies about it.
    """
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        first = forwarded.split(",")[0].strip()
        if first:
            return first
    return request.client.host if request.client else "unknown"


def _maybe_sweep() -> None:
    global _requests_seen
    _requests_seen += 1
    if _requests_seen % _SWEEP_EVERY == 0:
        _paid.sweep()
        _global.sweep()
        _cheap.sweep()


def _reject(retry_after: int) -> None:
    raise HTTPException(
        status_code=429,
        detail="Too many requests. Give it a minute and try again.",
        headers={"Retry-After": str(retry_after)},
    )


def enforce_paid(request: Request) -> None:
    """Dependency for the Opus-priced endpoints. 429 when either limit is out."""
    if not ENABLED:
        return
    _maybe_sweep()

    # Per-client first, so one noisy caller hitting its own limit doesn't
    # consume the shared allowance on the way to being rejected.
    retry_after = _paid.check(client_key(request))
    if retry_after is None:
        retry_after = _global.check(_GLOBAL_KEY)

    if retry_after is not None:
        _reject(retry_after)


def enforce_cheap(request: Request) -> None:
    """Dependency for /categorize. Per-client only; no global allowance."""
    if not ENABLED:
        return
    _maybe_sweep()

    retry_after = _cheap.check(client_key(request))
    if retry_after is not None:
        _reject(retry_after)


def _reset_for_tests() -> None:
    global _requests_seen
    _paid.reset()
    _global.reset()
    _cheap.reset()
    _requests_seen = 0
