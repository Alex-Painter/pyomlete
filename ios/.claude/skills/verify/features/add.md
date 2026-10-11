# Add a recipe

One field that takes a link or a description, plus Choose photos for pictures of a recipe. The button says what it will do: Import recipe for a link, Create recipe for a description, Read n photos for photos. It ends on the saved recipe with Add to list and Open. Specified by `client/src/routes/create.tsx`. Taking a photo with the camera is not built.

## Sub-features

- `add-link` imports a recipe from a web address.
- `add-already-saved` answers a link imported before with "You've already saved that one." and Open it.
- `add-describe` writes a recipe from a description.
- `add-photos` reads a recipe from photos chosen in the photo library.
- `add-failure` shows what went wrong, in words that fit the kind of request.
- `add-result` shows the saved recipe with Add to list and Open.

## How to get to it (user POV)

- Tap Add in the tab bar. From the empty recipe library, tap Add a recipe.

## Driving it with omlete-ios-verify

Preconditions:

- `$V up` just ran, `$V doctor` prints no `FAIL`, and `$V tap tab.add` has run.

- **The button follows the input.** `$V begin add`, `$V expect "Create recipe"`, `$V type add.textField "https://example.com/some-recipe"`, `$V expect "Import recipe"`, `$V type add.textField "leek and potato soup"`, `$V expect "Create recipe"`.
- **Already saved.** `$V type add.textField "https://example.com/verify-fixture-traybake"`, `$V tap add.submitButton`, `$V expect "You've already saved that one."`, `$V tap add.openExistingLink`, `$V expect-id recipe.cookButton`. `.verify-run/api.log` has `POST /api/recipes/import-from-url/` answered 409.
- **A link that cannot be fetched.** `$V type add.textField "http://127.0.0.1:9/x"`, `$V tap add.submitButton`, `$V expect "That link can't be fetched. Check it's a full, public recipe URL."`. The log has the same request answered 400.
- **A description that fails.** `$V type add.textField "leek and potato soup"`, `$V tap add.submitButton`, `$V expect "Something went wrong making that recipe. Try again."`. The log has `POST /api/recipes/generate/` answered 500.
- **No connection.** `$V api stop`, `$V tap add.submitButton`, `$V expect "Couldn't reach Omlete. Check your connection and try again."`, then `$V api start`.

## Gotchas

- These recipes rely on the API having no model key, which is how `up` starts it whatever `server/.env` holds. With `OMLETE_IOS_VERIFY_REAL_KEYS=1` the model calls succeed, cost money and never show their failure.
- With no key, nothing here can end on a saved recipe, so `add-result` (`add.addToList`, `add.openButton`) cannot be driven. `RecipeIntakeTests` and `ExploreAPITests` cover a saved link, description and photos against a scripted server.
- Choose photos (`add.choosePhotosButton`) opens the system photo picker, which runs outside the app and has no identifiers to drive. `PhotoEncoderTests` covers the re-encoding and `ExploreAPITests` the upload.
- The 404 and 502 messages for a link ("Couldn't find a recipe on that page", "That site didn't respond") need a page that answers but holds no recipe, or a host that times out. Neither is in the fixtures; `ExploreAPITests` covers both.
- The field keeps what was typed after a failure or an already-saved link, and clears only when a recipe is saved. `$V type` replaces its contents.
- With a photo attached the field is disabled and its text is ignored.
