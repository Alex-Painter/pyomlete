## Overview

Omlete is a full-stack AI-powered recipe management app. Users provide ingredients (text or images) and Claude AI generates/extracts recipes. The app is split into a Python/FastAPI backend (`/server`) and a React/TanStack Start frontend (`/client`), deployed as two separate services on Railway.

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
- **TanStack Query** for server state; routes are in `src/routes/`
- `src/lib/api.ts` — `apiFetch()` wrapper using `VITE_API_URL` env var
- shadcn/ui components (New York style) in `src/components/ui/`
- Route tree auto-generated at `src/routeTree.gen.ts` — do not edit manually
- **Pages:** Lists (`/`), List Detail with Plan/Shop modes (`/list/$listId`), My Recipes (`/recipes`), Recipe Detail (`/recipe/$recipeId`), Create (`/create`: from a link, generate, or extract from images), Settings (`/settings`: shopping categories)
- **Shared components:** `StarRating` (interactive 1-5 stars), `RecipeCard` (recipe display), `RecipeMetaRow` (times, servings and source for imported recipes)

### Backend (`/server/`)

- **FastAPI**, all routes under an `/api` prefix in `main.py`:
  - Recipe creation: `POST /recipes/generate/` (from an ingredient list), `POST /recipes/extract-from-images/` (from photos), `POST /recipes/import-from-url/` (from a link)
  - Recipes: `GET /recipes/`, `GET/PUT/DELETE /recipes/{id}`, `PATCH /recipes/{id}/rating`, `PATCH /recipes/{id}/ingredients/{index}/exclude`, `POST /recipes/suggest/` (AI meal suggestions for a list)
  - Lists: `GET/POST /lists/`, `GET/PATCH/DELETE /lists/{id}`, `POST /lists/{id}/duplicate`, `POST/DELETE /lists/{id}/recipes[/{recipe_id}]`, and item CRUD + reorder under `/lists/{id}/items`
  - Categories and units: `GET/PUT /settings/categories`, `POST /categorize` (cached lookup, then Haiku), `GET /units`
- **Beanie** (async MongoDB ODM) with four document types in `data_models/`: `IngredientDocument` (with 2048-dim Voyage-4 embeddings), `RecipeDocument`, `ListDocument` and `UserSettingsDocument`
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
