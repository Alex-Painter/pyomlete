# Omlete's driving principle

**Eat better and reduce cognitive load.**

Every feature, screen and line of code should be judged against this. If a change doesn't help someone eat better, or doesn't make eating better take less thought, it needs a very good reason to exist.

- **Eat better** means cooking from scratch more often, because the shopping list is effortless, and eating with more variety, because Omlete proactively suggests new recipes and ready-made lists instead of waiting to be asked.
- **Reduce cognitive load** means eating better should require less mental energy, not more. Omlete remembers, decides the boring parts, and never makes you manage the app.

## What it means in practice

| Principle | Design rule | Where it shows up |
|---|---|---|
| Lists are easy | Adding, editing and removing items is one gesture each. Type "2 onions, 500g mince" and it's parsed; paste a whole list at once. | `QuickAdd`, `ItemSheet`, `ListRow` (tap to check, swipe to delete or edit) |
| Nothing to undo by hand | Destructive actions happen at once with an Undo toast, never an "Are you sure?" dialog. | `UndoToast`, `useListActions`, every delete |
| Variety comes to you | Chef, the proactive suggestions agent, fills Discover (and Chef's picks on Home) from your taste (ratings, dismissals, what's on your lists). One tap saves it or adds it to a list. | `/discover`, `SuggestionDocument`, `POST /api/suggestions/` |
| Your taste is learned, not configured | Rating a meal after cooking and saying "Not for me" feed future suggestions. No profile forms. Clearing Chef's picks just tidies the feed and teaches Chef nothing, so you can clear without worrying. | Cook's "How was it?", `_taste_profile()` |
| Home is the starting point | The first screen answers "what's for dinner?": cook a meal from your list in one tap, open or start a list (the most common action, kept above the fold), then Chef's picks. | `/` (`HomePage`) |
| Four modes, freely switched | Explore (Discover, Recipes), Plan (a list), Shop, Cook are separate entry points with their own layout. Finishing one never moves you into another. | Routes `/discover`, `/list/$id`, `/shop/$id`, `/cook/$id` |
| The UI doesn't change when a step completes | Shops often have no signal and people forget to tick things. Nothing has to be checked off to reach Cook, and nothing is archived or hidden because a list is "done". | Shop has no done step; lists stay where they are |
| Works with no signal | Every list change is saved on the phone first and synced when the network allows. | `lib/offline.ts`, `public/sw.js` |
| Remember instead of asking | The last list you used is the default target for "Add to list"; servings, filters and sheets live in the URL. | `useCurrentList`, route `validateSearch` |
| Phone first | Large tap targets, bottom sheets, a tab bar and native-iOS patterns, so the same design carries to a future iOS app. | `BottomSheet`, `PageHeader`, mobile tab bar |

## How to use this

- **Designing:** start from "what's the least someone has to think to eat well here?" Prefer a sensible default plus Undo over a question.
- **Writing code:** components and hooks that encode one of the rules above say so in their doc comment, so the reason survives refactors.
- **Reviewing:** a PR that adds a confirmation dialog, a required field, a settings toggle or a mode switch should explain why it's worth the extra thought.

For the modes, Chef and what's planned next, see [DESIGN.md](DESIGN.md).
