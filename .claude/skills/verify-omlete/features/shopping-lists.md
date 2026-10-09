# Shopping lists

Shopping lists let a user create a dated list, quick-add items that are filed under a store category automatically, add whole recipes' ingredients, check items off, and switch between Plan and Shop layouts.

## Sub-features

- `lists-index` shows every list on the home page with its item and checked counts.
- `list-create` uses `New List` to create a list named after today's date (e.g. `9th October`) and opens it.
- `list-quick-add` adds an item from `Add item...` with an optional quantity and unit. The category comes from `POST /api/categorize`.
- `list-add-recipe` adds a library recipe's ingredients to the list (under `From your library`).
- `list-modes` toggles between `Plan` (recipes are the main column) and `Shop` (items are the main column, check-off).
- `list-duplicate-delete` duplicates or deletes a list from the home page.

## How to get to it (user POV)

- The `Lists` link in the top nav, or the `Omlete` logo, goes to `/`, headed `My Lists`.
- The `New List` button (or `Create your first list` on an empty home page) goes to `/list/<id>`.
- On a list: the `Add item...` textbox, the `Plan` / `Shop` toggle, and the recipe picker.

## Driving it with omlete-verify browse

Preconditions:

- `$V seed` just ran, so `milk` and `bananas` have cached categories (`Dairy & Eggs` and `Fresh Produce`).

- **Create a list and quick-add an item.** Run `$V browse / --label lists-add-item --click-button "New List" --expect-url '^/list/' --fill "Add item...=milk" --press Enter --expect "milk" --expect "Dairy & Eggs"`. `run.log` shows `POST /api/lists/ -> 200`, `POST /api/categorize -> 200` and `POST /api/lists/<id>/items -> 200`.
- **Confirm persistence.** Take the list id from the final URL in `run.log` and run `curl -s http://127.0.0.1:8000/api/lists/<id>`. The items include `{"name": "milk", "category": "Dairy & Eggs", ...}`.
- **List shows on the home page.** Run `$V browse / --label lists-index --expect "My Lists" --expect "$(date +'%B')"`. The new list's date-name is visible.

## Gotchas

- Quick-add calls `/api/categorize` first, and that calls Claude Haiku for any name not already in the `ingredients` collection. With the placeholder key it returns a 500, the browser reports it as `net::ERR_FAILED` (Starlette's 500 has no CORS headers), and the item is **not added at all**: the client has no fallback category. Use the seeded names (`milk`, `bananas`) unless real keys are set. This is a product gap, not a harness bug.
- Lists are not reset by `$V seed`. Each run adds a new dated list to the local DB, which `$V down` throws away.
- An empty list opens in Plan mode, where the quick-add row has no Qty or Unit fields. Those appear in Shop mode.
- The `Suggest`/AI panel on a list (`/api/recipes/suggest/`, `/api/recipes/generate/`) needs real keys. See `ai-recipe-creation.md`.
