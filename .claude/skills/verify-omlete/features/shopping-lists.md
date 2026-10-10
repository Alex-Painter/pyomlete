# Shopping lists

Lists are the Plan and Shop modes. Plan (`/list/<id>`) is where a list is built: quick-add typed or pasted items, add meals from the library or Discover, edit items in a sheet, delete with Undo. Shop (`/shop/<id>`) is a fullscreen, offline-first check-off view. Neither mode moves you into another when something finishes (see `docs/PRINCIPLES.md`).

## Sub-features

- `lists-cook` shows `Cook from <current list>` on `/`: each meal on the current list links straight to `/cook/<recipeId>?list=<id>`.
- `lists-index` shows every list on `/` (headed `Lists`) as a card; its `…` button opens an action sheet with Rename, Duplicate and Delete (Delete has an Undo toast, no confirm dialog).
- `list-create` uses `New list` to create a list and open it.
- `list-quick-add` parses the `Add items` field: `2 onions, 500g mince, oat milk` becomes three items with amounts and units. Pasting several lines adds them all. A local guess files the item under a category at once; `/api/categorize` corrects it afterwards if it can.
- `list-edit-item` taps an item's chevron (`Edit <name>`) or swipes right to open the edit sheet: name, quantity stepper, unit chips, aisle chips, Delete and Done.
- `list-check` taps anywhere on a row to check it. Checked items move to `Got it (n)` with `Clear checked`.
- `list-delete-undo` swipes left (or uses Delete in the sheet). The item disappears at once; the DELETE is only sent when the Undo toast expires.
- `list-add-meals` uses `Add meals` (`?sheet=meals`), which stays open for several picks and offers search, Discover picks and the library.
- `list-shop` uses `Start shopping` to open `/shop/<id>`: large rows, wake lock, `Spotted something? Add it`, an offline/syncing badge, and `Leave shopping mode`.
- `list-offline` queues every change in localStorage (`omlete:queue:v1`) and replays it when back online.

## How to get to it (user POV)

- The `Lists` tab (phone) or nav link (desktop) goes to `/`.
- `New list` creates one and opens it in Plan.
- On a list: the `Add items` field, `Add meals`, the item rows, and `Start shopping` in the header.

## Driving it with omlete-verify browse

Preconditions:

- `$V seed` just ran, so `milk` and `bananas` have cached categories (`Dairy & Eggs` and `Fresh Produce`).

- **Create a list and quick-add items.** Run `$V browse / --label lists-add-item --click-button "New list" --expect-url '^/list/' --fill "Add items=milk, 2 bananas" --press Enter --expect "milk" --expect "bananas" --expect "Dairy & Eggs"`. `run.log` shows `POST /api/lists/ -> 200` and two `POST /api/lists/<id>/items -> 200`.
- **Confirm persistence.** Take the list id from the final URL in `run.log` and run `curl -s http://127.0.0.1:8000/api/lists/<id>`. The items include `{"name": "bananas", "amount": 2, ...}`.
- **Shop mode.** Run `$V browse /list/<id> --label lists-shop --click-link "Start shopping" --expect-url '^/shop/' --click-sel '[role=checkbox]' --expect "Got it"`. Then check the API shows the item `"checked": true`.

## Gotchas

- With the placeholder key `/api/categorize` returns a 500 that the browser reports as a CORS error. Items are still added under the locally guessed category; only the correction is lost. Seeded names (`milk`, `bananas`) categorise correctly.
- Deletes are deferred by the Undo window (a few seconds). Check the API after the toast has gone, or the item is still there.
- Lists are not reset by `$V seed`. Each run adds a new list to the local DB, which `$V down` throws away.
- The service worker only registers in production builds, so offline page loads can't be tested against the dev server; offline edits on an already open page can (Playwright `context.setOffline(true)`).
