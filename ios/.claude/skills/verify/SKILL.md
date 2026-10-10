---
name: verify
description: Build the Omlete iOS app (SwiftUI, ios/Omlete), launch it on the pinned iPhone 17 Pro simulator and drive it by accessibility identifier to prove a change works, with UI-tree snapshots and screenshots as evidence. Use whenever you need to show that a change under ios/ actually behaves on screen, not just compiles or passes unit tests.
---

# Verify Omlete for iOS

Omlete for iOS is a native SwiftUI app (`ios/Omlete/Omlete.xcodeproj`, scheme `Omlete`, bundle id `com.alexpainter.omlete`). Users touch the app on an iPhone, so the surface to verify is the running app in the iOS Simulator. Read `ios/CLAUDE.md` first for the build rules; this skill only covers proving behaviour.

Everything goes through one helper. Run it from `ios/`:

```bash
V=.claude/skills/verify/scripts/omlete-ios-verify
```

The helper wraps the XcodeBuildMCP CLI (`npx -y xcodebuildmcp@latest`, the same tools as the MCP server in the root `.mcp.json`), which reads `ios/.xcodebuildmcp/config.yaml` for the project, scheme and simulator. It needs Xcode, `npx` and `jq`.

## Launch

```bash
$V up        # build, install, launch; returns once the app's UI tree answers
$V doctor    # must print no FAIL lines before you drive anything
```

- `up` runs `simulator build-and-run`, which boots the pinned simulator (iPhone 17 Pro) if it is shut down. A warm build takes about 20 seconds.
- **Ready means** `up` printed `==> up: Omlete pid <n> on iPhone 17 Pro`. Before that line it has already waited for the UI to settle.
- A build failure prints the compiler errors. The full result, including the paths of the build log and the app's runtime log, is in `.verify-run/build.json`.
- Run `up` again after every source change. It rebuilds and relaunches, so the app restarts from its launch screen.
- The simulator runs headless. Nothing needs the Simulator window open.

### Isolation

There is one pinned simulator and one install of the app on it, so only one instance runs at a time. `up` refuses to start when Omlete is already running on that simulator and this skill did not launch it, because that is someone's Xcode or manual session and a reinstall would kill it. Stop that session, or set `OMLETE_IOS_VERIFY_TAKEOVER=1` only when you know it is yours.

## Doctor

`$V doctor` is read-only and exits non-zero on any `FAIL`. It checks that:

- `up` has run (`.verify-run/state` exists)
- the simulator is booted
- Omlete is running, and as the same process `up` launched (a different pid means it crashed and was relaunched, or Xcode replaced it)
- no file under `ios/Omlete` is newer than the installed build
- the UI tree answers

Run it before the first drive and again after any step that fails unexpectedly.

## Drive

```bash
$V begin <label>              # start a new evidence folder; do this once per proof
$V snapshot                   # print what is on screen
```

`snapshot` prints one row per element as `ref|action|role|label|value|id`:

```
e10|tap|button|Bump||probe.bumpButton
e9|text|text|Count 0||
```

The last column is the control's `accessibilityIdentifier`. Every interactive control in this app has one (`ios/CLAUDE.md` requires it), named `screen.controlName`. Drive by that id, never by the `eN` ref (it changes on every snapshot) and never by coordinates:

| step | meaning |
|---|---|
| `$V expect <text>` | wait until text containing `<text>` is on screen |
| `$V gone <text>` | wait until `<text>` is no longer on screen |
| `$V expect-id <id>` | wait until a control with that identifier exists |
| `$V tap <id>` | tap a button, row, tab or toggle |
| `$V type <id> <text>` | replace a text field's contents with `<text>` |
| `$V swipe <id> up\|down\|left\|right` | swipe inside a scrollable element (`up` scrolls the content down) |

Every step waits up to 20 seconds (`OMLETE_IOS_VERIFY_TIMEOUT_MS` changes that), prints `PASS` or `FAIL`, and exits non-zero on failure. A typical proof:

```bash
$V begin launch
$V expect "Hello, omlete!"
```

`tap`, `type` and `swipe` fail with `no tappable or scrollable control with accessibility id ...` when the id is not on screen. Run `$V snapshot` to see what is there. If the control exists but has no id, add an `accessibilityIdentifier` to it in the app rather than driving it another way.

For a gesture the helper does not wrap (long press, drag, hardware buttons, a Return key), call the CLI from `ios/` with a ref from a fresh snapshot, for example `npx -y xcodebuildmcp@latest ui-automation long-press --element-ref e12`. `npx -y xcodebuildmcp@latest ui-automation --help` lists them.

For the per-screen recipes, read [`features/README.md`](features/README.md).

## Evidence

`begin <label>` creates `ios/verify-artifacts/<timestamp>-<label>/` (gitignored), and every step after it writes there:

- `NN-<step>.json`: the UI tree after the step
- `NN-<step>.jpg`: a screenshot after the step
- `run.log`: the app pid, the commit, and a `PASS`/`FAIL` line per step

A failed `expect` also saves `NN-fail.json` and `NN-fail.jpg`, which show what was on screen instead. Look at the screenshot yourself (Read the `.jpg`) before claiming a screen is right: the UI tree proves the text is there, not that it is laid out properly.

Proof standards:

- Drive the real user path: launch, then taps and typing by identifier. Do not prove a feature through a unit test, a debug-only launch argument or a SwiftUI preview.
- Capture the action and the resulting state. `tap` then `expect` gives you both.
- For anything the app stores, add a second view of it: relaunch with `$V up` and `expect` the stored value again.
- Proof comes from the build `up` installed. If `doctor` reports changed sources, rebuild before capturing.

`OMLETE_IOS_VERIFY_EVIDENCE_DIR` overrides the evidence location.

## Cleanup

```bash
$V down
```

`down` stops the Omlete process that `up` launched, and shuts the simulator down only if `up` was what booted it. A simulator that was already booted is left booted. It never erases the simulator, never uninstalls the app and never touches `verify-artifacts/`. Run `down` after a failed iteration too.

Never `xcrun simctl shutdown all`, `simctl erase`, or `killall Simulator`: those hit simulators and sessions this run did not start.

## Helpers

- `.claude/skills/verify/scripts/omlete-ios-verify`: the entry point above. Run it with no arguments for usage. State lives in `ios/.verify-run/` (gitignored): `state` (simulator id, app pid, current evidence folder) and `build.json` (the last build result).
