"""Fetch and parse recipes from public web pages.

This is stage 1 of the URL import pipeline described in docs/PRD_URL_IMPORT.md:
fetch a page and pull out whatever structured recipe data it publishes. The
ingredients come back as free text (``"2 onions, finely chopped"``) because
recipe-scrapers does not decompose them — turning those lines into structured
IngredientRecipe objects is stage 2 and lives elsewhere.

The fetch is deliberately paranoid. The URL comes from the caller and we make
the request, so an unguarded fetch would let anyone reach our loopback
interface, Railway's private network, or a cloud metadata endpoint. See
Appendix A of the PRD for the full threat model.
"""

import asyncio
import ipaddress
import re
import socket
from dataclasses import dataclass, field
from typing import Callable, Optional, TypeVar
from urllib.parse import urlparse

import httpx
from recipe_scrapers import scrape_html
from recipe_scrapers._exceptions import (
    NoSchemaFoundInWildMode,
    WebsiteNotImplementedError,
)

_MAX_BYTES = 2 * 1024 * 1024
_MAX_REDIRECTS = 5
_TIMEOUT = httpx.Timeout(10.0, connect=5.0)
# Plenty of recipe sites reject the default httpx agent outright.
_USER_AGENT = "OmleteBot/1.0 (+https://omlete.app; recipe import)"

# Yields above this are almost certainly a misparse (a stray year, a weight),
# so we drop them rather than store nonsense.
_MAX_PLAUSIBLE_SERVINGS = 100


class BlockedURL(Exception):
    """The URL is malformed, or resolves somewhere we refuse to fetch."""


class FetchFailed(Exception):
    """The page could not be retrieved from the origin."""


@dataclass
class IngredientGroup:
    """A run of ingredients under an optional heading ("For the sauce:")."""

    purpose: Optional[str]
    ingredients: list[str]


@dataclass
class ScrapedRecipe:
    """Stage 1 output. `ingredients` is free text pending stage 2."""

    title: str
    instructions: list[str]
    ingredients: list[str]
    source_url: str
    ingredient_groups: list[IngredientGroup] = field(default_factory=list)
    servings: Optional[int] = None
    prep_minutes: Optional[int] = None
    cook_minutes: Optional[int] = None
    total_minutes: Optional[int] = None
    image_url: Optional[str] = None
    source_name: Optional[str] = None
    description: Optional[str] = None
    cuisine: Optional[str] = None


# --- SSRF guard ---


def _is_forbidden(ip: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    """True for anything that isn't a routable public address.

    IPv4-mapped IPv6 (``::ffff:127.0.0.1``) is unwrapped first: IPv6Address
    reports is_loopback only for ``::1``, so the mapped form would otherwise
    slip straight through.
    """
    mapped = getattr(ip, "ipv4_mapped", None)
    if mapped is not None:
        ip = mapped
    return (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_reserved
        or ip.is_multicast
        or ip.is_unspecified
    )


async def _resolve(host: str) -> list[str]:
    """Resolve a hostname to every address it answers with."""
    loop = asyncio.get_running_loop()
    try:
        infos = await loop.getaddrinfo(host, None, proto=socket.IPPROTO_TCP)
    except socket.gaierror as exc:
        raise BlockedURL(f"could not resolve {host!r}") from exc
    return [info[4][0] for info in infos]


async def _assert_public(host: str) -> None:
    """Reject the host if *any* address it resolves to is non-public.

    A name with both an A and an AAAA record has to pass on both — otherwise
    an attacker publishes one public address to satisfy the check and one
    private address for the connection to actually use.
    """
    addresses = await _resolve(host)
    if not addresses:
        raise BlockedURL(f"could not resolve {host!r}")

    for raw in addresses:
        try:
            ip = ipaddress.ip_address(raw)
        except ValueError as exc:  # pragma: no cover - getaddrinfo shouldn't
            raise BlockedURL(f"unparseable address {raw!r} for {host!r}") from exc
        if _is_forbidden(ip):
            raise BlockedURL(f"{host!r} resolves to non-public address {ip}")


async def _validate(url: str) -> None:
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise BlockedURL(f"unsupported scheme: {parsed.scheme!r}")
    if not parsed.hostname:
        raise BlockedURL("URL has no hostname")
    await _assert_public(parsed.hostname)


def _make_client(
    transport: Optional[httpx.AsyncBaseTransport] = None,
) -> httpx.AsyncClient:
    """Build the fetch client. `transport` is a seam for tests."""
    return httpx.AsyncClient(
        follow_redirects=False,
        timeout=_TIMEOUT,
        headers={"User-Agent": _USER_AGENT},
        transport=transport,
    )


async def fetch_page(url: str) -> str:
    """Fetch a page as text, re-validating the target on every redirect hop.

    Redirects are followed by hand rather than by httpx: a page that passes the
    guard can still answer 302 to somewhere private, and httpx's own redirect
    handling would never re-check.
    """
    async with _make_client() as client:
        for _ in range(_MAX_REDIRECTS):
            await _validate(url)
            try:
                async with client.stream("GET", url) as response:
                    if response.is_redirect:
                        location = response.headers.get("location")
                        if not location:
                            raise BlockedURL("redirect with no Location header")
                        url = str(response.url.join(location))
                        continue

                    if response.status_code >= 400:
                        raise FetchFailed(
                            f"{url} returned HTTP {response.status_code}"
                        )

                    # Enforced while streaming — a Content-Length check would
                    # trust a header the origin controls.
                    chunks: list[bytes] = []
                    total = 0
                    async for chunk in response.aiter_bytes():
                        total += len(chunk)
                        if total > _MAX_BYTES:
                            raise BlockedURL(
                                f"response exceeded {_MAX_BYTES} bytes"
                            )
                        chunks.append(chunk)
            except httpx.InvalidURL as exc:
                # Redirect targets are attacker-controlled, so a Location that
                # httpx refuses to parse is a rejection, not a fetch failure.
                raise BlockedURL(f"unusable URL {url!r}: {exc}") from exc
            except httpx.HTTPError as exc:
                raise FetchFailed(f"could not fetch {url}: {exc}") from exc

            return b"".join(chunks).decode(
                response.encoding or "utf-8", errors="replace"
            )

    raise BlockedURL(f"more than {_MAX_REDIRECTS} redirects")


# --- Parsing ---

_T = TypeVar("_T")


def _maybe(getter: Callable[[], _T]) -> Optional[_T]:
    """Call an optional scraper field, treating any failure as absent.

    recipe-scrapers raises rather than returning None for fields a given site
    doesn't publish, and every one of these is optional for us.
    """
    try:
        value = getter()
    except Exception:
        return None
    return value or None


def _parse_servings(raw: Optional[str]) -> Optional[int]:
    """Pull a serving count out of a yields string.

    recipe-scrapers normalises before we see it — ``"serves 4-6"`` arrives as
    ``"6 servings"`` (it takes the upper bound of a range) — so the first
    integer in the string is the one we want.
    """
    if not raw:
        return None
    match = re.search(r"\d+", raw)
    if not match:
        return None
    value = int(match.group())
    if value < 1 or value > _MAX_PLAUSIBLE_SERVINGS:
        return None
    return value


def _clean_lines(values: Optional[list[str]]) -> list[str]:
    if not values:
        return []
    return [line.strip() for line in values if line and line.strip()]


def scrape(html: str, url: str) -> Optional[ScrapedRecipe]:
    """Parse a recipe out of already-fetched HTML.

    Returns None when the page publishes no recipe data we can read, which is
    the caller's signal to fall back to the model.

    supported_only=False is always passed (it replaces the deprecated
    wild_mode): the site's dedicated scraper is still used when one exists,
    and generic schema.org parsing handles everything else, so it is a strict
    superset of the supported-sites-only behaviour.
    """
    try:
        scraper = scrape_html(html, org_url=url, supported_only=False)
    except (NoSchemaFoundInWildMode, WebsiteNotImplementedError):
        return None

    title = _maybe(scraper.title)
    instructions = _clean_lines(_maybe(scraper.instructions_list))
    ingredients = _clean_lines(_maybe(scraper.ingredients))

    # A recipe with no title, no steps or no ingredients isn't usable, and
    # partial schema.org markup on non-recipe pages is common enough to matter.
    if not title or not instructions or not ingredients:
        return None

    groups: list[IngredientGroup] = []
    raw_groups = _maybe(scraper.ingredient_groups) or []
    for raw_group in raw_groups:
        group_ingredients = _clean_lines(getattr(raw_group, "ingredients", None))
        if group_ingredients:
            groups.append(
                IngredientGroup(
                    purpose=getattr(raw_group, "purpose", None),
                    ingredients=group_ingredients,
                )
            )

    return ScrapedRecipe(
        title=title.strip(),
        instructions=instructions,
        ingredients=ingredients,
        source_url=url,
        ingredient_groups=groups,
        servings=_parse_servings(_maybe(scraper.yields)),
        prep_minutes=_maybe(scraper.prep_time),
        cook_minutes=_maybe(scraper.cook_time),
        total_minutes=_maybe(scraper.total_time),
        image_url=_maybe(scraper.image),
        source_name=_maybe(scraper.host) or urlparse(url).hostname,
        description=_maybe(scraper.description),
        cuisine=_maybe(scraper.cuisine),
    )


async def import_from_url(url: str) -> Optional[ScrapedRecipe]:
    """Fetch and parse in one step. Raises BlockedURL / FetchFailed."""
    return scrape(await fetch_page(url), url)
