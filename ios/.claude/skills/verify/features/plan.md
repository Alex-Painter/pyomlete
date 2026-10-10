# Plan

One list: its meals in a strip, a quick-add field, the items still to get grouped by aisle in the user's aisle order, and a collapsible "Got it" section. Specified by `client/src/routes/list.$listId.tsx`. Every change is saved on the phone first and sent when the API answers.

## Sub-features

- `plan-quick-add` parses typed text ("2 onions, 500g mince") into items and files each under a guessed aisle.
- `plan-check` ticks an item off into "Got it" and back. No Undo banner here: the row is still on screen.
- `plan-edit` opens the item sheet from the row's chevron: name, amount, unit, aisle, and Delete.
- `plan-delete` removes an item (swipe, or the sheet's Delete) and "Clear checked" removes every ticked one. Both hide at once and are sent only after the Undo banner.
- `plan-rename` renames the list from the pencil button.
- `plan-meals` shows each meal as a chip whose menu cooks it, or removes it and its ingredients with Undo.
- `plan-start-shopping` opens Shop.

## How to get to it (user POV)

- On Home, tap a list. Or tap New list.

## Driving it with omlete-ios-verify

Preconditions:

- `$V up` just ran, `$V doctor` prints no `FAIL`, and `$V tap home.listRow.<listID>` has opened the fixture list.

- **Quick add.** `$V type plan.quickAddField "2 onions, 500g mince"`, `$V tap plan.quickAddButton`, `$V expect "mince"`. The API then lists `onions` (2, Fresh Produce) and `mince` (500, `g`, Meat & Fish).
- **Check.** `$V tap plan.itemRow.<itemID>`, then `$V expect "Got it (1)"`.
- **Edit.** `$V tap plan.itemEdit.<itemID>`, `$V type itemSheet.nameField "oat milk"`, `$V tap itemSheet.saveButton`, `$V expect "Oat milk"`.
- **Delete with Undo.** `$V tap plan.itemEdit.<itemID>`, then `$V tap itemSheet.deleteButton then undo.button`, then `$V expect "<name>"`. Seven seconds later the API still has the item. Without `then undo.button`, the tap's own `NN-tap.json` holds `Removed <name>`, and seven seconds later the API has dropped it.
- **Rename.** `$V tap plan.renameButton`, `$V type rename.nameField "Weekend"`, `$V tap rename.saveButton`. Prove it with the API or by going back to Home and `$V expect "Weekend"`.
- **Cook a meal.** `$V tap plan.mealChip.<recipeID>`, `$V tap plan.cookMealAction`, then `$V expect-id cook.startButton`. Closing Cook returns to Plan.
- **Start shopping.** `$V tap plan.startShoppingButton`, then `$V expect "left to get"`.

## Gotchas

- The list name is an inline navigation title, which is not in the UI tree. Check it in the screenshot or on Home.
- The name field capitalises the first letter as the keyboard would, so "oat milk" becomes "Oat milk".
- Swipe actions and drag-to-reorder have no helper step. Use the item sheet for delete, and the CLI's `ui-automation` gestures with a fresh ref for the rest.
- "Add meals" is not built, so a new list has no meals strip to drive. The fixture list has two meal chips, `plan.mealChip.<recipeID>`.
- Without an API key `/api/categorize` fails, so a new item keeps the app's own aisle guess.
