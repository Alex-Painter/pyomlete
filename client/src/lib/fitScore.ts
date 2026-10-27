/**
 * How well a meal fits one evening of the week, with the reason in a few words.
 *
 * A plain sum of signals, not a black box, so every suggestion can say why
 * it's there and you can trust or overrule it at a glance. Variety rules
 * (the same base, main or cuisine too close together) are clashes: a clashing
 * meal is never hidden, it sinks below every clean one and says why. Boosts
 * (rated well and not had lately, uses what's on the list) order the rest.
 *
 * Pure, so it runs offline and within a frame. `docs/fixtures/fit-score-cases.json`
 * pins the order for the web and for the iOS port (FitScore.swift), and
 * `docs/DESIGN.md` explains the rules.
 */
import { QUICK_MINUTES } from '@/lib/libraryQuery'
import {
  addDays,
  dayLong,
  daysBetween,
  monthLong,
  shortLabel,
} from '@/lib/week'
import type {
  CuisineFamily,
  ISODate,
  ListItem,
  PlanDay,
  RecipeSummary,
} from '@/lib/types'

/** Every weight in one place. Penalties are positive numbers taken off. */
export const WEIGHTS = {
  sameRecipe: 60,
  sameBase: 40,
  quickNight: 35,
  sameMain: 30,
  sameCuisine: 25,
  /** Per star above or below 3. */
  ratingStar: 5,
  /** Per week since last planned, up to `recencyWeeksCap`. */
  recencyWeek: 1.5,
  recencyWeeksCap: 8,
  /** A meal never planned: unknown, so a little less than a long gap. */
  neverPlanned: 4,
  /** Per perishable ingredient already on the list, up to `sharedCap`. */
  sharedIngredient: 6,
  sharedCap: 18,
  quickFit: 5,
} as const

/** Same cuisine family within this many days is a clash. */
export const CUISINE_DAYS = 2
/** Same recipe within this many days is a clash. */
export const REPEAT_DAYS = 14
/** Rated at least this and not had for this many days earns its own reason. */
const WELL_RATED = 4
const LONG_GAP_DAYS = 21

// Things that go off. Pantry staples are on every list, so they say nothing.
const PERISHABLE = new Set([
  'Fresh Produce',
  'Meat & Fish',
  'Dairy & Eggs',
  'Bakery',
])

const CUISINE_LABEL: Record<CuisineFamily, string> = {
  british: 'British',
  french: 'French',
  italian: 'Italian',
  spanish: 'Spanish',
  greek: 'Greek',
  middle_eastern: 'Middle Eastern',
  north_african: 'North African',
  indian: 'Indian',
  chinese: 'Chinese',
  japanese: 'Japanese',
  korean: 'Korean',
  south_east_asian: 'South-east Asian',
  mexican: 'Mexican',
  latin_american: 'Latin American',
  american: 'American',
  other: 'Other',
}

const capitalise = (s: string) => s.charAt(0).toUpperCase() + s.slice(1)

export type Fit = {
  score: number
  /** The strongest clash, else the strongest reason to pick it; null when nothing stands out. */
  reason: string | null
  clash: boolean
}

/** A meal planned near the day being ranked, from this week or from history. */
type Neighbour = {
  date: ISODate
  recipe: RecipeSummary
  inWeek: boolean
  /** Whole days from the evening being ranked, either way. */
  gap: number
}

/** Everything about one evening that doesn't depend on the meal, built once per day. */
export type FitContext = {
  day: PlanDay
  /** Nearby meals by recipe id, base, main and cuisine, each already inside its rule's window. */
  sameRecipe: Map<string, Neighbour[]>
  sameBase: Map<string, Neighbour[]>
  sameMain: Map<string, Neighbour[]>
  sameCuisine: Map<string, Neighbour[]>
  /** Perishable ingredients already on the list, by folded name, with the meals they came from. */
  onList: Map<string, { name: string; recipeIds: Set<string> }>
}

const fold = (s: string) =>
  s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim()

// Folding is the slow part of ranking a big library, and names don't change.
const foldedCache = new WeakMap<RecipeSummary, string[]>()
function foldedIngredients(r: RecipeSummary): string[] {
  let names = foldedCache.get(r)
  if (!names) {
    names = r.ingredient_names.map(fold)
    foldedCache.set(r, names)
  }
  return names
}

const byTitle = new Intl.Collator(undefined, { sensitivity: 'base' }).compare

function push(map: Map<string, Neighbour[]>, key: string, n: Neighbour) {
  const found = map.get(key)
  if (found) found.push(n)
  else map.set(key, [n])
}

export function fitContext({
  day,
  days,
  recipes,
  items,
  varietyDays,
}: {
  day: PlanDay
  /** The week's days; empty for a plain list. */
  days: PlanDay[]
  /** The whole library, with `last_planned_on` already covering this week. */
  recipes: RecipeSummary[]
  items: ListItem[]
  varietyDays: number
}): FitContext {
  const byId = new Map(recipes.map((r) => [r.id, r]))
  const week = new Set(days.map((d) => d.date))
  const near: Neighbour[] = []
  for (const d of days) {
    const recipe = d.recipe_id ? byId.get(d.recipe_id) : undefined
    if (recipe && d.date !== day.date) {
      const gap = Math.abs(daysBetween(d.date, day.date))
      near.push({ date: d.date, recipe, inWeek: true, gap })
    }
  }
  // Earlier weeks reach across the shop day: pasta last Friday counts on Saturday.
  // Inside this week, the week's own days are the truth.
  const reach = Math.max(varietyDays, REPEAT_DAYS)
  const from = addDays(day.date, -reach)
  const to = addDays(day.date, reach)
  for (const r of recipes) {
    const last = r.last_planned_on
    if (!last || last < from || last > to || week.has(last)) continue
    const gap = Math.abs(daysBetween(last, day.date))
    if (gap >= 1) near.push({ date: last, recipe: r, inWeek: false, gap })
  }

  const ctx: FitContext = {
    day,
    sameRecipe: new Map(),
    sameBase: new Map(),
    sameMain: new Map(),
    sameCuisine: new Map(),
    onList: new Map(),
  }
  for (const n of near) {
    if (n.gap <= REPEAT_DAYS) push(ctx.sameRecipe, n.recipe.id, n)
    const tags = n.recipe.tags
    if (!tags) continue
    if (tags.base !== 'none' && n.gap <= varietyDays)
      push(ctx.sameBase, tags.base, n)
    if (tags.main !== 'veggie' && n.gap === 1) push(ctx.sameMain, tags.main, n)
    if (tags.cuisine !== 'other' && n.gap <= CUISINE_DAYS)
      push(ctx.sameCuisine, tags.cuisine, n)
  }

  for (const item of items) {
    if (!PERISHABLE.has(item.category)) continue
    const key = fold(item.name)
    const entry = ctx.onList.get(key) ?? {
      name: item.name,
      recipeIds: new Set<string>(),
    }
    for (const s of item.sources)
      if (s.recipe_id) entry.recipeIds.add(s.recipe_id)
    ctx.onList.set(key, entry)
  }
  return ctx
}

type Signal = { weight: number; reason: string }

/** The closest nearby meal other than this one, for a rule's reason. */
function closestOther(found: Neighbour[] | undefined, id: string) {
  let best: Neighbour | undefined
  for (const n of found ?? []) {
    if (n.recipe.id !== id && (!best || n.gap < best.gap)) best = n
  }
  return best
}

function clashes(r: RecipeSummary, ctx: FitContext): Signal[] {
  const out: Signal[] = []
  const repeat = ctx.sameRecipe
    .get(r.id)
    ?.reduce((a, b) => (b.gap < a.gap ? b : a))
  if (repeat) {
    const reason = repeat.inWeek
      ? `On ${dayLong(repeat.date)} already`
      : `Had on ${shortLabel(repeat.date)}`
    out.push({ weight: WEIGHTS.sameRecipe, reason })
  }
  const tags = r.tags
  if (tags) {
    const base = closestOther(ctx.sameBase.get(tags.base), r.id)
    if (base && tags.base !== 'none') {
      out.push({
        weight: WEIGHTS.sameBase,
        reason: `${capitalise(tags.base)} on ${dayLong(base.date)}`,
      })
    }
    const main = closestOther(ctx.sameMain.get(tags.main), r.id)
    if (main) {
      out.push({
        weight: WEIGHTS.sameMain,
        reason: `${capitalise(tags.main)} on ${dayLong(main.date)}`,
      })
    }
    const cuisine = closestOther(ctx.sameCuisine.get(tags.cuisine), r.id)
    if (cuisine) {
      out.push({
        weight: WEIGHTS.sameCuisine,
        reason: `${CUISINE_LABEL[tags.cuisine]} on ${dayLong(cuisine.date)}`,
      })
    }
  }
  if (
    ctx.day.quick &&
    r.total_minutes != null &&
    r.total_minutes > QUICK_MINUTES
  ) {
    out.push({
      weight: WEIGHTS.quickNight,
      reason: `${r.total_minutes} min on a quick night`,
    })
  }
  return out
}

function listNames(names: string[]): string {
  if (names.length === 1) return names[0]
  if (names.length === 2) return `${names[0]} and ${names[1]}`
  return `${names[0]}, ${names[1]} and more`
}

/** The perishable ingredients this meal shares with what other meals put on the list. */
export function sharedWithList(r: RecipeSummary, ctx: FitContext): string[] {
  const shared: string[] = []
  const seen = new Set<string>()
  for (const key of foldedIngredients(r)) {
    const entry = ctx.onList.get(key)
    if (!entry || seen.has(key)) continue
    // An item only this meal put on the list isn't shared.
    if (
      entry.recipeIds.size > 0 &&
      [...entry.recipeIds].every((id) => id === r.id)
    )
      continue
    seen.add(key)
    shared.push(entry.name.toLowerCase())
  }
  return shared
}

function boosts(r: RecipeSummary, ctx: FitContext): Signal[] {
  const out: Signal[] = []
  const rating = r.rating != null ? (r.rating - 3) * WEIGHTS.ratingStar : 0
  const last = r.last_planned_on
  const gap = last ? daysBetween(last, ctx.day.date) : null
  const recency =
    gap == null
      ? WEIGHTS.neverPlanned
      : gap > 0
        ? Math.min(gap / 7, WEIGHTS.recencyWeeksCap) * WEIGHTS.recencyWeek
        : 0
  const wellRatedGap =
    r.rating != null &&
    r.rating >= WELL_RATED &&
    (gap == null || gap >= LONG_GAP_DAYS)
  out.push({
    weight: rating + recency,
    reason: !wellRatedGap
      ? ''
      : last
        ? `Not had since ${monthLong(last)}, rated ${r.rating}`
        : `Rated ${r.rating}, not planned yet`,
  })

  const shared = sharedWithList(r, ctx)
  if (shared.length > 0) {
    out.push({
      weight: Math.min(
        shared.length * WEIGHTS.sharedIngredient,
        WEIGHTS.sharedCap,
      ),
      reason: `Uses the ${listNames(shared)} already on the list`,
    })
  }

  if (
    ctx.day.quick &&
    r.total_minutes != null &&
    r.total_minutes <= QUICK_MINUTES
  ) {
    out.push({
      weight: WEIGHTS.quickFit,
      reason: `${r.total_minutes} min, quick enough`,
    })
  }
  return out
}

export function fitScore(r: RecipeSummary, ctx: FitContext): Fit {
  const bad = clashes(r, ctx)
  const good = boosts(r, ctx)
  const score =
    good.reduce((sum, s) => sum + s.weight, 0) -
    bad.reduce((sum, s) => sum + s.weight, 0)
  if (bad.length > 0) {
    const worst = bad.reduce((a, b) => (b.weight > a.weight ? b : a))
    return { score, reason: worst.reason, clash: true }
  }
  const best = good
    .filter((s) => s.reason)
    .reduce<Signal | null>(
      (a, b) => (a == null || b.weight > a.weight ? b : a),
      null,
    )
  return { score, reason: best?.reason ?? null, clash: false }
}

export type Ranked = { recipe: RecipeSummary; fit: Fit }

/** The library in order for this evening: clean meals first, then clashes, each by score. */
export function rankForDay(
  recipes: RecipeSummary[],
  ctx: FitContext,
): Ranked[] {
  return recipes
    .map((recipe) => ({ recipe, fit: fitScore(recipe, ctx) }))
    .sort(
      (a, b) =>
        Number(a.fit.clash) - Number(b.fit.clash) ||
        b.fit.score - a.fit.score ||
        byTitle(a.recipe.title, b.recipe.title),
    )
}
