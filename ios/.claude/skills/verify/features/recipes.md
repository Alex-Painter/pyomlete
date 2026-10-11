# Recipes

The recipe library and the recipe page. The library is a grid of every saved recipe with its picture, title, rating, time and source, a search field, a sort menu and three filter chips. The page shows one recipe: Cook, Add to list, your rating, the ingredients in the source's groups with an On list toggle each, and the method. Edit recipe in the More menu opens a sheet that changes the title, the ingredients and the method. Specified by `client/src/routes/recipes.tsx` and `client/src/routes/recipe.$recipeId.tsx`.

## Sub-features

- `recipes-library` shows every recipe, newest first, and "n saved".
- `recipes-search` narrows the grid to titles containing what is typed.
- `recipes-sort` orders by Newest, Top rated, Quickest or A–Z.
- `recipes-filter` keeps 4★ and up, Under 30 min, or From the web. Tapping the chosen chip again clears it.
- `recipe-page` shows the title, time, servings, source link, date added, ingredient groups and method.
- `recipe-cook` opens Cook over the page. Closing Cook returns to the page.
- `recipe-add-to-list` adds the recipe to the current list with Undo, or to a list chosen in the picker.
- `recipe-rate` sets your rating with one tap on a star.
- `recipe-on-list` turns an ingredient's shopping-list flag off and on.
- `recipe-delete` removes the recipe from the More menu, with Undo.
- `recipe-edit` changes the title, each ingredient's name, quantity, unit and aisle, and each step's text, and saves them with one `PUT`.
- `recipe-edit-rows` adds and removes ingredients and steps, and moves a step by dragging its handle.
- `recipe-edit-cancel` discards the edit with Undo, which reopens the editor as it was. An edit with changes cannot be swiped away.
- `recipe-edit-offline` keeps the editor up, with what was typed, when the save cannot be sent, and says it is not saved.

## How to get to it (user POV)

- Tap Recipes in the tab bar, then a recipe. A saved Discover card and the Add result also open the page.

## Driving it with omlete-ios-verify

Preconditions:

- `$V up` just ran, `$V doctor` prints no `FAIL`, and `$V tap tab.recipes` has run.
- `<traybake>`, `<shakshuka>`, `<egg>` and `<cake>` are the four fixture recipe ids: `curl -s http://127.0.0.1:8765/api/recipes/ | jq -r '.[] | "\(.id) \(.title)"'`. Only `Verify Fixture Traybake` has a source (`example.com`), ingredient groups and an ingredient kept off lists. It is rated 5 and takes 45 minutes. `Verify Fixture Shakshuka` is rated 4 and takes 25.

- **See the library.** `$V begin recipes-library`, `$V expect "4 saved"`, `$V expect "Verify Fixture Traybake"`.
- **Search.** `$V type recipes.searchField "tray"`, `$V gone "Verify Fixture Shakshuka"`, `$V expect "Verify Fixture Traybake"`. `$V type recipes.searchField "zzz"`, then `$V expect "Nothing matches"`. `$V tap recipes.clearSearchButton` brings all four back.
- **Filter.** `$V tap recipes.filter.fromTheWeb`, `$V gone "Verify Fixture Shakshuka"`; tap it again to clear. `recipes.filter.quick` leaves only the Shakshuka, and `recipes.filter.favourites` leaves the Shakshuka and the Traybake.
- **Sort.** `$V tap recipes.sortMenu`, `$V tap recipes.sort.topRated`. Read the order from the screenshot, left to right then down: Traybake first, then Shakshuka. The UI tree lists the tiles (`recipes.tile.<id>`) but not reliably in reading order. `recipes.sort.quickest` puts the Shakshuka first; `recipes.sort.alphabetical` puts the Lemon Drizzle Cake first.
- **Open the page.** `$V tap recipes.tile.<traybake>`, then `$V expect "Serves 4"`, `$V expect "olive oil: not on shopping lists"`. The title and the group headings ("For the traybake", "For the dressing") are section headers, which are not in the UI tree: check them in the screenshot.
- **On list.** `$V tap recipe.onList.0`, then `$V expect "chicken thighs: not on shopping lists"`. `curl -s http://127.0.0.1:8765/api/recipes/<traybake> | jq '.ingredients[0].excluded_from_list'` prints `true`.
- **Rate.** `$V tap recipe.star.3`; `curl -s http://127.0.0.1:8765/api/recipes/<traybake> | jq .rating` prints `3`.
- **Add to list.** `$V tap recipe.addToList`. The tap's `NN-tap.json` holds `Added Verify Fixture Traybake to Verify Fixture List` and `undo.button`. A second tap, after the banner has gone, holds `Verify Fixture Traybake is already on Verify Fixture List`. `$V tap tab.home`, `$V expect "3 meals"`. `$V tap recipe.addToList then undo.button` on a recipe not yet on the list leaves the list as it was.
- **Pick a list.** `$V tap recipe.addToList.choose`, `$V expect "Current"`, then `$V tap listPicker.newListButton`: the API has a second list holding the recipe.
- **Cook.** `$V tap recipe.cookButton`, `$V expect-id cook.startButton`, `$V tap cook.closeButton`, `$V expect-id recipe.cookButton`.
- **Delete with Undo.** `$V tap recipe.moreMenu`, then `$V tap recipe.deleteAction then undo.button`, then `$V expect "Verify Fixture Traybake"` in the library. Without `then undo.button`, `$V gone "Verify Fixture Traybake"` passes and seven seconds later the API no longer has the recipe.
- **Edit and save.** `$V begin recipe-edit`, `$V tap recipe.moreMenu`, `$V tap recipe.editAction`, `$V expect-id recipeEditor.saveButton`. `$V type recipeEditor.titleField "Verify Edited Traybake"`, `$V type recipeEditor.ingredient.1.quantityField "750"`, then `$V tap recipeEditor.saveButton`. The editor is gone when `$V snapshot | grep -c recipeEditor` prints `0`. `curl -s http://127.0.0.1:8765/api/recipes/<traybake> | jq '{title, ingredients}'` has the new title and `750`, and still has `"note": "halved"` on the potatoes, both groups and `"excluded_from_list": true` on the olive oil. `grep -c PUT .verify-run/api.log` went up by one (the log starts again at each `api start`). Read the new title on the page from the screenshot, then `$V tap BackButton` and `$V expect "Verify Edited Traybake"` for the tile.
- **Empty a quantity.** `$V type recipeEditor.ingredient.0.quantityField "1"`, then `npx -y xcodebuildmcp@latest ui-automation key-press --simulator-id <udid> --key-code 42` (Backspace; the udid is in `.verify-run/state`). The field's value in the snapshot becomes its placeholder, `Qty`. After Save, `jq '.ingredients[0].amount'` prints `null`.
- **Unit and aisle.** `$V tap recipeEditor.ingredient.0.unitMenu`, then `$V tap "recipeEditor.unit.to taste"`. `$V tap recipeEditor.ingredient.0.aislePicker`, then `$V tap "recipeEditor.aisle.Pantry & Dry Goods"`. The unit field also takes any typed text.
- **Add and remove rows.** `$V tap recipeEditor.ingredient.3.removeButton`. `$V tap recipeEditor.addIngredientButton`, then `$V type recipeEditor.ingredient.3.nameField "capers"`. `$V swipe recipeEditor.form up`, `$V tap recipeEditor.addStepButton`, `$V type recipeEditor.step.2.field "Scatter the capers and serve."`, and `$V tap recipeEditor.step.0.removeButton`. After Save the API has the rows as edited, and the page shows `capers: on shopping lists`.
- **Move a step.** The helper cannot do it: see Gotchas. After the drag, `$V snapshot | grep 'step\..\.field'` lists the steps in their new order, and after Save so does `jq .instructions`.
- **A quantity that is not a number.** `$V type recipeEditor.ingredient.1.quantityField "a few"`, `$V tap recipeEditor.saveButton`, `$V expect "The quantity for new potatoes has to be a plain number, or empty."`. The editor stays up and no `PUT` is sent.
- **Cancel with Undo.** Change the title, then `$V tap recipeEditor.cancelButton`. The tap's `NN-tap.json` holds `Discarded your changes to <title>` and `undo.button`, and the API still has the old title. `$V tap recipeEditor.cancelButton then undo.button` reopens the editor with the typed title in `recipeEditor.titleField`. Cancel with nothing changed shows no banner.
- **Save with the API stopped.** Change something, `$V api stop`, `$V tap recipeEditor.saveButton`, `$V expect "Couldn't reach Omlete, so this may not be saved"`. The field still holds what was typed. `$V api start`, `$V tap recipeEditor.saveButton`, and the API has it. To see that the tile needs no refresh, `$V api stop` again before `$V tap BackButton`, then `$V expect` the new title.
- **A recipe that is gone.** Delete a recipe through the API while its page is not open, open it from a saved Discover card, and `$V expect "This recipe doesn't exist any more."`.

## Gotchas

- **Edit from a copy saved on the phone.** Open a recipe once, `$V api stop`, `$V relaunch`, open it again, `$V tap recipe.moreMenu`, `$V tap recipe.editAction`: the tap's `NN-tap.json` holds `Couldn't reach Omlete. Editing a recipe needs a connection.` and no `recipeEditor.` id. After `$V api start`, the same two taps open the editor.
- The grid's own empty state ("No recipes yet", `recipes.addRecipeButton`, `recipes.browseDiscoverButton`) needs a library with no recipes. Delete the four fixtures through the API (`curl -X DELETE http://127.0.0.1:8765/api/recipes/<id>`), then pull the grid down or `$V relaunch`.
- The Sort menu's items exist only while the menu is open.
- An ingredient row's toggle is labelled `<name>: on shopping lists` or `<name>: not on shopping lists`; the visible text is "On list" or "Not on list". Its id is `recipe.onList.<n>`, where `n` is the ingredient's position in the recipe, counted from 0 across all groups.
- A rating tile reads "5 stars" in the UI tree and shows a star and the number on screen.
- No fixture recipe has a picture, so every tile and the page show the placeholder, and the page has no hero picture.
- The page stays in the UI tree under the editor, so `expect` and `gone` on the page's text pass while the sheet is up. The editor is closed when no `recipeEditor.` id is left in `$V snapshot`.
- "Edit recipe", the sheet's title, is a navigation title and is not in the UI tree. So is the recipe's title on Cook. Check both in the screenshot.
- An editor row's ids carry its position, counted from 0: `recipeEditor.ingredient.<n>.nameField`, `.quantityField`, `.unitField`, `.unitMenu`, `.aislePicker` and `.removeButton`, and `recipeEditor.step.<n>.field` and `.removeButton`. Removing a row renumbers the ones after it. A unit or aisle option exists only while its menu is open.
- `$V type` cannot empty a field, because it needs some text. Type one character and send Backspace, as in "Empty a quantity".
- A step's handle has no id. Its label is `Reorder <n>`. `ui-automation drag` on it reports success and moves nothing. The iOS Simulator `touch_path` action, which can hold before it moves, does it by coordinates read from a screenshot: touch down on the handle, hold 700 ms, move in steps of 150 ms, hold, lift. Screenshots are 368 points wide for a 402-point screen, so multiply by 1.09.
- The software keyboard does not come up when the helper types or a field takes focus, so the editor cannot be checked with the keyboard showing.
- An edit with changes does not swipe away. `recipeEditor.form` scrolls with `$V swipe`.
- The recipe page keeps the tab bar. Plan does not: it hides it so Start shopping has the bottom of the screen.
- The page reads its recipe from the same saved copy Cook uses, so a recipe opened once still shows with the API stopped.
