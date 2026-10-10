# Omlete for iOS

Native SwiftUI client for Omlete. Read the root `AGENTS.md` first for what the product is and the driving principle; this file covers only what is different about working in `ios/`.

**The web app in `client/src/routes` is the spec for each screen.** Before building a screen, read the matching route (and the components it uses) and reproduce its behaviour, not its markup. `docs/PRINCIPLES.md` applies here too: one-gesture edits, Undo instead of confirm dialogs, four modes that never switch on their own.

## Identity

| | |
|---|---|
| Xcode project | `ios/Omlete/Omlete.xcodeproj`, scheme `Omlete` |
| Targets | `Omlete` (app), `OmleteTests` (Swift Testing), `OmleteUITests` (XCUITest) |
| Bundle ID | `com.alexpainter.omlete` |
| Minimum iOS | iOS 26.0 |
| Swift | Swift 6 language mode: strict concurrency, `MainActor` default isolation |
| Signing | Automatic, Alex's team. Never touch it. |

The project uses file-system synchronized groups: a file created under `ios/Omlete/Omlete/`, `OmleteTests/` or `OmleteUITests/` joins that target automatically. You never need to edit the project file to add, move or delete source files.

## Build, run and test

Use the **XcodeBuildMCP** tools, not raw `xcodebuild` or `xcrun simctl`. The server is registered in the root `.mcp.json` and reads `ios/.xcodebuildmcp/config.yaml`, which pins the project, scheme and the iPhone 17 Pro simulator, so the tools need no arguments.

| To do this | Use |
|---|---|
| Compile only | `build_sim` |
| Build, install and launch | `build_run_sim` |
| Run unit and UI tests | `test_sim` |
| See the screen | `screenshot` |
| Read the UI tree, then drive it | `snapshot_ui`, then `tap` / `type_text` / `swipe` |
| Check what is pinned | `session_show_defaults` |

If the MCP server is not connected, the same tools exist as a CLI. Run it from `ios/`:

```bash
npx -y xcodebuildmcp@latest simulator build-and-run
npx -y xcodebuildmcp@latest simulator test
```

Run a single test with `test_sim` and `extraArgs: ["-only-testing:OmleteTests/SomeSuite/someTest"]`. The UI tests are slow (about three minutes for the template set), so run only the unit target while iterating: `-only-testing:OmleteTests`.

A change is not done until it builds, the tests pass, and you have looked at a screenshot of the screen you changed.

## How to write the code

- **SwiftUI only.** No UIKit unless SwiftUI has no way to do it, and then wrap it in one small representable.
- **State is `@Observable`.** Model classes are `@Observable`, owned with `@State`, passed down directly or through `@Environment`, bound with `@Bindable`.
- **Navigation is `NavigationStack`** with value-based `navigationDestination(for:)`.
- **Asynchronous work is `async`/`await`.** Start it from `.task` so it is cancelled with the view. Use `AsyncSequence` for streams.
- **Every interactive control gets an `accessibilityIdentifier`**: buttons, text fields, toggles, list rows, tabs. Use dotted lower-camel names scoped by screen, such as `list.addItemField` or `recipe.addToListButton`. The UI tests and `snapshot_ui` find controls by these.
- **Tests:** unit tests use Swift Testing (`@Test`, `#expect`), UI tests use XCUITest and look controls up by identifier, never by label text.

## Never

- **Never edit `project.pbxproj`** (a hook blocks it) or anything else inside `Omlete.xcodeproj`. Build settings, targets, capabilities and package dependencies are changed in Xcode; if one is needed, stop and ask Alex.
- **Never hand-edit `.entitlements` files or `Info.plist`.**
- **Never touch signing**: team, provisioning, certificates, bundle IDs. Never archive, export or upload a build. Alex does TestFlight uploads himself.
- **No `ObservableObject`, `@Published`, `@StateObject`, `@ObservedObject` or `@EnvironmentObject`.** Use `@Observable`.
- **No `NavigationView`.** Use `NavigationStack`.
- **No Combine.** Use `async`/`await`.
- **No completion-handler APIs or `DispatchQueue`** in new code when an async alternative exists.
