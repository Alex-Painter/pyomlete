# Launch screen

Opening Omlete shows its first screen. Today that is the scaffold placeholder: a globe icon above the text `Hello, omlete!`, with nothing to tap. Proving it shows that the app builds, installs, launches without crashing and renders.

## Sub-features

- `launch` opens the app to the placeholder screen showing `Hello, omlete!`.

## How to get to it (user POV)

- Tap the Omlete icon on the Home Screen. `$V up` does the same thing: it launches the installed app from cold.

## Driving it with omlete-ios-verify

Preconditions:

- `$V up` just ran and `$V doctor` prints no `FAIL`.

- **Open the app.** Run `$V begin launch`, then `$V expect "Hello, omlete!"`. It prints `PASS expect "Hello, omlete!"`.
- **Proof.** Run `$V snapshot`. The rows include `|text|text|Hello, omlete!||` and no `tap` rows. Read the `NN-snapshot.jpg` it names: the globe and the text are centred on a plain background, under the status bar.
- **Still running.** Run `$V doctor`. The line `Omlete pid <n> is the process up launched` shows the app did not crash after rendering.

## Gotchas

- The screen has no interactive controls, so `tap`, `type` and `swipe` have nothing to act on here.
- The globe is an image with no text, so it does not appear in `snapshot`. Only the screenshot shows it.
- This file describes the scaffold. When a real first screen replaces `ContentView`, rewrite it for that screen (most likely Home).
