# Omlete design

How the app is shaped and why. The principle behind every choice here is in [PRINCIPLES.md](PRINCIPLES.md): **eat better and reduce cognitive load**. For where things live in the code, see [AGENTS.md](../AGENTS.md).

This describes the October 2026 redesign as built. It is deliberately short; screenshots go stale, so check the app itself (or the `verify-omlete` feature map in `.claude/skills/verify-omlete/features/`) for what a screen looks like today.

## Context

The redesign started from a UX audit of the desktop and mobile apps in October 2026. Alex's priorities, in order:

1. **Making shopping lists is the top pain**, especially adding, removing and editing items. It has to take one gesture each.
2. **Discovery should be proactive and taste-based.** The app suggests recipes and lists from what you like, rather than waiting to be searched. Web search comes later, so the UI is built around suggestion cards any agent can fill.
3. **Mobile first, and carry over to iOS.** Prefer patterns with native iOS equivalents so a future native app is a port, not a rethink.

## Decisions

Each of these was settled in discussion; the reason is what to weigh before changing it.

| Decision | Why |
|---|---|
| Four separate modes: Explore, Plan, Shop, Cook | They used to blend into one list page, so no task had a screen built for it. |
| Plan stays its own mode, separate from Explore | Building the list is the top priority and deserves its own focused screen rather than sharing one with browsing. |
| Modes are entry points, not stages; the UI never changes because a step finished | People forget to tick things and shops have no signal. Cook can't wait on a "complete" list, and nothing should move or disappear on its own. |
| Shop works offline | Many shops have no reception, so a list must open and accept changes with no network. |
| Undo instead of confirm dialogs | Fewer decisions and taps; a mistake is one tap to reverse. |
| The suggest-meals sheet moved off the list page into Discover | Suggestions on the list page got in the way of building the list. |
| Lists live on Home, with New list above the fold | Lists are opened most and New list is the most common action, so a separate Lists tab would add a hop. |
| Home leads with meals to cook from the current list | Opening the app to cook shouldn't mean opening the list first. |
| Chef's picks sit below Lists on Home | Suggestions shouldn't push the most common action out of reach. |
| Chef is the name of the suggestions agent | One named character for "the app suggests things" across Home, Discover and future features. |
| Clear is separate from "Not for me" | Clearing the feed is tidying, not a verdict on the food; mixing them would skew Chef's taste profile. |
| Detected timers in Cook | Alex liked them in the audit: times in the method become one-tap timers. |
| On iOS a cook is saved on the phone, recipe included: the step, servings, timers and an unsent rating survive closing Cook or the app being killed | A phone propped by the hob gets locked, switched away from and loses signal. The web keeps this in the page, so closing it loses a running timer. |
| On iOS, reopening Cook resumes within 8 hours and otherwise starts from the overview; a finished cook always starts over | Coming back mid-meal should find your place, and cooking the same recipe next week should not start on step 6. |
| iOS timers ring in the app with a sound and a haptic, with no notifications yet | A notification needs a permission prompt, which is a product decision of its own. A timer that ends while the app is in the background rings once when you come back. |
| On iOS a rating shows at once and is sent when it can be; one the server refuses is dropped without a message | There should never be an error to dismiss with a pan in the other hand. |
| Closing Cook on iOS returns to where it was opened, Home or the list | Cook covers the screen it was opened from, so leaving it is not a navigation. The web goes to the list. |
| Settings behind a cog, Add as a plain tab | A profile icon promised more than it did, and a raised plus button looked out of place. |

## Home plus four modes

People use Omlete in four distinct ways, and the old app blended them into one list page. Each now has its own screen and layout:

| Mode | Screens | What it's for |
|---|---|---|
| **Explore** | `/discover`, `/recipes`, `/recipe/$id`, `/create` | Finding something to cook: Chef's suggestions, your library, adding a recipe from a link, description or photos |
| **Plan** | `/list/$id` | Building a shopping list: add meals, quick-add and paste items, edit and delete with Undo |
| **Shop** | `/shop/$id` | In the shop: fullscreen, large rows, works with no signal |
| **Cook** | `/cook/$id` | At the stove: one step at a time, scaled amounts, detected timers, a rating at the end |

**Home** (`/`) is where you land and the hub between them. It is a stack of sections, in order of how often they're used:

1. **Cook from your list**: meals on the current list, one tap into Cook.
2. **Lists**, with **New list** beside the heading, the most common action, so it stays above the fold.
3. **Chef's picks**: Chef's newest suggestions, with See all going to Discover.

The phone tab bar is Home, Discover, Add, Recipes. Settings sits behind the cog in each page header.

## Modes are entry points, not stages

The UI never changes because another step finished. You can go from any mode to any other at any time, and finishing one never moves you into the next.

- **Nothing has to be checked off.** People forget to tick items, and shops often have no signal. Cook never depends on the list being done, and Shop has no "done" step.
- **Nothing is archived or hidden** because a list looks finished. Lists stay where they are until you delete them.
- **Shop works offline.** Every list change is written to the phone first (`client/src/lib/offline.ts`) and synced when the network allows. A list opened at home still opens in the shop, and the service worker (`client/public/sw.js`, production only) keeps the app shell loading.
- **Destructive actions are instant with Undo** rather than an "Are you sure?" dialog.

## Chef

Chef is the proactive suggestions agent. Its job is the "more variety" half of the principle: new ideas reach you without you going looking.

- **Cards, not recipes.** A suggestion is a title, a reason it suits you, and optionally a photo and source link (`SuggestionDocument`). Saving one turns it into a recipe in the background; from a link it's imported, otherwise Claude writes it.
- **Where cards come from.** Today, Refresh on Discover (`POST /api/suggestions/refresh`) asks Claude for ideas from your taste: ratings, "Not for me" dismissals, recent lists and Tune settings. Any agent can also post cards to `POST /api/suggestions/`.
- **Taste is learned, not configured.** Ratings after cooking and "Not for me" are the signals. **Clear** (`POST /api/suggestions/clear`) is different: it tidies the feed and teaches Chef nothing, so you can clear without worrying about skewing future picks.

## Planned (v2)

Not built yet; the current structure leaves room for each.

- **Chef searches the web.** Replace the generate-only Refresh with an agent that finds real recipes online and posts cards with a `source_url` and `image_url`. Save then imports the real recipe, and the Discover and Home UI need no changes.
- **Chef suggests whole lists**, not just meals, e.g. a week of dinners ready to shop for.
- **More Home sections** below Chef's picks: recent activity (lists and meals cooked lately) and stats (how often you cooked from scratch, how varied the week was). Home is a stack of sections, so these slot in without a redesign.
- **iOS app.** The web UI uses patterns with native iOS equivalents (tab bar, large titles, bottom and action sheets, swipe actions), and components are written to map onto SwiftUI views.
