# Home

The first screen: the meals on the list you last opened, one tap from cooking, then your lists, newest first, each with its meal count, how many items are left and a progress bar. Specified by the web Home (`client/src/routes/index.tsx`); Chef's picks are not built yet.

## Sub-features

- `home` shows the saved lists, and shows them from the phone's copy with the API stopped.
- `home-cook-from-list` shows a card per meal on the current list (the one last opened, else the newest); tapping one opens Cook.
- `home-new-list` creates a list (the server names it after today's date) and opens it in Plan.
- `home-list-actions` renames, duplicates or deletes a list from its More menu. Delete hides the list at once and is sent after the Undo banner.

## How to get to it (user POV)

- Open the app. From Plan, tap the back button (`BackButton`).

## Driving it with omlete-ios-verify

Preconditions:

- `$V up` just ran and `$V doctor` prints no `FAIL`.

- **See the lists.** `$V begin home`, then `$V expect "Verify Fixture List"` and `$V expect "2 meals · 6 to get"`.
- **Cook from the list.** `$V expect-id home.cookCard.<recipeID>`, `$V tap home.cookCard.<recipeID>`, then `$V expect-id cook.startButton`. The section title "Cook from Verify Fixture List" shows only in the screenshot.
- **New list.** `$V tap home.newListButton`, then `$V expect-id plan.quickAddField`: the app is now in Plan for the new list. `curl -s http://127.0.0.1:8765/api/lists/ | jq -c '[.[].name]'` shows two names.
- **Delete a list.** Back on Home, `$V tap home.listActions.<listID>`, `$V tap home.deleteAction`, then `$V gone "<name>"`. About seven seconds later the list is gone from `GET /api/lists/` too. `$V tap home.deleteAction then undo.button` instead keeps it, on screen and on the server.
- **Rename and duplicate.** The same menu holds `home.renameAction` (then `rename.nameField`, `rename.saveButton`) and `home.duplicateAction`.
- **Saved on the phone.** `$V api stop`, `$V relaunch`, `$V expect "Verify Fixture List"`.

## Gotchas

- New list and Duplicate need the API: the server mints the id and the name. With the API stopped they show an inline error.
- The row's label is the whole row ("Verify Fixture List, 1 meal · 6 to get, ..."), so `expect` on the name alone matches it.
- The More menu's actions exist only while the menu is open.
