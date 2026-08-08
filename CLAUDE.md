# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Omlete is a full-stack AI-powered recipe management app. Users provide ingredients (text or images) and Claude AI generates/extracts recipes. The app is split into a Python/FastAPI backend (`/server`) and a React/TanStack Start frontend (`/client`), deployed as two separate services on Render.com.

## Commands

### Frontend (`/client`)
```bash
npm run dev        # Start Vite dev server (port 5173, proxies /api → localhost:8000)
npm run build      # Production build
npm run test       # Run Vitest tests
npm run lint       # ESLint
npm run check      # Format + auto-fix linting
```

### Backend (`/server`)
```bash
uvicorn main:app --reload   # Start FastAPI dev server (port 8000)
```
Python 3.12 required. Install deps: `pip install -r requirements.txt`.

## Architecture

### Frontend (`/client/src/`)
- **TanStack Start** (React meta-framework with Nitro SSR) + **TanStack Router** for routing
- **TanStack Query** for server state; routes are in `src/routes/`
- `src/lib/api.ts` — `apiFetch()` wrapper using `VITE_API_URL` env var
- shadcn/ui components (New York style) in `src/components/ui/`
- Route tree auto-generated at `src/routeTree.gen.ts` — do not edit manually

### Backend (`/server/`)
- **FastAPI**, all routes under an `/api` prefix in `main.py`. Three ways to create a recipe: `POST /recipes/generate/` (from an ingredient list), `POST /recipes/extract-from-images/` (from photos), and `POST /recipes/import-from-url/` (from a link). The rest of the file is CRUD for recipes, lists, list items and categories.
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
- `render.yaml` defines two Render services: `omlete-api` (Python) and `omlete-client` (Node)
- Frontend uses `VITE_API_URL` at build time to point to the backend service URL

## Environment Variables

**Backend** (`.env` in `/server/`):
- `ANTHROPIC_API_KEY`
- `VOYAGE_API_KEY`
- `DB_USER`, `DB_PASS` — MongoDB credentials

**Frontend**: `VITE_API_URL` — base URL for API calls (empty in dev, set on Render for prod)

## shadcn Components

Install new shadcn components with:
```bash
npx shadcn@latest add <component>
```
