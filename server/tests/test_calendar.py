"""Google Calendar: connect, read busy times, and cope with a revoked token, against a fake Google."""

import json
from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from beanie import init_beanie
from mongomock_motor import AsyncMongoMockClient

import calendar_google
import main
from data_models import CalendarConnectionDocument

WEB = "http://127.0.0.1:5173/settings"


class FakeGoogle:
    """Answers the four Google endpoints the app calls, and counts the calls."""

    def __init__(self):
        self.calls: list[str] = []
        self.revoked = False
        self.busy = {
            "primary@example.com": [{"start": "2026-10-28T18:00:00Z", "end": "2026-10-28T21:00:00Z"}],
            "family": [
                {"start": "2026-10-28T20:30:00Z", "end": "2026-10-28T22:00:00Z"},
                {"start": "2026-10-30T00:00:00Z", "end": "2026-10-31T00:00:00Z"},
            ],
        }
        self.last_freebusy: dict | None = None

    def handler(self, request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        self.calls.append(url.split("?")[0])
        if url == calendar_google.TOKEN_URL:
            form = parse_qs(request.content.decode())
            if form["grant_type"] == ["authorization_code"]:
                return httpx.Response(200, json={
                    "access_token": "access-1", "expires_in": 3600, "refresh_token": "refresh-secret",
                })
            if self.revoked:
                return httpx.Response(400, json={"error": "invalid_grant"})
            return httpx.Response(200, json={"access_token": "access-2", "expires_in": 3600})
        if url.startswith(calendar_google.REVOKE_URL):
            return httpx.Response(200)
        if url.endswith("/users/me/calendarList"):
            return httpx.Response(200, json={"items": [
                {"id": "primary@example.com", "summary": "Alex", "primary": True},
                {"id": "family", "summary": "Family"},
            ]})
        if url.endswith("/freeBusy"):
            body = json.loads(request.content)
            self.last_freebusy = body
            return httpx.Response(200, json={"calendars": {
                item["id"]: {"busy": self.busy.get(item["id"], [])} for item in body["items"]
            }})
        return httpx.Response(404)


@pytest.fixture
async def google(monkeypatch):
    monkeypatch.setenv("GOOGLE_CLIENT_ID", "client-id")
    monkeypatch.setenv("GOOGLE_CLIENT_SECRET", "client-secret")
    monkeypatch.delenv("CALENDAR_TOKEN_KEY", raising=False)
    fake = FakeGoogle()
    monkeypatch.setattr(calendar_google, "transport", httpx.MockTransport(fake.handler))
    calendar_google._access.clear()
    calendar_google._busy_cache.clear()
    return fake


@pytest.fixture
async def api():
    client = AsyncMongoMockClient()
    await init_beanie(database=client["calendar"], document_models=[CalendarConnectionDocument])
    transport = httpx.ASGITransport(app=main.app)
    async with httpx.AsyncClient(transport=transport, base_url="http://127.0.0.1:8000/api") as http:
        yield http
    client.close()


async def connect(api) -> dict:
    res = await api.get("/calendar/google/start", params={"return_to": WEB})
    assert res.status_code == 200
    consent = parse_qs(urlparse(res.json()["url"]).query)
    res = await api.get(
        "/calendar/google/callback", params={"code": "the-code", "state": consent["state"][0]}
    )
    assert res.status_code == 307
    assert res.headers["location"] == f"{WEB}?calendar=connected"
    return consent


WEEK = {"start": "2026-10-24T00:00:00+01:00", "end": "2026-10-31T00:00:00+00:00"}


async def test_unconfigured_server_says_so_and_nothing_else_breaks(api, monkeypatch):
    monkeypatch.delenv("GOOGLE_CLIENT_ID", raising=False)
    monkeypatch.delenv("GOOGLE_CLIENT_SECRET", raising=False)
    assert (await api.get("/calendar")).json()["configured"] is False
    res = await api.get("/calendar/google/start", params={"return_to": WEB})
    assert res.status_code == 503
    assert "GOOGLE_CLIENT_ID" in res.json()["detail"]


async def test_consent_asks_only_for_free_busy_and_the_calendar_list(api, google):
    consent = await connect(api)
    assert consent["scope"][0].split() == calendar_google.SCOPES
    assert consent["access_type"] == ["offline"]
    assert consent["redirect_uri"] == ["http://127.0.0.1:8000/api/calendar/google/callback"]


async def test_return_to_must_be_the_web_app(api, google):
    res = await api.get("/calendar/google/start", params={"return_to": "https://evil.example/"})
    assert res.status_code == 400


async def test_a_forged_state_is_refused(api, google):
    await api.get("/calendar/google/start", params={"return_to": WEB})
    res = await api.get("/calendar/google/callback", params={"code": "c", "state": "forged"})
    assert res.headers["location"] == f"{WEB}?calendar=failed"
    assert (await api.get("/calendar")).json()["connected"] is False


async def test_the_token_is_stored_encrypted(api, google):
    await connect(api)
    conn = await CalendarConnectionDocument.find_one()
    assert "refresh-secret" not in conn.model_dump_json()
    assert calendar_google.decrypt(conn.refresh_token) == "refresh-secret"
    status = (await api.get("/calendar")).json()
    assert status["connected"] is True
    assert status["calendars"] == [
        {"id": "primary@example.com", "name": "Alex", "chosen": True},
        {"id": "family", "name": "Family", "chosen": False},
    ]


async def test_busy_merges_the_chosen_calendars_and_caches(api, google):
    await connect(api)
    res = await api.get("/calendar/busy", params=WEEK)
    assert res.json()["busy"] == [{"start": "2026-10-28T18:00:00+00:00", "end": "2026-10-28T21:00:00+00:00"}]

    res = await api.put("/calendar/settings", json={"calendar_ids": ["primary@example.com", "family", "unknown"]})
    assert [c["chosen"] for c in res.json()["calendars"]] == [True, True]
    res = await api.get("/calendar/busy", params=WEEK)
    assert res.json()["busy"] == [
        {"start": "2026-10-28T18:00:00+00:00", "end": "2026-10-28T22:00:00+00:00"},
        {"start": "2026-10-30T00:00:00+00:00", "end": "2026-10-31T00:00:00+00:00"},
    ]
    assert [i["id"] for i in google.last_freebusy["items"]] == ["primary@example.com", "family"]

    before = google.calls.count(f"{calendar_google.API}/freeBusy")
    await api.get("/calendar/busy", params=WEEK)
    assert google.calls.count(f"{calendar_google.API}/freeBusy") == before


async def test_a_revoked_token_asks_to_reconnect(api, google):
    await connect(api)
    calendar_google._access.clear()
    google.revoked = True
    res = await api.get("/calendar/busy", params=WEEK)
    assert res.status_code == 409
    assert res.json()["reconnect"] is True


async def test_dinner_window_is_validated(api, google):
    await connect(api)
    res = await api.put("/calendar/settings", json={"dinner_start": "19:00", "dinner_end": "21:00"})
    assert (res.json()["dinner_start"], res.json()["dinner_end"]) == ("19:00", "21:00")
    assert (await api.put("/calendar/settings", json={"dinner_end": "18:00"})).status_code == 422
    assert (await api.put("/calendar/settings", json={"dinner_start": "7pm"})).status_code == 422


async def test_disconnect_deletes_the_token(api, google):
    await connect(api)
    status = (await api.delete("/calendar")).json()
    assert status["connected"] is False
    assert await CalendarConnectionDocument.find_one() is None
    assert any(c.startswith(calendar_google.REVOKE_URL) for c in google.calls)
    assert (await api.get("/calendar/busy", params=WEEK)).status_code == 404


async def test_busy_needs_a_time_zone_and_a_sensible_range(api, google):
    await connect(api)
    assert (await api.get("/calendar/busy", params={"start": "2026-10-24T00:00:00", "end": "2026-10-31T00:00:00"})).status_code == 422
    assert (await api.get("/calendar/busy", params={"start": "2026-10-24T00:00:00Z", "end": "2026-12-31T00:00:00Z"})).status_code == 422


def test_a_token_key_can_be_set_explicitly(monkeypatch):
    from cryptography.fernet import Fernet

    key = Fernet.generate_key().decode()
    monkeypatch.setenv("CALENDAR_TOKEN_KEY", key)
    stored = calendar_google.encrypt("t")
    assert Fernet(key.encode()).decrypt(stored.encode()) == b"t"
