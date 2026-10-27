# Home

The first screen: the meals on the list you last opened, one tap from cooking, then your lists, newest first, each with its meal count, how many items are left and a progress bar, then Chef's picks, up to three of Discover's newest ideas. Specified by the web Home (`client/src/routes/index.tsx`).

## Sub-features

- `home` shows the saved lists, and shows them from the phone's copy with the API stopped.
- `home-cook-from-list` shows a card per meal on the current list (the one last opened, else the newest); tapping one opens Cook.
- `home-plan-week` opens in Plan the list for this week, or next week on the last day of this one, counted from the shop day `GET /api/settings/plan` gives (Saturday until the phone is told). With no list for that week it makes one (`POST /api/lists/` with `week_start`), so a second tap opens the same list. The shop day is saved on the phone, so with the API stopped it still opens a week already there.
- `home-list-actions` renames, duplicates or deletes a list from its More menu. Delete hides the list at once and is sent after the Undo banner.
- `home-chef-picks` shows up to three cards nobody has acted on, in feed order, under Lists. A row or See all switches to Discover. The section is absent when there is no such card or the feed did not load.
- `home-chef-picks-clear` hides every such card, on Home and on Discover, with Undo, and sends `POST /api/suggestions/clear` with `only_new` after the banner. Cards that are saving, saved or failed stay, and so does one the server has as saved or failed that the phone still showed as a pick.
- `home-week-card` shows Chef's week below Lists while a plan is waiting (`GET /api/weeks/current`): five dinners on their evenings, each with a line of why, the new ideas marked New. Make the list (`POST /api/weeks/{id}/make`) puts their recipes on their evenings at once and shows a banner with Open and Undo for eight seconds. Undo sends `POST /api/chef/actions/{undo}/undo` and the card comes back; a list that changed since (an idea already landed) is kept and the banner says so. Open opens the list in Plan. The made list is fetched every three seconds until each new idea's free evening holds a meal, for up to eight minutes. Not this week hides the card with Undo and sends `POST /api/weeks/{id}/skip` after the banner.
- `home-no-lists` shows "No weeks planned yet" over the whole screen, or as a row in the Lists section when there are picks to show below it.

## How to get to it (user POV)

- Open the app. From another tab, tap Home in the tab bar (`tab.home`). From Plan, tap the back button (`BackButton`).

## Driving it with omlete-ios-verify

Preconditions:

- `$V up` just ran and `$V doctor` prints no `FAIL`.

- **See the lists.** `$V begin home`, then `$V expect "Verify Fixture List"` and `$V expect "2 meals · 6 to get"`.
- **Cook from the list.** `$V expect-id home.cookCard.<recipeID>`, `$V tap home.cookCard.<recipeID>`, then `$V expect-id cook.startButton`. The section title "Cook from Verify Fixture List" shows only in the screenshot.
- **Plan a week, already there.** The seed's `Verify Fixture Week` starts on the Saturday on or before today, so it is the week to plan unless today is a Friday (the week's last day, when next week is). `$V tap home.planWeekButton`, then `$V expect-id plan.list`: Plan shows `Verify Fixture Week` in the screenshot, and `.verify-run/api.log` has no `POST /api/lists/` after the seed's two.
- **Plan a week, made.** `curl -s -X PUT http://127.0.0.1:8765/api/settings/plan -H 'content-type: application/json' -d '{"week_start_weekday":0}'`, then `$V relaunch` (Home reads the shop day as it loads). `$V tap home.planWeekButton`, `$V expect-id plan.list`: the screenshot shows `Week of Mon <date>` with the strip starting on Monday, and `curl -s http://127.0.0.1:8765/api/lists/ | jq -c '[.[] | {name, week_start}]'` has one new list with that Monday as `week_start`. `$V tap BackButton`, `$V tap home.planWeekButton` again, and the API still has the same lists. The seed puts the shop day back to Saturday.
- **Plan a week with no signal.** After the step above, `$V api stop`, `$V relaunch`, `$V tap home.planWeekButton`, `$V expect-id plan.list`: Plan opens the Monday week made above, with the offline note.
- **Delete a list.** Back on Home, `$V tap home.listActions.<listID>`, `$V tap home.deleteAction`, then `$V gone "<name>"`. About seven seconds later the list is gone from `GET /api/lists/` too. `$V tap home.deleteAction then undo.button` instead keeps it, on screen and on the server.
- **Rename and duplicate.** The same menu holds `home.renameAction` (then `rename.nameField`, `rename.saveButton`) and `home.duplicateAction`.
- **See the picks.** `$V swipe home.list up`, `$V expect-id home.picks.clearButton`, then `$V snapshot | grep home.pick.` prints three rows: `Verify Card Bean Chilli`, `Verify Card Miso Aubergine` and `Verify Card Quick Noodles`, the first three of `curl -s http://127.0.0.1:8765/api/suggestions/ | jq -r '.[] | "\(.id) \(.title)"'`. The header "Chef's picks" is not in the UI tree: check it in the screenshot, and take `home.picks.clearButton` as the sign the section is there.
- **To Discover.** `$V tap home.pick.<card>`, then `$V expect-id discover.clearAllButton`. `$V tap tab.home`, `$V tap home.picks.seeAllButton` lands there too.
- **Clear the picks, undone.** `$V tap home.picks.clearButton then undo.button`, then `$V expect-id home.picks.clearButton`. All five cards are still on Discover and `.verify-run/api.log` has no `POST /api/suggestions/clear`.
- **Clear the picks.** `$V tap home.picks.clearButton`. The tap's `NN-tap.json` holds `Cleared 5 suggestions` and no `home.pick.` row. Then `$V snapshot | grep -c home.picks.clearButton` prints 0, `$V tap tab.discover`, `$V expect "No ideas here yet"`. Seven seconds after the tap, once the banner has settled, the log has one `POST /api/suggestions/clear` and `curl -s http://127.0.0.1:8765/api/suggestions/ | jq length` prints 0.
- **Clear leaves a card answered elsewhere.** `$V api seed`, `$V relaunch`, `$V swipe home.list up`, and with Home showing its three picks answer two cards behind the phone's back: `curl -s -X POST http://127.0.0.1:8765/api/suggestions/<Imported Traybake>/save -H 'content-type: application/json' -d '{}'` saves one, and `docker exec omlete-ios-verify-mongo mongosh --quiet omlete --eval 'db.suggestions.updateOne({_id: ObjectId("<Miso Aubergine>")}, {$set: {status: "failed"}})'` fails another. Home still shows Miso Aubergine as a pick. `$V tap home.picks.clearButton` says `Cleared 5 suggestions`; seven seconds later the API lists those two, still `saved` and `failed`, and Discover shows them (`$V swipe discover.feed up` for the Traybake).
- **A failed card is not a pick.** `$V api seed`, `$V relaunch` to get five cards back. With no model key a save fails for every card but the Traybake. `$V tap tab.discover`, `$V tap discover.save.<Bean Chilli>`, `$V expect "Couldn't save this one."`, `$V tap tab.home`. `home.pick.<Bean Chilli>` is gone and `Verify Card Imported Traybake` is the third pick. `$V tap home.picks.clearButton` says `Cleared 4 suggestions`, and Discover still shows the failed card.
- **No lists.** `$V api seed`, delete the list with `curl -X DELETE http://127.0.0.1:8765/api/lists/<listID>`, `$V relaunch`. `$V expect "No weeks planned yet. Plan one"` and `$V expect-id home.picks.clearButton` hold together. After `$V tap home.picks.clearButton` the full-screen message is back: `$V expect "No weeks planned yet"`, on the grouped grey background in the screenshot, and `$V snapshot | grep -c home.picks.clearButton` prints 0.
- **See Chef's week.** `$V swipe home.list up`, `$V expect-id home.week.makeButton`. `$V snapshot | grep home.week.meal.` prints the five dinners as `<Day>, <title>, <reason>`, with `New` on the two ideas. The heading `Your week from <date>` and the note are in the screenshot.
- **Make the list, and Open.** `$V tap home.week.makeButton`, then `$V tap undo.actionButton` while the banner is up (it lasts eight seconds), then `$V expect-id plan.list`. The first tap's `NN-tap.json` holds `Made Verify Fixture Week. New ideas join it as they're ready.`, `undo.actionButton` (Open) and `undo.button`. `curl -s http://127.0.0.1:8765/api/lists/<Verify Fixture Week> | jq -c '[.days[] | {date, recipe_id}]'` has the three fixture recipes on Sunday, Monday and Wednesday and the Traybake on Tuesday too, and Friday free. `.verify-run/api.log` has one `POST /api/weeks/<plan>/make` and then a `GET /api/lists/<Verify Fixture Week>` every three seconds, for the Friday idea that never lands. `GET /api/suggestions/` still lists five cards: a week's ideas stay out of the feed.
- **Make the list, undone.** The seeded Tuesday idea lands within a second, which changes the list, so an Undo after it is refused (409) and the banner says `That list has changed since, so it was kept.`. To see an Undo that goes through, block that idea first: `docker exec omlete-ios-verify-mongo mongosh --quiet omlete --eval 'db.week_plans.updateOne({}, {$set: {"meals.2.source_url": "http://127.0.0.1:9/x"}})'`. Then `$V tap home.week.makeButton then undo.button` and `$V expect-id home.week.makeButton`: the card is back, the log has `POST /api/chef/actions/<id>/undo` answered 200, and the week list has only the Traybake on Saturday again.
- **Not this week.** `$V tap home.week.skipButton then undo.button` brings the card back and sends nothing. `$V tap home.week.skipButton` alone hides it; seven seconds later the log has `POST /api/weeks/<plan>/skip` and `GET /api/weeks/current` answers `null`. `features/discover.md` drives the same card there.
- **Saved on the phone.** `$V api stop`, `$V relaunch`, `$V expect "Verify Fixture List"`.

## Gotchas

- Making a week and Duplicate need the API: the server mints the id and the name. With the API stopped they show an inline error. Opening a week that is already there does not.
- The row's label is the whole row ("Verify Fixture List, 1 meal · 6 to get, ..."), so `expect` on the name alone matches it.
- The More menu's actions exist only while the menu is open.
- The seed sets the cards' creation times a minute apart, so the feed order is the same on every seed: Bean Chilli, Miso Aubergine, Quick Noodles, Imported Traybake, Loose Idea. Ids are still new each time.
- Home asks for the feed on its first appearance, on a pull to refresh and when the app comes to the front, not each time its tab is shown. A card changed with `curl` or in Mongo shows on Home after `$V relaunch`, or after a visit to Discover, which does ask each time.
- On a fresh launch the third pick is in the UI tree but behind the tab bar in the screenshot. `$V swipe home.list up` first when the picture matters.
- `$V api seed` followed by `$V relaunch` puts the five cards back without a rebuild, and the week plan too.
- The week card is below Lists, so on a fresh launch `$V swipe home.list up` before tapping its buttons.
