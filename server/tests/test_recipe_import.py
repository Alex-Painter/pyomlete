import json
from pathlib import Path
from unittest.mock import patch
from urllib.parse import urlparse

import httpx
import pytest

import recipe_import
from recipe_import import (
    BlockedURL,
    FetchFailed,
    _is_forbidden,
    _parse_servings,
    fetch_page,
    scrape,
)

FIXTURES = Path(__file__).parent / "fixtures"


def build_page(**overrides) -> str:
    """A minimal page carrying a schema.org/Recipe JSON-LD block."""
    recipe = {
        "@context": "https://schema.org",
        "@type": "Recipe",
        "name": "Classic Lasagne",
        "image": ["https://images.example.com/lasagne.jpg"],
        "description": "A proper family favourite.",
        "prepTime": "PT30M",
        "cookTime": "PT1H30M",
        "totalTime": "PT2H",
        "recipeYield": "6 servings",
        "recipeCuisine": "Italian",
        "recipeIngredient": ["1 tbsp olive oil", "500g beef mince"],
        "recipeInstructions": [
            {"@type": "HowToStep", "text": "Fry the onions."},
            {"@type": "HowToStep", "text": "Bake for 45 mins."},
        ],
    }
    recipe.update(overrides)
    for key in [k for k, v in recipe.items() if v is None]:
        del recipe[key]
    return (
        '<html><head><script type="application/ld+json">'
        f"{json.dumps(recipe)}"
        "</script></head><body><p>blog preamble</p></body></html>"
    )


def patch_resolve(mapping: dict[str, list[str]]):
    """Patch DNS so resolution is deterministic and offline."""

    async def fake_resolve(host: str) -> list[str]:
        if host not in mapping:
            raise BlockedURL(f"could not resolve {host!r}")
        return mapping[host]

    return patch.object(recipe_import, "_resolve", fake_resolve)


def patch_transport(handler):
    """Route fetches through a MockTransport, keeping the real client config."""
    real_make_client = recipe_import._make_client

    def make_client() -> httpx.AsyncClient:
        return real_make_client(transport=httpx.MockTransport(handler))

    return patch.object(recipe_import, "_make_client", make_client)


# --- SSRF guard: address classification ---


class TestIsForbidden:
    @pytest.mark.parametrize(
        "address",
        [
            "127.0.0.1",  # loopback
            "10.0.0.5",  # private
            "172.16.4.1",  # private
            "192.168.1.1",  # private
            "169.254.169.254",  # cloud metadata
            "0.0.0.0",  # unspecified
            "224.0.0.1",  # multicast
            "::1",  # v6 loopback
            "fd00::1",  # v6 unique-local
            "fe80::1",  # v6 link-local
            "::ffff:127.0.0.1",  # IPv4-mapped loopback
            "::ffff:169.254.169.254",  # IPv4-mapped metadata
        ],
    )
    def test_rejects_non_public(self, address):
        import ipaddress

        assert _is_forbidden(ipaddress.ip_address(address)) is True

    @pytest.mark.parametrize(
        "address",
        ["93.184.216.34", "8.8.8.8", "2606:2800:220:1:248:1893:25c8:1946"],
    )
    def test_allows_public(self, address):
        import ipaddress

        assert _is_forbidden(ipaddress.ip_address(address)) is False

    def test_unwraps_ipv4_mapped_before_classifying(self):
        """Why the unwrap exists.

        CPython's classification of IPv4-mapped IPv6 has changed across patch
        releases (CVE-2024-4032 altered is_private/is_global), and this runs on
        3.11 locally but 3.12 in production. Normalising to the embedded IPv4
        address makes the verdict ours rather than the stdlib's.
        """
        import ipaddress

        mapped = ipaddress.ip_address("::ffff:169.254.169.254")
        assert mapped.ipv4_mapped == ipaddress.ip_address("169.254.169.254")
        assert _is_forbidden(mapped) is True


# --- SSRF guard: end-to-end through fetch_page ---


class TestFetchGuard:
    async def test_rejects_non_http_scheme(self):
        with pytest.raises(BlockedURL, match="scheme"):
            await fetch_page("file:///etc/passwd")

    async def test_rejects_url_without_host(self):
        with pytest.raises(BlockedURL):
            await fetch_page("http:///nohost")

    @pytest.mark.parametrize(
        "url,resolved",
        [
            ("http://localhost:8000/", "127.0.0.1"),
            ("http://169.254.169.254/latest/meta-data/", "169.254.169.254"),
            ("http://omlete-client.railway.internal/", "fd12::1"),
            ("http://internal.example/", "10.1.2.3"),
        ],
    )
    async def test_rejects_private_targets(self, url, resolved):
        host = urlparse(url).hostname
        with patch_resolve({host: [resolved]}):
            with pytest.raises(BlockedURL, match="non-public"):
                await fetch_page(url)

    @pytest.mark.parametrize(
        "url", ["http://0177.0.0.1/", "http://2130706433/", "http://127.1/"]
    )
    async def test_rejects_encoded_loopback_forms(self, url):
        """Encoded forms resolve to loopback; string matching would miss them."""
        host = urlparse(url).hostname
        with patch_resolve({host: ["127.0.0.1"]}):
            with pytest.raises(BlockedURL, match="non-public"):
                await fetch_page(url)

    async def test_rejects_when_any_resolved_address_is_private(self):
        """A public A record does not excuse a private AAAA record."""
        with patch_resolve({"dual.example": ["93.184.216.34", "10.0.0.1"]}):
            with pytest.raises(BlockedURL, match="non-public"):
                await fetch_page("http://dual.example/r")

    async def test_rejects_unresolvable_host(self):
        with patch_resolve({}):
            with pytest.raises(BlockedURL, match="resolve"):
                await fetch_page("http://nope.example/r")

    async def test_revalidates_after_redirect(self):
        """The hop that matters: public host 302s to the metadata endpoint."""
        calls = []

        def handler(request: httpx.Request) -> httpx.Response:
            calls.append(str(request.url))
            return httpx.Response(
                302, headers={"location": "http://169.254.169.254/"}
            )

        resolve = {
            "safe.example": ["93.184.216.34"],
            "169.254.169.254": ["169.254.169.254"],
        }
        with patch_resolve(resolve), patch_transport(handler):
            with pytest.raises(BlockedURL, match="non-public"):
                await fetch_page("http://safe.example/r")

        # The first hop was fetched; the second was blocked before any request.
        assert calls == ["http://safe.example/r"]

    async def test_rejects_redirect_without_location(self):
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(302)

        with patch_resolve({"safe.example": ["93.184.216.34"]}), patch_transport(
            handler
        ):
            with pytest.raises(BlockedURL, match="Location"):
                await fetch_page("http://safe.example/r")

    async def test_caps_redirect_chain(self):
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(302, headers={"location": "/next"})

        with patch_resolve({"safe.example": ["93.184.216.34"]}), patch_transport(
            handler
        ):
            with pytest.raises(BlockedURL, match="redirects"):
                await fetch_page("http://safe.example/r")

    async def test_caps_response_size(self):
        oversized = b"x" * (recipe_import._MAX_BYTES + 1)

        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(200, content=oversized)

        with patch_resolve({"safe.example": ["93.184.216.34"]}), patch_transport(
            handler
        ):
            with pytest.raises(BlockedURL, match="exceeded"):
                await fetch_page("http://safe.example/big")

    async def test_raises_fetch_failed_on_http_error(self):
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(404)

        with patch_resolve({"safe.example": ["93.184.216.34"]}), patch_transport(
            handler
        ):
            with pytest.raises(FetchFailed, match="404"):
                await fetch_page("http://safe.example/missing")

    async def test_raises_fetch_failed_on_transport_error(self):
        def handler(request: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError("refused")

        with patch_resolve({"safe.example": ["93.184.216.34"]}), patch_transport(
            handler
        ):
            with pytest.raises(FetchFailed):
                await fetch_page("http://safe.example/r")

    async def test_fetches_a_public_page(self):
        def handler(request: httpx.Request) -> httpx.Response:
            assert "OmleteBot" in request.headers["user-agent"]
            return httpx.Response(200, text="<html>hi</html>")

        with patch_resolve({"safe.example": ["93.184.216.34"]}), patch_transport(
            handler
        ):
            assert await fetch_page("http://safe.example/r") == "<html>hi</html>"


# --- Servings parsing ---


class TestParseServings:
    @pytest.mark.parametrize(
        "raw,expected",
        [
            ("6 servings", 6),
            ("Serves 4", 4),
            ("Makes 12 cookies", 12),
            ("1 loaf", 1),
            (None, None),
            ("", None),
            ("a few", None),
            ("0 servings", None),
            ("2024 servings", None),  # implausible, likely a misparse
        ],
    )
    def test_parses(self, raw, expected):
        assert _parse_servings(raw) == expected


# --- Scraping ---


class TestScrape:
    def test_extracts_a_full_recipe(self):
        result = scrape(build_page(), "https://food.example/lasagne")

        assert result is not None
        assert result.title == "Classic Lasagne"
        assert result.instructions == ["Fry the onions.", "Bake for 45 mins."]
        assert result.ingredients == ["1 tbsp olive oil", "500g beef mince"]
        assert result.servings == 6
        assert result.prep_minutes == 30
        assert result.cook_minutes == 90
        assert result.total_minutes == 120
        assert result.image_url == "https://images.example.com/lasagne.jpg"
        assert result.cuisine == "Italian"
        assert result.source_url == "https://food.example/lasagne"

    def test_ingredients_stay_free_text(self):
        """Stage 1 does not decompose ingredients — that's stage 2's job."""
        page = build_page(recipeIngredient=["2 onions, finely chopped"])
        result = scrape(page, "https://food.example/r")

        assert result is not None
        assert result.ingredients == ["2 onions, finely chopped"]

    def test_returns_none_without_structured_data(self):
        html = "<html><body><p>Just a blog post about my holiday.</p></body></html>"
        assert scrape(html, "https://blog.example/post") is None

    @pytest.mark.parametrize(
        "overrides",
        [
            {"recipeIngredient": []},
            {"recipeInstructions": []},
            {"name": None},
        ],
        ids=["no-ingredients", "no-instructions", "no-title"],
    )
    def test_returns_none_when_essentials_missing(self, overrides):
        assert scrape(build_page(**overrides), "https://food.example/r") is None

    def test_optional_fields_absent_is_fine(self):
        page = build_page(
            image=None,
            prepTime=None,
            cookTime=None,
            totalTime=None,
            recipeYield=None,
            recipeCuisine=None,
            description=None,
        )
        result = scrape(page, "https://food.example/r")

        assert result is not None
        assert result.title == "Classic Lasagne"
        assert result.servings is None
        assert result.prep_minutes is None
        assert result.image_url is None
        assert result.cuisine is None

    def test_takes_upper_bound_of_a_yield_range(self):
        """Documents recipe-scrapers' behaviour rather than endorsing it."""
        result = scrape(
            build_page(recipeYield="serves 4-6"), "https://food.example/r"
        )

        assert result is not None
        assert result.servings == 6

    def test_strips_whitespace_and_blank_lines(self):
        page = build_page(
            recipeIngredient=["  1 tbsp olive oil  ", "", "   "],
            recipeInstructions=[
                {"@type": "HowToStep", "text": "  Fry the onions.  "}
            ],
        )
        result = scrape(page, "https://food.example/r")

        assert result is not None
        assert result.ingredients == ["1 tbsp olive oil"]
        assert result.instructions == ["Fry the onions."]

    def test_populates_ingredient_groups(self):
        result = scrape(build_page(), "https://food.example/r")

        assert result is not None
        assert len(result.ingredient_groups) == 1
        assert result.ingredient_groups[0].ingredients == [
            "1 tbsp olive oil",
            "500g beef mince",
        ]

    def test_parses_a_realistic_saved_page(self):
        """Guards against markup noise a hand-built fixture wouldn't have."""
        html = (FIXTURES / "recipe_jsonld.html").read_text()
        result = scrape(html, "https://www.bbcgoodfood.com/recipes/classic-lasagne")

        assert result is not None
        assert result.title == "Classic Lasagne"
        assert len(result.ingredients) == 10
        assert len(result.instructions) == 5
        assert result.servings == 6
        assert result.total_minutes == 120
        assert result.source_name == "bbcgoodfood.com"
