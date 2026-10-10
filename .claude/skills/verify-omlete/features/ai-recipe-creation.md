# AI recipe creation

The Create page turns user input into a saved recipe: a list of ingredients is generated into a recipe by Claude Opus, photos of a recipe are extracted by Claude, or a recipe URL is imported (schema.org scrape, with Haiku structuring the ingredients and Opus as a fallback). New ingredients are embedded with Voyage and canonicalised through `$vectorSearch`.

## Sub-features

- `create-generate` generates a recipe from free-text ingredients (`POST /api/recipes/generate/`).
- `create-extract` extracts a recipe from uploaded photos (`POST /api/recipes/extract-from-images/`).
- `create-import-url` imports from a link (`POST /api/recipes/import-from-url/`). The same URL is not imported twice (lookup by `source_url`).

## How to get to it (user POV)

- The `Create` link in the top nav goes to `/create`, headed `Create Recipe`.
- Three tab buttons: `From link` (the default), `Generate` and `Extract from Images`.
- Generate: the textarea with placeholder `e.g. eggs, crème fraîche, salt, pepper, chives...`, then the `Generate Recipe` button.
- From link: the URL field with placeholder `https://www.bbcgoodfood.com/recipes/...`.

## Driving it with omlete-verify browse

Preconditions:

- **Real `ANTHROPIC_API_KEY` and `VOYAGE_API_KEY`** in `server/.env` or the environment before `$V up`. See "Using real keys" in `../SKILL.md`; keep the default `local` DB mode.
- Without them, report this feature as `verified-unreachable: no ANTHROPIC_API_KEY/VOYAGE_API_KEY`.
- Import also needs outbound internet to the recipe site.

- **Page renders.** This works without keys. Run `$V browse /create --expect "Create Recipe"`.
- **Generate.** Run `$V browse /create --label create-generate --click-button Generate --fill "e.g. eggs, crème fraîche, salt, pepper, chives...=eggs, spinach, feta" --timeout 120000 --click-button "Generate Recipe" --expect "Ingredients"`. A recipe card renders inline under the button; the page does not navigate. Then `curl -s http://127.0.0.1:8000/api/recipes/` shows a new non-fixture recipe at the top.
- **Without keys (expected failure).** The same command FAILs, with `PROBLEM: API request failed ... /api/recipes/generate/ net::ERR_FAILED`, and `.verify-run/api.log` shows `anthropic.AuthenticationError`. Verified in this state; useful as a negative control.

## Gotchas

- With the placeholder keys the API still boots, but these endpoints return 500 with `anthropic.AuthenticationError` in `.verify-run/api.log`.
- The local atlas-local DB starts with no Atlas Search / vector index, and nothing in the repo creates one. How `find_similar_ingredients` behaves there (an empty result, or an error the model sees) is not yet verified. Record it here after the first keyed run. Ingredient canonicalisation is out of scope until then.
- Each successful run spends real API tokens and writes new `ingredients` documents. Run against the local DB only.
- The page opens on `From link`, so click the `Generate` tab first. Role names match by substring, and `first()` picks the tab because it precedes `Generate Recipe` in the DOM.
