# Recipe library

The recipe library lets a user see every saved recipe on My Recipes, open one to read its ingredients and steps, rate it with 1–5 stars, edit its title, ingredients and steps, and delete it.

## Sub-features

- `recipes-list` shows every saved recipe, newest first, with its ingredient count, time and rating.
- `recipes-view-toggle` switches between the list and grid layouts (remembered in localStorage).
- `recipe-open` opens a recipe's detail page from its title link.
- `recipe-rate` sets a 1–5 star rating from the list or the detail page.
- `recipe-edit` edits the title, ingredients and steps, then saves.
- `recipe-delete` deletes after a `confirm()` and returns to My Recipes.

## How to get to it (user POV)

- The `Recipes` link in the top nav (desktop), or the bottom tab bar (mobile), goes to `/recipes`, headed `My Recipes`.
- A recipe's title link goes to `/recipe/<id>`. `Back to recipes` returns.
- On the detail page: the `Edit` button (then `Save` / `Cancel`), the `Delete` button, and the star row next to `Rate`.

## Driving it with omlete-verify browse

Preconditions:

- `$V seed` just ran: `Verify Fixture Shakshuka` (rated 4, 25 min) and `Verify Fixture Lemon Drizzle Cake` (unrated) exist.

- **List renders real data.** Run `$V browse /recipes --expect "My Recipes" --expect "Verify Fixture Shakshuka" --expect "Verify Fixture Lemon Drizzle Cake"`. PASS, and `run.log` shows `GET http://127.0.0.1:8000/api/recipes/ -> 200`. Cross-check with `curl -s http://127.0.0.1:8000/api/recipes/`.
- **Open a recipe.** Run `$V browse /recipes --label recipe-open --click-link "Verify Fixture Shakshuka" --expect-url '^/recipe/' --expect "chopped tomatoes" --expect "Make wells, crack in the eggs"`. The detail page shows ingredients and steps.
- **Rate.** Run `$V browse /recipes --label recipe-rate --click-link "Verify Fixture Lemon Drizzle Cake" --expect-url '^/recipe/' --expect "self-raising flour" --click-sel 'button:has(.lucide-star) >> nth=2'`. Then `curl -s http://127.0.0.1:8000/api/recipes/` shows the cake with `"rating": 3`.
- **Edit the title.** Run `$V browse /recipes --label recipe-edit --click-link "Verify Fixture Shakshuka" --expect-url '^/recipe/' --click-button Edit --fill-sel 'input >> nth=0=>Verify Fixture Shakshuka (edited)' --click-button Save --expect "Verify Fixture Shakshuka (edited)"`. The API list shows the new title.
- **Delete.** Run `$V browse /recipes --label recipe-delete --click-link "Verify Fixture Lemon Drizzle Cake" --expect-url '^/recipe/' --accept-dialogs --click-button Delete --expect-url '^/recipes$' --absent "Verify Fixture Lemon Drizzle Cake"`. `run.log` shows `DELETE ... -> 204`, and the API list no longer has the cake.
- **Reset.** Run `$V seed` to restore both fixtures.

## Gotchas

- The star buttons have no accessible name, so `--click-button` can't target them. Use `--click-sel 'button:has(.lucide-star) >> nth=N'`, where N is the rating minus one. On `/recipes` the stars of every row share that selector, so drive ratings from the detail page.
- The edit-mode title `<input>` has no label; it is the first input on the page in edit mode (`input >> nth=0`).
- Delete uses a native `confirm()`. Without `--accept-dialogs` the click is silently dismissed and nothing is deleted.
- After Delete, the in-flight detail refetch is aborted by the navigation. `run.log` lists it as `aborted by navigation`, which is not a failure.
- Saving an edit embeds new ingredient names with Voyage in a fire-and-forget task. With the placeholder key it fails silently, and the save itself still succeeds.
- An HTTP 200 on `/recipes` proves nothing: the shell renders even when the API is unreachable. Only rendered fixture titles do.
