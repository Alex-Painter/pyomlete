---
name: verify
description: Build the Omlete iOS app (SwiftUI, ios/Omlete), launch it on the pinned iPhone 17 Pro simulator against a disposable local API with fixture data, and drive it by accessibility identifier to prove a change works, with UI-tree snapshots and screenshots as evidence. Use whenever you need to show that a change under ios/ actually behaves on screen, not just compiles or passes unit tests.
---

# Verify Omlete for iOS

Omlete for iOS is a native SwiftUI app (`ios/Omlete/Omlete.xcodeproj`, scheme `Omlete`, bundle id `com.alexpainter.omlete`). Users touch the app on an iPhone, so the surface to verify is the running app in the iOS Simulator. Read `ios/CLAUDE.md` first for the build rules; this skill only covers proving behaviour.

Everything goes through one helper. Run it from `ios/`:

```bash
V=.claude/skills/verify/scripts/omlete-ios-verify
```

The helper wraps the XcodeBuildMCP CLI (`npx -y xcodebuildmcp@latest`, the same tools as the MCP server in the root `.mcp.json`), which reads `ios/.xcodebuildmcp/config.yaml` for the project, scheme and simulator. It needs Xcode, `npx`, `jq`, Docker and the backend's `server/.venv`.

## Launch

```bash
$V up        # local API and fixtures, then build, install, launch; returns once the app's UI tree answers
$V doctor    # must print no FAIL lines before you drive anything
```

- **The app talks to its own local backend.** `up` starts a disposable Mongo (container `omlete-ios-verify-mongo`, port 27019) and the FastAPI server on `http://127.0.0.1:8765`, then launches the app with `-apiBaseURL http://127.0.0.1:8765`. Debug builds read that launch argument; Release builds ignore it and use production. The ports differ from the web `verify-omlete` skill's (8000, 27018), so both can run at once. `OMLETE_IOS_VERIFY_API_PORT` and `OMLETE_IOS_VERIFY_MONGO_PORT` change them.
- **`server/.venv` must exist.** If `up` says it is missing, run `.claude/skills/verify-omlete/scripts/omlete-verify setup` from the repo root once. Docker must be running.
- **Every `up` reseeds.** It deletes every list in the disposable database and leaves two. `Verify Fixture List` is a plain list with two meals: `Verify Fixture Shakshuka` (3 steps, serves 2, a 10-minute timer in step 2) and `Verify Fixture Soft Egg` (2 steps, no serving count, a 5-second timer in step 1). Its six items are their ingredients plus `milk` (2 pint) and `bananas` (6). It is Home's first row, so Home cooks from it and Add to list adds to it. `Verify Fixture Week` is a week list for the week under way, starting on the Saturday on or before today, with `Verify Fixture Traybake` on its first evening, its sixth evening Out, and `Verify Fixture Soft Egg` on it with no day; `features/plan.md` drives it. Item and list ids change on every seed, so read them from the line `up` prints, `$V snapshot` or `curl -s http://127.0.0.1:8765/api/lists/`.
- **The seed also leaves four recipes and five Discover cards.** The recipes are the two meals, `Verify Fixture Lemon Drizzle Cake`, and `Verify Fixture Traybake`, which has the shape a link import saves: a source (`https://example.com/verify-fixture-traybake`), 45 minutes, a rating of 5, two ingredient groups and one ingredient kept off shopping lists. Any other recipe is deleted. The cards are named `Verify Card ...` and sit on four shelves; `features/discover.md` lists them.
- **The seed also leaves a week plan waiting**, Chef's week for the week `GET /api/weeks/current` asks for (the Saturday on or before today, or the next one on a Friday), so Home and Discover show Chef's week card. Planning a week needs a model, so the seed writes the plan straight into Mongo with the server's own `WeekPlanDocument`. Its five dinners, one evening after the week's first: Sunday `Verify Fixture Shakshuka`, Monday `Verify Fixture Soft Egg`, Tuesday the new idea `Verify Week Idea Sheet Pan Chicken`, Wednesday `Verify Fixture Lemon Drizzle Cake` and Friday the new idea `Verify Week Idea Blocked Link`. The Sheet Pan Chicken's link is the Traybake's source, so once the list is made it saves with no model, in about a second, and lands on Tuesday as `Verify Fixture Traybake`. The Blocked Link's link is refused by the fetch guard, so it fails and Friday stays free. `features/home.md` drives the card.
- **The seed also leaves three preferences** for What Chef knows in Settings: told `Never mushrooms` and `More fish` through `POST /api/preferences`, and inferred `Likes curry`, written straight into Mongo with the server's `PreferenceDocument`. Any other is deleted. `features/settings.md` drives them.
- **The seed puts the aisle order back** to the server's nine defaults, so a run that renames, deletes or reorders aisles in Settings leaves nothing behind for the next.
- **No API keys are needed.** `/api/categorize` fails without one, and the app keeps its own aisle guess, which is the offline behaviour anyway. Everything that asks a model fails too: Get new ideas, saving a Discover card and adding a recipe.
- **Real keys in `server/.env` are not used.** The API is started with placeholder keys whatever that file holds, because the Discover and Add recipes prove the failures and a real key costs money on every run. `OMLETE_IOS_VERIFY_REAL_KEYS=1 $V up` (after `$V api stop`) passes the real ones through; the model calls then succeed and spend money, so use it only when Alex asks for that.
- The API log is `.verify-run/api.log`. It is the second view of anything the app sends: one line per request.

- `up` runs `simulator build-and-run`, which boots the pinned simulator (iPhone 17 Pro) if it is shut down. A warm build takes about 20 seconds.
- **Ready means** `up` printed `==> up: Omlete pid <n> on iPhone 17 Pro`. Before that line it has already waited for the UI to settle.
- A build failure prints the compiler errors. The full result, including the paths of the build log and the app's runtime log, is in `.verify-run/build.json`.
- Run `up` again after every source change. It rebuilds, reseeds and relaunches, so the app restarts on Home with the fixture list. The app's own saved copies of lists survive a reinstall; Home drops the ones the server no longer has once it has loaded.
- The simulator runs headless. Nothing needs the Simulator window open.

### Isolation

There is one pinned simulator and one install of the app on it, so only one instance runs at a time. `up` also refuses to start when something it did not start already answers on the API port. `up` refuses to start when Omlete is already running on that simulator and this skill did not launch it, because that is someone's Xcode or manual session and a reinstall would kill it. Stop that session, or set `OMLETE_IOS_VERIFY_TAKEOVER=1` only when you know it is yours.

## Doctor

`$V doctor` is read-only and exits non-zero on any `FAIL`. It checks that:

- `up` has run (`.verify-run/state` exists)
- the simulator is booted
- Omlete is running, and as the same process `up` launched (a different pid means it crashed and was relaunched, or Xcode replaced it)
- the local API answers and its Mongo container is healthy
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
| `$V tap <id> then <id2>` | tap, then tap a second control at once with no capture in between. More can follow (`then <id3>`); all of them must be on screen straight after the first tap |
| `$V type <id> <text>` | replace a text field's contents with `<text>` |
| `$V swipe <id> up\|down\|left\|right` | swipe inside a scrollable element (`up` scrolls the content down) |
| `$V drag <id> up\|down\|left\|right [distance]` | drag from an element, text included, by a fraction of the screen (default 0.4). Dragging a sheet by its title moves the sheet between its heights |

Every step waits up to 20 seconds (`OMLETE_IOS_VERIFY_TIMEOUT_MS` changes that), prints `PASS` or `FAIL`, and exits non-zero on failure. A typical proof:

```bash
$V begin home
$V expect "Verify Fixture List"
```

**The Undo banner lasts five seconds**, and a normal step (find the control, act, capture) takes about that long. To press Undo, use `$V tap <id> then undo.button`. To prove the banner appeared, read the `NN-tap.json` the tap saved: it holds `undo.banner` and `undo.button`. An `expect "Got ..."` as a separate step usually arrives too late.

`expect` and `gone` match a substring of any element's label or value, case-sensitively. An inline navigation title (Plan's list name) and section headers ("Cook from ...", "You'll need") are not in the UI tree, so they cannot be expected; check them in the screenshot.

Two more steps for what the app stores and for working offline:

| step | meaning |
|---|---|
| `$V relaunch` | cold-start the installed build: no rebuild, no reseed, API left as it is |
| `$V api stop` / `$V api start` | take the local API away and bring it back |
| `$V api freeze` / `$V api release` | freeze the API now, so nothing is read or answered, and let it go again |
| `$V api hold` | freeze the API once it has answered the next recipe job's start |
| `$V api bounce` | restart the API once it has answered the next recipe job's start, as a deploy would |

With the API stopped the app is "offline" as far as lists go: changes are saved on the phone and shown, and they are sent when the API returns (the app retries with a backoff, so allow about 20 seconds, or `relaunch`).

These three are for recipe jobs, and `features/add.md` has the recipes. `api freeze` stops the process with `SIGSTOP`: a request sent to it sits unread, which is how to show a start whose answer never arrives. `api hold` and `api bounce` are run in the background before the tap that starts the job (`$V api hold &`). Each waits for the API to answer the start and then acts, so the job is outstanding when it does. The app looks at a job as soon as its start is answered, and that first look can be answered before `hold` freezes the API or `bounce` stops it. `bounce` copies the old log to `.verify-run/api.before-bounce.log`, because the new API starts a new `api.log`.

`tap`, `type` and `swipe` fail with `no tappable or scrollable control with accessibility id ...` when the id is not on screen. Run `$V snapshot` to see what is there. If the control exists but has no id, add an `accessibilityIdentifier` to it in the app rather than driving it another way.

### Chef without a model

A real Chef reply needs a model key, which `up` never passes. To prove a streamed reply, a change with Undo and the refresh of the screen it touched, put a canned Chef in front of the API:

| step | meaning |
|---|---|
| `$V chef-stub start` | start `scripts/chef-stub.py` on `http://127.0.0.1:8766` (`OMLETE_IOS_VERIFY_CHEF_STUB_PORT`) and relaunch the app against it |
| `$V chef-stub stop` | stop it and relaunch the app against the API |

The stub is test-only and changes nothing on the server. It answers `POST /api/chef/chat` with a paced, canned stream that adds `Verify Chef Lemons` to the list on screen through the real list endpoints, answers Undo for its own action ids (409 when the item has been checked or deleted since), and passes every other request to the API. `features/chef.md` has the recipes. `relaunch` keeps the app on the stub until `chef-stub stop` or the next `up`.

For a gesture the helper does not wrap (long press, hardware buttons, a Return key), call the CLI from `ios/` with a ref from a fresh snapshot, for example `npx -y xcodebuildmcp@latest ui-automation long-press --element-ref e12`. `npx -y xcodebuildmcp@latest ui-automation --help` lists them.

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
- For anything the app stores, add a second view of it: `$V relaunch` and `expect` the stored value again, and for anything it sends, read it back from the API (`curl -s http://127.0.0.1:8765/api/lists/<id>`).
- Proof comes from the build `up` installed. If `doctor` reports changed sources, rebuild before capturing.

`OMLETE_IOS_VERIFY_EVIDENCE_DIR` overrides the evidence location.

## Cleanup

```bash
$V down
```

`down` stops the Omlete process that `up` launched, stops the canned Chef and the local API, removes the disposable Mongo container, and shuts the simulator down only if `up` was what booted it. A simulator that was already booted is left booted. It never erases the simulator, never uninstalls the app and never touches `verify-artifacts/`. Run `down` after a failed iteration too.

Never `xcrun simctl shutdown all`, `simctl erase`, or `killall Simulator`: those hit simulators and sessions this run did not start.

## Helpers

- `.claude/skills/verify/scripts/omlete-ios-verify`: the entry point above. Run it with no arguments for usage. State lives in `ios/.verify-run/` (gitignored): `state` (simulator id, app pid, current evidence folder), `build.json` (the last build result), `api.pid` and `api.log`.
