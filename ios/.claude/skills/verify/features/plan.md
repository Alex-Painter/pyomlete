# Plan

One list: its meals in a strip with Add meals beside the heading, a quick-add field, the items still to get grouped by aisle in the user's aisle order, and a collapsible "Got it" section. Specified by `client/src/routes/list.$listId.tsx` and, for the Add meals sheet, `client/src/components/MealsSheet.tsx`. Every change is saved on the phone first and sent when the API answers.

## Sub-features

- `plan-quick-add` parses typed text ("2 onions, 500g mince") into items and files each under a guessed aisle.
- `plan-check` ticks an item off into "Got it" and back. No Undo banner here: the row is still on screen.
- `plan-edit` opens the item sheet from the row's chevron: name, amount, unit, aisle, and Delete.
- `plan-delete` removes an item (swipe, or the sheet's Delete) and "Clear checked" removes every ticked one. Both hide at once and are sent only after the Undo banner.
- `plan-rename` renames the list from the pencil button.
- `plan-meals` shows each meal as a chip whose menu cooks it, or removes it and its ingredients with Undo.
- `plan-add-meals` opens the picker from Add meals, or from "Pick this week's meals" on a list with none. It stays open until Done, and shows the Undo banner itself while it is up.
- `plan-add-meals-search` narrows both of the picker's sections by title.
- `plan-add-meals-library` lists every recipe under "Your recipes". Tapping one adds it to this list and ticks it; tapping a ticked one removes it and its ingredients with Undo.
- `plan-add-meals-picks` lists up to four Discover cards that are not yet recipes under "Discover picks". Tapping one saves it onto this list.
- `plan-add-meals-empty` is the picker with no recipes saved: Add a recipe and Browse Discover close it and switch tab.
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
- **Open the picker.** `$V tap plan.addMealsButton`, then `$V expect-id meals.searchField`. The four picks are `meals.pick.<card>` and the recipes `meals.recipe.<recipeID>`; a recipe on the list has the value `On the list`. `$V swipe meals.list up` brings the lower recipes into the UI tree. `$V tap meals.doneButton` closes it.
- **Search the picker.** `$V type meals.searchField "lemon"`, then `$V gone "Verify Card Bean Chilli"` and `$V gone "Verify Fixture Shakshuka, 4"`: one recipe is left and no picks. `$V tap meals.clearSearchButton` brings everything back.
- **Add a recipe from the picker.** `$V tap meals.recipe.<Lemon Drizzle Cake>`, then `$V expect "Verify Fixture Lemon Drizzle Cake, 4 ingredients"` with the row's value `On the list` in the capture. The tap's `NN-tap.json` holds `Added Verify Fixture Lemon Drizzle Cake to Verify Fixture List`. The API's `.recipes` gains the id and `.items` grows by four. After `$V tap meals.doneButton`, `$V expect-id plan.mealChip.<Lemon Drizzle Cake>`.
- **Remove a meal from the picker.** `$V tap meals.recipe.<Shakshuka> then undo.button`: the row still has `On the list`, and seven seconds later `.verify-run/api.log` has no `DELETE /api/lists/<listID>/recipes/<Shakshuka>`. Without `then undo.button` the tap's `NN-tap.json` holds `Removed <title> and its ingredients`, the row loses its value at once, and seven seconds later the API has dropped the recipe and its ingredients.
- **Add a Discover pick.** `$V tap meals.pick.<Imported Traybake>`. The tap's `NN-tap.json` holds `Saving Verify Card Imported Traybake. It goes on Verify Fixture List when it's ready.` and the pick is gone, with `Verify Card Miso Aubergine` in its place. The API's `.recipes` gains the `Verify Fixture Traybake` id, and `$V swipe meals.list up` shows that recipe with `On the list`.
- **A pick that cannot be saved.** `$V tap meals.pick.<Bean Chilli>`, then `$V expect "Couldn't save Verify Card Bean Chilli, so it isn't on your list."` straight away: the banner lasts five seconds. The pick leaves the picker, and Discover shows the card with Try again.
- **A list with no meals.** On Home, `$V tap home.newListButton` opens an empty list. `$V expect "Pick this week's meals"`, then `$V tap plan.pickMealsButton` and `$V expect-id meals.searchField`.
- **The picker with no recipes.** Delete the four recipes first (`curl -s -X DELETE http://127.0.0.1:8765/api/recipes/<recipeID>` for each), `$V relaunch`, open the list and the picker, then `$V expect "No recipes yet"`. `$V tap meals.addRecipeButton` lands on Add (`$V expect-id add.textField`) and `meals.browseDiscoverButton` on Discover; `$V tap tab.home` shows Plan still open.
- **Start shopping.** `$V tap plan.startShoppingButton`, then `$V expect "left to get"`.

## Gotchas

- The list name is an inline navigation title, which is not in the UI tree. Check it in the screenshot or on Home.
- The name field capitalises the first letter as the keyboard would, so "oat milk" becomes "Oat milk".
- Swipe actions and drag-to-reorder have no helper step. Use the item sheet for delete, and the CLI's `ui-automation` gestures with a fresh ref for the rest.
- The fixture list has two meal chips, `plan.mealChip.<recipeID>`. The "Meals (2)" heading is a section header and not in the UI tree, but its Add meals button is.
- While the picker is up the UI tree still holds Plan's controls underneath it. The Undo banner is the picker's own, so `undo.banner` and `undo.button` appear once.
- `tap <row> then undo.button` in the picker can lose its race with the banner: the bigger UI tree makes finding `undo.button` slower, and a late tap lands on the row under where the button was, which adds the meal back. A lost race leaves a `DELETE` then a `POST /api/lists/<listID>/recipes` in the log and an `Added ...` banner in the capture. Run the step again.
- Only the picker's rows on screen are in the UI tree. The first screen holds the four picks and the first two recipes.
- With no key only `Verify Card Imported Traybake` can be saved, as on [Discover](./discover.md).
- Plan hides the tab bar, so `tab.*` cannot be tapped from here. Go back to Home first.
- Without an API key `/api/categorize` fails, so a new item keeps the app's own aisle guess.
