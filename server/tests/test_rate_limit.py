from unittest.mock import MagicMock

import pytest
from fastapi import HTTPException

import rate_limit
from rate_limit import SlidingWindow, client_key, enforce_cheap, enforce_paid


@pytest.fixture(autouse=True)
def clean_counters():
    rate_limit._reset_for_tests()
    yield
    rate_limit._reset_for_tests()


def make_request(ip: str = "203.0.113.7", forwarded: str | None = None) -> MagicMock:
    request = MagicMock()
    request.headers = {"x-forwarded-for": forwarded} if forwarded else {}
    request.client = MagicMock()
    request.client.host = ip
    return request


class TestSlidingWindow:
    def test_allows_up_to_the_limit(self):
        window = SlidingWindow(limit=3, window_seconds=60)

        assert [window.check("a", now=0) for _ in range(3)] == [None, None, None]

    def test_rejects_past_the_limit(self):
        window = SlidingWindow(limit=2, window_seconds=60)
        window.check("a", now=0)
        window.check("a", now=0)

        assert window.check("a", now=0) is not None

    def test_keys_are_independent(self):
        window = SlidingWindow(limit=1, window_seconds=60)
        window.check("a", now=0)

        assert window.check("b", now=0) is None

    def test_slot_opens_once_the_oldest_hit_ages_out(self):
        window = SlidingWindow(limit=2, window_seconds=60)
        window.check("a", now=0)
        window.check("a", now=30)

        assert window.check("a", now=59) is not None
        assert window.check("a", now=61) is None

    def test_rejection_does_not_extend_the_window(self):
        """A caller that keeps hammering must still recover on schedule."""
        window = SlidingWindow(limit=1, window_seconds=60)
        window.check("a", now=0)

        for t in range(1, 60):
            window.check("a", now=t)

        assert window.check("a", now=61) is None

    def test_retry_after_counts_down(self):
        window = SlidingWindow(limit=1, window_seconds=60)
        window.check("a", now=0)

        early = window.check("a", now=10)
        late = window.check("a", now=50)

        assert early is not None and late is not None
        assert late < early

    def test_retry_after_is_never_zero(self):
        window = SlidingWindow(limit=1, window_seconds=60)
        window.check("a", now=0)

        assert window.check("a", now=59.9) >= 1

    def test_sweep_drops_keys_that_have_aged_out(self):
        window = SlidingWindow(limit=5, window_seconds=60)
        window.check("a", now=0)

        window.sweep(now=120)

        assert window._hits == {}

    def test_sweep_keeps_live_keys(self):
        window = SlidingWindow(limit=5, window_seconds=60)
        window.check("a", now=0)

        window.sweep(now=30)

        assert "a" in window._hits


class TestClientKey:
    def test_prefers_the_forwarded_client(self):
        """Behind Railway's proxy, request.client is the proxy, not the caller."""
        request = make_request(ip="10.0.0.1", forwarded="203.0.113.7, 10.0.0.1")

        assert client_key(request) == "203.0.113.7"

    def test_falls_back_to_the_socket_address(self):
        assert client_key(make_request(ip="203.0.113.7")) == "203.0.113.7"

    def test_survives_a_missing_client(self):
        request = make_request()
        request.client = None

        assert client_key(request) == "unknown"


class TestEnforcePaid:
    def test_allows_traffic_under_the_limit(self):
        request = make_request()

        for _ in range(rate_limit.PAID_LIMIT):
            enforce_paid(request)

    def test_429s_past_the_per_client_limit(self):
        request = make_request()
        for _ in range(rate_limit.PAID_LIMIT):
            enforce_paid(request)

        with pytest.raises(HTTPException) as exc:
            enforce_paid(request)

        assert exc.value.status_code == 429
        assert int(exc.value.headers["Retry-After"]) > 0

    def test_one_client_does_not_block_another(self):
        noisy = make_request(forwarded="203.0.113.7")
        for _ in range(rate_limit.PAID_LIMIT):
            enforce_paid(noisy)

        enforce_paid(make_request(forwarded="198.51.100.4"))

    def test_the_global_ceiling_holds_against_spoofed_clients(self):
        """Rotating X-Forwarded-For defeats the per-client key, not the total."""
        for i in range(rate_limit.GLOBAL_LIMIT):
            enforce_paid(make_request(forwarded=f"198.51.100.{i % 256}.{i}"))

        with pytest.raises(HTTPException) as exc:
            enforce_paid(make_request(forwarded="198.51.100.254"))

        assert exc.value.status_code == 429

    def test_a_rejected_client_does_not_spend_the_global_allowance(self):
        request = make_request()
        for _ in range(rate_limit.PAID_LIMIT):
            enforce_paid(request)
        spent = len(rate_limit._global._hits.get("all", []))

        for _ in range(10):
            with pytest.raises(HTTPException):
                enforce_paid(request)

        assert len(rate_limit._global._hits.get("all", [])) == spent

    def test_disabling_the_limiter_lets_everything_through(self, monkeypatch):
        monkeypatch.setattr(rate_limit, "ENABLED", False)
        request = make_request()

        for _ in range(rate_limit.PAID_LIMIT * 3):
            enforce_paid(request)


class TestThroughTheApp:
    """The limiter is only useful if it runs before the handler does.

    Everything above tests the dependency in isolation, which would keep
    passing if the endpoints were never wired to it.
    """

    def _client(self):
        from fastapi.testclient import TestClient

        import main

        # No `with`: that would run the lifespan and try to reach MongoDB.
        return TestClient(main.app), main

    def test_paid_endpoint_429s_once_the_limit_is_spent(self):
        from unittest.mock import AsyncMock, patch

        from recipe_import import BlockedURL

        client, main = self._client()
        body = {"url": "https://example.com/recipe"}

        # Fail the fetch immediately: we are testing the gate, not the import.
        with patch.object(
            main, "fetch_page", AsyncMock(side_effect=BlockedURL("nope"))
        ), patch.object(main, "RecipeDocument") as doc:
            doc.find_one = AsyncMock(return_value=None)

            allowed = [
                client.post("/api/recipes/import-from-url/", json=body).status_code
                for _ in range(rate_limit.PAID_LIMIT)
            ]
            blocked = client.post("/api/recipes/import-from-url/", json=body)

        assert allowed == [400] * rate_limit.PAID_LIMIT
        assert blocked.status_code == 429
        assert blocked.headers["Retry-After"]

    def test_the_gate_runs_before_the_handler(self):
        """A blocked request must not reach the fetch at all."""
        from unittest.mock import AsyncMock, patch

        from recipe_import import BlockedURL

        client, main = self._client()
        body = {"url": "https://example.com/recipe"}
        fetch = AsyncMock(side_effect=BlockedURL("nope"))

        with patch.object(main, "fetch_page", fetch), patch.object(
            main, "RecipeDocument"
        ) as doc:
            doc.find_one = AsyncMock(return_value=None)

            for _ in range(rate_limit.PAID_LIMIT):
                client.post("/api/recipes/import-from-url/", json=body)
            calls_before = fetch.await_count
            client.post("/api/recipes/import-from-url/", json=body)

        assert fetch.await_count == calls_before

    def test_reading_a_recipe_is_never_rate_limited(self):
        """Only the endpoints that spend money are gated."""
        from unittest.mock import AsyncMock, patch

        client, main = self._client()

        with patch.object(main, "RecipeDocument") as doc:
            doc.find_all.return_value.sort.return_value.to_list = AsyncMock(
                return_value=[]
            )
            codes = {
                client.get("/api/recipes/").status_code
                for _ in range(rate_limit.PAID_LIMIT + 5)
            }

        assert codes == {200}

class TestEnforceCheap:
    def test_categorize_has_a_far_larger_allowance(self):
        """Adding a long shopping list must not trip the recipe limit."""
        assert rate_limit.CHEAP_LIMIT > rate_limit.PAID_LIMIT

        request = make_request()
        for _ in range(rate_limit.PAID_LIMIT * 2):
            enforce_cheap(request)

    def test_429s_past_its_own_limit(self):
        request = make_request()
        for _ in range(rate_limit.CHEAP_LIMIT):
            enforce_cheap(request)

        with pytest.raises(HTTPException) as exc:
            enforce_cheap(request)

        assert exc.value.status_code == 429

    def test_does_not_consume_the_paid_global_allowance(self):
        request = make_request()

        for _ in range(rate_limit.CHEAP_LIMIT):
            enforce_cheap(request)

        assert rate_limit._global._hits.get("all", []) == []
