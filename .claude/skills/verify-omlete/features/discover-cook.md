# Discover and Cook

Discover (`/discover`) is a feed of suggestion cards grouped into shelves, filled by Chef (the proactive suggestions agent) through `POST /api/suggestions/` or by `Refresh` (`POST /api/suggestions/refresh`, which calls Claude). Each card can be saved as a recipe, added to a list, or dismissed with `Not for me`. Cook (`/cook/<recipeId>`) walks through a recipe step by step with scaled amounts and detected timers, and ends with a rating that feeds future suggestions.

## Sub-features

- `home-chef-picks` shows Chef's three newest picks on Home, below Lists, with `See all` going to Discover.
- `discover-feed` shows shelves of cards from `GET /api/suggestions/`, with skeletons while loading and an empty state.
- `discover-tune` opens `Tune suggestions` (diet, effort, free-text notes), stored on the phone and sent with Refresh.
- `discover-save` uses `Save`; `POST /api/suggestions/<id>/save` returns at once and the recipe is made in the background (the card shows saving, then saved or failed).
- `discover-dismiss` uses `Not for me`; the card hides with an Undo toast and the PATCH is sent when the toast expires. It is a taste signal: Chef avoids similar ideas.
- `discover-clear` uses `Clear all` on Discover or `Clear` beside Chef's picks on Home. Every visible card hides with an Undo toast, then `POST /api/suggestions/clear` sets them to `cleared`. Unlike `Not for me`, Chef learns nothing from it.
- `cook-overview` shows servings (scales every amount) and ingredients; `?servings=` and `?step=` are in the URL.
- `cook-steps` shows one step at a time with `For this step` ingredients and a `Start mm:ss timer` button for any time in the text.
- `cook-finish` ends on `How was it?` with a star rating saved to the recipe.

## How to get to it (user POV)

- The `Discover` tab or nav link, or `See all` beside Chef's picks on Home.
- Home's `Cook from <list>` cards, a recipe page's `Cook` button, or `Cook` on a meal in a list.

## Driving it with omlete-verify browse

Preconditions: seed suggestions with the API, since Refresh needs a real key:

```bash
curl -s -X POST http://127.0.0.1:8000/api/suggestions/ -H 'Content-Type: application/json' \
  -d '{"suggestions":[{"title":"Miso salmon with greens","reason":"Ready in 20 minutes","total_minutes":20,"section":"Under 30 minutes"}]}'
```

- **Feed and dismiss.** Run `$V browse /discover --label discover-dismiss --expect "Miso salmon with greens" --click-button "Not for me" --expect "Undo"`. After the toast, `curl -s http://127.0.0.1:8000/api/suggestions/` no longer lists it.
- **Clear all.** Run `$V browse /discover --label discover-clear-all --expect "Miso salmon with greens" --click-button "Clear all" --expect "Cleared" --absent "Miso salmon with greens"`. Wait for the toast to expire before checking `GET /api/suggestions/`; the browser closing first skips the request.
- **Cook a seeded recipe.** Run `$V browse /recipes --label recipe-cook --click-link "Verify Fixture Shakshuka" --expect-url '^/recipe/' --click-link "Cook" --expect-url '^/cook/' --click-button "Start cooking" --expect "Step 1 of 3" --click-button "Next" --expect "Start 10:00 timer"`. The last step ends on `How was it?`.
- **Cook from Home.** With the Shakshuka on the current list (the last list opened, else the newest), Home shows `Cook from <list>` and a `Cook Verify Fixture Shakshuka` link straight to `/cook/<id>?list=<id>`.

## Gotchas

- `Refresh` and `Save` on a card with no `source_url` need `ANTHROPIC_API_KEY`; with the placeholder key Refresh 500s and Save ends in `failed`.
- Suggestions live in their own `suggestions` collection, which `$V seed` doesn't reset.
