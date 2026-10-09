# Settings: categories

The Settings page lets a user manage the store categories that shopping-list items are grouped under: add a new one, rename it, move it up or down, or delete it. The order chosen here is the order sections appear in on a list.

## Sub-features

- `categories-list` shows the nine defaults (`Fresh Produce` … `Other`) in order.
- `categories-add` adds a category from `New category name...` with the `Add` button or Enter.
- `categories-rename` uses the pencil button to open an inline editor, then `Save` or Escape.
- `categories-reorder` moves a category with the up and down arrow buttons.
- `categories-delete` removes a category with the trash button.

## How to get to it (user POV)

- The `Settings` link at the right of the top nav goes to `/settings`, headed `Settings`, with a `Categories` section.

## Driving it with omlete-verify browse

Preconditions:

- A fresh local DB (the settings document is created on first read with the nine defaults).

- **Defaults render.** Run `$V browse /settings --expect Settings --expect "Fresh Produce" --expect "Household"`.
- **Add a category.** Run `$V browse /settings --label settings-add-category --expect "Fresh Produce" --fill "New category name...=Verify Spices" --press Enter --expect "Verify Spices"`. Then `curl -s http://127.0.0.1:8000/api/settings/categories` ends with `{"name":"Verify Spices","order":9}`.
- **Delete it.** Run `$V browse /settings --label settings-delete-category --expect "Verify Spices" --accept-dialogs --click-sel 'div:has(> span:text-is("Verify Spices")) button >> nth=3' --absent "Verify Spices"`. The categories API no longer lists it.

## Gotchas

- The per-row up, down, rename and delete buttons are icon-only with no accessible name. To drive them, use `--click-sel 'div:has(> span:text-is("<name>")) button >> nth=N'`, where N is 0 for up, 1 for down, 2 for rename and 3 for delete.
- Delete asks for `confirm()`. Without `--accept-dialogs` the click does nothing and no request is sent.
- `$V seed` does not reset categories. Added categories persist until `$V down` removes the Mongo container.
- `PUT /api/settings/categories` replaces the entire list, so a stale page saving over a fresh one silently drops changes.
