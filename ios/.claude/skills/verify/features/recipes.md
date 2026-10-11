# Recipes

The recipe library and the recipe page. The library is a grid of every saved recipe with its picture, title, rating, time and source, a search field, a sort menu and three filter chips. The page shows one recipe: Cook, Add to list, your rating, the ingredients in the source's groups with an On list toggle each, and the method. Specified by `client/src/routes/recipes.tsx` and `client/src/routes/recipe.$recipeId.tsx`. Editing a recipe is not built.

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

## How to get to it (user POV)

- Tap Recipes in the tab bar, then a recipe. A saved Discover card and the Add result also open the page.

## Driving it with omlete-ios-verify

Preconditions:

- `$V up` just ran, `$V doctor` prints no `FAIL`, and `$V tap tab.recipes` has run.
- `<traybake>`, `<shakshuka>`, `<egg>` and `<cake>` are the four fixture recipe ids: `curl -s http://127.0.0.1:8765/api/recipes/ | jq -r '.[] | "\(.id) \(.title)"'`. Only `Verify Fixture Traybake` has a source (`example.com`), ingredient groups and an ingredient kept off lists. It is rated 5 and takes 45 minutes. `Verify Fixture Shakshuka` is rated 4 and takes 25.

- **See the library.** `$V begin recipes-library`, `$V expect "4 saved"`, `$V expect "Verify Fixture Traybake"`.
- **Search.** `$V type recipes.searchField "tray"`, `$V gone "Verify Fixture Shakshuka"`, `$V expect "Verify Fixture Traybake"`. `$V type recipes.searchField "zzz"`, then `$V expect "Nothing matches"`. `$V tap recipes.clearSearchButton` brings all four back.
- **Filter.** `$V tap recipes.filter.fromTheWeb`, `$V gone "Verify Fixture Shakshuka"`; tap it again to clear. `recipes.filter.quick` leaves only the Shakshuka, and `recipes.filter.favourites` leaves the Shakshuka and the Traybake.
- **Sort.** `$V tap recipes.sortMenu`, `$V tap recipes.sort.topRated`. Read the order from `$V snapshot`: the tiles are listed as `recipes.tile.<id>` in grid order, Traybake first, then Shakshuka. `recipes.sort.quickest` puts the Shakshuka first; `recipes.sort.alphabetical` puts the Lemon Drizzle Cake first.
- **Open the page.** `$V tap recipes.tile.<traybake>`, then `$V expect "For the dressing"`, `$V expect "Serves 4"`, `$V expect "olive oil: not on shopping lists"`. The title and "For the traybake" show in the screenshot.
- **On list.** `$V tap recipe.onList.0`, then `$V expect "chicken thighs: not on shopping lists"`. `curl -s http://127.0.0.1:8765/api/recipes/<traybake> | jq '.ingredients[0].excluded_from_list'` prints `true`.
- **Rate.** `$V tap recipe.star.3`; `curl -s http://127.0.0.1:8765/api/recipes/<traybake> | jq .rating` prints `3`.
- **Add to list.** `$V tap recipe.addToList`. The tap's `NN-tap.json` holds `Added Verify Fixture Traybake to Verify Fixture List` and `undo.button`. A second tap, after the banner has gone, holds `Verify Fixture Traybake is already on Verify Fixture List`. `$V tap tab.home`, `$V expect "3 meals"`. `$V tap recipe.addToList then undo.button` on a recipe not yet on the list leaves the list as it was.
- **Pick a list.** `$V tap recipe.addToList.choose`, `$V expect "Current"`, then `$V tap listPicker.newListButton`: the API has a second list holding the recipe.
- **Cook.** `$V tap recipe.cookButton`, `$V expect-id cook.startButton`, `$V tap cook.closeButton`, `$V expect-id recipe.cookButton`.
- **Delete with Undo.** `$V tap recipe.moreMenu`, then `$V tap recipe.deleteAction then undo.button`, then `$V expect "Verify Fixture Traybake"` in the library. Without `then undo.button`, `$V gone "Verify Fixture Traybake"` passes and seven seconds later the API no longer has the recipe.
- **A recipe that is gone.** Delete a recipe through the API while its page is not open, open it from a saved Discover card, and `$V expect "This recipe doesn't exist any more."`.

## Gotchas

- The grid's own empty state ("No recipes yet", `recipes.addRecipeButton`, `recipes.browseDiscoverButton`) needs a library with no recipes. Delete the four fixtures through the API (`curl -X DELETE http://127.0.0.1:8765/api/recipes/<id>`), then pull the grid down or `$V relaunch`.
- The Sort menu's items exist only while the menu is open.
- An ingredient row's toggle is labelled `<name>: on shopping lists` or `<name>: not on shopping lists`; the visible text is "On list" or "Not on list". Its id is `recipe.onList.<n>`, where `n` is the ingredient's position in the recipe, counted from 0 across all groups.
- A rating tile reads "5 stars" in the UI tree and shows a star and the number on screen.
- No fixture recipe has a picture, so every tile and the page show the placeholder, and the page has no hero picture.
- The recipe page keeps the tab bar. Plan does not: it hides it so Start shopping has the bottom of the screen.
- The page reads its recipe from the same saved copy Cook uses, so a recipe opened once still shows with the API stopped.
