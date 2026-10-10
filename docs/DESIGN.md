# Omlete design

How the app is shaped and why. The principle behind every choice here is in [PRINCIPLES.md](PRINCIPLES.md): **eat better and reduce cognitive load**. For where things live in the code, see [AGENTS.md](../AGENTS.md).

This describes the October 2026 redesign as built. It is deliberately short; screenshots go stale, so check the app itself (or the `verify-omlete` feature map in `.claude/skills/verify-omlete/features/`) for what a screen looks like today.

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
