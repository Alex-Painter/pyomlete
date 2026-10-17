# AGENTS.md

Guidance for coding agents (Claude Code, Codex and others) working in this repository. `CLAUDE.md` imports this file, so edit here.

## Driving principle

**Eat better and reduce cognitive load.** Better means cooking from scratch more often because lists are easy, and more variety because Omlete proactively suggests new recipes and lists. Less cognitive load means eating better takes less mental energy. Every design and code decision should serve this; see `docs/PRINCIPLES.md` for what it means in practice and `docs/DESIGN.md` for how the app is shaped around it (one-gesture list edits, Undo instead of confirm dialogs, four separate modes that never switch on their own, offline lists, suggestions that learn from ratings).

## Recording decisions

When a project or design discussion settles something (a priority, a product rule, a trade-off), record the decision and the reason for it in `docs/` in the same change, so future work starts from it instead of rediscovering it. Product and UX decisions go in `docs/DESIGN.md` (Context and Decisions); a larger feature gets its own doc, like `docs/PRD_URL_IMPORT.md`. Update or remove an entry when a decision is reversed.

## Overview

Omlete helps people eat better with less effort: it turns recipes (from a link, a description or photos) into shopping lists that are easy to edit and work in the shop with no signal, suggests new meals from your taste, and walks you through cooking. Claude does the recipe extraction and suggestions. The app is split into a Python/FastAPI backend (`/server`) and a React/TanStack Start frontend (`/client`), deployed as two separate services on Railway. A native iOS client is being built in `/ios`.

## Commands

### Frontend (`/client`)
```bash
npm run dev        # Start Vite dev server (port 5173) — needs VITE_API_URL, see below
npm run build      # Production build
npm run test       # Run Vitest tests
npm run lint       # ESLint
npm run check      # Format + auto-fix linting
```

### Backend (`/server`)
```bash
uvicorn main:app --reload --host 127.0.0.1   # Start FastAPI dev server (port 8000)
```
Python 3.12 required (`brew install python@3.12`). Install deps into a venv: `python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt`.

### Running locally

There is no dev proxy. `apiFetch()` requests `${VITE_API_URL}/api/...`; with `VITE_API_URL` unset it fetches a relative `/api/...` from the Vite server, which TanStack Router answers with a 404 page. Vite's `server.proxy` can't fix this, because TanStack Start/Nitro handle requests before Vite's proxy middleware. So for local dev:

- `client/.env`: `VITE_API_URL=http://127.0.0.1:8000`. Use `127.0.0.1`, not `localhost`: `localhost` can resolve to `::1`, where a different process (e.g. a Docker container) may own port 8000. The backend's CORS allowlist accepts both `http://localhost:5173` and `http://127.0.0.1:5173`.
- `server/.env`: see Environment Variables. The production values point at the live Atlas cluster, so for local work set `DB_URI` to a local Mongo instead, e.g. `docker run -d -p 127.0.0.1:27018:27017 mongodb/mongodb-atlas-local:8.0` and `DB_URI=mongodb://127.0.0.1:27018/?directConnection=true`.

Agents: use the `verify-omlete` skill (`.claude/skills/verify-omlete/`). It does all of this, starting a disposable DB and driving the UI in headless Chromium.

## Architecture

### Frontend (`/client/src/`)
- **TanStack Start** (React meta-framework with Nitro SSR) + **TanStack Router** for routing
- **TanStack Query** for server state; routes are in `src/routes/`, shared queries in `src/lib/queries.ts`
- **Home** (`/`) is a stack of sections: meals to cook from the current list, your lists (with New list), then Chef's picks (Chef is the proactive suggestions agent). Recent activity and stats are planned as further sections.
- Four modes, each its own route and layout: **Explore** (`/discover` suggestion feed, `/recipes` library, `/recipe/$id`, `/create`), **Plan** (`/list/$id`), **Shop** (`/shop/$id`, fullscreen, offline) and **Cook** (`/cook/$id`, step by step with timers). Finishing one never navigates to another.
- `src/lib/offline.ts` — every list change goes through a localStorage queue and list snapshots, so lists work with no signal; `public/sw.js` caches the app shell in production
- `src/components/UndoToast.tsx` — destructive actions apply at once with Undo; don't add confirm dialogs
- `src/components/Chef.tsx` — Chef beside every screen: a right sidebar on wide windows, a three-height sheet on phones opened from the Chef tab. `src/lib/chef.ts` reads Chef's stream and undoes its changes
- `src/components/` also holds the iOS-style building blocks (`BottomSheet`, `ListRow`, `ItemSheet`, `QuickAdd`, `AddToListButton`, `SuggestionCard`)
- `src/lib/api.ts` — `apiFetch()` wrapper using `VITE_API_URL` env var
- shadcn/ui components (New York style) in `src/components/ui/`
- Route tree auto-generated at `src/routeTree.gen.ts` — do not edit manually

### Backend (`/server/`)
- **FastAPI**, all routes under an `/api` prefix in `main.py`. Three ways to create a recipe: `POST /recipes/generate/` (from an ingredient list), `POST /recipes/extract-from-images/` (from photos), and `POST /recipes/import-from-url/` (from a link). Each waits for the recipe, which is what the web uses. The iOS app starts the same work as a job instead, because a phone that switches apps drops a long request. The app mints a UUID as the job's key and names it in the start: `PUT /recipe-jobs/{key}/link`, `/recipe-jobs/{key}/describe` and `/recipe-jobs/{key}/photos` take what those three take (photos as one recipe, up to six of up to 5 MB) and answer at once, 202 for a job this call started and 200 for one already there under that key, which starts nothing. `GET /recipe-jobs/{key}` answers `working`, `saved` or `already_imported` with a `recipe_id`, or `failed` with a `failure` of `link_blocked`, `no_recipe_on_page`, `site_did_not_respond` or `other`, and 404 for a key never started. A fifth job while four are working is answered 429. A job runs the same `services.recipes` function as the endpoint a waiting client calls, so change the creation code in one place. On shutdown the server cancels the jobs it is running and writes them as failed. The rest is CRUD for recipes, lists, list items and categories (`PUT /settings/categories` takes the whole aisle list and stores it cleaned: names trimmed, empty ones and later repeats in any case dropped, never a 422 for those), plus Discover suggestions: `POST /suggestions/` is where an agent drops suggestion cards, `POST /suggestions/refresh` asks Claude for new ones from the user's taste (ratings, dismissals, recent lists), `POST /suggestions/{id}/save` turns one into a recipe in the background (under the recipe jobs' time limit; a card still `saving` six minutes after its save began is answered as `failed`, and can then be saved again or cleared; starting a save and ending it are conditional updates on the card's `status` and `saving_since`, so write a card's save state that way and never with a whole-document `save()`), and `POST /suggestions/clear` hides cards without it counting as a dismissal (with `only_new`, which the iOS Home sends, it takes only cards still `new` on the server). Routes stay thin: they shape requests and responses and call `services/`.
- `services/` — what the routes do, shared with Chef's tools: `recipes.py` (generate, from photos, URL import, edits), `lists.py` (lists, the recipe-to-items merge, items) and `settings.py` (aisle order, categorize). Errors are `HTTPException` subclasses in `services/errors.py` (`NotFound`, `Invalid`, `AlreadyImported`…), so routes pass them through and tools can tell them apart
- **Beanie** (async MongoDB ODM) with seven document types in `data_models/`: `IngredientDocument` (with 2048-dim Voyage-4 embeddings), `RecipeDocument`, `ListDocument`, `UserSettingsDocument`, `SuggestionDocument`, `RecipeJobDocument` and `ChefActionDocument`
- `chef/` — Chef, the suggestions agent, on Pydantic AI. `chef/discover.py` builds the taste profile and runs Refresh. `chef/chat.py` is Chef in chat (`POST /chef/chat`, streamed in the AI SDK's format): its tools change data through `services/` and record each change in `chef/actions.py`, which `POST /chef/actions/{id}/undo` puts back. A route that changes data needs a matching tool, or `tests/test_chef_parity.py` fails. See `docs/PRD_CHEF.md` for where it is going
- `tools.py` — defines the `find_similar_ingredients` Claude tool, which runs a MongoDB `$vectorSearch` to find semantically similar existing ingredients (threshold ≥ 0.9)
- `recipe_import.py` — SSRF-guarded page fetch + `recipe-scrapers` parsing (stage 1 of URL import)
- `ingredient_structurer.py` — Haiku pass that turns free-text ingredient lines into structured ingredients (stage 2 of URL import)
- `lib/db.py` — MongoDB connection (Motor) and Voyage AI client setup

### AI / Data Flow

Generate and extract both go straight to Opus:
1. Request hits FastAPI → images encoded to base64 if needed
2. Claude Opus 4.5 called with system prompt + `find_similar_ingredients` tool
3. Claude generates structured JSON recipe, calling the tool for ingredient lookups
4. New ingredients embedded via Voyage AI and saved to MongoDB
5. Recipe document saved and returned as JSON

URL import is two stages, and the cheap one does most of the work:
1. `recipe_import.fetch_page()` fetches the page behind an SSRF guard, `scrape()` reads its schema.org data — title, instructions, image, times, servings. No tokens.
2. `ingredient_structurer.structure_ingredients()` splits the free-text ingredient lines into name/amount/unit on Haiku, calling `find_similar_ingredients` to canonicalise
3. Pages that publish no structured data fall back to Opus over the page text
4. Saved via the same `services.recipes.save()` path as everything else, plus a `RecipeMetadata` carrying the provenance

See `docs/PRD_URL_IMPORT.md` for the design and what's still outstanding.

### Deployment
- `railway.json` defines two Railway services: `omlete-api` (Python) and `omlete-client` (Node)
- Frontend uses `VITE_API_URL` at build time to point to the backend service URL

## Environment Variables

**Backend** (`.env` in `/server/`). Production values live in Railway project `courageous-enjoyment`, service `omlete-api` (`railway link`, then `railway variables --service omlete-api --kv`):

- `ANTHROPIC_API_KEY`
- `VOYAGE_API_KEY`
- `DB_USER`, `DB_PASS`: credentials for the production Atlas cluster. Or set `DB_URI`, which takes precedence. **Local dev against these reads and writes real data.**

**Frontend**: `VITE_API_URL`, the base URL for API calls. Required in dev too (`http://127.0.0.1:8000`; see Running locally). On Railway it's set to the API service URL at build time.

## iOS app (`/ios`)

A native SwiftUI client lives in `ios/` (Xcode project at `ios/Omlete/Omlete.xcodeproj`). It has its own rules, build tooling and prohibitions: read `ios/CLAUDE.md` before touching anything there. The web routes in `client/src/routes` are the spec for each iOS screen.

## shadcn Components

Install new shadcn components with:
```bash
npx shadcn@latest add <component>
```
