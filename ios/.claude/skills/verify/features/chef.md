# Chef

Chef's chat, a sheet over the screen on show with three heights: a bar with Chef's last line, half height with the screen above still in use, and full height. While you type it fills the space above the keyboard. Each message carries the screen's path (`/list/<id>`, `/recipe/<id>`, `/discover` and so on, as the web names them), and a line above the message box says what Chef is looking at. Each change Chef makes shows in the chat with its own Undo, and the screen it touched refreshes as it lands. Specified by `client/src/components/Chef.tsx` and `client/src/lib/chef.ts`; the decisions are in `docs/PRD_CHEF.md`.

## Sub-features

- `chef-sheet` opens from `tab.chef` at half height, moves between its three heights, and closes. The tab never becomes the selected tab.
- `chef-context` says what Chef is looking at: the list or recipe on screen by name, or else the page (Home, Discover, Recipes, New recipe, Settings).
- `chef-immersive` hides the sheet while Shop or Cook is up, and brings it back at the same height when they end.
- `chef-add-recipe` is Add a recipe yourself in the empty chat: it pushes Add a recipe on the tab on show and drops the sheet to its bar.
- `chef-stream` shows a reply as it arrives: text, "Searching the web…" for a web search, "Working…" for one of Chef's tools, then the change with Undo.
- `chef-refresh` refreshes what a change touched as it lands, before the reply ends: the lists on the phone, the recipes, the recipe on screen, Discover's cards and Chef's week.
- `chef-undo` undoes one change from its row, which strikes it through. One that has changed since says so (409).
- `chef-away` gives a reply's changes one banner with Undo when the chat is not on screen: closed, at the bar, or under Shop or Cook.
- `chef-photos` sends up to six photos with a message, re-encoded as Add's are.
- `chef-failure` keeps what Chef said before a failure and says it couldn't answer; with no connection it says Chef needs one.
- `chef-new-chat` starts again, dropping a reply still coming. The chat lasts while the app runs, as on the web.

## How to get to it (user POV)

- Tap Chef in the tab bar. On Plan, which hides the tab bar, tap the Chef button beside Rename.

## Driving it with omlete-ios-verify

Preconditions:

- `$V up` just ran and `$V doctor` prints no `FAIL`. `<list>` is the `Verify Fixture List` id and `<shakshuka>` the `Verify Fixture Shakshuka` recipe id (`features/README.md` says how to read them).
- The sheet's grabber has no accessibility element, so the heights are changed with `$V drag chef.title up|down <distance>`: from half, `up 0.4` is full; from full, `down 0.4` is half; from half, `down 0.35` is the bar. With the message field focused the sheet is full, and a drag can land it on any height.
- No model key means a real reply cannot run (see SKILL.md). Streaming, changes and Undo run against the canned Chef: `$V chef-stub start` starts it on port 8766 in front of the API and relaunches the app against it, `$V chef-stub stop` points the app back. Every other request passes through to the real API. Its log is `.verify-run/chef-stub.log`.

Against the real API:

- **The sheet and its heights.** `$V begin chef-sheet`, `$V tap tab.chef`, `$V expect-id chef.empty`, `$V expect "Chef is looking at: Home"`. `$V drag chef.title up 0.4` (full), `$V drag chef.title down 0.4` (half), `$V drag chef.title down 0.35`, `$V expect-id chef.bar` (the bar, reading Ask Chef). `$V tap chef.bar` and `$V expect-id chef.empty` is half again. Look at each screenshot: the bar floats over the tab bar.
- **Shop and Cook.** At half height, `$V tap home.cookCard.<shakshuka>`, `$V expect-id cook.closeButton`, `$V gone "What can I do for you?"`. `$V tap cook.closeButton` and `$V expect-id chef.empty`: back at half.
- **What Chef is looking at.** `$V tap chef.closeButton`, `$V tap tab.recipes`, `$V tap recipes.tile.<shakshuka>`, `$V tap tab.chef`, `$V expect "Chef is looking at: Verify Fixture Shakshuka"`. On Plan, `$V tap home.listRow.<list>`, `$V tap plan.chefButton`, `$V expect "Chef is looking at: Verify Fixture List"`.
- **Add a recipe yourself.** In the empty chat, `$V tap chef.addRecipeButton`, `$V expect-id add.textField`, `$V expect-id chef.bar`.
- **No model.** `$V type chef.messageField "what's for dinner?"`, `$V tap chef.sendButton`, `$V expect "Chef couldn't answer. Try again?"`. The API log has `POST /api/chef/chat` answered 200: the server streams an error event when the model call fails.

Against the canned Chef (`$V chef-stub start` first):

- **A reply streams, its change lands, and Plan refreshes before the reply ends.** `$V begin chef-stream-undo`, `$V tap home.listRow.<list>`, `$V tap plan.chefButton`, `$V type chef.messageField "add lemons to this list"`, `$V tap chef.sendButton`, then `$V expect "Let me"`, `$V expect "Searching the web"`, `$V expect "Working"`, `$V expect "Added Verify Chef Lemons to Verify Fixture List"`. `$V drag chef.title down 0.4` shows Plan at half height with `Items (7)`; `$V expect-id plan.itemRow.<item>` with `<item>` from `curl -s http://127.0.0.1:8765/api/lists/<list> | jq -r '.items[] | select(.name=="Verify Chef Lemons") | .id'`. In `.verify-run/chef-stub.log` the app's `GET /api/lists/<list>` comes after `added Verify Chef Lemons` and before `finished the reply`.
- **Undo.** `<undo>` is the id after `undo` on the stub's `added` line. `$V tap chef.undo.<undo>`: the row is struck through, Plan reads `Items (6)`, and the API no longer has the item. The stub log has `undo <undo>: deleted`.
- **Changed since.** Send another message, wait for the reply, then check the item off behind the app's back: `curl -s -X PATCH http://127.0.0.1:8765/api/lists/<list>/items/<item> -H 'content-type: application/json' -d '{"checked":true}'`. `$V tap chef.undo.<undo>` and `$V expect "That's changed since, so it can't be undone"`. The stub log has `refused` and a 409.
- **With the chat away.** Send a message, then drag the sheet down to the bar before the reply ends (the stub pauses eight seconds between steps). When the reply ends the bar reads Chef's last line and the screen has `undo.banner` with the change and `undo.button`.
- **A reply that fails.** `$V type chef.messageField "please fail"`, `$V tap chef.sendButton`, `$V expect "Chef couldn't answer. Try again?"`. "Let me find that." stays above it.
- **Photos.** `$V tap chef.addPhotosButton` opens the system picker, which has no identifiers. Tap a photo and the check with the iOS Simulator control tool by device point (on iPhone 17 Pro the first photo is near (67, 410) and the check near (366, 144)), then `$V expect-id chef.removePhoto.0`, type and send. The stub logs `with 1 photo(s)`.
- **New chat.** `$V tap chef.newChatButton`, `$V expect-id chef.empty`.

## Gotchas

- The simulator usually has a hardware keyboard connected, so a focused field shows no on-screen keyboard and the sheet sits at full height above nothing. To see the keyboard, focus `chef.messageField` and use the iOS Simulator control tool's `set_keyboard show`; `set_keyboard hide` puts it back.
- The canned Chef is test-only and lives in this skill (`scripts/chef-stub.py`). It changes nothing on the server: it adds and deletes the item through the ordinary list endpoints, and answers Undo for its own action ids only. `OMLETE_IOS_VERIFY_CHEF_STUB_PACE` scales its pauses (default 1, about eight seconds per tool step so a capture lands inside each).
- `up` stops the canned Chef and launches the app against the real API again.
- `expect "Searching the web"` and `expect "Working"` each have one window of the stub's pause. A slow capture before them can miss it; raise the pace and run again.
- Plan behind the sheet at half height is mostly covered: the item row is in the UI tree, and the `Items (n)` count is above the sheet in the screenshot.
- A real reply, with a real web search and real tools, needs `OMLETE_IOS_VERIFY_REAL_KEYS=1` and spends money. Only Alex runs that.
