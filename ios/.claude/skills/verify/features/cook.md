# Cook

One recipe, full screen over the whole app, screen kept awake. An overview with a servings control and everything you'll need, then one step at a time in large type with the ingredients that step uses and a button for each cooking time it mentions, then "How was it?". Specified by `client/src/routes/cook.$recipeId.tsx`. The cook is saved on the phone with its recipe, so it resumes where you left off, with or without a connection.

## Sub-features

- `cook-overview` lists the ingredients and scales every amount with the servings control ("Servings" when the recipe says how many it serves, "Amount" as a ×multiplier when it does not).
- `cook-steps` walks the method with Back and Next, showing "Step n of m" and the ingredients for that step.
- `cook-timers` starts a timer from a time written in the step. Running timers show as chips on every step and read "Step n: done" when they end.
- `cook-rate` sends a 1 to 5 star rating from the last page. With no connection it is kept and sent later.
- `cook-resume` reopens a cook at the step, servings and timers it had, after closing Cook or a cold relaunch.
- `cook-close` returns to where Cook was opened: Home, Plan or a recipe page.

## How to get to it (user POV)

- On Home, tap a card under "Cook from <list>". Or in Plan, tap a meal chip and choose Cook this. Or on a recipe page, tap Cook.

## Driving it with omlete-ios-verify

Preconditions:

- `$V up` just ran and `$V doctor` prints no `FAIL`. `<egg>` and `<shakshuka>` are the ids of the two fixture recipes on the list.

- **Overview and scaling.** `$V tap home.cookCard.<shakshuka>`, `$V expect "chopped tomatoes, 400g"`, `$V tap cook.moreButton` twice, then `$V expect "chopped tomatoes, 800g"` and `$V expect "eggs, 8"`. For the Soft Egg, which has no serving count, the value reads `×1` and `cook.moreButton` makes it `×1.5` with `eggs, 1.5`.
- **Steps.** `$V tap cook.startButton`, `$V expect "Step 1 of 3"`, `$V tap cook.nextButton`, `$V expect "Step 2 of 3"`. `cook.backButton` goes back; on the last step `cook.nextButton` is labelled Finish.
- **A timer finishing.** In the Soft Egg: `$V tap cook.startButton`, `$V tap cook.startTimer.0`, `$V tap cook.nextButton`, then `$V expect "Step 1: done"` on step 2. `cook.dismissTimer.0` removes the chip.
- **A timer running.** In the Shakshuka's step 2, `$V tap cook.startTimer.0`; `$V snapshot` shows `cook.timerChip.0` counting down from `10:00`.
- **Rate.** On the last page, `$V expect "How was it?"`, `$V tap cook.star.4`, `$V expect "Thanks. Discover will suggest more like this, or less."`. `curl -s http://127.0.0.1:8765/api/recipes/<id> | jq .rating` prints `4`.
- **Rate offline.** `$V api stop`, `$V tap cook.star.5`, `$V expect "Saved. It will send when you're back online."`, `$V api start`, `$V relaunch`. A few seconds later the API has `5`, and `.verify-run/api.log` holds one `PATCH /api/recipes/<id>/rating`.
- **Resume.** Mid-cook with a timer running: `$V api stop`, `$V relaunch`, `$V tap home.cookCard.<shakshuka>`, `$V expect "Step 2 of 3"`. The chip is still counting.
- **Close.** `$V tap cook.closeButton`, then `$V expect-id home.planWeekButton` (or `plan.startShoppingButton` when opened from Plan, or `recipe.cookButton` when opened from a recipe page).

## Gotchas

- The recipe title, "You'll need" and Home's "Cook from ..." are titles and section headers, which are not in the UI tree. Check them in the screenshot.
- An ingredient row's label is `<name>, <quantity>`, so `expect "eggs, 8"` matches it.
- Timer ids are positions, counted from 0: `cook.startTimer.<n>` among the times found in the step, `cook.timerChip.<n>` and `cook.dismissTimer.<n>` among the running timers.
- A finished cook, or one untouched for 8 hours, reopens at the overview. To see resume, leave the cook on a step.
- Saved cooks survive `up`. A recipe id is new on every seed, so an old cook is never reopened by accident.
- The chime is a system sound and a haptic. Neither can be observed from here; the unit tests count it.
- Home and Plan stay in the UI tree underneath Cook.
