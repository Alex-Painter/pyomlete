# iOS parity

Every web change is ported to the iOS app (see the parity rule in `docs/DESIGN.md` and `AGENTS.md`). This table lists each web change since the last full catch-up, the iOS PR that ports it and where it stands. Add a row when a web PR merges; update it when the port merges.

States: **to port**, **porting** (iOS PR open), **done**, **not needed** (nothing on iOS to change, with the reason).

| Web change | Web PR | iOS PR | State | Notes |
|---|---|---|---|---|
| Week view on Plan (Phase 1) | #98 | #121, #122 | done | |
| Cooked tick on a list's meals | #118 | #130 | done | |
| New list: a plain list or a week ahead | #139 | #139 | done | Open nit: a plain list's Meals section says "Pick this week's meals" |
| Recipe tags (base, main, mood, cuisine, traits) | #131 | | not needed | Server only; iOS reads the tags for the fit score below |
| Fit score: each evening ranked, top three, reasons, Quick night, Planning the week in Settings | #132 | #151 | porting | P2-IOS in the plan-the-week build plan; shared cases in `docs/fixtures/fit-score-cases.json` |
| Narrow it down (Help me choose) | #133 | | to port | P3-IOS; shared cases in `docs/fixtures/narrow-cases.json`. Builds on the fit score |
| Calendar on the week: busy, part-busy and free evenings, Settings | #134, #135 | | to port | P4-IOS reads the phone's calendar with EventKit instead of Google sign-in. Needs `NSCalendarsFullAccessUsageDescription` in Info.plist, which only Alex adds |
| Link import and weekly plan fixes on the new keys and models | #137 | | not needed | Server only |
| Every Claude call on the 5.5 family | #140 | | not needed | Server only |
| Recipe tool loops capped | #141 | | not needed | Server only |
| PostHog for errors and product events | #138, #144 | | not needed for now | The server sends iOS's errors and events already. Crash and screen events from the app itself need the PostHog iOS package, a dependency only Alex adds in Xcode |
| Open link on the recipe or list Chef makes | #145 | | to port | Chef chat's change rows get Open beside Undo |
| Generate image for a recipe, and photos served by the API | #146 | | to port | `image_url` can now be a path (`/api/recipe-images/{id}`) that must be resolved against the API, as the web's `mediaUrl()` does, or the photo doesn't show on iOS |
| Web photo import fix, HEIC converted on the server | #147 | | not needed | The web fix is to the browser's file input; the server conversion covers iOS uploads too |
