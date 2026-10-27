# Chef: always-on meal planner

Chef, the suggestions agent, grows into a planner you can talk to. Once a week it proposes a week of dinners that one tap turns into a list. In chat it acts for you: it finds a recipe on the web, adds it to Omlete and puts it on a list, each step with Undo. Under both it keeps a household memory of told and inferred preferences that you can read and correct.

The full plan, with the data model, the tool list and a diagram, is the [Chef planner doc](https://claude.ai/code/artifact/aaa81a68-9b7e-48ed-bb56-83dc708c2a25). This file records what is settled.

## Decisions

| Decision | Why |
|---|---|
| Grow Chef rather than add a second assistant | One named character for "the app suggests things" is already a decision in `DESIGN.md`. |
| Pydantic AI for Chef only. Generate, extract and URL import stay on the Anthropic SDK | Chef needs an agent loop with typed output, injected database access and web search. The other pipelines work, and moving them would add risk and nothing a user notices. |
| The weekly run only proposes. In chat, Chef acts at once, each step with Undo | Modes never switch on their own, so nothing changes without a tap. In chat the request is the tap, and Undo replaces asking first, as everywhere else in the app. |
| Only chat runs get the tools that write | A scheduled run cannot change anything. |
| Chef can do anything the user can, deletes included, and a test fails when a route changes data with no matching Chef tool | The end goal is that Chef can control the whole app. Every delete already has Undo, and the test means a new feature reaches Chef the day it ships. |
| Chef sits beside every screen: a right-hand sidebar on wide web windows. On phones, web and iOS, it is a sheet over the current screen with three heights (a slim status bar, half height with the screen behind still usable, full height), opened from the Add tab, which becomes Chef. Messages carry the current route and its ids | Chef should be with you wherever you are, and "put this on my list" should need no names. Revised on 11 Oct 2026 from a Chef tab of its own. |
| Chat runs on Sonnet for now, the weekly plan on Opus | Chat needs to answer quickly. The weekly plan runs once and quality matters more. |
| Chef's Undo puts back the documents a tool changed, as they were, and refuses (409) when anything has changed them since | Undoing over a later edit would lose it without a word. Each tool call is one action, so the client undoes a whole reply by undoing its actions newest first. |
| When Chef changes a recipe's ingredients it rewrites the method in the same call; `update_recipe` refuses new ingredients without instructions | Alex asked for edits to change the method too (19 Oct 2026). Steps name ingredients and their amounts, so an edit to the list alone leaves a method that mentions what's gone and the old amounts. The refusal makes it every time rather than when the model remembers. |
| Messages carry only the path of the screen (`page: {"path": "/list/<id>"}`); the server reads the ids from it | The web and iOS then send the same thing, and a new screen needs no new field. |
| Recipe jobs and Discover cards have no Chef tools | A job is the same recipe making as `create_recipe`, `import_recipe` and `create_recipe_from_photos`, started for a phone that may drop a long request. Discover cards are Chef's own ideas; in chat it suggests in its reply. `tests/test_chef_parity.py` lists each exemption with its reason. |
| The web reads Chef's stream itself rather than adding the AI SDK's `useChat` | The protocol is a few event types and the client needs only a few dozen lines for it (`client/src/lib/chef.ts`), with no new dependency in an app that has to keep working offline. |
| While the chat is on screen, its changes carry their own Undo in the conversation and no toast; with Chef closed or at the slim bar, the reply's changes get one Undo toast | The toast would cover the message box, and the Undo is already beside each change. |
| On wide web windows Chef's sidebar starts open, until it is closed there; then it stays closed on later visits until reopened. Phones start with it closed | Alex asked for it open by default on the web (18 Oct 2026). On a phone the sheet would cover the page you came to. |
| Finishing Cook records the meal, under a key the page makes once, and rating it after updates the same row | One dinner is one row however often the page sends it, and the rating is kept per cook as well as on the recipe. |
| Only what they tell Chef can be "never". An inference can only lean (avoid, prefer, more, less) | A hard rule should be theirs to make. Code drops any Discover card that names a "never" subject, plural or not, after the model answers. |
| Inferred preferences are rewritten as a whole by distil, which runs at the start of each Refresh and before each weekly run. Forgetting one keeps it, marked forgotten, so a rewrite never brings it back | Rewriting means a second run or one after a crash ends in the same rows. Refresh is where fresh preferences are used today, and costs one Haiku call more. |
| Distil returns its preferences as a tool call, not native structured output | Pydantic AI 1.83 has no native-output profile for the newest Haiku. |
| What Chef knows in Settings shows told preferences first, then what Chef noticed, each with its evidence and a Forget with Undo. New ones are told in chat; Tell Chef opens it | Telling Chef is the one way in, as the plan says, and Settings is for reading and correcting. |
| A week plan is its own document (`week_plans`, one per week), not a kind of Discover card. Its new ideas become cards with origin `week` only when the list is made, and those stay out of the feed and out of Clear | The feed, its saves and the iOS client stay as they are. The ideas still save exactly as a Discover card does. |
| The week has 5 dinners on different evenings: 3 of their recipes (rated highly, not cooked or planned in the last 3 weeks, nothing they said never to) and 2 new ideas with a recipe page found by web search. Fewer recipes than that means more new ideas. Code checks each rule and sends a plan that breaks one back with the reason, three times at most | The plan's default. Rules the model is only asked to keep get broken. |
| Make the list fills the week's list if it already has one, on evenings that are still free, and a dinner whose evening is taken goes on as an any-day meal. Otherwise it makes the list. Their recipes go on at once; each new idea lands on its evening when its save finishes | A week planned by hand is never overwritten. |
| Make the list is undone with Chef's Undo (`POST /chef/actions/{id}/undo`), from the toast, which also offers Open. An idea that finishes saving after an Undo keeps its recipe but goes on no list | One Undo for Chef's changes, in chat or on the card. Nothing navigates on its own. |
| A week is planned by the weekly run, by Plan my week on Discover, or by asking Chef in chat | Home shows the card only when a plan is waiting. |
| The weekly run plans the coming week on Sunday at 08:00 UK time by default, and the day, hour and on/off are settings, in Settings and in chat (`set_weekly_plan`) | Alex asked for Sunday rather than Saturday, and for the day and time to be configurable (27 Oct 2026). |
| The API server schedules the run itself: a background task sleeps until the chosen day and hour in UK time, and a change to the time wakes it to reschedule. A run up to 4 hours late still happens (after a restart, or an hour after a failure), and a week with a plan, made, skipped or waiting, is never planned again | Alex asked for something better than a cron that checks the time every hour (27 Oct 2026). This needs no extra service, and a new time takes effect at once. |
| The coming week is the first week starting on or after the run's day. Its card shows on Home from then, before that week begins | With weeks from Saturday, a Sunday run plans the week from next Saturday, so the list is ready for that shop. |
| On phones Chef stays out of Shop and Cook | Both take the whole screen and have no tab bar for the sheet to sit on. The sidebar on wide windows stays. |
| Notifications, iOS first: week ready, recipe ready, Cook timer done | The timer is a local notification. The others are APNs pushes from the server. Permission is asked the first time one is useful, not at launch. |

## Phases

Each phase is its own PR.

1. Move Chef into `server/chef/` on Pydantic AI, with no visible change.
2. Move recipe and list logic out of the routes into `server/services/`, so the routes and Chef's tools share it.
3. Chef chat with its tools, web search, streaming and Undo.
4. Memory: a meal log from Cook, told and inferred preferences, and What Chef knows in Settings.
5. Parked on 18 Oct 2026 at Alex's request: a rough nutrition profile on each recipe, so Chef can balance a week. Until it comes back, the weekly plan balances on variety and the household's taste alone.
6. Week cards and Make the list.
7. Chef runs the week on its own, scheduled by the API server.
8. iOS notifications. Alex creates the APNs key and turns on the Push capability in Xcode first.

Still open, with the default the build uses: a week is 5 dinners (3 from the library, 2 new), nutrition is tracked as food groups rather than calories, balance starts from NHS guidance, Chef plans on Sunday at 08:00 UK time (a setting), and inferred preferences are shown with their evidence.
