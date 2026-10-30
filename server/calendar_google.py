"""Google Calendar, read for when you're busy, so the week knows which evenings need a dinner.

There are no accounts, so there is one household connection. It asks for the
narrowest scopes Google has: free/busy and the list of calendars. Omlete sees
when you're busy, never what your events are. The refresh token is stored
encrypted (Fernet), and a revoked or expired one answers 409 with
`reconnect: true` so the app can ask to connect again, never a 500.

The calendar only suggests. The app reads busy blocks and shows what they
mean for each evening; nothing here writes to a list.
"""

import base64
import hashlib
import os
import secrets
import time
from datetime import datetime
from urllib.parse import urlencode

import httpx
from cryptography.fernet import Fernet, InvalidToken

from data_models import CalendarConnectionDocument

AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
REVOKE_URL = "https://oauth2.googleapis.com/revoke"
API = "https://www.googleapis.com/calendar/v3"
SCOPES = [
    "https://www.googleapis.com/auth/calendar.freebusy",
    "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
]
CACHE_SECONDS = 600

# Busy answers by (from, to, calendars), and the access token, in memory.
_busy_cache: dict[tuple, tuple[float, list[dict]]] = {}
_access: dict[str, tuple[str, float]] = {}

# Tests swap this for a transport that answers like Google.
transport: httpx.AsyncBaseTransport | None = None


class NotConfigured(Exception):
    """The server has no Google OAuth client."""


class NotConnected(Exception):
    """No calendar is connected."""


class Reconnect(Exception):
    """Google refused the stored token: it was revoked or has expired."""


def configured() -> bool:
    return bool(os.environ.get("GOOGLE_CLIENT_ID") and os.environ.get("GOOGLE_CLIENT_SECRET"))


def _client() -> tuple[str, str]:
    if not configured():
        raise NotConfigured()
    return os.environ["GOOGLE_CLIENT_ID"], os.environ["GOOGLE_CLIENT_SECRET"]


def _fernet() -> Fernet:
    """`CALENDAR_TOKEN_KEY` when set, else a key derived from the client secret.

    Deriving it means one less secret to manage. Rotating the client secret then
    makes the stored token unreadable, which reads as Reconnect.
    """
    key = os.environ.get("CALENDAR_TOKEN_KEY")
    if key:
        return Fernet(key.encode())
    _, secret = _client()
    digest = hashlib.sha256(f"omlete-calendar:{secret}".encode()).digest()
    return Fernet(base64.urlsafe_b64encode(digest))


def encrypt(token: str) -> str:
    return _fernet().encrypt(token.encode()).decode()


def decrypt(stored: str) -> str:
    try:
        return _fernet().decrypt(stored.encode()).decode()
    except InvalidToken as exc:
        raise Reconnect() from exc


def _http() -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=transport, timeout=10)


async def connection() -> CalendarConnectionDocument | None:
    return await CalendarConnectionDocument.find_one()


async def consent_url(redirect_uri: str, return_to: str) -> str:
    """Where to send the person to connect, remembering where to bring them back."""
    client_id, _ = _client()
    state = secrets.token_urlsafe(24)
    conn = await connection() or CalendarConnectionDocument()
    conn.pending_state = state
    conn.pending_return = return_to
    await conn.save()
    return f"{AUTH_URL}?" + urlencode({
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": " ".join(SCOPES),
        # A refresh token, every time, so a reconnect replaces a revoked one.
        "access_type": "offline",
        "prompt": "consent",
        "include_granted_scopes": "false",
        "state": state,
    })


async def finish(code: str, state: str, redirect_uri: str) -> str:
    """Swap the code for tokens, store the refresh token encrypted, and return where to go back to."""
    client_id, secret = _client()
    conn = await connection()
    if conn is None or not conn.pending_state or not secrets.compare_digest(conn.pending_state, state):
        raise NotConnected()
    async with _http() as http:
        res = await http.post(TOKEN_URL, data={
            "code": code,
            "client_id": client_id,
            "client_secret": secret,
            "redirect_uri": redirect_uri,
            "grant_type": "authorization_code",
        })
    if res.status_code != 200:
        raise Reconnect()
    body = res.json()
    if "refresh_token" not in body:
        raise Reconnect()
    return_to = conn.pending_return
    conn.refresh_token = encrypt(body["refresh_token"])
    conn.pending_state = None
    conn.pending_return = None
    conn.connected_at = datetime.now()
    _access["token"] = (body["access_token"], time.time() + body.get("expires_in", 3600) - 60)
    _busy_cache.clear()
    calendars = await _calendar_list(body["access_token"])
    conn.calendars = calendars
    # Your own calendar counts until you choose otherwise.
    conn.calendar_ids = [c["id"] for c in calendars if c.get("primary")] or [c["id"] for c in calendars[:1]]
    await conn.save()
    return return_to or ""


async def _access_token(conn: CalendarConnectionDocument) -> str:
    cached = _access.get("token")
    if cached and cached[1] > time.time():
        return cached[0]
    if not conn.refresh_token:
        raise NotConnected()
    client_id, secret = _client()
    async with _http() as http:
        res = await http.post(TOKEN_URL, data={
            "client_id": client_id,
            "client_secret": secret,
            "refresh_token": decrypt(conn.refresh_token),
            "grant_type": "refresh_token",
        })
    if res.status_code in (400, 401):
        raise Reconnect()
    res.raise_for_status()
    body = res.json()
    _access["token"] = (body["access_token"], time.time() + body.get("expires_in", 3600) - 60)
    return body["access_token"]


async def _calendar_list(token: str) -> list[dict]:
    async with _http() as http:
        res = await http.get(
            f"{API}/users/me/calendarList", headers={"Authorization": f"Bearer {token}"}
        )
    if res.status_code == 401:
        raise Reconnect()
    res.raise_for_status()
    return [
        {"id": c["id"], "name": c.get("summaryOverride") or c.get("summary") or c["id"], "primary": bool(c.get("primary"))}
        for c in res.json().get("items", [])
    ]


async def refresh_calendars() -> CalendarConnectionDocument:
    """Fetch the calendar list again, for Settings."""
    conn = await connection()
    if conn is None or not conn.refresh_token:
        raise NotConnected()
    conn.calendars = await _calendar_list(await _access_token(conn))
    await conn.save()
    return conn


async def busy(start: datetime, end: datetime) -> list[dict]:
    """Busy blocks across the chosen calendars, merged and sorted, as UTC ISO times."""
    conn = await connection()
    if conn is None or not conn.refresh_token:
        raise NotConnected()
    key = (start.isoformat(), end.isoformat(), tuple(conn.calendar_ids))
    hit = _busy_cache.get(key)
    if hit and hit[0] > time.time():
        return hit[1]
    token = await _access_token(conn)
    async with _http() as http:
        res = await http.post(
            f"{API}/freeBusy",
            headers={"Authorization": f"Bearer {token}"},
            json={
                "timeMin": start.isoformat(),
                "timeMax": end.isoformat(),
                "items": [{"id": cid} for cid in conn.calendar_ids],
            },
        )
    if res.status_code == 401:
        _access.pop("token", None)
        raise Reconnect()
    res.raise_for_status()
    blocks = []
    for cal in res.json().get("calendars", {}).values():
        blocks.extend(cal.get("busy", []))
    merged = _merge(blocks)
    _busy_cache[key] = (time.time() + CACHE_SECONDS, merged)
    return merged


def _merge(blocks: list[dict]) -> list[dict]:
    spans = sorted(
        (datetime.fromisoformat(b["start"].replace("Z", "+00:00")), datetime.fromisoformat(b["end"].replace("Z", "+00:00")))
        for b in blocks
    )
    out: list[list[datetime]] = []
    for s, e in spans:
        if out and s <= out[-1][1]:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return [{"start": s.isoformat(), "end": e.isoformat()} for s, e in out]


async def disconnect() -> None:
    """Forget the connection, and ask Google to revoke the token on the way out."""
    conn = await connection()
    _access.clear()
    _busy_cache.clear()
    if conn is None:
        return
    if conn.refresh_token:
        try:
            token = decrypt(conn.refresh_token)
            async with _http() as http:
                await http.post(REVOKE_URL, data={"token": token})
        except (Reconnect, httpx.HTTPError):
            pass
    await conn.delete()


def forget_cache() -> None:
    _busy_cache.clear()
