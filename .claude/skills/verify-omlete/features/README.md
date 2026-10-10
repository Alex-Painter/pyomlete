# Omlete verification map

This directory is the maintained source for verifying Omlete's user-facing behavior. Read this index before driving the app, then use the matching feature file as the recipe. Launch, doctor, evidence and cleanup are in [`../SKILL.md`](../SKILL.md).

## Baseline preconditions

- `$V up` has run in the default `local` DB mode, and `$V doctor` prints no `FAIL` (`V=.claude/skills/verify-omlete/scripts/omlete-verify`).
- `$V seed` has run since the last mutation. It is idempotent: it resets the two `Verify Fixture ...` recipes and the cached `milk` / `bananas` categories, but leaves lists and category edits in place.
- The web app is at `http://127.0.0.1:5173` and the API at `http://127.0.0.1:8000`. Never use `localhost`.
- Never drive an instance that `$V up` didn't start, and never drive the production DB (`OMLETE_VERIFY_DB=env`).

## Driving conventions

- Every UI action goes through `$V browse <path> [steps]`. Start from a nav path (`/`, `/recipes`, `/create`, `/settings`) and click through, rather than deep-linking an id, unless the recipe says otherwise.
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

- [Recipe library](./recipes.md): list, open, rate, edit and delete saved recipes. No API key needed.
- [Shopping lists](./shopping-lists.md): create a list, quick-add items (auto-categorised), view by category. No key is needed for seeded item names.
- [Settings: categories](./settings-categories.md): add, rename, reorder and delete shopping categories. No API key needed.
- [AI recipe creation](./ai-recipe-creation.md): generate from ingredients, extract from photos, import from a URL. **Needs real keys.**
