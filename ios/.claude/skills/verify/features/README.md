# Omlete iOS verification map

This directory is the maintained source for verifying what a user can do in Omlete for iOS. Read this index before driving the app, then use the matching feature file as the recipe. Launch, doctor, evidence and cleanup are in [`../SKILL.md`](../SKILL.md).

## Baseline preconditions

- Commands run from `ios/` with `V=.claude/skills/verify/scripts/omlete-ios-verify`.
- `$V up` has run since the last source change, and `$V doctor` prints no `FAIL`. `up` seeds one list, `Verify Fixture List`, with six items and one meal.
- Ids are new on every seed. Each recipe below uses `<listID>` and `<itemID>`: read them from `$V snapshot`, or with `curl -s http://127.0.0.1:8765/api/lists/ | jq -r '.[0].id'` and `curl -s http://127.0.0.1:8765/api/lists/<listID> | jq -r '.items[] | "\(.id) \(.name)"'`.
- Never drive an Omlete instance that `$V up` did not launch.

## Driving conventions

- Start each recipe with `$V begin <label>`, using the sub-feature id as the label.
- Start from the launch screen (a fresh `$V up`) and tap through, unless the recipe says otherwise.
- Find controls by accessibility identifier (`screen.controlName`). Text is for `expect` and `gone` only.
- Follow each action with an `expect` or `gone` for the state it should produce.

## Proof and skip reporting

- A `PASS` line per step, plus the `ios/verify-artifacts/<stamp>-<label>/` folder (UI tree and screenshot after every step, `run.log`).
- Name the feature file and sub-feature id with each artifact.
- A path that cannot be reached is reported with the command tried and the precondition that was not met. Never report it as verified through a different path.

## Feature entry contract

Each feature file has an H1, a one-paragraph description, and then four H2s in this order: `Sub-features`, `How to get to it (user POV)`, `Driving it with omlete-ios-verify`, and `Gotchas`. One file per screen.

## Features

- [Home](./home.md): your lists. Open one, start a new one, rename, duplicate, delete with Undo.
- [Plan](./plan.md): one list. Quick add, check off, edit, delete with Undo, reorder, meals, Start shopping.
- [Shop](./shop.md): the list full screen in aisle order. Check with Undo, quick add, works with the API stopped.

## Screens not built yet

Each follows a web route (`client/src/routes`, the spec named in `ios/CLAUDE.md`). When a screen is built, add its feature file here in the same change, and move it from this table to the list above.

| Screen | Web route that specifies it |
|---|---|
| Home's other sections (cook from list, Chef's picks) | `/` |
| Discover | `/discover` |
| Recipe library and recipe detail | `/recipes`, `/recipe/$recipeId` |
| Add a recipe | `/create` |
| Meal picker in Plan ("Add meals") | `/list/$listId` (`MealsSheet`) |
| Cook | `/cook/$recipeId` |
| Settings | `/settings` |
