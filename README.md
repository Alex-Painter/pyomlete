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
- **Pages:** Create (`/`), My Recipes (`/recipes`), Recipe Detail (`/recipe/$recipeId`), Meal Plan (`/meal-plan`)
- **Shared components:** `StarRating` (interactive 1-5 stars), `RecipeCard` (recipe display)

### Backend (`/server/`)

- **FastAPI** with endpoints for recipe CRUD, rating, and meal planning:
  - `POST /recipes/generate/` and `POST /recipes/extract-from-images/` — AI-powered recipe creation
  - `GET /recipes/` — list all recipes (summary)
  - `GET /recipes/{id}` — full recipe detail
  - `PATCH /recipes/{id}/rating` — update star rating (1-5)
  - `POST /meal-plan/suggest/` — suggest random recipes for a meal plan
  - `POST /meal-plan/shopping-list/` — generate combined shopping list from selected recipes
- **Beanie** (async MongoDB ODM) with two document types in `data_models/`: `IngredientDocument` (with 2048-dim Voyage-4 embeddings) and `RecipeDocument`
- `tools.py` — defines the `find_similar_ingredients` Claude tool, which runs a MongoDB `$vectorSearch` to find semantically similar existing ingredients (threshold ≥ 0.9)
- `lib/db.py` — MongoDB connection (Motor) and Voyage AI client setup

### AI / Data Flow

1. Request hits FastAPI → images encoded to base64 if needed
2. Claude Opus 4.5 called with system prompt + `find_similar_ingredients` tool
3. Claude generates structured JSON recipe, calling the tool for ingredient lookups
4. New ingredients embedded via Voyage AI and saved to MongoDB
5. Recipe document saved and returned as JSON

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
