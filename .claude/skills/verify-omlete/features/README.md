# Omlete verification map

This directory is the maintained source for verifying Omlete's user-facing behavior. Read this index before driving the app, then use the matching feature file as the recipe. Launch, doctor, evidence and cleanup are in [`../SKILL.md`](../SKILL.md).

## Baseline preconditions

- `$V up` has run in the default `local` DB mode, and `$V doctor` prints no `FAIL` (`V=.claude/skills/verify-omlete/scripts/omlete-verify`).
- `$V seed` has run since the last mutation. It is idempotent: it resets the two `Verify Fixture ...` recipes and the cached `milk` / `bananas` categories, but leaves lists and category edits in place.
- The web app is at `http://127.0.0.1:5173` and the API at `http://127.0.0.1:8000`. Never use `localhost`.
- Never drive an instance that `$V up` didn't start, and never drive the production DB (`OMLETE_VERIFY_DB=env`).

## Driving conventions

- Every UI action goes through `$V browse <path> [steps]`. Start from a nav path (`/`, `/discover`, `/recipes`, `/create`, `/settings`) and click through, rather than deep-linking an id, unless the recipe says otherwise.
- Prefer `--click-link` / `--click-button` / `--fill` (ARIA role and accessible name, or placeholder). Use `--click-sel` / `--fill-sel` only where a control has no accessible name; each feature file says where.
- For mutations, follow the UI run with a read-only API check (`curl -s http://127.0.0.1:8000/api/...`).

## Proof and skip reporting

- A PASS line from `browse`, plus its `verify-artifacts/<stamp>-<label>/` folder (step screenshots, ARIA snapshots, `run.log` with every `/api` call and its status).
- Mutation proof also includes the API JSON showing the stored value.
- Name the feature file and entry point used with each artifact.
- A path needing real API keys is reported as unreachable along with the unmet precondition (`ANTHROPIC_API_KEY` / `VOYAGE_API_KEY` not set). Never report it as verified through a different path.

## Feature entry contract

Each feature file has an H1, a one-paragraph description, and then four H2s in this order: `Sub-features`, `How to get to it (user POV)`, `Driving it with omlete-verify browse`, and `Gotchas`.

## Features

The app is organised by the four modes in `docs/PRINCIPLES.md` (Explore, Plan, Shop, Cook), plus Home and Settings.

- [Shopping lists](./shopping-lists.md): Home (`/`: Cook from your list, Lists, Chef's picks) plus Plan and Shop. Create a list, quick-add and paste items, edit in a sheet, delete with Undo, shop offline. No key needed.
- [Discover and Cook](./discover-cook.md): Chef's suggestion cards (save, add to list, dismiss) and step-by-step cooking with timers and a rating. Refresh needs real keys.
- [Recipe library](./recipes.md): search, open, rate, add to a list, edit and delete recipes. No API key needed.
- [Settings: aisles](./settings-categories.md): add, rename, reorder and delete aisles. No API key needed.
- [Add a recipe](./ai-recipe-creation.md): one field for a link or a description, or photos. **Needs real keys.**
