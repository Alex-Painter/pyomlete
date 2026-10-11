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
| On iOS each of the four tabs keeps its own stack, and Plan hides the tab bar | Switching tabs should not lose your place. Start shopping owns the bottom of Plan, and the tab bar would sit on top of it. The web shows both because its tab bar is not floating. |
| On iOS, finding ideas, saving a card and adding a recipe carry on when you leave the screen | Each waits on a model for up to a few minutes and has already cost money by the time you switch tabs. The app owns the request, not the screen, and allows it 180 seconds where other requests get 20. |
| On iOS a Discover card that is saving cannot be dismissed or cleared | The server marks the card saved when the recipe is ready, which would bring a dismissed card back. The web allows the tap and has that bug. |
| On iOS a card whose save could not be sent reads "Couldn't save this one" with Try again | The web puts the card back as if nothing was tapped, which reads as the tap being ignored. |
| On iOS, Add to list that fails says so in the banner, and so does a card sent to a list whose recipe could not be made | The web ends the spinner and shows nothing. A failed card also drops out of Add meals' picks, as on the web, so there the banner is the only thing that can say the meal is not coming. |
| On iOS, news nobody tapped for (a save that failed in the background) waits while a banner with Undo is up | Replacing that banner would commit the change and take the Undo away at a moment the user did not choose. |
| On iOS, tapping a meal back on in Add meals while its removal can still be undone is that Undo | The server still has the meal then, so asking it to add would answer "already there" and the removal would go through anyway. |
| On iOS, Add meals with an empty library offers Add a recipe and Browse Discover, and each closes the sheet and switches tab, leaving Plan open under its own tab | The web links to both pages. On iOS both are tabs, Plan hides the tab bar, and a sheet cannot stay up over another tab, so without the buttons the empty sheet is a dead end. |
| On iOS, adding a recipe that was sent and never answered says the recipe may still be on its way, and refreshes Recipes | The server usually finishes it, so "couldn't reach Omlete" would invite a second paid request and a duplicate. Only a link is deduplicated by the server. |
| On iOS a card still saving after about five minutes is shown as failed | The server loses a save when it restarts and never clears the card, which would leave it undismissable. |
| On iOS, Add a recipe takes photos from the library only | The camera needs a usage string in Info.plist, which is Alex's to add. |
| On iOS, Home's Clear tidies only the picks nobody has acted on, and Discover's Clear all takes everything but a card still saving | A saved or failed card is never on Home, so clearing it from there would remove something the user did not see go. The web's Home Clear is the same. |
| On iOS, Home with picks and no lists puts "No lists yet" in the Lists section instead of over the whole screen | The full-screen message would cover the picks, and the picks alone would hide the invitation to start a list. With no picks it keeps the screen to itself, as before. |
| On iOS, Chef's picks wait for the lists to load, a feed that never loaded shows nothing on Home, and a refresh that fails keeps the picks already there | Picks under a spinner or a failure message would read as the screen being ready. Nobody asked for the section, so its failure is Discover's to report, and ideas already on screen are no worse for a failed refresh. |
| On iOS, Home with no lists waits for the suggestions to answer before showing "No lists yet" | Otherwise the full-screen message shows on every launch and then rearranges itself around the picks. |
| On iOS a recipe is edited in a sheet and saved in one go, and the save needs signal: one that cannot be sent leaves the sheet up with everything typed and says it is not saved | A save replaces the recipe's whole ingredient list on the server, so a queued one sent later could overwrite a newer copy. Lists queue because each change is small and safe to replay. |
| On iOS an edit with changes cannot be swiped away, and Cancel discards it at once with Undo, which reopens the editor as it was | A swipe is the gesture made by accident while scrolling a long form, and "Discard changes?" is the confirm dialog the app does without. An edit with no changes swipes away as any sheet does. |
| On iOS a quantity that is not a number stops the save and marks the ingredient; an emptied quantity is saved as none | The web saves 0 for what it cannot read, and a 0 nobody typed would go on every shopping list the recipe is added to. |
| On iOS an emptied title keeps the title the recipe had | A recipe with no title is a blank tile in the library, and an error to dismiss costs more than keeping the old name. The web saves the empty title. |
| On iOS the steps of a recipe being edited are moved by dragging a handle | It is how a list is reordered on iOS. The web has an up and a down arrow on each step. |
| On iOS, Edit recipe is offered only once the server has answered for that recipe this launch, and a save takes the note, group and on-list flag from the recipe as it is at that moment | A save replaces the whole recipe, so an edit begun from an old copy on the phone, or sent with a flag that has since changed, would put old values back. |
| On iOS, a discarded edit is offered back only while its recipe page is open and the recipe has not changed since | The Undo reopens the editor on that page, and a draft made from an older recipe would save the older values. |
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
