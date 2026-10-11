# Home

The first screen: the meals on the list you last opened, one tap from cooking, then your lists, newest first, each with its meal count, how many items are left and a progress bar, then Chef's picks, up to three of Discover's newest ideas. Specified by the web Home (`client/src/routes/index.tsx`).

## Sub-features

- `home` shows the saved lists, and shows them from the phone's copy with the API stopped.
- `home-cook-from-list` shows a card per meal on the current list (the one last opened, else the newest); tapping one opens Cook.
- `home-new-list` creates a list (the server names it after today's date) and opens it in Plan.
- `home-list-actions` renames, duplicates or deletes a list from its More menu. Delete hides the list at once and is sent after the Undo banner.
- `home-chef-picks` shows up to three cards nobody has acted on, in feed order, under Lists. A row or See all switches to Discover. The section is absent when there is no such card or the feed did not load.
- `home-chef-picks-clear` hides every such card, on Home and on Discover, with Undo, and sends `POST /api/suggestions/clear` with `only_new` after the banner. Cards that are saving, saved or failed stay, and so does one the server has as saved or failed that the phone still showed as a pick.
- `home-no-lists` shows "No lists yet" over the whole screen, or as a row in the Lists section when there are picks to show below it.

## How to get to it (user POV)

- Open the app. From another tab, tap Home in the tab bar (`tab.home`). From Plan, tap the back button (`BackButton`).

## Driving it with omlete-ios-verify

Preconditions:

- `$V up` just ran and `$V doctor` prints no `FAIL`.

- **See the lists.** `$V begin home`, then `$V expect "Verify Fixture List"` and `$V expect "2 meals · 6 to get"`.
- **Cook from the list.** `$V expect-id home.cookCard.<recipeID>`, `$V tap home.cookCard.<recipeID>`, then `$V expect-id cook.startButton`. The section title "Cook from Verify Fixture List" shows only in the screenshot.
- **New list.** `$V tap home.newListButton`, then `$V expect-id plan.quickAddField`: the app is now in Plan for the new list. `curl -s http://127.0.0.1:8765/api/lists/ | jq -c '[.[].name]'` shows two names.
- **Delete a list.** Back on Home, `$V tap home.listActions.<listID>`, `$V tap home.deleteAction`, then `$V gone "<name>"`. About seven seconds later the list is gone from `GET /api/lists/` too. `$V tap home.deleteAction then undo.button` instead keeps it, on screen and on the server.
- **Rename and duplicate.** The same menu holds `home.renameAction` (then `rename.nameField`, `rename.saveButton`) and `home.duplicateAction`.
- **See the picks.** `$V swipe home.list up`, `$V expect-id home.picks.clearButton`, then `$V snapshot | grep home.pick.` prints three rows: `Verify Card Bean Chilli`, `Verify Card Miso Aubergine` and `Verify Card Quick Noodles`, the first three of `curl -s http://127.0.0.1:8765/api/suggestions/ | jq -r '.[] | "\(.id) \(.title)"'`. The header "Chef's picks" is not in the UI tree: check it in the screenshot, and take `home.picks.clearButton` as the sign the section is there.
- **To Discover.** `$V tap home.pick.<card>`, then `$V expect-id discover.clearAllButton`. `$V tap tab.home`, `$V tap home.picks.seeAllButton` lands there too.
- **Clear the picks, undone.** `$V tap home.picks.clearButton then undo.button`, then `$V expect-id home.picks.clearButton`. All five cards are still on Discover and `.verify-run/api.log` has no `POST /api/suggestions/clear`.
- **Clear the picks.** `$V tap home.picks.clearButton`. The tap's `NN-tap.json` holds `Cleared 5 suggestions` and no `home.pick.` row. Then `$V snapshot | grep -c home.picks.clearButton` prints 0, `$V tap tab.discover`, `$V expect "No ideas here yet"`. Seven seconds after the tap, once the banner has settled, the log has one `POST /api/suggestions/clear` and `curl -s http://127.0.0.1:8765/api/suggestions/ | jq length` prints 0.
- **Clear leaves a card answered elsewhere.** `$V api seed`, `$V relaunch`, `$V swipe home.list up`, and with Home showing its three picks answer two cards behind the phone's back: `curl -s -X POST http://127.0.0.1:8765/api/suggestions/<Imported Traybake>/save -H 'content-type: application/json' -d '{}'` saves one, and `docker exec omlete-ios-verify-mongo mongosh --quiet omlete --eval 'db.suggestions.updateOne({_id: ObjectId("<Miso Aubergine>")}, {$set: {status: "failed"}})'` fails another. Home still shows Miso Aubergine as a pick. `$V tap home.picks.clearButton` says `Cleared 5 suggestions`; seven seconds later the API lists those two, still `saved` and `failed`, and Discover shows them (`$V swipe discover.feed up` for the Traybake).
- **A failed card is not a pick.** `$V api seed`, `$V relaunch` to get five cards back. With no model key a save fails for every card but the Traybake. `$V tap tab.discover`, `$V tap discover.save.<Bean Chilli>`, `$V expect "Couldn't save this one."`, `$V tap tab.home`. `home.pick.<Bean Chilli>` is gone and `Verify Card Imported Traybake` is the third pick. `$V tap home.picks.clearButton` says `Cleared 4 suggestions`, and Discover still shows the failed card.
- **No lists.** `$V api seed`, delete the list with `curl -X DELETE http://127.0.0.1:8765/api/lists/<listID>`, `$V relaunch`. `$V expect "No lists yet. Start one"` and `$V expect-id home.picks.clearButton` hold together. After `$V tap home.picks.clearButton` the full-screen message is back: `$V expect "No lists yet"`, on the grouped grey background in the screenshot, and `$V snapshot | grep -c home.picks.clearButton` prints 0.
- **Saved on the phone.** `$V api stop`, `$V relaunch`, `$V expect "Verify Fixture List"`.

## Gotchas

- New list and Duplicate need the API: the server mints the id and the name. With the API stopped they show an inline error.
- The row's label is the whole row ("Verify Fixture List, 1 meal · 6 to get, ..."), so `expect` on the name alone matches it.
- The More menu's actions exist only while the menu is open.
- The seed sets the cards' creation times a minute apart, so the feed order is the same on every seed: Bean Chilli, Miso Aubergine, Quick Noodles, Imported Traybake, Loose Idea. Ids are still new each time.
- Home asks for the feed on its first appearance, on a pull to refresh and when the app comes to the front, not each time its tab is shown. A card changed with `curl` or in Mongo shows on Home after `$V relaunch`, or after a visit to Discover, which does ask each time.
- On a fresh launch the third pick is in the UI tree but behind the tab bar in the screenshot. `$V swipe home.list up` first when the picture matters.
- `$V api seed` followed by `$V relaunch` puts the five cards back without a rebuild.
