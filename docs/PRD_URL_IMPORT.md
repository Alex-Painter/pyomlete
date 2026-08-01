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

Installs cleanly in a venv with current setuptools; **583 scrapers** available. The `jstyleson` wheel failure seen earlier is a Debian-patched-setuptools artifact (`AttributeError: install_layout`) specific to the sandbox's system Python — **not** a real packaging problem. Still worth confirming on Nixpacks before merge.

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
| Unsupported host, `wild_mode=False` | `WebsiteNotImplementedError` | n/a — we always use `wild_mode=True` |
| No structured data anywhere | `NoSchemaFoundInWildMode` | → Claude fallback on page text |

`wild_mode=True` is a strict superset: it uses the dedicated scraper when the host is supported and falls back to generic schema.org parsing when it isn't. **Always pass `wild_mode=True`.**

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
def scrape(html: str, url: str) -> ScrapedRecipe | None   # wild_mode=True
```

**SSRF guard — required, not optional.** This endpoint takes a user-supplied URL and makes the server fetch it. Without a guard it's a hole straight into the internal network. Must:

- Allow only `http`/`https` schemes
- Resolve the hostname and **reject private/reserved ranges**: `127.0.0.0/8`, `10/8`, `172.16/12`, `192.168/16`, `169.254/16` (cloud metadata — `169.254.169.254` is the one that matters), `::1`, unique-local v6
- Re-check after **every redirect**, cap redirects at ~5
- Cap response size (~2 MB) and timeout (~10s)
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
| Save directly or preview first? | **Preview, then save** | See open question 1 — recommended but costs an extra step |
| Default Create tab | From link | Will be the most-used path |
| robots.txt | Ignore, but always store `source_url` | User is importing a page they're already viewing; attribution is the right etiquette |

---

## Implementation plan

### Step 1 — Dependency + scraper module
- Add `recipe-scrapers` to `server/requirements.txt`
- **Verify it builds on Nixpacks** before going further (the sandbox failure was environmental, but confirm)
- Create `server/recipe_import.py`: `fetch_page()` with the full SSRF guard, `scrape()` wrapping `scrape_html(..., wild_mode=True)`
- Normalise `yields()` → `Optional[int]` with a range sanity-check
- Return a `ScrapedRecipe` dataclass

### Step 2 — Tests for step 1 (before wiring anything up)
- `server/tests/test_recipe_import.py` with **saved HTML fixtures** — no network in tests
- Fixtures: a JSON-LD page, a page with `ingredient_groups`, a no-structured-data page, a `"serves 4-6"` yields case
- SSRF guard tests: `127.0.0.1`, `169.254.169.254`, `10.x`, `file://`, a redirect from a public host to a private one
- This is the highest-value test surface in the feature — it's pure functions over fixed input

### Step 3 — Ingredient structurer
- `server/ingredient_structurer.py` on Haiku, reusing the `tool_runner` + `find_similar_ingredients` pattern
- Unit tests with a mocked Anthropic client, mirroring `tests/test_ingredient_service.py`
- **Risk:** confirm Haiku 4.5 handles structured output + tool use reliably. If not, fall back to Sonnet — still far cheaper than Opus

### Step 4 — Model changes
- Extend `Recipe` and `IngredientRecipe` in `server/lib/types.py`
- No migration needed (all optional), but confirm existing docs still deserialise
- Add the `source_url` index

### Step 5 — Endpoint
- `POST /api/recipes/import-from-url/` in `server/main.py`
- Wire the fallback chain and the error taxonomy above
- Dedup check on `source_url`

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

1. **Preview before save, or save immediately?** The existing extract flow saves immediately. Preview is better UX — Paprika does it, and it stops bad imports polluting the library — but it's an extra screen and an extra state. *Recommendation: preview.* Import quality varies too much across sites to save blind.
2. **What do we do about `amount` on unquantified ingredients?** `IngredientRecipe.amount` is currently a **required `float`**, so "salt and pepper to taste" has no honest representation and the model presumably invents one. This is a pre-existing wart that URL import will hit constantly. *Recommendation: make `amount` `Optional[float]`* — but it touches the list-merge arithmetic at `main.py:540-557`, so it needs its own care.
3. **Video links?** Pasting an Instagram or TikTok URL will fail with `NoSchemaFoundInWildMode`. Do we detect those hosts and show "video import isn't supported yet", or let it fall through to the generic error? A clear message is cheap and this *will* happen.
4. **Rate limiting.** This endpoint makes the server fetch arbitrary URLs. Even with the SSRF guard it's an abuse vector for traffic amplification. Needs the #50 P0 rate-limiting work — arguably a hard dependency rather than a nice-to-have.
