# PRD: Import recipe from a web link

_Child of #50. Verified against `recipe-scrapers` 15.11.0._

---

## Problem

Omlete has two ways to get a recipe in: type your ingredients, or photograph a cookbook. Both are high-effort and low-frequency. **Pasting a link is how people actually acquire recipes**, and every competitor — Paprika, AnyList, Mela, Mealie, Tandoor, and the entire AI-native cohort — supports it.

The UK case is especially strong. BBC Good Food is the [#1 cooking site in the UK](https://www.similarweb.com/top-websites/united-kingdom/food-and-drink/cooking-and-recipes/) at ~30.7M monthly visits, ahead of RecipeTin Eats, Allrecipes, HelloFresh and Jamie Oliver. UK recipes live on the open web, not in an app.

## Solution

A third tab on `/create` — **From link** — that takes a URL and produces a saved recipe.

The important architectural point: **this is a two-stage pipeline, not one.**

```
URL ──▶ Stage 1: SCRAPE (free, ~1s, zero tokens)
        └─ title, instructions[], image, prep/cook/total time,
           yields, description, cuisine, category, source_url
        └─ ingredients as FREE-TEXT STRINGS  ──▶ Stage 2: STRUCTURE (Haiku)
                                                  └─ name / amount / unit / category
                                                  └─ find_similar_ingredients
                                                  └─ ──▶ _save_recipe()
```

Stage 1 gets us most of a recipe for nothing. Stage 2 is the only part that needs a model — and it's a *parsing* task, not a generation task, so it can run on Haiku and can't hallucinate the recipe itself. The instructions come through verbatim from the source.

That makes this **both cheaper and more accurate than the existing image-extraction path**, which pays Opus prices to invent structure from pixels.

## Verified findings

All of the below was tested directly against `recipe-scrapers` 15.11.0.

### Installation

Installs cleanly in a venv with current setuptools; **583 scrapers** available. The `jstyleson` wheel failure seen earlier is a Debian-patched-setuptools artifact (`AttributeError: install_layout`) specific to the sandbox's system Python — **not** a real packaging problem.

**Resolved during implementation:** `recipe-scrapers==15.11.0` installs alongside the full existing `requirements.txt` with `pip check` reporting no broken requirements. It adds ~15 transitive packages (`lxml`, `rdflib`, `pyrdfa3`, `extruct`, `html5lib`, `beautifulsoup4`, `isodate` and friends), which is a meaningful bump to image size and build time but no version conflict. Still worth watching the first Nixpacks build for `lxml` wheel availability.

### UK site coverage (confirmed present in `SCRAPERS`)

`bbcgoodfood.com` · `jamieoliver.com` · `greatbritishchefs.com` · `waitrose.com` · `realfood.tesco.com` · `mob.co.uk` · `mobkitchen.co.uk` · `gousto.co.uk` · `thehappyfoodie.co.uk` · `schoolofwok.co.uk` · `books.ottolenghi.co.uk` · `tofoo.co.uk`

Not covered by a dedicated scraper: `bbc.co.uk/food`, `olivemagazine.com`, `deliciousmagazine.co.uk`, `nigella.com`, `riverford.co.uk` — these should still work through `wild_mode` if they publish JSON-LD.

### What the scraper returns

Tested against a realistic schema.org JSON-LD payload:

| Field | Type returned | Notes |
|---|---|---|
| `title()` | `str` | |
| `total_time()` / `prep_time()` / `cook_time()` | **`int`, minutes** | ISO 8601 durations already parsed for us |
| `yields()` | `str` — `'6 servings'` | ⚠️ see gotcha below |
| `image()` | `str` URL | |
| `ingredients()` | **`list[str]` — free text** | ⚠️ the core constraint |
| `ingredient_groups()` | `[IngredientGroup(ingredients=[...], purpose=None)]` | `purpose` carries "For the sauce:" headings |
| `instructions_list()` | `list[str]` | |
| `nutrients()` | `dict[str, str]` — `{'calories': '636 calories'}` | strings, need parsing |
| `ratings()` | `float` — `4.7` | the *site's* crowd rating, not the user's |
| `author()` / `category()` / `cuisine()` / `description()` | `str` | |
| `to_json()` | `dict` of everything above | |

**⚠️ Gotcha:** given `recipeYield: "serves 4-6"`, `yields()` returned `'6 servings'` — it takes the **upper bound** of a range. Best-effort normalisation; sanity-check the parsed integer rather than trusting it.

**⚠️ The core constraint:** ingredients arrive as `'2 onions, finely chopped'`, not `{name, amount, unit}`. `recipe-scrapers` ships **no** ingredient parser (only internal `_grouping_utils` / `_utils`). Stage 2 is mandatory.

### Failure modes (clean and distinguishable)

| Condition | Exception | Our response |
|---|---|---|
| Unsupported host, `supported_only=True` | `WebsiteNotImplementedError` | n/a — we always pass `supported_only=False` |
| No structured data anywhere | `NoSchemaFoundInWildMode` | → Claude fallback on page text |

⚠️ **`wild_mode` is deprecated in 15.11.0** — it emits a `DeprecationWarning` and may be removed. Use **`supported_only=False`**, which is the documented replacement.

Verified equivalent: with `supported_only=False`, a supported host still resolves to its dedicated scraper (confirmed `BBCGoodFood` is returned for a bbcgoodfood.com URL), and unsupported hosts fall back to generic schema.org parsing. Exceptions raised are unchanged. It is a strict superset — **always pass `supported_only=False`**.

---

## UX

### The Create page

Tabs become: **From link** · Generate · Extract from Images — with *From link* as the default (it will be the most-used path; today `extract` is the default at `create.tsx:16`).

```
┌──────────────────────────────────────────────┐
│  [ From link ]  Generate   Extract from Images│
├──────────────────────────────────────────────┤
│  Paste a recipe link                          │
│  ┌────────────────────────────────┐ ┌──────┐ │
│  │ https://bbcgoodfood.com/...    │ │Import│ │
│  └────────────────────────────────┘ └──────┘ │
│                                               │
│  Works with BBC Good Food, Jamie Oliver,      │
│  Tesco Real Food, Waitrose, Mob and 580 more. │
└──────────────────────────────────────────────┘
```

States: idle → `Reading the page…` (stage 1) → `Sorting the ingredients…` (stage 2) → recipe card + "View recipe" / "Add to list". Errors surface inline with the reason and a "try extracting from a photo instead" escape hatch.

Expected latency ~5-8s total, versus 20-60s for the current generate flow. No streaming needed.

### PWA share target

`manifest.webmanifest` already exists. Adding a `share_target` lets Android users share a URL straight from Chrome, Instagram or TikTok into Omlete — which is exactly the mechanic the AI-native cohort competes on.

```json
"share_target": {
  "action": "/create",
  "method": "GET",
  "params": { "title": "title", "text": "text", "url": "url" }
}
```

`/create` reads `?url=` on mount and pre-fills the field. Cheap, and it's the difference between a feature people try once and one they use constantly.

---

## Technical design

### New module: `server/recipe_import.py`

```python
async def fetch_page(url: str) -> str        # SSRF-guarded async fetch
def scrape(html: str, url: str) -> ScrapedRecipe | None   # supported_only=False
```

**SSRF guard — required, not optional.** This endpoint takes a user-supplied URL and makes the server fetch it, then returns the parsed result to the caller. That is a textbook full-read SSRF primitive. See [Appendix A](#appendix-a--ssrf-in-detail) for the full threat model, why the obvious mitigations fail, and a reference implementation.

Summary of what the guard must do:

- Allow only `http` / `https` schemes
- Resolve the hostname and reject **every** returned address that is loopback, private, link-local, reserved, multicast or unspecified — checked with `ipaddress`, not string matching
- Disable automatic redirects and **re-validate every hop**, capped at ~5
- Cap response size (~2 MB, enforced while streaming) and total timeout (~10s)
- Send a real User-Agent; many sites 403 a default `python-httpx`

`httpx==0.28.1` is already in `requirements.txt`, so use `httpx.AsyncClient` rather than `scrape_me()` — the latter fetches synchronously and would block the event loop.

### New module: `server/ingredient_structurer.py`

Takes `list[str]` of raw ingredient lines plus the category list; returns `list[IngredientModelResponse]`.

Reuses the existing `tool_runner` + `find_similar_ingredients` + `output_config` pattern from `main.py:124-133`, but on **`claude-haiku-4-5-20251001`**.

Prompt requirements:
- Split each line into `name`, `amount`, `unit`
- **Strip preparation from the name**: `"2 onions, finely chopped"` → name `onions`, note `finely chopped`
- Call `find_similar_ingredients` to canonicalise against our vocabulary
- Assign a category from the user's list for new ingredients
- Preserve group headings from `ingredient_groups()` where present

### Endpoint: `POST /api/recipes/import-from-url/`

```
Request:  { "url": "https://www.bbcgoodfood.com/recipes/classic-lasagne" }
200 →     RecipeDocument (same shape as the existing extract endpoint)
400 →     malformed URL, unsupported scheme, or blocked host
404 →     page fetched but no recipe found (after Claude fallback)
502 →     source site unreachable / timed out
409 →     already imported (returns the existing recipe id)
```

Flow:

1. Validate + SSRF-guard the URL
2. Fetch HTML
3. `scrape_html(html, org_url=url, wild_mode=True)`
4. On `NoSchemaFoundInWildMode` → strip the page to text and run the **existing** Opus generate path as a fallback
5. Structure the ingredient strings (Haiku)
6. Map to `RecipeDocument` and `_save_recipe()`

### Model changes

`server/lib/types.py` — extend `Recipe`:

```python
class Recipe(BaseModel):
    title: str
    instructions: list[str]
    servings: Optional[int] = None
    prep_minutes: Optional[int] = None
    cook_minutes: Optional[int] = None
    total_minutes: Optional[int] = None
    image_url: Optional[str] = None
    source_url: Optional[str] = None
    source_name: Optional[str] = None      # e.g. "BBC Good Food"
    description: Optional[str] = None
    cuisine: Optional[str] = None
```

All optional, so existing documents deserialise unchanged — **no migration needed**.

`IngredientRecipe` gains `note: Optional[str]` for the stripped prep text.

### Deduplication

Index `source_url` and return 409 with the existing recipe id on re-import. Requires the index work from #50's P0 anyway.

---

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Scrape library | `recipe-scrapers`, `wild_mode=True` always | 583 dedicated scrapers + generic schema.org fallback in one call |
| Fetching | `httpx.AsyncClient`, not `scrape_me()` | `scrape_me()` blocks the event loop |
| Stage 2 model | Haiku 4.5 | Parsing, not generation. ~95% cheaper than Opus |
| No-structured-data fallback | Existing Opus generate path on page text | Reuses code; rare enough that cost doesn't matter |
| Import the site's rating? | **No** | It's the crowd's rating, not the user's. Our `rating` field means "did *I* like it" |
| Import nutrition? | **No, not yet** | Returns unparsed strings; out of scope per #50 |
| Hero image | Store the URL, don't re-host | Cheap. Hotlinks can rot — re-hosting is a later improvement |
| Save directly or preview first? | **Save immediately** | Consistent with the existing generate and extract flows. Recipes are editable and deletable, so a bad import is cheap to fix |
| Default Create tab | From link | Will be the most-used path |
| robots.txt | Ignore, but always store `source_url` | User is importing a page they're already viewing; attribution is the right etiquette |

---

## Implementation plan

### Step 1 — Dependency + scraper module ✅ done
- Add `recipe-scrapers` to `server/requirements.txt`
- **Verify it builds on Nixpacks** before going further (the sandbox failure was environmental, but confirm)
- Create `server/recipe_import.py`: `fetch_page()` with the full SSRF guard, `scrape()` wrapping `scrape_html(..., wild_mode=True)`
- Normalise `yields()` → `Optional[int]` with a range sanity-check
- Return a `ScrapedRecipe` dataclass

### Step 2 — Tests for step 1 (before wiring anything up) ✅ done
- `server/tests/test_recipe_import.py` with **saved HTML fixtures** — no network in tests
- Fixtures: a JSON-LD page, a page with `ingredient_groups`, a no-structured-data page, a `"serves 4-6"` yields case
- SSRF guard tests: `127.0.0.1`, `169.254.169.254`, `10.x`, `file://`, a redirect from a public host to a private one
- This is the highest-value test surface in the feature — it's pure functions over fixed input

### Step 3 — Ingredient structurer ✅ done
- `server/ingredient_structurer.py` on Haiku, reusing the `tool_runner` + `find_similar_ingredients` pattern
- Unit tests with a mocked Anthropic client, mirroring `tests/test_ingredient_service.py`
- **Risk:** confirm Haiku 4.5 handles structured output + tool use reliably. If not, fall back to Sonnet — still far cheaper than Opus
- **Still open:** the risk above is unverified. The tests mock the client, so nothing here has exercised a real Haiku call — that needs a live import against a real page before this ships. `MODEL` is a single constant to change if it disappoints.
- Group headings are only used when they account for every ingredient line. Partial `ingredient_groups()` is common enough that trusting it would silently drop ingredients.

### Step 4 — Model changes ✅ done
- Extend `Recipe` and `IngredientRecipe` in `server/lib/types.py`
- No migration needed (all optional), but confirm existing docs still deserialise
- Add the `source_url` index
- **Changed from the plan:** the metadata went on a separate `RecipeMetadata` mixin rather than onto `Recipe`. `Recipe` is the base of `RecipeModelResponse`, which is what generates the JSON schema handed to Claude — extending it would have put `image_url` and `source_url` in front of a model that has no way to know them and every incentive to fill them in. `RecipeDocument` inherits both; the model only ever sees `Recipe`.
- `IngredientRecipe` also gained `group`, so the headings from step 3 have somewhere to live.
- Open question 2 resolved: `amount` is now `Optional[float]`. `ItemSource.amount` followed it, and the two `sum()` sites in the list-merge arithmetic went through `_total_amount()`, which ignores unquantified sources instead of treating them as zero.

### Step 5 — Endpoint ✅ done
- `POST /api/recipes/import-from-url/` in `server/main.py`
- Wire the fallback chain and the error taxonomy above
- Dedup check on `source_url`
- The dedup read happens before the fetch, so a re-import costs neither a request nor a token. The index is non-unique (every hand-made recipe has `source_url` unset), so two simultaneous imports of the same URL race to a duplicate rather than an error.
- The Opus fallback is told to return an empty recipe for a page that has none, which is what turns into the 404. Without that it will always oblige with something.
- **Not done, still required before this is public:** rate limiting (open question 4). The endpoint makes the server fetch arbitrary URLs and then spends tokens on the result, with no authentication in front of it.

### Step 6 — Frontend
- New `LinkTab` in `client/src/routes/create.tsx`, made the default
- Two-phase progress copy ("Reading the page…" → "Sorting the ingredients…")
- **Real error handling** — this is the first feature that genuinely needs it, and it's a #50 P0 item
- Surface `image_url`, times and servings on `RecipeCard` and the recipe detail page

### Step 7 — Share target
- `share_target` in `manifest.webmanifest`
- `/create` reads `?url=` on mount and pre-fills
- Test on Android Chrome — iOS does not support Web Share Target

### Step 8 — Docs
- Update `README.md` / `CLAUDE.md` (both currently describe endpoints that don't exist)

**Suggested sequencing:** steps 1-2 are self-contained and testable with zero network and zero tokens — worth doing first and merging on their own. Steps 3-5 are the backend spine. Steps 6-7 are frontend. Step 4 (model changes) unblocks other #50 work, so pulling it earlier is reasonable.

---

## Verification

1. A BBC Good Food URL produces a complete recipe — title, steps, image, times, servings — with structured ingredients and **zero Opus calls**
2. Ingredients are canonicalised: importing a recipe with "spring onions" matches an existing "scallions" entry rather than creating a duplicate
3. `"2 onions, finely chopped"` yields name `onions`, amount `2`, with `finely chopped` in the note
4. A recipe with "For the sauce:" headings preserves the grouping
5. An unsupported site that publishes JSON-LD still imports via `wild_mode`
6. A blog with no structured data falls back to Claude and still produces a recipe
7. Re-importing the same URL returns 409 with the existing recipe rather than a duplicate
8. `http://169.254.169.254/latest/meta-data/` is rejected, as is a public URL that 302s to a private address
9. A 50 MB response is truncated, not swallowed
10. Sharing a link from Chrome on Android opens Omlete with the URL pre-filled

---

## Open questions

1. ~~**Preview before save, or save immediately?**~~ **Resolved: save immediately**, matching the existing generate and extract flows. Imports land straight in the library; the user edits or deletes if the import was poor.
2. **What do we do about `amount` on unquantified ingredients?** `IngredientRecipe.amount` is currently a **required `float`**, so "salt and pepper to taste" has no honest representation and the model presumably invents one. This is a pre-existing wart that URL import will hit constantly. *Recommendation: make `amount` `Optional[float]`* — but it touches the list-merge arithmetic at `main.py:540-557`, so it needs its own care.
3. **Video links?** Pasting an Instagram or TikTok URL will fail with `NoSchemaFoundInWildMode`. Do we detect those hosts and show "video import isn't supported yet", or let it fall through to the generic error? A clear message is cheap and this *will* happen.
4. **Rate limiting.** This endpoint makes the server fetch arbitrary URLs. Even with the SSRF guard it's an abuse vector for traffic amplification. Needs the #50 P0 rate-limiting work — arguably a hard dependency rather than a nice-to-have.

---

## Appendix A — SSRF in detail

### What the vulnerability is

Server-Side Request Forgery: the client supplies a URL and the **server** makes the request. The attacker doesn't get to reach the destination themselves — they borrow our server's network position to do it.

That matters because our server sits *inside* a trust boundary the attacker is outside of. It can reach the container's loopback interface, Railway's private network, and whatever the platform exposes on link-local addresses. A browser on the open internet can reach none of those.

`POST /api/recipes/import-from-url/` is close to the worst-case shape:

- **The attacker fully controls the destination** — that's the entire feature
- **The response comes back to them.** We parse the fetched page and return the result. That makes it a **full-read** SSRF rather than a blind one. Blind SSRF leaks timing; full-read leaks content.
- **It is currently unauthenticated** (see #50 P0). Anyone on the internet, no account needed.

### What an attacker actually gets

**1. Cloud metadata services.** The classic target is the link-local endpoint `169.254.169.254`. On AWS this serves IAM role credentials at `/latest/meta-data/iam/security-credentials/`, which is precisely how the 2019 Capital One breach happened — an SSRF used to lift EC2 role credentials, ~100M records.

Railway runs on GCP, where the metadata service requires a `Metadata-Flavor: Google` header and returns 403 without it. That is real defence-in-depth, and it means a naive `GET http://169.254.169.254/` probably fails today. **Do not rely on it.** It's a property of the current platform, not of our code; it evaporates if we ever add header passthrough, move providers, or run anything locally. I have not verified exactly what Railway's runtime exposes to containers — treat that as unknown rather than safe.

**2. Railway's private network.** Services in a Railway project reach each other over an internal DNS namespace on IPv6. `railway.json` defines two services, so `http://omlete-client.railway.internal:3000/` is reachable from the API container today. The exposure grows with every internal service added later — a Redis, an admin surface, a database.

**3. Loopback.** `http://127.0.0.1:8000/` is our own API. Two consequences: it bypasses any IP-based rate limiting (requests appear to originate locally), and any future admin endpoint bound to localhost-only becomes internet-reachable.

**4. Internal reconnaissance.** Even where the body isn't readable, response timings and error types distinguish "connection refused" from "connected but wrong protocol" — enough to map what's listening.

**5. Request laundering.** Ignoring internal access entirely: an unauthenticated fetch-any-URL endpoint lets someone use our server as an anonymising relay. The target sees Railway's IP, not theirs.

### Why the obvious mitigations fail

This is the part worth internalising. Each of these looks like a fix and isn't.

**"Block hostnames containing localhost or 127.0.0.1."** Defeated by encoding: `http://0177.0.0.1/` (octal), `http://2130706433/` (decimal), `http://127.1/` (shorthand), `http://[::ffff:127.0.0.1]/` (IPv4-mapped IPv6). Also defeated by public DNS names that resolve inward — `localtest.me` and friends resolve to `127.0.0.1`. String matching on the hostname is the wrong layer. **Resolve first, then check the resulting IP.**

**"Check the IP before fetching."** Necessary but not sufficient on its own, because of redirects. We validate `https://evil.example/x`, it's a genuine public address, we fetch it — and it returns `302 Location: http://169.254.169.254/`. `httpx` follows redirects when asked to, and the second request never passes through our check. **This is the mitigation people most often miss.** Either disable automatic redirects and walk the chain manually, re-validating each hop, or don't allow redirects at all.

**"Check the IP, then fetch."** There's still a time-of-check/time-of-use gap. We resolve the name and validate; `httpx` then resolves it *again* when it opens the connection. An attacker serving a TTL-0 record can return a public address to the first lookup and a private one to the second — DNS rebinding.

Closing this properly means connecting to the already-validated IP rather than re-resolving, which is fiddly with TLS (SNI and `Host` have to be set explicitly, and it breaks against some CDNs). **My recommendation: accept this as a known residual risk for now.** It requires an attacker to control a DNS server *and* win a timing race, which is a long way beyond the realistic threat model for this app. Document it, don't over-engineer it. Revisit if the app ever holds credentials worth stealing.

**"Only allow http and https."** Do it — it's free, and it kills `file:///etc/passwd`, `gopher://` and `dict://`. But note `httpx` is HTTP-only anyway, so this is belt-and-braces rather than the main control.

**"Only check IPv4 private ranges."** Railway's private networking is IPv6. Missing `::1`, unique-local `fc00::/7`, link-local `fe80::/10` and IPv4-mapped forms leaves the most relevant path open.

### Reference implementation

```python
import ipaddress, socket
from urllib.parse import urlparse
import httpx

MAX_BYTES = 2 * 1024 * 1024
MAX_REDIRECTS = 5
TIMEOUT = httpx.Timeout(10.0, connect=5.0)
UA = "OmleteBot/1.0 (+https://omlete.app; recipe import)"


class BlockedURL(Exception):
    """The URL resolves somewhere we refuse to fetch."""


def _assert_public(host: str) -> None:
    """Resolve `host` and reject if ANY returned address is non-public."""
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror as exc:
        raise BlockedURL(f"cannot resolve {host}") from exc

    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        # IPv4-mapped IPv6 (::ffff:127.0.0.1) must be unwrapped before checking
        if getattr(ip, "ipv4_mapped", None):
            ip = ip.ipv4_mapped
        if (
            ip.is_private or ip.is_loopback or ip.is_link_local
            or ip.is_reserved or ip.is_multicast or ip.is_unspecified
        ):
            raise BlockedURL(f"{host} resolves to non-public address {ip}")


def _validate(url: str) -> None:
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise BlockedURL(f"unsupported scheme: {parsed.scheme!r}")
    if not parsed.hostname:
        raise BlockedURL("missing hostname")
    _assert_public(parsed.hostname)


async def fetch_page(url: str) -> str:
    """Fetch a page, re-validating on every redirect hop."""
    async with httpx.AsyncClient(
        follow_redirects=False,          # we walk the chain ourselves
        timeout=TIMEOUT,
        headers={"User-Agent": UA},
    ) as client:
        for _ in range(MAX_REDIRECTS):
            _validate(url)               # <-- runs again for each hop
            async with client.stream("GET", url) as response:
                if response.is_redirect:
                    location = response.headers.get("location")
                    if not location:
                        raise BlockedURL("redirect without Location")
                    url = str(response.url.join(location))
                    continue

                response.raise_for_status()

                # Enforce the size cap while streaming, not after
                chunks, total = [], 0
                async for chunk in response.aiter_bytes():
                    total += len(chunk)
                    if total > MAX_BYTES:
                        raise BlockedURL("response too large")
                    chunks.append(chunk)
                return b"".join(chunks).decode(
                    response.encoding or "utf-8", errors="replace"
                )

        raise BlockedURL("too many redirects")
```

Three details that carry most of the weight:

1. `_validate()` is inside the redirect loop, so every hop is checked — not just the URL the user typed.
2. `_assert_public()` iterates **all** `getaddrinfo` results. A hostname with both an A and an AAAA record has to pass on both.
3. The size cap is enforced **while streaming**. Checking `Content-Length` afterwards is useless against a server that lies or omits it.

### Test cases

These belong in `server/tests/test_recipe_import.py` and need no network:

| Input | Expected |
|---|---|
| `http://127.0.0.1:8000/` | `BlockedURL` |
| `http://169.254.169.254/latest/meta-data/` | `BlockedURL` |
| `http://[::1]/` | `BlockedURL` |
| `http://0177.0.0.1/` and `http://2130706433/` | `BlockedURL` |
| `http://[::ffff:127.0.0.1]/` | `BlockedURL` (exercises the `ipv4_mapped` unwrap) |
| `http://omlete-client.railway.internal/` | `BlockedURL` |
| `file:///etc/passwd` | `BlockedURL` (scheme) |
| Public host → `302` → `http://169.254.169.254/` | `BlockedURL` **on the second hop** |
| 6-hop redirect chain | `BlockedURL` (too many redirects) |
| Response streaming past 2 MB | `BlockedURL` (too large) |
| Ordinary public recipe URL | succeeds |

Mock `socket.getaddrinfo` to make the resolution cases deterministic.

### Residual risks, accepted knowingly

- **DNS rebinding**, as discussed above — needs attacker-controlled DNS plus a race win.
- **Traffic amplification** — mitigated by the #50 P0 rate limiting, not by this guard. Treat that rate limiting as a hard dependency of shipping this endpoint, not a follow-up.
