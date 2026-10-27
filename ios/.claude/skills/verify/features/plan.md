# Plan

One list. A week list opens on its seven evenings: a Week and List switch and a strip of days pinned at the top, then the meals on the list with no day, the selected evening's card, and the meal library inline under it. List shows the items. A plain list (no week) shows its meals in a strip with Add meals beside the heading, a quick-add field, the items still to get grouped by aisle in the user's aisle order, a collapsible "Got it" section, and the same library at the bottom. Specified by `client/src/routes/list.$listId.tsx` and its `WeekStrip`, `DayCard` and `DayLibrary` components. Every change, a day's included, is saved on the phone first and sent when the API answers.

## Sub-features

- `plan-week-open` opens a week list on Week with today selected when it is in the week, else the first evening still to plan. The choice is held: planning or marking Out never moves it on its own.
- `plan-week-strip` shows each evening with a dot for a meal, a ring for open and a moon for Out, today labelled Today. A tap selects it.
- `plan-week-pick` plans the selected evening from the library and moves the selection to the next open evening, wrapping round the week. Tapping the meal already on that evening takes it off, as Clear does.
- `plan-day-clear` (Clear on the card) takes the meal off its evening at once, with Undo. The meal stays on the list as an any-day meal.
- `plan-day-out` marks an open evening Out in one tap; an Out evening offers Plan anyway.
- `plan-day-cook` and `plan-day-open` cook the evening's meal or open its recipe. Swap scrolls to the library.
- `plan-any-day` lists the meals on the list with no evening under "This week, any day".
- `plan-meal-actions` is a meal chip's menu: Plan for <selected day> (week lists only), Cook this, Open recipe, and Remove from list (with Undo; it also clears the meal's days).
- `plan-library` searches titles, cuisines and ingredients, ignoring case and accents, filters by Quick, Not had lately and Favourites, and sorts by Not had lately (the default), Your favourites, Quickest, Newest or A to Z. Each row says when the meal was last had. A meal on this week counts as had at once.
- `plan-library-plain` on a plain list: tapping a meal adds it and its ingredients (needs the API); tapping one on the list removes it with Undo. Add meals and "Pick this week's meals" scroll to the library.
- `plan-library-empty` is the library with no recipes saved: Add a recipe and Browse Discover switch tab and leave Plan open.
- `plan-quick-add` parses typed text ("2 onions, 500g mince") into items and files each under a guessed aisle.
- `plan-check` ticks an item off into "Got it" and back from the circle at the start of its row. No Undo banner here: the row is still on screen.
- `plan-edit` opens the item sheet from a tap anywhere else on the row, "Got it" rows included: name, amount, unit, aisle, and Delete. Tapping a row never checks it; that is Shop.
- `plan-delete` removes an item (swipe, or the sheet's Delete) and "Clear checked" removes every ticked one. Both hide at once and are sent only after the Undo banner.
- `plan-rename` renames the list from the pencil button.
- `plan-offline-day` plans an evening with the API stopped; it shows at once and reaches the server when the API is back.
- `plan-start-shopping` opens Shop.

Plan shows no Discover picks. They are on Discover and Home.

## How to get to it (user POV)

- On Home, tap a list. Or tap New list.

## Driving it with omlete-ios-verify

Preconditions:

- `$V up` just ran and `$V doctor` prints no `FAIL`. The seed leaves two lists: `Verify Fixture Week` (`<weekID>`, a week list starting on the Saturday on or before today, with `Verify Fixture Traybake` on its first evening, its sixth evening Out, and `Verify Fixture Soft Egg` on it with no day) and `Verify Fixture List` (`<listID>`, a plain list, Home's first row). `up` prints both ids, and `curl -s http://127.0.0.1:8765/api/lists/ | jq -r '.[] | "\(.id) \(.name) \(.week_start)"'` lists them.
- Day buttons are `plan.day.<YYYY-MM-DD>`, labelled like `Today, Tuesday 27 October, nothing planned`, `Saturday 24 October, Verify Fixture Traybake` or `Thursday 29 October, out`. That label is how to prove what an evening holds.

The week:

- **Open on today.** `$V tap home.listRow.<weekID>`, then `$V expect "Today, Tuesday 27 October, nothing planned"` (today's date). The screenshot shows Today ringed and "Pick for Tuesday" over the library.
- **Pick a meal.** `$V tap plan.library.recipe.<Shakshuka>`, then `$V expect "Today, Tuesday 27 October, Verify Fixture Shakshuka"`. The card moves to the next open evening: `$V expect-id plan.day.outButton` and its label `Out on Wednesday`. The API's `.days` has the recipe on today, and `.verify-run/api.log` has `PUT /api/lists/<weekID>/days/<today>`.
- **Clear with Undo.** Select the planned evening (`$V tap plan.day.<date>`), then `$V tap plan.day.clearButton then undo.button` and `$V expect "<label with the meal>"`. Without `then undo.button`, the tap's `NN-tap.json` holds `Took <title> off <Day>`, the label says `nothing planned`, the meal shows as `plan.mealChip.<recipeID>` under "This week, any day", and the API keeps it in `.recipes` with the day's `recipe_id` null.
- **Take a meal off by tapping it again.** On a planned evening its library row has the value `Planned for <Day>`; tapping it holds `Took <title> off <Day>` as Clear does.
- **Out and Plan anyway.** On an open evening `$V tap plan.day.outButton`, then `$V expect "<date>, out"` and `$V expect-id plan.day.planAnywayButton`; the API's day has `status` `out`. `$V tap plan.day.planAnywayButton` and the label says `nothing planned` again.
- **A meal's menu.** `$V tap plan.mealChip.<Soft Egg>` shows `plan.planMealAction` (`Plan for <Day>`), `plan.cookMealAction`, `plan.openRecipeAction` and `plan.removeMealAction`. `$V tap plan.planMealAction` plans it on the selected evening and moves on, as a library tap does. `plan.openRecipeAction` pushes the recipe: `$V expect-id recipe.addToList`, and `$V tap BackButton` returns to Plan.
- **Search by an ingredient.** `$V type plan.library.searchField "potatoes"`, then `$V gone "Verify Fixture Lemon Drizzle Cake"`: only the Traybake is left, whose title does not say potatoes. `$V tap plan.library.clearSearchButton` brings everything back.
- **Sort.** `$V tap plan.library.sortMenu`, `$V tap plan.library.sort.quickest`, then `$V expect "Sort, Quickest"`. `$V swipe plan.list up` and the snapshot lists the Shakshuka (25 min), the Traybake (45 min), then the two with no time by title. The other ids are `notLately`, `favourites`, `newest` and `aToZ`.
- **Filter.** `$V tap plan.library.filter.quick` leaves only meals of 30 minutes or less; tap it again to turn it off. The others are `plan.library.filter.notLately` and `plan.library.filter.favourites`.
- **Week and List.** `$V tap plan.listViewButton`, then `$V expect-id plan.quickAddField`: the items, with no day strip. `$V tap plan.weekViewButton` goes back.
- **Offline.** `$V api stop`, select an open evening and tap a library row: `$V expect "<date>, <title>"` and `$V expect "Offline"`. `$V api start`; within about 20 seconds the API's day has the recipe, `.verify-run/api.log` has the `PUT .../days/<date>`, and once the list is fetched again the meal's ingredients are among `.items`.

A plain list:

- **Add a meal from the library.** `$V tap home.listRow.<listID>`, `$V tap plan.addMealsButton` (scrolls to the library), then `$V tap plan.library.recipe.<Lemon Drizzle Cake>`. The tap's `NN-tap.json` holds `Added Verify Fixture Lemon Drizzle Cake to Verify Fixture List`, the row's value becomes `On the list`, and the API's `.recipes` gains the id and `.items` grows by four.
- **Remove a meal from the library.** `$V tap plan.library.recipe.<Shakshuka> then undo.button`: the row still has `On the list`, and seven seconds later `.verify-run/api.log` has no `DELETE /api/lists/<listID>/recipes/<Shakshuka>`. Without `then undo.button` the tap's `NN-tap.json` holds `Removed <title> and its ingredients`, and seven seconds later the API has dropped the recipe and its ingredients.
- **Put a meal back inside the Undo window.** Two `$V tap` calls are about five seconds apart, which is the whole window, so send both taps as one batch, from `ios/`:

  ```bash
  UDID="$(sed -n 's/^udid=//p' .verify-run/state)"
  ref="$(npx -y xcodebuildmcp@latest ui-automation snapshot-ui --simulator-id "$UDID" --output json \
    | jq -r --arg id "plan.library.recipe.<Shakshuka>" '[.data.capture.targets[] | split("|") | select(.[-1] == $id) | .[0]][0]')"
  npx -y xcodebuildmcp@latest ui-automation batch --simulator-id "$UDID" --ax-cache perBatch \
    --json "{\"steps\":[{\"action\":\"tap\",\"elementRef\":\"$ref\",\"postDelay\":1},{\"action\":\"tap\",\"elementRef\":\"$ref\"}]}"
  $V snapshot
  ```

  The snapshot holds `Added Verify Fixture Shakshuka to Verify Fixture List` and the row's value `On the list`. Seven seconds later `.verify-run/api.log` has no `DELETE` and no `POST` under `/api/lists/<listID>/recipes`: the second tap was the Undo. On a week list, planning a meal whose removal can still be undone is that Undo too, and clears the meal's other evenings.
- **A list with no meals.** On Home, `$V tap home.newListButton` opens an empty plain list. `$V expect "Pick this week's meals"`, and `$V snapshot` has no `plan.addMealsButton`. `$V tap plan.pickMealsButton` scrolls to the library.
- **The library with no recipes.** Delete the four recipes first (`curl -s -X DELETE http://127.0.0.1:8765/api/recipes/<recipeID>` for each), `$V relaunch`, open the plain list, `$V swipe plan.list up`, then `$V expect "No recipes yet"`. `$V tap plan.library.addRecipeButton` lands on Add (`$V expect-id add.textField`) and `plan.library.browseDiscoverButton` on Discover; `$V tap tab.home` shows Plan still open.

The items, on a plain list or a week list's List view:

- **Quick add.** `$V type plan.quickAddField "2 onions, 500g mince"`, `$V tap plan.quickAddButton`, `$V expect "mince"`. The API then lists `onions` (2, Fresh Produce) and `mince` (500, `g`, Meat & Fish).
- **Check.** `$V tap plan.itemCheck.<itemID>`, and the API shows the item checked. "Got it (1)" heads the last section, which the Quick add step's two items push below the fold, so `$V swipe plan.list up` and then `$V expect "Got it (1)"`. To uncheck, `$V tap plan.itemCheck.<itemID>` again there, then `$V gone "Got it (1)"`.
- **Edit.** `$V tap plan.itemRow.<itemID>`, `$V expect-id itemSheet.nameField` (the API still shows the item unchecked), `$V type itemSheet.nameField "oat milk"`, `$V tap itemSheet.saveButton`, `$V expect "Oat milk"`.
- **Delete with Undo.** `$V tap plan.itemRow.<itemID>`, then `$V tap itemSheet.deleteButton then undo.button`, then `$V expect "<name>"`. Seven seconds later the API still has the item. Without `then undo.button`, the tap's own `NN-tap.json` holds `Removed <name>`, and seven seconds later the API has dropped it.
- **Rename.** `$V tap plan.renameButton`, `$V type rename.nameField "Weekend"`, `$V tap rename.saveButton`. Prove it with the API or by going back to Home and `$V expect "Weekend"`.
- **Cook a meal.** `$V tap plan.mealChip.<recipeID>`, `$V tap plan.cookMealAction`, then `$V expect-id cook.startButton`. Closing Cook returns to Plan.
- **Start shopping.** `$V tap plan.startShoppingButton`, then `$V expect "left to get"`.

## Gotchas

- The list name is an inline navigation title, and section headers ("Pick for Tuesday", "This week, any day", the selected evening's date, "Meals (2)") are not in the UI tree. Check them in the screenshot. Buttons inside a header are: `plan.addMealsButton`, `plan.library.sortMenu`.
- The selected evening has no value in the snapshot. Tell it by the card's controls (`plan.day.outButton` is labelled `Out on <Day>`) or the screenshot.
- Only the rows on screen are in the UI tree. The library sits under the day card, so after a few taps the rows you want may be below the fold: `$V swipe plan.list up`.
- A row is two controls: `plan.itemCheck.<itemID>` (label `Check off <name>`) and `plan.itemRow.<itemID>` (label `Edit <name>`, value the quantity), so `$V expect "<name>"` still matches.
- The name field capitalises the first letter as the keyboard would, so "oat milk" becomes "Oat milk".
- Swipe actions and drag-to-reorder have no helper step. Use the item sheet for delete. To see the swipe actions, `npx -y xcodebuildmcp@latest ui-automation drag --element-ref <ref of plan.itemRow.<itemID>> --direction left --distance 0.5` shows Delete, and `--direction right` shows Edit.
- `tap <row> then undo.button` can lose its race with the banner. If the banner has gone before the button is looked for, the step fails with `no tappable or scrollable control with accessibility id 'undo.button'`; if it goes between the look and the tap, the tap lands on whatever is under where the button was. Either way, put things back and run the step again.
- A day planned with a meal not yet on the list shows the meal at once, but its ingredients arrive only once the server has the day and the list is fetched again.
- Plan hides the tab bar, so `tab.*` cannot be tapped from here. Go back to Home first.
- Without an API key `/api/categorize` fails, so a new item keeps the app's own aisle guess.
