# Omlete iOS verification map

This directory is the maintained source for verifying what a user can do in Omlete for iOS. Read this index before driving the app, then use the matching feature file as the recipe. Launch, doctor, evidence and cleanup are in [`../SKILL.md`](../SKILL.md).

## Baseline preconditions

- Commands run from `ios/` with `V=.claude/skills/verify/scripts/omlete-ios-verify`.
- `$V up` has run since the last source change, and `$V doctor` prints no `FAIL`.
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

- [Launch screen](./launch.md): the app opens to its first screen. This is the only screen the app has today.

## Screens not built yet

The app is a scaffold. Its screens will follow the web app's routes (`client/src/routes`, the spec named in `ios/CLAUDE.md`). When a screen is built, add its feature file here in the same change, and move it from this list to the one above.

| Screen | Web route that specifies it |
|---|---|
| Home | `/` |
| Discover | `/discover` |
| Recipe library and recipe detail | `/recipes`, `/recipe/$recipeId` |
| Add a recipe | `/create` |
| Plan a list | `/list/$listId` |
| Shop | `/shop/$listId` |
| Cook | `/cook/$recipeId` |
| Settings | `/settings` |

The app makes no network requests yet, so this skill starts no backend. The first screen that loads data needs a local API to talk to and known fixture data; extend `../SKILL.md` (Launch, Doctor, Cleanup) when that lands.
