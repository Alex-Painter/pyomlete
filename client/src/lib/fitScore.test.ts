import { describe, expect, it } from 'vitest'
import cases from '../../../docs/fixtures/fit-score-cases.json'
import { WEIGHTS, fitContext, fitScore, rankForDay } from './fitScore'
import { addDays } from './week'
import type { ListItem, PlanDay, RecipeSummary, RecipeTags } from './types'

type CaseRecipe = {
  id: string
  title: string
  tags: string | null
  rating?: number
  total_minutes?: number
  last_planned_on?: string
  ingredients?: string[]
}

type Case = {
  name: string
  week_start: string | null
  day: string
  quick?: boolean
  variety_days?: number
  week: Record<string, string>
  items?: { name: string; category: string; from: string[] }[]
  recipes: CaseRecipe[]
  order: string[]
  reasons?: Record<string, string | null>
  clash?: string[]
}

function tags(short: string | null): RecipeTags | null {
  if (short == null) return null
  const [base, main, mood, cuisine] = short.split(' ')
  return {
    base,
    main,
    mood,
    cuisine,
    traits: {
      oily_fish: false,
      red_meat: false,
      veg_led: false,
      legumes: false,
    },
  } as RecipeTags
}

function recipe(r: Partial<RecipeSummary> & { id: string }): RecipeSummary {
  return {
    title: r.id,
    ingredient_count: 0,
    rating: null,
    created_at: null,
    image_url: null,
    total_minutes: null,
    servings: null,
    source_name: null,
    ingredient_names: [],
    cuisine: null,
    tags: null,
    last_planned_on: null,
    ...r,
  }
}

function day(
  date: string,
  recipeId: string | null = null,
  quick = false,
): PlanDay {
  return { date, recipe_id: recipeId, status: 'open', origin: 'user', quick }
}

function load(c: Case) {
  const recipes = c.recipes.map((r) =>
    recipe({
      id: r.id,
      title: r.title,
      tags: tags(r.tags),
      rating: r.rating ?? null,
      total_minutes: r.total_minutes ?? null,
      last_planned_on: r.last_planned_on ?? null,
      ingredient_names: r.ingredients ?? [],
    }),
  )
  const days = c.week_start
    ? Array.from({ length: 7 }, (_, i) => {
        const date = addDays(c.week_start!, i)
        return day(date, c.week[date] ?? null, date === c.day && !!c.quick)
      })
    : []
  const items: ListItem[] = (c.items ?? []).map((entry, i) => ({
    id: `item-${i}`,
    name: entry.name,
    amount: null,
    unit: null,
    category: entry.category,
    checked: false,
    sources: entry.from.map((id) => ({ recipe_id: id, amount: null })),
  }))
  const ctx = fitContext({
    day: days.find((d) => d.date === c.day) ?? day(c.day, null, !!c.quick),
    days,
    recipes,
    items,
    varietyDays: c.variety_days ?? 3,
  })
  return { recipes, ctx }
}

describe('fit score cases shared with iOS', () => {
  for (const c of cases.cases as unknown as Case[]) {
    it(c.name, () => {
      const { recipes, ctx } = load(c)
      const ranked = rankForDay(recipes, ctx)
      expect(ranked.map((r) => r.recipe.id)).toEqual(c.order)
      const byId = new Map(ranked.map((r) => [r.recipe.id, r.fit]))
      for (const [id, reason] of Object.entries(c.reasons ?? {})) {
        expect(byId.get(id)?.reason, id).toBe(reason)
      }
      if (c.clash) {
        expect(
          ranked
            .filter((r) => r.fit.clash)
            .map((r) => r.recipe.id)
            .sort(),
        ).toEqual([...c.clash].sort())
      }
    })
  }
})

describe('fit score rules', () => {
  const smallestPenalty = Math.min(
    WEIGHTS.sameRecipe,
    WEIGHTS.sameBase,
    WEIGHTS.quickNight,
    WEIGHTS.sameMain,
    WEIGHTS.sameCuisine,
  )

  it('keeps reuse below the smallest variety penalty', () => {
    expect(WEIGHTS.sharedCap).toBeLessThan(smallestPenalty)
  })

  // A seeded generator, so a failure names a library that can be replayed.
  function random(seed: number) {
    return () => {
      seed = (seed * 1103515245 + 12345) % 2 ** 31
      return seed / 2 ** 31
    }
  }

  it('never ranks a clash above a clean meal with the same rating, over 200 random weeks', () => {
    const bases = ['rice', 'pasta', 'potatoes', 'bread', 'noodles', 'none']
    const mains = ['chicken', 'beef', 'pork', 'lamb', 'fish', 'veggie', 'beans']
    const cuisines = [
      'italian',
      'indian',
      'british',
      'south_east_asian',
      'mexican',
    ]
    const foods = ['spinach', 'feta', 'coriander', 'lime', 'chicken', 'cream']
    for (let seed = 1; seed <= 200; seed++) {
      const rnd = random(seed)
      const pick = <T>(xs: T[]) => xs[Math.floor(rnd() * xs.length)]
      const recipes = Array.from({ length: 30 }, (_, i) =>
        recipe({
          id: `r${i}`,
          tags: tags(`${pick(bases)} ${pick(mains)} fresh ${pick(cuisines)}`),
          rating: rnd() < 0.7 ? 1 + Math.floor(rnd() * 5) : null,
          total_minutes: 10 + Math.floor(rnd() * 80),
          last_planned_on:
            rnd() < 0.5 ? addDays('2026-10-17', -Math.floor(rnd() * 90)) : null,
          ingredient_names: foods.filter(() => rnd() < 0.3),
        }),
      )
      const days = Array.from({ length: 7 }, (_, i) =>
        day(
          addDays('2026-10-17', i),
          rnd() < 0.4 ? pick(recipes).id : null,
          rnd() < 0.2,
        ),
      )
      const items: ListItem[] = foods.map((name, i) => ({
        id: `i${i}`,
        name,
        amount: null,
        unit: null,
        category: 'Fresh Produce',
        checked: false,
        sources: [{ recipe_id: pick(recipes).id, amount: null }],
      }))
      const target = pick(days)
      const ctx = fitContext({
        day: target,
        days,
        recipes,
        items,
        varietyDays: 3,
      })
      const ranked = rankForDay(recipes, ctx)
      ranked.forEach((a, i) => {
        if (!a.fit.clash) return
        for (const b of ranked.slice(i + 1)) {
          if (!b.fit.clash && b.recipe.rating === a.recipe.rating) {
            throw new Error(
              `seed ${seed}: ${a.recipe.id} clashes but ranks above ${b.recipe.id}`,
            )
          }
        }
      })
    }
  })

  it('takes no tag signal from an untagged meal', () => {
    const pasta = recipe({
      id: 'pasta',
      tags: tags('pasta pork comforting italian'),
    })
    const untagged = recipe({ id: 'u' })
    const days = [day('2026-10-19', 'pasta'), day('2026-10-20')]
    const ctx = fitContext({
      day: days[1],
      days,
      recipes: [pasta, untagged],
      items: [],
      varietyDays: 3,
    })
    expect(fitScore(untagged, ctx)).toEqual({
      score: WEIGHTS.neverPlanned,
      reason: null,
      clash: false,
    })
  })
})
