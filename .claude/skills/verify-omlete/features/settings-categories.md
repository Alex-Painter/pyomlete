# Settings: aisles

Settings (`/settings`, behind the cog on phones and desktop) manages the aisles (store categories) that list items are grouped under: add, rename, reorder and delete. The order here is the order sections appear in on a list and in Shop.

## Sub-features

- `aisles-list` shows the nine defaults (`Fresh Produce` … `Other`) in order.
- `aisles-add` adds one from `New aisle name` with Enter or the add button.
- `aisles-rename` uses `Rename <name>`, then `Save name` or `Cancel`.
- `aisles-reorder` drags a row by `Reorder <name>`, or uses `Move <name> up` / `Move <name> down`.
- `aisles-delete` uses `Delete <name>`, then confirms `Delete aisle` in the action sheet.

## How to get to it (user POV)

- The cog (`Settings`) at the top right of each tab on phones, or at the right of the desktop nav, goes to `/settings`, headed `Settings`, with an `Aisles` section.

## Driving it with omlete-verify browse

Preconditions:

- A fresh local DB (the settings document is created on first read with the nine defaults).

- **Defaults render.** Run `$V browse /settings --expect Aisles --expect "Fresh Produce" --expect "Household"`.
- **Add an aisle.** Run `$V browse /settings --label settings-add-aisle --fill "New aisle name=Verify Spices" --press Enter --expect "Verify Spices"`. Then `curl -s http://127.0.0.1:8000/api/settings/categories` ends with `{"name":"Verify Spices","order":9}`.
- **Delete it.** Run `$V browse /settings --label settings-delete-aisle --click-button "Delete Verify Spices" --click-button "Delete aisle" --absent "Verify Spices"`. The categories API no longer lists it.

## Gotchas

- Deleting an aisle is the one place that still asks first, in an action sheet rather than a `confirm()`, because it changes how every list is grouped.
- `$V seed` does not reset aisles. Added ones persist until `$V down` removes the Mongo container.
- `PUT /api/settings/categories` replaces the entire list, so a stale page saving over a fresh one silently drops changes.
