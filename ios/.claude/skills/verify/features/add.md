# Add a recipe

One field that takes a link or a description, plus Choose photos for pictures of a recipe. Text with a web address anywhere in it is a link, and whatever is typed with the address ("<link> but use tofu mince") goes with it as the changes to make, as `client/src/lib/splitLink.ts` does on the web. The button says what it will do: Import recipe for a link, Import with changes for a link with words around it, Create recipe for a description, Read n photos for photos. It ends on the saved recipe with Add to list and Open. Specified by `client/src/routes/create.tsx`. Taking a photo with the camera is not built.

The server makes the recipe as a job under a key the app mints. A tap writes the key to the phone, then the app sends the start (`PUT /api/recipe-jobs/<key>/link`, `/describe` or `/photos`, answered 202, or 200 when the server already has that key) and asks after it (`GET /api/recipe-jobs/<key>`) until it ends. Coming back, a relaunch and the network returning all do the same thing: ask for the job, and send the start again if the answer is 404. The job is over for the phone eight minutes after the tap whatever the server says. The web waits on one long request instead.

## Sub-features

- `add-link` imports a recipe from a web address.
- `add-link-with-changes` imports a link with what was typed around it sent as `changes`, and says Making your changes… while it works.
- `add-already-saved` answers a link imported before with "You've already saved that one." and Open it.
- `add-describe` writes a recipe from a description.
- `add-photos` reads a recipe from photos chosen in the photo library.
- `add-failure` shows what went wrong, in words that fit the kind of request.
- `add-result` shows the saved recipe with Add to list and Open.
- `add-resume` comes back to a job that was outstanding when the app was killed or left, and shows its outcome without starting it again.
- `add-lost-start` sends a start again under the same key when its answer never arrived, and the server still has one job.
- `add-waiting` says it is waiting for a connection, or that Omlete is having trouble, when the job cannot be asked after.
- `add-busy` says Omlete is busy when the server is already making four recipes.
- `add-bound` ends a job nothing has answered for, eight minutes after the tap.
- `add-restart` shows a job the server was restarted under as a failure on the next look.

## How to get to it (user POV)

- Tap Add in the tab bar. From the empty recipe library, tap Add a recipe.

## Driving it with omlete-ios-verify

Preconditions:

- `$V up` just ran, `$V doctor` prints no `FAIL`, and `$V tap tab.add` has run.

- **The button follows the input.** `$V begin add`, `$V expect "Create recipe"`, `$V type add.textField "https://example.com/some-recipe"`, `$V expect "Import recipe"`, `$V type add.textField "leek and potato soup"`, `$V expect "Create recipe"`.
- **A link with changes.** `$V type add.textField "http://127.0.0.1:9/x but use tofu mince"`, `$V expect "Import with changes"`, `$V tap add.submitButton`, `$V expect "That link can't be fetched. Check it's a full, public recipe URL."`, `$V expect "but use tofu mince"`. The log has `PUT /api/recipe-jobs/<key>/link`, not `/describe`. With `http://example.com:81/x but use tofu mince` the job works for five seconds and `$V expect "Making your changes"` passes first. The API log has no bodies, and the job document keeps only its kind, so to read the `changes` the app sent, put a body-logging pass-through on another port in front of the API and `OMLETE_IOS_VERIFY_API_PORT=<that port> $V relaunch`; the start's body is `{"url":"http://127.0.0.1:9/x","changes":"but use tofu mince"}`, and a bare link's has no `changes`.
- **Already saved.** `$V type add.textField "https://example.com/verify-fixture-traybake"`, `$V tap add.submitButton`, `$V expect "You've already saved that one."`, `$V tap add.openExistingLink`, `$V expect-id recipe.cookButton`. `.verify-run/api.log` has `PUT /api/recipe-jobs/<key>/link` answered 202, then `GET /api/recipe-jobs/<key>` answered 200.
- **A link that cannot be fetched.** `$V type add.textField "http://127.0.0.1:9/x"`, `$V tap add.submitButton`, `$V expect "That link can't be fetched. Check it's a full, public recipe URL."`. The log has the same two requests.
- **A site that does not answer.** `$V type add.textField "http://example.com:81/x"`, `$V tap add.submitButton`, `$V expect "That site didn't respond. It may be down or blocking us. Try again in a minute."`. The job works for five seconds first, with a `GET` about every second and a half.
- **A description that fails.** `$V type add.textField "leek and potato soup"`, `$V tap add.submitButton`, `$V expect "Something went wrong making that recipe. Try again."`. The log has `PUT /api/recipe-jobs/<key>/describe` answered 202, a traceback under `Recipe job <key> failed`, and the `GET`s.
- **Omlete is busy.** Fill the server's four places from the shell, then tap within five seconds: `for i in 1 2 3 4; do curl -s -o /dev/null -X PUT http://127.0.0.1:8765/api/recipe-jobs/$(uuidgen)/link -H 'content-type: application/json' -d '{"url":"http://example.com:81/x"}'; done`, `$V tap add.submitButton`, `$V expect "Omlete is busy making other recipes. Try again shortly."`. The log has the app's `PUT` answered 429 and no `GET` for its key.
- **A start whose answer never arrives, then the app is killed.** `$V type add.textField "http://example.com:81/x"`, `$V api freeze`, `$V tap add.submitButton`, `$V relaunch`, `$V tap tab.add`, and `$V snapshot` shows the working line. `$V api release`, then `OMLETE_IOS_VERIFY_TIMEOUT_MS=60000 $V expect "That site didn't respond"`. The frozen API read the first start off a connection the killed app had closed, so it made the job and logged nothing. The log has the relaunched app's `GET` answered 404, then its `PUT` answered 200, which is the server saying it already had that key, then `GET`s. `docker exec omlete-ios-verify-mongo mongosh --quiet omlete --eval 'db.recipe_jobs.countDocuments({})'` before and after differs by one.
- **A job outlives the app being killed.** `$V type add.textField "http://example.com:81/x"`, `$V api hold &`, `$V tap add.submitButton`, then `OMLETE_IOS_VERIFY_TIMEOUT_MS=90000 $V expect "Waiting for a connection"` (two unanswered looks, about 45 seconds). `$V relaunch`, `$V tap tab.add`, and `$V snapshot` shows the working line again with the button disabled. `$V api release`, then `OMLETE_IOS_VERIFY_TIMEOUT_MS=60000 $V expect "That site didn't respond"` and `$V expect "example.com:81/x"`. The log has one `PUT /api/recipe-jobs/<key>/link` for the whole run, and the `GET`s after the release come from the relaunched app.
- **A job outlives the app being left.** As above up to `$V tap add.submitButton`, then press Home with `npx -y xcodebuildmcp@latest ui-automation button --simulator-id <udid> --button-type home` (the udid is in `.verify-run/state`), `$V api release`, and wait 15 seconds: the job ends on the server while the app is suspended, and `curl -s http://127.0.0.1:8765/api/recipe-jobs/<key>` says `failed`. Come back by tapping the Omlete icon (`ui-automation snapshot-ui`, then `ui-automation tap --element-ref <ref>`), `$V expect "That site didn't respond"`, and `$V doctor` shows the same pid. The log has one `PUT` and no second one after the return.
- **The server is restarted under a job.** `$V type add.textField "http://example.com:81/x"`, `$V api bounce &`, `$V tap add.submitButton`, `$V expect "Something went wrong making that recipe. Try again."`, which passes about eight seconds after the tap. `.verify-run/api.before-bounce.log` ends with the `PUT`, `Shutting down` and `Application shutdown complete`, and `curl -s http://127.0.0.1:8765/api/recipe-jobs/<key>` says `failed` with `other`: the old API wrote that as it stopped. Had the job run on it would have said `site_did_not_respond`.
- **Nothing answers.** `$V type add.textField "http://example.com:81/x"`, `$V api freeze`, `$V tap add.submitButton`, `OMLETE_IOS_VERIFY_TIMEOUT_MS=90000 $V expect "Waiting for a connection"`, then `OMLETE_IOS_VERIFY_TIMEOUT_MS=540000 $V expect "Omlete didn't answer in time. Check your recipes before trying again."`, which passes eight minutes after the tap, and `$V api release`. The field still holds the link and the button is enabled.
- **No connection.** `$V type add.textField "leek and potato soup"`, `$V api stop`, `$V tap add.submitButton`, `$V expect "Couldn't reach Omlete. Check your connection and try again."`, `$V expect "leek and potato soup"`, then `$V api start`. A refused connection never leaves the phone, so this fails at once with no job; the log has no `PUT`.
- **A server that is killed under a job.** `$V api hold &`, `$V tap add.submitButton`, `$V api stop`, `$V api start`. A frozen process cannot shut down, so `stop` kills it and the job is left `working` with no task. Six minutes after the start `curl -s http://127.0.0.1:8765/api/recipe-jobs/<key>` says `failed`, and `OMLETE_IOS_VERIFY_TIMEOUT_MS=480000 $V expect "Something went wrong making that recipe. Try again."` passes.

## Gotchas

- The field autocorrects, so a word the keyboard does not know is changed as `$V type` enters it: "quorn" arrives as "quorum". Use words it leaves alone, such as "tofu".

- These recipes rely on the API having no model key, which is how `up` starts it whatever `server/.env` holds. With `OMLETE_IOS_VERIFY_REAL_KEYS=1` the model calls succeed, cost money and never show their failure.
- With no key, nothing here can end on a saved recipe, so `add-result` (`add.addToList`, `add.openButton`) cannot be driven. `RecipeIntakeTests` and `ExploreAPITests` cover a saved link, description and photos against a scripted server, and a saved job whose recipe has been deleted, and `server/tests/test_recipe_jobs.py` covers a job that ends saved.
- Choose photos (`add.choosePhotosButton`) opens the system photo picker, which runs outside the app and has no identifiers to drive. `PhotoEncoderTests` covers the re-encoding, `ExploreAPITests` the upload, and `RecipeIntakeTests` the message after a relaunch when the photos had not arrived ("Your photos didn't reach Omlete before the app closed. Choose them again.").
- The 404 message for a link ("Couldn't find a recipe on that page") needs a public page that answers but holds no recipe, and with no model key the server cannot tell. `ExploreAPITests` and `server/tests/test_recipe_jobs.py` cover it.
- `http://example.com:81/x` is a real address on the internet that never answers, so those recipes need the Mac to be online. The server gives up connecting after five seconds, which is what holds the job open. A local address cannot stand in: the import refuses anything that is not public.
- `api hold` and `api freeze` freeze the whole API, not only the job, so everything the app asks hangs until `api release`. A held API also stops the job's own clock, so release it before reading anything into how long the job took.
- `api hold` acts after the start is answered, and the app looks at the job at once, so the log can hold one answered `GET` from before the freeze.
- Leave ten seconds between recipes that use `http://example.com:81/x` from the shell and a tap: jobs still working count towards the four the server allows.
- "Omlete is having trouble" (`add.serverTrouble`) needs the API to answer 5xx or something unreadable, which the local one does not. `RecipeIntakeTests` covers it.
- While a job is working the field is disabled and drops out of the UI tree, so `expect` cannot find what was typed until the job ends. The screenshot shows it.
- A simulator can hold a second app called Omlete (an Xcode template that shows "Hello, world!"). If the icon you tap opens that, press Home and tap the other one.
- `simulator launch-app` restarts a running app and drops the `-apiBaseURL` argument. To bring the app back to the front, tap its icon.
- The field keeps what was typed after a failure or an already-saved link, and clears only when a recipe is saved. `$V type` replaces its contents.
- With a photo attached the field is disabled and its text is ignored.
