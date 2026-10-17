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
| Messages carry only the path of the screen (`page: {"path": "/list/<id>"}`); the server reads the ids from it | The web and iOS then send the same thing, and a new screen needs no new field. |
| Recipe jobs and Discover cards have no Chef tools | A job is the same recipe making as `create_recipe`, `import_recipe` and `create_recipe_from_photos`, started for a phone that may drop a long request. Discover cards are Chef's own ideas; in chat it suggests in its reply. `tests/test_chef_parity.py` lists each exemption with its reason. |
| The web reads Chef's stream itself rather than adding the AI SDK's `useChat` | The protocol is a few event types and the client needs only a few dozen lines for it (`client/src/lib/chef.ts`), with no new dependency in an app that has to keep working offline. |
| While the chat is on screen, its changes carry their own Undo in the conversation and no toast; with Chef closed or at the slim bar, the reply's changes get one Undo toast | The toast would cover the message box, and the Undo is already beside each change. |
| On phones Chef stays out of Shop and Cook | Both take the whole screen and have no tab bar for the sheet to sit on. The sidebar on wide windows stays. |
| Notifications, iOS first: week ready, recipe ready, Cook timer done | The timer is a local notification. The others are APNs pushes from the server. Permission is asked the first time one is useful, not at launch. |

## Phases

Each phase is its own PR.

1. Move Chef into `server/chef/` on Pydantic AI, with no visible change.
2. Move recipe and list logic out of the routes into `server/services/`, so the routes and Chef's tools share it.
3. Chef chat with its tools, web search, streaming and Undo.
4. Memory: a meal log from Cook, told and inferred preferences, and What Chef knows in Settings.
5. A rough nutrition profile on each recipe, so Chef can balance a week.
6. Week cards and Make the list.
7. The `omlete-chef` Railway cron service runs the week on its own.
8. iOS notifications. Alex creates the APNs key and turns on the Push capability in Xcode first.

Still open, with the default the build uses: a week is 5 dinners (3 from the library, 2 new), nutrition is tracked as food groups rather than calories, balance starts from NHS guidance, Chef plans on Saturday at 08:00 UK time, and inferred preferences are shown with their evidence.
