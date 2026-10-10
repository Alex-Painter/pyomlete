# Shop

The list as you walk the aisles: full screen over the whole app, screen kept awake, large rows in aisle order, a count of what is left, and only quick add besides. Specified by `client/src/routes/shop.$listId.tsx`. It works with no connection, and nothing but its close button leaves it.

## Sub-features

- `shop-check` ticks an item off with one tap anywhere on the row and offers Undo ("Got mince").
- `shop-quick-add` adds something spotted in the shop.
- `shop-offline` keeps working with the API stopped, shows "Offline, saved here", and sends the changes when the API returns.
- `shop-close` returns to Plan with nothing changed.

## How to get to it (user POV)

- In Plan, tap Start shopping.

## Driving it with omlete-ios-verify

Preconditions:

- `$V up` just ran, `$V doctor` prints no `FAIL`, the fixture list is open in Plan, and `$V tap plan.startShoppingButton` has run.

- **Check.** `$V expect "6 left to get"`, `$V tap shop.itemRow.<itemID>`, `$V expect "5 left to get"`. The tap's `NN-tap.json` holds `Got <name>` and `undo.button`, and the API shows the item checked within a second.
- **Undo.** `$V tap shop.itemRow.<itemID> then undo.button`, then `$V expect` the count from before the tap. `.verify-run/api.log` shows two PATCH lines for that item.
- **Offline.** `$V api stop`, tap a row, `$V expect "Offline, saved here"`, add something with `shop.quickAddField` and `shop.quickAddButton`, then `$V api start`. Within about 20 seconds `$V gone "Offline, saved here"` passes and the API has both changes, in the order they were made.
- **Close.** `$V tap shop.closeButton`, then `$V expect-id plan.startShoppingButton`.

## Gotchas

- Plan stays in the UI tree underneath Shop, so a snapshot lists both `plan.itemRow.*` and `shop.itemRow.*`. Drive the `shop.` ids.
- The Undo banner covers the bottom row for five seconds. A tap aimed at `undo.button` after it has gone lands on that row and ticks it off.
- The pill and the count are text, not controls: use `expect` and `gone`, not `expect-id`.
