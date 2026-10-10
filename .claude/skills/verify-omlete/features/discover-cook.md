# Discover and Cook

Discover (`/discover`) is a feed of suggestion cards grouped into shelves, filled by an agent through `POST /api/suggestions/` or by `Refresh` (`POST /api/suggestions/refresh`, which calls Claude). Each card can be saved as a recipe, added to a list, or dismissed with `Not for me`. Cook (`/cook/<recipeId>`) walks through a recipe step by step with scaled amounts and detected timers, and ends with a rating that feeds future suggestions.

## Sub-features

- `discover-feed` shows shelves of cards from `GET /api/suggestions/`, with skeletons while loading and an empty state.
- `discover-tune` opens `Tune suggestions` (diet, effort, free-text notes), stored on the phone and sent with Refresh.
- `discover-save` uses `Save`; `POST /api/suggestions/<id>/save` returns at once and the recipe is made in the background (the card shows saving, then saved or failed).
- `discover-dismiss` uses `Not for me`; the card hides with an Undo toast and the PATCH is sent when the toast expires.
- `cook-overview` shows servings (scales every amount) and ingredients; `?servings=` and `?step=` are in the URL.
- `cook-steps` shows one step at a time with `For this step` ingredients and a `Start mm:ss timer` button for any time in the text.
- `cook-finish` ends on `How was it?` with a star rating saved to the recipe.

## How to get to it (user POV)

- The `Discover` tab or nav link.
- A recipe page's `Cook` button, or `Cook` on a meal in a list.

## Driving it with omlete-verify browse

Preconditions: seed suggestions with the API, since Refresh needs a real key:

```bash
curl -s -X POST http://127.0.0.1:8000/api/suggestions/ -H 'Content-Type: application/json' \
  -d '{"suggestions":[{"title":"Miso salmon with greens","reason":"Ready in 20 minutes","total_minutes":20,"section":"Under 30 minutes"}]}'
```

- **Feed and dismiss.** Run `$V browse /discover --label discover-dismiss --expect "Miso salmon with greens" --click-button "Not for me" --expect "Undo"`. After the toast, `curl -s http://127.0.0.1:8000/api/suggestions/` no longer lists it.
- **Cook a seeded recipe.** Open `/recipes`, click `Verify Fixture Shakshuka`, then `Cook`. Expect `Step 1 of 3`, `Next`, a `Start 10:00 timer` on step 2, and `How was it?` at the end.

## Gotchas

- `Refresh` and `Save` on a card with no `source_url` need `ANTHROPIC_API_KEY`; with the placeholder key Refresh 500s and Save ends in `failed`.
- Suggestions live in their own `suggestions` collection, which `$V seed` doesn't reset.
