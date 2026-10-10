---
name: verify-omlete
description: Launch the real Omlete stack locally (FastAPI on 127.0.0.1:8000, TanStack Start web on 127.0.0.1:5173, disposable Atlas-local Mongo) and drive it in headless Chromium to prove a change works, with screenshots, ARIA snapshots and API logs as evidence. Use whenever you need to show that a UI or API change in /client or /server actually behaves, not just compiles. A plain `npm run dev` + `uvicorn main:app` does not work out of the box, so use this instead.
---

# Verify Omlete

Omlete is a recipe and shopping-list web app: a client-rendered React SPA (`/client`, TanStack Start under Vite) that talks to a FastAPI backend (`/server`) over `/api/...`, with Beanie on MongoDB. Users touch the browser UI, and that is the surface to verify. The API is the second surface, for checking side effects.

Everything below goes through one helper. All paths are relative to the repo root:

```bash
V=.claude/skills/verify-omlete/scripts/omlete-verify
```

## Launch

```bash
$V setup     # idempotent: Python 3.12 venv in server/.venv, npm ci, Playwright in .verify-run/tools
$V up        # Mongo container, API, web; returns only once all three answer
$V doctor    # must print no FAIL lines before you drive anything
$V seed      # known fixtures (local DB only; idempotent)
```

What `up` does, and why a plain dev start fails:

- **Python 3.12 exactly.** `setup` looks for `python3.12` and accepts no other version (the backend targets 3.12). If it's missing, install it with `brew install python@3.12` on macOS, or `apt install python3.12 python3.12-venv` / `uv python install 3.12` on Linux.
- **Database: a disposable local Mongo by default.** `up` runs `mongodb/mongodb-atlas-local:8.0` as container `omlete-verify-mongo` on `127.0.0.1:27018` and exports `DB_URI` to it. An exported variable beats `server/.env` (`load_dotenv` never overrides), so a production `DB_URI` in `.env` is never used here. The atlas-local image is used because `tools.py` runs `$vectorSearch`, which plain `mongo` doesn't support. If Docker isn't running, `up` starts `dockerd` itself when it runs as root on Linux (cloud containers); on a laptop, start Docker Desktop or colima yourself.
- **API keys are optional for CRUD.** `main.py` builds the Anthropic and Voyage clients at import time. When neither the environment nor `server/.env` has a key, `up` exports a placeholder so the API boots. Every page except the AI paths then works (see `features/ai-recipe-creation.md`).
- **The frontend needs `VITE_API_URL`.** With it unset, `apiFetch('/api/...')` is a relative fetch against Vite itself, and TanStack's router answers it with a 307 and then a 404 HTML page. There is no dev proxy: `server.proxy` in `vite.config.ts` doesn't work in this stack, because TanStack Start and Nitro handle every request before Vite's proxy middleware runs. `up` exports `VITE_API_URL=http://127.0.0.1:8000`, and an exported `VITE_*` overrides `client/.env`.
- **127.0.0.1, never localhost.** On at least one dev machine `localhost` resolved to `::1`, where an unrelated Docker container held port 8000 and answered with a bogus 503; uvicorn binds IPv4 only. Every URL here is explicit IPv4, and `doctor` warns when `localhost:8000` is answered by something other than our uvicorn. The backend CORS allowlist names both `http://localhost:5173` and `http://127.0.0.1:5173`, so the web port is fixed at 5173.
- **Ready means:** `GET http://127.0.0.1:8000/api/recipes/` returns 200, and `GET http://127.0.0.1:5173/` returns 200. Logs are in `.verify-run/api.log` and `.verify-run/web.log`.

### Using real keys or the production DB (opt-in only)

Real secrets live in Railway project `courageous-enjoyment`, service `omlete-api`:

```bash
railway link            # choose courageous-enjoyment and its environment
railway variables --service omlete-api --kv > server/.env
```

That file contains `ANTHROPIC_API_KEY`, `VOYAGE_API_KEY` and the production `DB_URI` / `DB_USER` / `DB_PASS`. In the default `local` mode, `up` takes only the keys from it and still points the API at the local container, which is the safe way to exercise the AI paths.

**`OMLETE_VERIFY_DB=env` points the API at the live production Atlas cluster.** Every rating, edit, list or delete lands in real user data. `up` refuses it unless you also set `OMLETE_VERIFY_I_KNOW_THIS_IS_PROD=1`, and `seed` refuses it unconditionally. Don't use it for verification. If you're ever told to, drive read-only.

### Isolation

Only one instance runs at a time: ports 8000, 5173 and 27018 are fixed. `up` refuses to start when something it didn't start already answers on 8000 or 5173, because that is someone's dev session and driving it would mix your writes into their data. Free the port rather than reusing the process.

## Doctor

`$V doctor` is read-only and exits non-zero on any `FAIL`. It checks:

- the PID files for the API and web processes started by `up`
- that `127.0.0.1:8000` answers with `server: uvicorn` and a 200 on `/api/recipes/`
- that `127.0.0.1:5173/recipes` serves the HTML shell titled `Omlete`
- the CORS preflight for origin `http://127.0.0.1:5173`
- the health of the Mongo container
- whether `localhost:8000` is shadowed by something else (IPv6 warning)

Run it before the first drive and again after any drive that fails unexpectedly.

## Drive

```bash
$V browse <path> [steps...] [--label NAME]
```

`browse` opens `http://127.0.0.1:5173<path>` in headless Chromium and waits for network idle. That wait matters: the HTML is SSR'd, so buttons exist before React hydrates, and an earlier click is silently dropped. It then runs the steps in order:

| step | meaning |
|---|---|
| `--expect TEXT` | wait (20s) until TEXT is visible |
| `--absent TEXT` | TEXT must not be visible |
| `--click-link NAME` / `--click-button NAME` | click by ARIA role and accessible name |
| `--fill NAME=VALUE` | fill a textbox by accessible name or placeholder |
| `--click-sel SEL` / `--fill-sel 'SEL=>VALUE'` | Playwright selector, only for controls with no accessible name (star ratings, icon buttons, the edit-title input) |
| `--press KEY` | press a key in the focused element, e.g. `Enter` |
| `--expect-url REGEX` | wait until the URL pathname matches |
| `--timeout MS` | per-step timeout for the steps after it (default 20000; AI calls need ~120000) |
| `--accept-dialogs` | auto-accept `confirm()` from now on (the app no longer uses `confirm()`: deletes use an Undo toast, so this is rarely needed) |

The run **fails** if any step fails, if any `/api/` request goes to an origin other than `http://127.0.0.1:8000` (that catches a missing `VITE_API_URL`), or if any `/api/` response is a 4xx/5xx or a network failure. A backend 500 appears in the browser as `net::ERR_FAILED`, as if it were CORS, because Starlette's error response carries no CORS headers. When you see that, read `.verify-run/api.log` for the traceback.

For example, the canonical smoke test of the app working end to end:

```bash
$V seed
curl -s http://127.0.0.1:8000/api/recipes/        # backend directly: both fixture titles present
$V browse /recipes --expect "Recipes" \
  --expect "Verify Fixture Shakshuka" --expect "Verify Fixture Lemon Drizzle Cake"
```

A 200 on `/recipes` proves nothing, because the shell is served even when every API call fails. Only the rendered fixture titles prove the page fetched data.

Check side effects through the API, not just the UI. For example, after adding an item to a list, `curl -s http://127.0.0.1:8000/api/lists/<id>` must show it. For the per-feature recipes, read [`features/README.md`](features/README.md).

## Evidence

Each `browse` run writes `verify-artifacts/<timestamp>-<label>/` (gitignored):

- `NN-<step>.png` and `NN-<step>.aria.txt`: the state after every step
- `final.png` and `final.aria.txt`
- `run.log`: the URL, PASS/FAIL, the steps, every `/api` call with its status, and any problems

Proof standards:

- Drive the real user path (nav links, buttons, forms), not test-only endpoints.
- Capture the action and the resulting state.
- For mutations, add a read-only second view: the API JSON, or a reload of a different page.
- Seeding fixtures straight into Mongo is setup, never proof of a feature.

`OMLETE_VERIFY_EVIDENCE_DIR` overrides the evidence location.

## Cleanup

```bash
$V down              # stops the web and API processes started by `up` (by PID file), removes the Mongo container
$V down --keep-db    # same, but keeps the container and its data for the next `up`
```

`down` kills only PIDs from `.verify-run/*.pid`. Never `pkill -f vite` / `pkill -f uvicorn`: a pattern can match the user's own dev servers, and even your own shell, whose command line contains the pattern. `down` leaves `dockerd` running if `up` started it, and never touches `verify-artifacts/`. Run `down` after every failed iteration too, so stale processes don't hold the ports.

## Helpers

All of these live in `.claude/skills/verify-omlete/scripts/`:

- `omlete-verify`: the entry point above. Run it with no arguments for usage.
- `seed.py <mongo-uri> [--clear]` is run by `$V seed`. It inserts the two `Verify Fixture ...` recipes, plus cached ingredient categories for `milk` and `bananas`, so `POST /api/categorize` answers from Mongo instead of calling Claude. `--clear` removes them.
- `browse.mjs` is run by `$V browse`. It uses Playwright 1.56.1 from `.verify-run/tools`; `setup` downloads Chromium only when that version's browser is missing.
