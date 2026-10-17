# Omlete

## Driving principle

**Eat better and reduce cognitive load.** Better means cooking from scratch more often because lists are easy, and more variety because Omlete proactively suggests new recipes and lists. Less cognitive load means eating better takes less mental energy. Every design and code decision should serve this; see `docs/PRINCIPLES.md` for what it means in practice (one-gesture list edits, Undo instead of confirm dialogs, four separate modes that never switch on their own, offline lists, suggestions that learn from ratings).

## Overview

Omlete helps people eat better with less effort: it turns recipes (from a link, a description or photos) into shopping lists that are easy to edit and work in the shop with no signal, suggests new meals from your taste, and walks you through cooking. Claude does the recipe extraction and suggestions. The app is split into a Python/FastAPI backend (`/server`) and a React/TanStack Start frontend (`/client`), deployed as two separate services on Railway.

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
- Four modes, each its own route and layout: **Explore** (`/discover` suggestion feed, `/recipes` library, `/recipe/$id`, `/create`), **Plan** (`/list/$id`), **Shop** (`/shop/$id`, fullscreen, offline) and **Cook** (`/cook/$id`, step by step with timers). Finishing one never navigates to another.
- `src/lib/offline.ts` — every list change goes through a localStorage queue and list snapshots, so lists work with no signal; `public/sw.js` caches the app shell in production
- `src/components/UndoToast.tsx` — destructive actions apply at once with Undo; don't add confirm dialogs
- `src/components/` also holds the iOS-style building blocks (`BottomSheet`, `ListRow`, `ItemSheet`, `QuickAdd`, `AddToListButton`, `SuggestionCard`)
- `src/lib/api.ts` — `apiFetch()` wrapper using `VITE_API_URL` env var
- shadcn/ui components (New York style) in `src/components/ui/`
- Route tree auto-generated at `src/routeTree.gen.ts` — do not edit manually
- **Home** (`/`) is a stack of sections: meals to cook from the current list, your lists (with New list), then Chef's picks (Chef is the proactive suggestions agent). Recent activity and stats are planned as further sections.
- **Other pages:** Settings (`/settings`, behind the cog: shopping aisles). Shared components include `StarRating`, `RecipeCard`, `RecipeThumb` and `RecipeMetaRow`.

### Backend (`/server/`)

- **FastAPI**, all routes under an `/api` prefix in `main.py`:
  - Recipe creation: `POST /recipes/generate/` (from an ingredient list), `POST /recipes/extract-from-images/` (from photos), `POST /recipes/import-from-url/` (from a link)
  - Recipes: `GET /recipes/`, `GET/PUT/DELETE /recipes/{id}`, `PATCH /recipes/{id}/rating`, `PATCH /recipes/{id}/ingredients/{index}/exclude`
  - Lists: `GET/POST /lists/`, `GET/PATCH/DELETE /lists/{id}`, `POST /lists/{id}/duplicate`, `POST/DELETE /lists/{id}/recipes[/{recipe_id}]`, and item CRUD + reorder under `/lists/{id}/items`
  - Categories and units: `GET/PUT /settings/categories`, `POST /categorize` (cached lookup, then Haiku), `GET /units`
  - Discover suggestions from Chef: `GET/POST /suggestions/` (`POST` is where an agent drops suggestion cards), `POST /suggestions/refresh` (Claude suggests from your ratings, dismissals and lists), `PATCH /suggestions/{id}` (dismiss, a taste signal), `POST /suggestions/clear` (hide cards, not a taste signal), `POST /suggestions/{id}/save` (turn one into a recipe in the background)
- **Beanie** (async MongoDB ODM) with five document types in `data_models/`: `IngredientDocument` (with 2048-dim Voyage-4 embeddings), `RecipeDocument`, `ListDocument`, `UserSettingsDocument` and `SuggestionDocument`
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
4. Saved via the same `_save_recipe()` path as everything else, plus a `RecipeMetadata` carrying the provenance

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

## shadcn Components

Install new shadcn components with:

```bash
npx shadcn@latest add <component>
```
