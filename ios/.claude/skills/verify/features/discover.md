# Discover

Chef's suggestions as shelves of cards that scroll sideways: For this week, Under 30 minutes, Something new, then More ideas for any card with no shelf of its own. Each card has a picture, title, time, source and the reason it was suggested, with Save, Add to list and Not for me. Specified by `client/src/routes/discover.tsx` and `client/src/components/SuggestionCard.tsx`.

## Sub-features

- `discover-feed` shows the cards in their shelves, in section order.
- `discover-save` turns a card into a recipe. The card says "Saving." at once, the feed is polled every three seconds while any card is saving, and the card then reads Saved and opens its recipe. A save that fails reads "Couldn't save this one." with Try again.
- `discover-add-to-list` puts a card's meal on a list. An unsaved card is saved first, and the server adds it to the list when the recipe exists.
- `discover-not-for-me` hides a card at once with Undo, and tells the server after the banner.
- `discover-clear-all` hides every card that is not saving, with Undo. The server learns nothing about taste from it.
- `discover-get-ideas` asks for a new batch from the toolbar button or by pulling down.
- `discover-tune` sets diet, effort and a note for the next batch, and remembers them.

## How to get to it (user POV)

- Tap Discover in the tab bar. From the empty recipe library, tap Browse Discover.

## Driving it with omlete-ios-verify

Preconditions:

- `$V up` just ran, `$V doctor` prints no `FAIL`, and `$V tap tab.discover` has run.
- `<card>` is a suggestion id: `curl -s http://127.0.0.1:8765/api/suggestions/ | jq -r '.[] | "\(.id) \(.title)"'`. The seed leaves five cards: `Verify Card Bean Chilli` and `Verify Card Miso Aubergine` (For this week), `Verify Card Quick Noodles` (Under 30 minutes), `Verify Card Imported Traybake` (Something new) and `Verify Card Loose Idea` (More ideas).

- **See the shelves.** `$V begin discover-feed`, `$V expect "Verify Card Bean Chilli"`, `$V expect "You rated the shakshuka highly."`, then `$V swipe discover.feed up` and `$V expect "Verify Card Loose Idea"`. The shelf titles show in the screenshot. `$V swipe discover.shelf.thisWeek left` brings the second card of a shelf into view.
- **Save, and open the recipe.** `$V swipe discover.feed up`, `$V tap discover.save.<Imported Traybake>`, then `$V expect-id discover.saved.<Imported Traybake>`. `$V tap discover.saved.<Imported Traybake>`, then `$V expect-id recipe.cookButton`. The API shows the card `saved` with a `recipe_id`.
- **A save that fails.** `$V tap discover.save.<Bean Chilli>`, then `$V expect "Couldn't save this one."`. The button now reads Try again.
- **Add an unsaved card to a list.** `$V tap discover.addToList.<Imported Traybake>`. The tap's `NN-tap.json` holds `Saving Verify Card Imported Traybake. It goes on Verify Fixture List when it's ready.` Then `$V expect-id discover.saved.<Imported Traybake>`, `$V tap tab.home`, `$V expect "3 meals"`.
- **Add a saved card to a list.** Once a card reads Saved, `discover.addToList.<card>` adds its recipe at once with `Added <title> to <list>` and Undo. `discover.addToList.<card>.choose` opens the picker (`listPicker.list.<listID>`, `listPicker.newListButton`).
- **Not for me.** `$V tap discover.notForMe.<card> then undo.button`, then `$V expect "<title>"`: the card is back and the API still has it as `new`. Without `then undo.button` the tap's `NN-tap.json` holds `Hid <title>. You'll see less like it.`, and seven seconds later `curl -s http://127.0.0.1:8765/api/suggestions/` no longer lists it and `.verify-run/api.log` has one `PATCH /api/suggestions/<card>`.
- **Clear all.** `$V tap discover.clearAllButton`, then `$V expect "No ideas here yet"`. Seven seconds later the API lists no cards and the log has `POST /api/suggestions/clear`. `$V tap discover.clearAllButton then undo.button` keeps them.
- **Get new ideas, failing.** `$V tap discover.getIdeasButton`. The tap's `NN-tap.json` holds `Couldn't get new ideas right now. Try again in a bit.` and the log has `POST /api/suggestions/refresh` answered 500.
- **Tune.** `$V tap discover.tuneButton`, `$V tap tune.diet.vegan`, `$V tap tune.effort.quick`, `$V type tune.notesField "more fish"`, `$V tap tune.applyButton`. The log has `POST /api/suggestions/refresh`. Then `$V relaunch`, `$V tap tab.discover`, `$V tap discover.tuneButton`, `$V expect "More fish"` (the field capitalises the first letter as the keyboard would). The screenshot shows Vegan and Quick & easy still chosen.

## Gotchas

- These recipes rely on the API having no model key, which is how `up` starts it whatever `server/.env` holds. With `OMLETE_IOS_VERIFY_REAL_KEYS=1` the model calls succeed, cost money and never show their failure.
- With no key, only `Verify Card Imported Traybake` can be saved. Its link is the source of the `Verify Fixture Traybake` recipe, so the server finds that recipe without asking a model. Every other card fails to save, and Get new ideas always fails. Their success is covered by `ChefTests`.
- Saving the Traybake card takes under a second, so "Saving." is rarely on screen for a capture. `Verify Card Bean Chilli` shows it for a moment before it fails.
- Shelf titles and the "Finding new ideas…" row are plain text in a scroll view and are in the UI tree, but only for shelves on screen. Scroll with `discover.feed` first.
- A card that is saving cannot be dismissed or cleared: Not for me is disabled and Clear all leaves it.
- Card ids are new on every seed.
