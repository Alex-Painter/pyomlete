# Recipe library

The recipe library (Explore mode) lists every saved recipe on `/recipes`, headed `Recipes`, with search, sort and a grid or list view. A recipe page (`/recipe/<id>`) shows ingredients and method, a `Cook` button, an `Add to list` split button, a star rating, per-ingredient `On list` toggles, and a `More actions` menu with Edit and Delete. Deletes use an Undo toast, never a confirm dialog (see `docs/PRINCIPLES.md`).

## Sub-features

- `recipes-list` shows every saved recipe as a whole-card link with time and rating. Search (`?q=`), sort (`?sort=`) and view (`?view=grid|list`) live in the URL.
- `recipe-open` opens a recipe from its card.
- `recipe-rate` sets a 1–5 star rating from `Your rating`, a radio group whose options are named `1 star` … `5 stars`.
- `recipe-add-to-list` adds the recipe's ingredients to the current list (`Add to list`), or to another or a new list from the chevron.
- `recipe-cook` opens Cook (`/cook/<id>`); see `discover-cook.md`.
- `recipe-edit` uses `More actions` → `Edit recipe`; fields are labelled (`Title`, `Ingredient name`, `Quantity`, `Unit`, `Aisle`, `Step N`) and a sticky bar holds `Save` and `Cancel`.
- `recipe-delete` uses `More actions` → `Delete recipe`, returns to `/recipes`, and shows `Deleted <title>` with Undo. The DELETE is sent when the toast expires.

## How to get to it (user POV)

- The `Recipes` tab (phone) or nav link (desktop) goes to `/recipes`.
- A recipe card goes to `/recipe/<id>`; the `Recipes` back link returns.

## Driving it with omlete-verify browse

Preconditions:

- `$V seed` just ran: `Verify Fixture Shakshuka` (rated 4, 25 min) and `Verify Fixture Lemon Drizzle Cake` (unrated) exist.

- **List renders real data.** Run `$V browse /recipes --expect "Verify Fixture Shakshuka" --expect "Verify Fixture Lemon Drizzle Cake"`. `run.log` shows `GET http://127.0.0.1:8000/api/recipes/ -> 200`.
- **Open a recipe.** Run `$V browse /recipes --label recipe-open --click-link "Verify Fixture Shakshuka" --expect-url '^/recipe/' --expect "chopped tomatoes" --expect "Make wells, crack in the eggs"`.
- **Rate.** Run `$V browse /recipes --label recipe-rate --click-link "Verify Fixture Lemon Drizzle Cake" --expect-url '^/recipe/' --expect "self-raising flour" --click-sel '[role=radio][aria-label="3 stars"]'`. Then `curl -s http://127.0.0.1:8000/api/recipes/` shows the cake with `"rating": 3`.
- **Edit the title.** Run `$V browse /recipes --label recipe-edit --click-link "Verify Fixture Shakshuka" --expect-url '^/recipe/' --click-button "More actions" --click-button "Edit recipe" --fill "Title=Verify Fixture Shakshuka (edited)" --click-button Save --expect "Verify Fixture Shakshuka (edited)"`.
- **Delete.** Run `$V browse /recipes --label recipe-delete --click-link "Verify Fixture Lemon Drizzle Cake" --expect-url '^/recipe/' --click-button "More actions" --click-button "Delete recipe" --expect-url '^/recipes' --expect "Deleted Verify Fixture Lemon Drizzle Cake"`. After the toast expires, the API list no longer has the cake.
- **Reset.** Run `$V seed` to restore both fixtures.

## Gotchas

- Delete is deferred by the Undo window, so check the API after the toast has gone; until then the recipe still exists on the server.
- Saving an edit embeds new ingredient names with Voyage in a fire-and-forget task. With the placeholder key it fails silently, and the save itself still succeeds.
- An HTTP 200 on `/recipes` proves nothing: the shell renders even when the API is unreachable. Only rendered fixture titles do.
