# Settings

One section, Aisles: the aisles in the order lists are grouped by, each with its name in a field, a delete button and a drag handle, then a field that adds a new aisle. Specified by `client/src/routes/settings.tsx`. Every change is one `PUT /api/settings/categories` of the whole order, and Plan, Shop and both aisle pickers follow it. A change made while the API cannot be reached is kept on the phone and sent later. Opening Settings asks for the aisles alone: one `GET /api/settings/categories`.

## Sub-features

- `settings-cog` opens Settings from the cog on each tab's first screen, pushed on that tab's stack.
- `settings-add` adds an aisle last. A name another aisle has, whatever its case, is refused under the field.
- `settings-rename` renames an aisle in its row, when the field is left or Back is tapped, and not when the row scrolls off screen. A name another aisle has is refused under the row and stays in the field, and an emptied name goes back to the old one.
- `settings-delete` hides an aisle at once and sends the order after the Undo banner. Undo sends nothing.
- `settings-reorder` moves an aisle by its handle.
- `settings-items-keep-their-aisle` leaves the items of a renamed or deleted aisle under the old name, after every aisle still in the order.
- `settings-offline` keeps a change made with the API away, shows it, and sends it when the app next comes to the front, is relaunched or loads the aisles. A save the server refuses (a 4xx) is put back and the banner says so; only the unit tests cover that (`AisleStoreTests`, `AisleDraftsTests`).
- `settings-not-loaded` shows the saved aisles greyed out, with Try again, until the API has answered once this launch. An order still owed is the one shown.

## How to get to it (user POV)

- On Home, Discover, Add or Recipes, tap the cog at the top left (`home.settingsButton`, `discover.settingsButton`, `add.settingsButton`, `recipes.settingsButton`). Back (`BackButton`) returns to that tab.

## Driving it with omlete-ios-verify

Preconditions:

- `$V up` just ran and `$V doctor` prints no `FAIL`. The seed puts the aisles back to the server's nine defaults: Fresh Produce, Meat & Fish, Dairy & Eggs, Bakery, Pantry & Dry Goods, Frozen, Drinks, Household, Other.
- `curl -s http://127.0.0.1:8765/api/settings/categories | jq -c '[.[].name]'` is the second view of every step below.

- **Open from each tab.** `$V tap tab.<tab>`, `$V tap <tab>.settingsButton`, `$V expect-id settings.newAisleField`, `$V tap BackButton`, `$V expect-id <tab>.settingsButton`, for `home`, `discover`, `add` and `recipes`.
- **Add.** `$V type settings.newAisleField "World foods"`, `$V tap settings.addAisleButton`, `$V expect-id "settings.aisle.World foods"`. The API lists it last with `order` 9. In Plan, `$V tap plan.itemRow.<itemID>`, `$V tap itemSheet.categoryPicker`, `$V expect "World foods"`.
- **A name already taken.** `$V type settings.newAisleField "bakery"`, `$V tap settings.addAisleButton`, `$V expect "There's already an aisle called Bakery."`. The log gains no `PUT /api/settings/categories`.
- **Rename.** `$V type "settings.aisle.Dairy & Eggs" "Dairy"`, `$V tap settings.newAisleField` to leave the field, `$V expect-id settings.aisle.Dairy`. Typing and then `$V tap BackButton` saves it too.
- **A rename that is refused.** `$V type settings.aisle.Frozen "drinks"`, `$V tap settings.newAisleField`, `$V expect "There's already an aisle called Drinks."`, `$V expect-id settings.aisle.Frozen`. The row's field still holds what was typed: `$V snapshot` shows `Drinks` as the value of `settings.aisle.Frozen` (the keyboard capitalises it). Typing a free name there and leaving the field renames the aisle.
- **Delete, undone.** `$V tap "settings.deleteAisle.Fresh Produce" then undo.button`, `$V expect-id "settings.aisle.Fresh Produce"`. Seven seconds later the log has no new `PUT /api/settings/categories`.
- **Delete.** `$V tap "settings.deleteAisle.Fresh Produce"`. The tap's `NN-tap.json` holds `Deleted Fresh Produce` and `undo.button`, and no PUT has gone out. Seven seconds later the log has one more PUT and the API no longer lists the aisle.
- **Where its items go.** After the delete, open the fixture list in Plan. The API still gives onion, red pepper and bananas the category `Fresh Produce`, and the screenshot shows that section last, after Pantry & Dry Goods and any other aisle no longer in the order. A renamed aisle's items do the same under the old name.
- **Reorder.** No helper step moves a handle, so drag the handle by its element with the CLI. The handle is the button labelled `Reorder <name>`: take its ref from a fresh snapshot (`npx -y xcodebuildmcp@latest ui-automation snapshot-ui | grep "Reorder Drinks"`, first column) and run `npx -y xcodebuildmcp@latest ui-automation drag --element-ref <ref> --direction up --distance 0.2 --duration 2 --pre-delay 1 --steps 20`. A distance of 0.2 moves the aisle about three rows on an iPhone 17 Pro, so read how far it went from the API's order and do not assume it. Then check the section order in Plan's and Shop's screenshots.
- **Scrolling renames nothing.** With a list too long for the screen (PUT about 25 aisles with curl, `$V relaunch`, open Settings), `$V type "settings.aisle.<first>" "Greens"`, then `$V swipe settings.list up` three times. The row is no longer in `$V snapshot` and the log has no new PUT. Swipe back down: the field still holds `Greens`. `$V tap BackButton` then sends the rename.
- **A change made with the API away.** `$V api stop`, `$V type settings.newAisleField "Nowhere"`, `$V tap settings.addAisleButton`. The tap's `NN-tap.json` holds `settings.aisle.Nowhere` and no `Couldn't reach Omlete`. `$V relaunch`, `$V tap home.settingsButton`: the aisle is still listed, under `Aisles can be changed once it answers`. `$V api start` (the API still lists the old order), `$V relaunch`: the new `api.log` has one PUT and the API lists `Nowhere`. A delete made with the API stopped goes the same way once its banner has settled.
- **Not loaded.** `$V api stop`, `$V relaunch`, `$V tap home.settingsButton`, `$V expect "Aisles can be changed once it answers"`. The screenshot shows the rows greyed out with no handles. `$V api start`, `$V tap settings.retryButton`, `$V gone "Aisles can be changed once it answers"`.

## Gotchas

- The title "Settings" and the section header "Aisles" are not in the UI tree. The explanation under the section is, as one text.
- An id with a space or an ampersand in it needs quoting in the shell: `"settings.aisle.Dairy & Eggs"`.
- `$V type` leaves the keyboard in the field. A rename is sent when the field is left, so tap another field or Back before reading the API.
- `settings.addAisleButton` is in the UI tree only while the new-aisle field holds text.
- `$V type settings.newAisleField` taps the field first. With eleven aisles and the keyboard up, that tap has landed on the Discover tab instead, so make a long list with curl, not by adding.
- `$V api start` begins a new `api.log`.
- `$V type` cannot type an empty or all-space text, so an emptied name going back to the old one is covered by the unit tests (`AisleOrderTests`) and not by a drive.
- The handles have no identifier. They are system controls labelled `Reorder <name>`.
- `.verify-run/api.log` is not cleared by `up`, so count `PUT /api/settings/categories` lines before and after a step.
- A change made within the five seconds of a delete's banner is saved with the deleted aisle still in its place: one PUT, and none on Undo. The helper is too slow for a second action inside the banner (about five seconds a step); taps by coordinate through the iOS Simulator tool do it.
- While that banner is up the deleted aisle's name is still taken: adding or renaming to it is refused with "<name> is being deleted. Tap Undo to keep it."
- Settings can be open under more than one tab at once. Each shows the same order.
