# Omlete — Codebase Audit & Competitive Gap Analysis

_July 2026. Based on `main` @ `9ec7077`._

---

## 1. What Omlete actually is today

Stripped of the marketing, Omlete is **a shopping-list app with an AI recipe importer attached**. That's a real product, and the shopping-list half is genuinely good. But it is not, today, a recipe manager — and the README/CLAUDE.md describe an app that doesn't exist (they still reference Render, a `/meal-plan` route, and `POST /meal-plan/shopping-list/`, none of which are in the codebase).

### What's genuinely strong

| Thing | Why it's good |
|---|---|
| **Ingredient canonicalisation via embeddings** (`ingredient_service.py`, `tools.py`) | Voyage-4 2048-dim embeddings + Mongo `$vectorSearch` at ≥0.9, exposed to Claude as a tool so the model reconciles "spring onions" against your existing library at generation time. **Nobody in the competitive set does this.** This is the most interesting thing in the repo. |
| **Shopping list source tracking** (`ItemSource`, `main.py:519-595`) | Items remember which recipes contributed which amounts, so removing a recipe subtracts exactly its share and drops the item only when nothing else needs it. Paprika and AnyList do *not* do this cleanly — they merge and forget. |
| **Plan vs Shop modes** (`list.$listId.tsx:389-406`) | Same data, two layouts, sensible default. Genuinely thoughtful. |
| **Optimistic mutations + drag reorder** | The list page is the most polished surface in the app. |
| **Multi-photo → single recipe extraction** | Handles the real case of a cookbook spread across two pages. Most competitors treat each photo as one recipe. |
| **Editable categories with custom aisle order** | Matches AnyList/Tandoor. Table stakes, and you have it. |

### The data model, in full

```python
Recipe   = title + instructions[]                       # lib/types.py:33
Ingredient = name + unit + amount + category + excluded_from_list
RecipeDocument = Recipe + ingredients[] + rating + created_at
```

**That's it.** No servings, no prep/cook time, no photo, no source URL, no tags, no cuisine, no notes, no nutrition, no difficulty, no yield. Verified: `grep -riE "servings|prep_time|cook_time|tags|image_url|source_url|nutrition|calories"` returns **zero hits** across `server/` and `client/src/`.

Every gap below flows from that one line.

---

## 2. The competitive landscape

Three cohorts, and Omlete is currently competitive with none of them.

**Cohort A — Classic managers.** [Paprika](https://www.paprikaapp.com/) (URL import, pantry with expiry tracking, daily/weekly/monthly meal planner, reusable menus, scaling + unit conversion, cook mode, cross-device sync), [Mela](https://mela.recipes/) (Apple-only, structured-data import only), [AnyList](https://www.anylist.com/) (real-time shared household lists, aisle ordering, item photos, running price total, recipe import, meal-plan calendar — $9.99/yr). Paprika hasn't shipped a major feature since 2018; the category is stagnant and beatable.

**Cohort B — Self-hosted.** [Mealie and Tandoor](https://cooklang.org/blog/42-tandoor-vs-mealie-vs-kitchenowl/) — both do URL scraping. Tandoor adds OCR for cookbooks, keyword/tag systems, full-text search, iCal meal-plan export, OpenFoodFacts nutrition, barcode scanning, aisle mapping, and meal-cost calculation. This is the closest architectural comparator to what you've built, and Tandoor is well ahead on feature surface.

**Cohort C — AI-native (2024-2026 wave).** ReciMe, Pluck, Recipe Bro, FoodiePrep, Nutrola, CookNest. Their entire pitch is **import from anywhere** — [any website, Instagram, TikTok, YouTube, Pinterest, screenshots](https://recipebro.com/import) — plus auto-derived nutrition and an agentic assistant. [Nutrola](https://nutrola.app/en/blog/best-apps-that-extract-recipes-from-video-urls-2026) pulls full ingredient lists with quantities out of TikTok/Reels/Shorts. This is the cohort Omlete is actually in, and it's the cohort moving fastest.

Separately: [SuperCook](https://apps.apple.com/us/app/supercook-ai-meals-scanner/id6743327665) owns "what can I make with what I have" — a pantry of 2000+ ingredients matched against 11M recipes. That's the closest thing to Omlete's original stated premise ("turn leftover ingredients into a recipe"), and Omlete has **no pantry at all**.

### Feature matrix

| | Omlete | Paprika | AnyList | Tandoor | AI-native cohort |
|---|:--:|:--:|:--:|:--:|:--:|
| Import from URL | ❌ | ✅ | ✅ | ✅ | ✅ |
| Import from photo / OCR | ✅ | ❌ | ❌ | ✅ | ✅ |
| Import from video / social | ❌ | ❌ | ❌ | ❌ | ✅ |
| Generate recipe from ingredients | ✅ | ❌ | ❌ | ❌ | ✅ |
| Recipe photos | ❌ | ✅ | ✅ | ✅ | ✅ |
| Search / tags / filter | ❌ | ✅ | ✅ | ✅ | ✅ |
| Servings + scaling | ❌ | ✅ | ✅ | ✅ | ✅ |
| Prep/cook times | ❌ | ✅ | ✅ | ✅ | ✅ |
| Meal-plan calendar | ❌ | ✅ | ✅ | ✅ | ✅ |
| Pantry | ❌ | ✅ | ❌ | ✅ | partial |
| Cook mode (step tracking, timers) | wake lock only | ✅ | ❌ | ✅ | ✅ |
| Nutrition | ❌ | ❌ | ❌ | ✅ | ✅ |
| Shared / household lists | ❌ | ✅ | ✅ | ✅ | ✅ |
| Offline | ❌ | ✅ | ✅ | ❌ | partial |
| Aisle-ordered lists | ✅ | ✅ | ✅ | ✅ | ✅ |
| Ingredient-level dedup across recipes | ✅✅ | partial | partial | partial | ❌ |
| Semantic ingredient matching | ✅✅ | ❌ | ❌ | ❌ | ❌ |

Two columns where you're **ahead of the entire field**. Ten where you're behind all of it.

---

## 3. The biggest gaps, ranked

### 🔴 Gap 1 — No URL import

**The single highest-leverage missing feature.** Every app in every cohort has it. It is how normal people acquire recipes: they find a link, they paste it. Omlete's only two inputs are "type your ingredients" and "photograph a cookbook" — both are high-effort, low-frequency paths.

The implementation is cheap because you already have every piece:

1. `pip install recipe-scrapers` — [649 supported sites](https://docs.recipe-scrapers.com/), parses JSON-LD, Microdata, RDFa and OpenGraph.
2. On a hit, you get title, ingredients, instructions, image, times, yield, nutrition — **for free**, no LLM call, no token cost, sub-second.
3. On a miss, fall back to your existing Claude path with the page text.
4. Either way, run the result through `find_similar_ingredients` so the ingredients land canonicalised. That's your differentiator applied to the industry-standard input.

You'd match Paprika/Mealie on import in a day or two, and beat them on the ingredient reconciliation.

**Then extend to social video** (yt-dlp → transcript + keyframes → Claude). That's where the AI-native cohort is competing right now and it plays directly to a Claude-backed backend.

### 🔴 Gap 2 — No recipe photos

A recipe library with no images is a text list. This is why `/recipes` grid view (`recipes.tsx:135-145`) looks identical to list view — there's nothing to put in the grid. Users pick what to cook by looking at food.

Note the irony: you upload photos to *create* recipes and then throw them away. `_extract_and_save` (`main.py:176-204`) base64s the image, sends it to Claude, and discards it. Storing that image (or the first one) as the recipe's hero image is nearly free.

### 🔴 Gap 3 — No search, no tags, no filtering

`GET /recipes/` is `RecipeDocument.find_all()` (`main.py:242`) — every recipe, every time, unpaginated, unsorted beyond `created_at`, rendered as a flat list. This is fine at 20 recipes. At 100 it's unusable, at 500 it's a several-hundred-KB payload on every page load of `/recipes`, `/list/$listId`, and the suggest sheet.

You need, in order: text search on title+ingredients (Mongo text index or Atlas Search — you already pay for Atlas), tags/cuisine/meal-type, filter by rating, and pagination. Without this the library is write-only.

### 🟠 Gap 4 — No servings, and therefore no scaling

`Recipe` has no `servings` field, so "scale to 6 people" is impossible, and the shopping-list amounts are meaningless in absolute terms — a recipe adds "500g pasta" with no statement of how many people that feeds. Paprika markets scaling + unit conversion as a headline feature.

This also silently corrupts the list: `add_recipe_to_list` sums raw amounts across recipes with no notion of yield.

### 🟠 Gap 5 — No times or metadata

No prep time, no cook time, no total time, no difficulty. "Quick & easy" exists as a *suggestion filter* (`DIET_OPTIONS`/`EASE_OPTIONS`, `list.$listId.tsx:837-849`) but is never persisted to the recipe, so you can't filter your own library by it. The information is in the model's head at generation time and you're discarding it.

### 🟠 Gap 6 — No meal-plan calendar

Every competitor has one. Your `ListDocument` is *nearly* a meal plan — it has recipes and a date-derived name (`_auto_list_name()`, `main.py:354-357`) — but there's no day assignment, so "Tuesday: chilli" isn't expressible. This is the smallest gap-to-value ratio on the list: add `day` to the list↔recipe relation and you have a week planner.

### 🟠 Gap 7 — No cook mode

You have `useWakeLock` (good, that's the annoying part) but nothing else. Paprika's cook mode: cross off ingredients as you use them, highlight the current step, timers. Yours renders a static `<ol>`. `highlightAmounts.tsx` is a nice touch that's begging to be wired to a step-by-step view with a "start timer" affordance when a step mentions a duration.

### 🟡 Gap 8 — No pantry

The app's origin story is "turn leftover ingredients into a recipe" and there's no representation of what you have. SuperCook's whole business is this. You have the best ingredient vocabulary of anyone (embedded, canonicalised, scored) and no place to say "I own these."

Pantry also closes the loop on the shopping list: check something off → it's in the pantry → next list omits it.

### 🟡 Gap 9 — No auth, no users, no sharing

There is **zero authentication anywhere in the codebase** (verified — no `Depends`, no tokens, no sessions). Consequences:

- Every deployed instance is single-tenant-by-accident: one global recipe pool, one global list pool, one `UserSettingsDocument` (`_get_or_create_settings` does `find_one()` with no filter, `main.py:450-455`).
- **Household sharing — AnyList's entire value proposition — is unbuildable** without this.
- See §4; it's also a live cost and abuse problem.

### 🟡 Gap 10 — No offline

`manifest.webmanifest` exists but there is **no service worker** (verified: no `serviceWorker`, no `vite-plugin-pwa`, no `workbox`). So the PWA installs and then shows a blank screen in a supermarket basement with no signal. That's the exact moment the app is most needed. The manifest also still has `background_color`/`theme_color` of `#0f172a` — dark slate, from before the retheme.

---

## 4. Engineering risks that will bite before any of that

These aren't features; they're things that break.

### 🔴 Unauthenticated LLM endpoints = an open wallet

`POST /api/recipes/generate/` and `POST /api/recipes/extract-from-images/` invoke **Claude Opus 4.5** with no auth, no rate limit, no quota, no per-IP throttle. Anyone who finds the Railway URL can run your Anthropic bill up indefinitely, and the image endpoint reads uploads fully into memory (`await file.read()`, `main.py:179`) with no size cap — a large multipart POST is also a straightforward OOM.

CORS (`main.py:59-65`) allows `https://.*\.up\.railway\.app`, which is a wildcard over every app on Railway — but that's moot, because with no auth the API is equally callable by curl.

**Fix before anything else:** an API key or session check on the two Claude endpoints, `slowapi` rate limiting, and a `MAX_UPLOAD_BYTES` guard.

### 🔴 Zero database indexes

No `Indexed()` fields, no `Settings.indexes` on any of the four documents. Concretely:

- `/categorize` (`main.py:476-484`) runs `find_one({"name": {"$regex": "^…$", "$options": "i"}})` against the ingredients collection — an **unanchored-in-practice regex collection scan on every quick-add**, over a collection with 2048-float embeddings in every document. This is the slowest query in the app and it runs on the most latency-sensitive interaction.
- `IngredientDocument.name` has no unique index, and `_save_recipe` inserts new ingredients with no dedupe check. Two recipes generated in parallel both marking "shallots" as new both insert it. Your canonical ingredient vocabulary drifts.

**Fix:** unique index on lowercased `name`; index `RecipeDocument.created_at`; store a lowercase `name_key` and query on equality instead of regex.

### 🟠 N+1 on the lists page

`GET /lists/` (`main.py:360-378`) loops over every list and issues a separate `RecipeDocument.find(In(...))` per list. Ten lists = eleven round trips on your home screen. Collect all recipe ids, one query, map in memory.

### 🟠 The frontend has no error handling

**No toast, no error banner, no `isError` branch anywhere** in `client/src`. The three `onError` handlers in `list.$listId.tsx` are optimistic-rollback only — they restore state silently and tell the user nothing. Worse, `create.tsx:147-149`:

```ts
} catch {
  // Continue with next group on error
}
```

A failed extraction is **completely silent** — the spinner advances, the recipe never appears, no explanation. Add `sonner` and surface failures. This is a 30-minute fix with an outsized effect on how the app *feels*.

### 🟠 Long blocking requests with no progress

`runner.until_done()` consumes the stream server-side and returns one JSON blob. A generate is 20-60s of a spinner. Then `handleAddSelected` (`list.$listId.tsx:899-935`) generates selected meals **sequentially** — pick 5 suggestions and you wait 2-5 minutes with a `done/total` counter and no cancel. No client timeout, no retry, no partial results.

Consider SSE with incremental recipe fields, or a job + poll pattern. Also: `suggest_meals` and `categorize` don't need Opus-class reasoning — `suggest_meals` uses Opus 4.5 for five one-line meal ideas (`main.py:166-171`). Move it to Haiku and cut that call's cost by ~95%.

### 🟠 The shopping list merge ignores your best asset

`add_recipe_to_list` (`main.py:540-543`) merges items on `item.name.lower() == ing.name.lower() and item.unit == ing.unit`. Exact string, exact unit. So:

- "spring onions" and "scallions" → two lines
- "500 g flour" and "2 cups flour" → two lines
- "garlic clove" and "garlic cloves" → two lines

**You have a semantic ingredient matcher and a vector index sitting right there and you're using `==` on the shopping list.** Fixing this is the clearest expression of your differentiator and it's mostly plumbing you've already written. Pair it with a unit-conversion table (g↔kg, ml↔l, tsp↔tbsp↔cup) and the list gets visibly smarter than Paprika's.

### 🟡 The retheme is half-finished

The `a00628e` cream+amber retheme missed the "Suggest meals" sheet, which is still **entirely on the old dark theme** — `bg-slate-900 border-slate-700 text-white`, `text-emerald-400`, `bg-slate-800` inputs (`list.$listId.tsx:961-1055`). Opening it from a cream page is jarring. Plus scattered leftovers: `border-slate-700` on the Delete button (`recipe.$recipeId.tsx:207`), `text-slate-500 hover:text-red-400` in six files, `border-b border-slate-700/50` (`list.$listId.tsx:706`), and `StarRating` unfilled stars at `text-slate-500` against cream.

### 🟡 Test coverage is ~2% and there's no CI

One backend test file (`tests/test_ingredient_service.py`, 104 lines, covering only `find_similar`). **Zero tests on any of the 25 API endpoints.** Vitest is configured and there are **zero frontend test files**. No `.github/` directory at all — nothing runs on push.

The riskiest untested logic is the list arithmetic: `add_recipe_to_list`/`remove_recipe_from_list` do read-modify-write amount summing across sources, and `reorder_items` has genuinely subtle slot-preservation logic (`main.py:618-639`) mirrored by hand in TypeScript (`list.$listId.tsx:104-116`). Two implementations of the same algorithm in two languages, neither tested.

### 🟡 Docs describe a different app

`README.md` and `CLAUDE.md` both claim Render deployment (you moved to Railway in `71d4f1e`), a `/meal-plan` page, and `POST /meal-plan/suggest/` + `POST /meal-plan/shopping-list/` endpoints. None exist. Anyone onboarding — human or agent — starts from a false map.

---

## 5. Where Omlete can actually win

Don't try to out-feature Paprika. Pick the thing nobody else has and push it hard.

**The semantic ingredient graph is the moat.** Every competitor treats ingredients as strings. You treat them as embedded entities with a canonical vocabulary that grows as you cook. Things that unlocks, roughly in order of effort:

1. **Semantic list merging** (§4) — immediate, visible, uses code you've already written.
2. **Pantry with fuzzy matching** — "I have scallions" satisfies a recipe calling for spring onions. SuperCook can't do this; they use a fixed 2000-item taxonomy.
3. **"What can I make?"** — vector-match pantry contents against your recipe library, rank by coverage, show "you're 2 ingredients away from X." This is the app's original premise, finally delivered.
4. **Substitutions** — "no crème fraîche" → nearest neighbours in embedding space, filtered by what's in the pantry.
5. **Waste-driven suggestions** — items that have sat unchecked on lists, or pantry items by age, feed into `suggest_meals` as a bias. That's a real, defensible reason to open the app on a Tuesday.

None of these are buildable without the boring work in §3 and §4 first. But they're the reason to do that work.

---

## 6. Recommended sequence

**Phase 0 — Stop the bleeding (days)**
- Auth on the Claude endpoints + rate limiting + upload size cap
- Database indexes (unique lowercase ingredient name; `created_at`)
- Error toasts on the frontend
- Fix the N+1 in `GET /lists/`
- Move `suggest_meals` and `categorize` off Opus
- Update README/CLAUDE.md to match reality
- A GitHub Actions workflow running pytest + vitest + lint

**Phase 1 — Become a recipe manager (2-3 weeks)**
- **URL import** via `recipe-scrapers` with Claude fallback ← *the big one*
- Extend `Recipe`: `servings`, `prep_minutes`, `cook_minutes`, `tags[]`, `image_url`, `source_url`, `notes`
- Persist the extraction photo as the hero image
- Search + tag filter + pagination on `/recipes`
- Backfill: one-off script to have Claude infer the new fields for existing recipes

**Phase 2 — Cooking and planning (2-3 weeks)**
- Servings + scaling (recompute amounts, scale list contributions)
- Cook mode: step tracking, ingredient check-off, timers from step text
- Meal-plan calendar (day assignment on the existing list↔recipe relation)
- Service worker for offline list access

**Phase 3 — The moat (ongoing)**
- Semantic + unit-aware list merging
- Pantry
- "What can I make?" / substitutions / waste-driven suggestions
- Social-video import
- Multi-user + household sharing (needs Phase 0 auth as its foundation)

---

## Appendix — file reference

| Finding | Location |
|---|---|
| Recipe model missing all metadata | `server/lib/types.py:33-39` |
| No indexes on any document | `server/data_models/__init__.py:11-77` |
| CORS wildcard over Railway | `server/main.py:59-65` |
| Unauthenticated Opus endpoint | `server/main.py:115-135` |
| Opus used for one-line suggestions | `server/main.py:166-171` |
| Uncapped in-memory image read | `server/main.py:179` |
| Unpaginated `find_all()` | `server/main.py:242` |
| N+1 on lists | `server/main.py:360-378` |
| Regex collection scan on categorize | `server/main.py:476-484` |
| Exact-string list merge | `server/main.py:540-543` |
| Untested reorder slot logic (Python) | `server/main.py:618-639` |
| Untested reorder slot logic (TS mirror) | `client/src/routes/list.$listId.tsx:104-116` |
| Silently swallowed extraction errors | `client/src/routes/create.tsx:147-149` |
| Dark-theme "Suggest meals" sheet | `client/src/routes/list.$listId.tsx:961-1055` |
| Stale dark theme colours in manifest | `client/public/manifest.webmanifest` |

## Sources

- [Paprika Recipe Manager](https://www.paprikaapp.com/)
- [AnyList](https://www.anylist.com/)
- [Best Recipe Management Software 2026 — Cooklang](https://cooklang.org/blog/48-best-recipe-management-software/)
- [Tandoor vs Mealie vs KitchenOwl — Cooklang](https://cooklang.org/blog/42-tandoor-vs-mealie-vs-kitchenowl/)
- [recipe-scrapers documentation](https://docs.recipe-scrapers.com/)
- [Recipe structured data — Google Search Central](https://developers.google.com/search/docs/appearance/structured-data/recipe)
- [schema.org/Recipe](https://schema.org/Recipe)
- [Recipe Bro — import from web and social](https://recipebro.com/import)
- [Best apps that extract recipes from video URLs 2026 — Nutrola](https://nutrola.app/en/blog/best-apps-that-extract-recipes-from-video-urls-2026)
- [SuperCook](https://apps.apple.com/us/app/supercook-ai-meals-scanner/id6743327665)
- [Instacart Developer Platform — shopping list page](https://docs.instacart.com/developer_platform_api/guide/concepts/shopping_list/)
