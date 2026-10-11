# Add a recipe

One field that takes a link or a description, plus Choose photos for pictures of a recipe. The button says what it will do: Import recipe for a link, Create recipe for a description, Read n photos for photos. It ends on the saved recipe with Add to list and Open. Specified by `client/src/routes/create.tsx`. Taking a photo with the camera is not built.

The server makes the recipe as a job. The app starts one (`POST /api/recipe-jobs/link`, `/describe` or `/photos`, answered 202), keeps its id on the phone and asks after it (`GET /api/recipe-jobs/<id>`) until it ends, so the job outlives the app going to the background or being killed. The web waits on one long request instead.

## Sub-features

- `add-link` imports a recipe from a web address.
- `add-already-saved` answers a link imported before with "You've already saved that one." and Open it.
- `add-describe` writes a recipe from a description.
- `add-photos` reads a recipe from photos chosen in the photo library.
- `add-failure` shows what went wrong, in words that fit the kind of request.
- `add-result` shows the saved recipe with Add to list and Open.
- `add-resume` comes back to a job that was outstanding when the app was killed or left, and shows its outcome without starting it again.
- `add-waiting` says it is waiting for a connection when the job cannot be asked after.
- `add-stale` ends a job the server lost to a restart as a failure, six minutes after it started.

## How to get to it (user POV)

- Tap Add in the tab bar. From the empty recipe library, tap Add a recipe.

## Driving it with omlete-ios-verify

Preconditions:

- `$V up` just ran, `$V doctor` prints no `FAIL`, and `$V tap tab.add` has run.

- **The button follows the input.** `$V begin add`, `$V expect "Create recipe"`, `$V type add.textField "https://example.com/some-recipe"`, `$V expect "Import recipe"`, `$V type add.textField "leek and potato soup"`, `$V expect "Create recipe"`.
- **Already saved.** `$V type add.textField "https://example.com/verify-fixture-traybake"`, `$V tap add.submitButton`, `$V expect "You've already saved that one."`, `$V tap add.openExistingLink`, `$V expect-id recipe.cookButton`. `.verify-run/api.log` has `POST /api/recipe-jobs/link` answered 202, then `GET /api/recipe-jobs/<id>` answered 200.
- **A link that cannot be fetched.** `$V type add.textField "http://127.0.0.1:9/x"`, `$V tap add.submitButton`, `$V expect "That link can't be fetched. Check it's a full, public recipe URL."`. The log has the same two requests.
- **A site that does not answer.** `$V type add.textField "http://example.com:81/x"`, `$V tap add.submitButton`, `$V expect "That site didn't respond. It may be down or blocking us. Try again in a minute."`. The job works for five seconds first, with a `GET` about every second and a half.
- **A description that fails.** `$V type add.textField "leek and potato soup"`, `$V tap add.submitButton`, `$V expect "Something went wrong making that recipe. Try again."`. The log has `POST /api/recipe-jobs/describe` answered 202, a traceback under `Recipe job <id> failed`, and the `GET`s.
- **No connection.** `$V api stop`, `$V tap add.submitButton`, `$V expect "Couldn't reach Omlete. Check your connection and try again."`, then `$V api start`. Nothing was started, so this is the one failure that says so.
- **A job outlives the app being killed.** `$V type add.textField "http://example.com:81/x"`, `$V api hold &`, `$V tap add.submitButton`, then `OMLETE_IOS_VERIFY_TIMEOUT_MS=70000 $V expect "Waiting for a connection"` (two unanswered looks, about 45 seconds). `$V relaunch`, `$V tap tab.add`, and `$V snapshot` shows the working line again with the button disabled. `$V api release`, then `OMLETE_IOS_VERIFY_TIMEOUT_MS=60000 $V expect "That site didn't respond"` and `$V expect "example.com:81/x"`. The log has one `POST /api/recipe-jobs/link` for the whole run, and the `GET`s after the release come from the relaunched app.
- **A job outlives the app being left.** As above up to `$V tap add.submitButton`, then press Home with `npx -y xcodebuildmcp@latest ui-automation button --simulator-id <udid> --button-type home` (the udid is in `.verify-run/state`), `$V api release`, and wait 15 seconds: the job ends on the server while the app is suspended, and `curl -s http://127.0.0.1:8765/api/recipe-jobs/<id>` says `failed`. Come back by tapping the Omlete icon (`ui-automation snapshot-ui`, then `ui-automation tap --element-ref <ref>`), `$V expect "That site didn't respond"`, and `$V doctor` shows the same pid. The log has one `POST` and one `GET` after the return.
- **A job lost to a server restart.** `$V type add.textField "http://example.com:81/x"`, `$V api hold &`, `$V tap add.submitButton`, `$V api stop`, `$V api start`. The job's task died with the old process, so `curl -s http://127.0.0.1:8765/api/recipe-jobs/<id>` says `working` and Add shows the working line. Six minutes after the start, `OMLETE_IOS_VERIFY_TIMEOUT_MS=480000 $V expect "Something went wrong making that recipe. Try again."` passes and the same `curl` says `failed`. `api start` begins a new `api.log`, so copy the old one first if the start request matters.

## Gotchas

- These recipes rely on the API having no model key, which is how `up` starts it whatever `server/.env` holds. With `OMLETE_IOS_VERIFY_REAL_KEYS=1` the model calls succeed, cost money and never show their failure.
- With no key, nothing here can end on a saved recipe, so `add-result` (`add.addToList`, `add.openButton`) cannot be driven. `RecipeIntakeTests` and `ExploreAPITests` cover a saved link, description and photos against a scripted server, and `server/tests/test_recipe_jobs.py` covers a job that ends saved.
- Choose photos (`add.choosePhotosButton`) opens the system photo picker, which runs outside the app and has no identifiers to drive. `PhotoEncoderTests` covers the re-encoding and `ExploreAPITests` the upload.
- The 404 message for a link ("Couldn't find a recipe on that page") needs a public page that answers but holds no recipe, and with no model key the server cannot tell. `ExploreAPITests` and `server/tests/test_recipe_jobs.py` cover it.
- `http://example.com:81/x` is a real address on the internet that never answers, so those recipes need the Mac to be online. The server gives up connecting after five seconds, which is what holds the job open. A local address cannot stand in: the import refuses anything that is not public.
- `api hold` freezes the whole API, not only the job, so everything the app asks hangs until `api release`. A held API also stops the job's own clock, so release it before reading anything into how long the job took.
- While a job is working the field is disabled and drops out of the UI tree, so `expect` cannot find what was typed until the job ends. The screenshot shows it.
- A simulator can hold a second app called Omlete (an Xcode template that shows "Hello, world!"). If the icon you tap opens that, press Home and tap the other one.
- `simulator launch-app` restarts a running app and drops the `-apiBaseURL` argument. To bring the app back to the front, tap its icon.
- The field keeps what was typed after a failure or an already-saved link, and clears only when a recipe is saved. `$V type` replaces its contents.
- With a photo attached the field is disabled and its text is ignored.
