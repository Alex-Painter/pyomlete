import { describe, expect, it } from 'vitest'
import {
  contextLine,
  initialLibraryQuery,
  libraryReducer,
  queryLibrary,
  withWeekHistory,
} from './libraryQuery'
import type { LibraryQuery } from './libraryQuery'
import type { PlanDay, RecipeSummary } from './types'

const TODAY = '2026-10-20'

function recipe(id: string, fields: Partial<RecipeSummary> = {}): RecipeSummary {
  return {
    id,
    title: id,
    ingredient_count: 0,
    rating: null,
    created_at: null,
    image_url: null,
    total_minutes: null,
    servings: null,
    source_name: null,
    ingredient_names: [],
    cuisine: null,
    last_planned_on: null,
    tags: null,
    ...fields,
  }
}

const library: RecipeSummary[] = [
  recipe('saag', {
    title: 'Saag paneer',
    ingredient_names: ['spinach', 'paneer', 'garam masala'],
    cuisine: 'Indian',
    total_minutes: 40,
    rating: 5,
    created_at: '2026-01-10T12:00:00',
    last_planned_on: '2026-08-01',
  }),
  recipe('spanakopita', {
    title: 'Spanakopita',
    ingredient_names: ['Spinach', 'feta', 'filo pastry'],
    cuisine: 'Greek',
    total_minutes: 75,
    rating: 4,
    created_at: '2026-09-01T12:00:00',
    last_planned_on: '2026-10-14',
  }),
  recipe('carbonara', {
    title: 'Carbonara',
    ingredient_names: ['spaghetti', 'eggs', 'guanciale'],
    cuisine: 'Italian',
    total_minutes: 25,
    rating: 3,
    created_at: '2026-05-05T12:00:00',
  }),
  recipe('omelette', {
    title: 'Crème fraîche omelette',
    ingredient_names: ['eggs', 'crème fraîche', 'chives'],
    total_minutes: 10,
    created_at: '2026-10-01T12:00:00',
    last_planned_on: '2026-09-25',
  }),
]

const q = (over: Partial<LibraryQuery> = {}): LibraryQuery => ({ ...initialLibraryQuery, ...over })
const ids = (rs: RecipeSummary[]) => rs.map((r) => r.id)

describe('queryLibrary search', () => {
  it('finds a recipe by an ingredient missing from its title', () => {
    expect(ids(queryLibrary(library, q({ text: 'spinach' }), TODAY)).sort()).toEqual([
      'saag',
      'spanakopita',
    ])
  })

  it('matches cuisine, and every word must match somewhere', () => {
    expect(ids(queryLibrary(library, q({ text: 'greek' }), TODAY))).toEqual(['spanakopita'])
    expect(ids(queryLibrary(library, q({ text: 'eggs italian' }), TODAY))).toEqual(['carbonara'])
  })

  it('ignores case and accents', () => {
    expect(ids(queryLibrary(library, q({ text: 'CREME' }), TODAY))).toEqual(['omelette'])
  })

  it('returns nothing when nothing matches', () => {
    expect(queryLibrary(library, q({ text: 'durian' }), TODAY)).toEqual([])
    expect(queryLibrary([], q(), TODAY)).toEqual([])
  })
})

describe('queryLibrary sorts', () => {
  it('Not had lately puts never planned first, then the oldest', () => {
    expect(ids(queryLibrary(library, q({ sort: 'not-lately' }), TODAY))).toEqual([
      'carbonara',
      'saag',
      'omelette',
      'spanakopita',
    ])
  })

  it('Your favourites goes by rating, unrated last', () => {
    expect(ids(queryLibrary(library, q({ sort: 'favourites' }), TODAY))).toEqual([
      'saag',
      'spanakopita',
      'carbonara',
      'omelette',
    ])
  })

  it('Quickest goes by total time', () => {
    expect(ids(queryLibrary(library, q({ sort: 'quickest' }), TODAY))).toEqual([
      'omelette',
      'carbonara',
      'saag',
      'spanakopita',
    ])
  })

  it('Newest goes by date added', () => {
    expect(ids(queryLibrary(library, q({ sort: 'newest' }), TODAY))).toEqual([
      'omelette',
      'spanakopita',
      'carbonara',
      'saag',
    ])
  })

  it('A to Z goes by title', () => {
    expect(ids(queryLibrary(library, q({ sort: 'az' }), TODAY))).toEqual([
      'carbonara',
      'omelette',
      'saag',
      'spanakopita',
    ])
  })

  it('does not reorder the array it was given', () => {
    const before = ids(library)
    queryLibrary(library, q({ sort: 'az' }), TODAY)
    expect(ids(library)).toEqual(before)
  })
})

describe('queryLibrary filters', () => {
  it('Quick keeps 30 minutes or less', () => {
    expect(ids(queryLibrary(library, q({ filters: ['quick'] }), TODAY))).toEqual([
      'carbonara',
      'omelette',
    ])
  })

  it('Not had lately drops anything planned in the last 21 days', () => {
    // Spanakopita was 6 days ago, the omelette 25 days ago.
    expect(ids(queryLibrary(library, q({ filters: ['not-lately'] }), TODAY))).toEqual([
      'carbonara',
      'saag',
      'omelette',
    ])
  })

  it('Favourites keeps 4 stars and up', () => {
    expect(ids(queryLibrary(library, q({ filters: ['favourites'] }), TODAY))).toEqual([
      'saag',
      'spanakopita',
    ])
  })

  it('combines filters and search', () => {
    expect(
      ids(queryLibrary(library, q({ text: 'spinach', filters: ['favourites', 'not-lately'] }), TODAY)),
    ).toEqual(['saag'])
    expect(queryLibrary(library, q({ filters: ['quick', 'favourites'] }), TODAY)).toEqual([])
  })
})

describe('withWeekHistory', () => {
  const days: PlanDay[] = [
    { date: '2026-10-22', recipe_id: 'carbonara', status: 'open', origin: 'user' },
    { date: '2026-10-23', recipe_id: null, status: 'out', origin: 'user' },
  ]

  it('counts a meal on this week as planned, so it sinks and leaves Not had lately', () => {
    const merged = withWeekHistory(library, days)
    expect(merged.find((r) => r.id === 'carbonara')?.last_planned_on).toBe('2026-10-22')
    expect(ids(queryLibrary(merged, q(), TODAY)).at(-1)).toBe('carbonara')
    expect(ids(queryLibrary(merged, q({ filters: ['not-lately'] }), TODAY))).not.toContain(
      'carbonara',
    )
  })

  it('keeps a later date the server already has', () => {
    const later = [recipe('x', { last_planned_on: '2026-11-01' })]
    expect(withWeekHistory(later, [{ ...days[0], recipe_id: 'x' }])[0].last_planned_on).toBe(
      '2026-11-01',
    )
  })
})

describe('contextLine', () => {
  it.each([
    [null, 'Never planned'],
    ['2026-10-22', 'Planned for Thu 22 Oct'],
    ['2026-10-20', 'Planned for today'],
    ['2026-10-19', 'Last had yesterday'],
    ['2026-10-16', 'Last had 4 days ago'],
    ['2026-10-12', 'Last had a week ago'],
    ['2026-09-15', 'Last had 5 weeks ago'],
    ['2026-06-01', 'Last had 4 months ago'],
    ['2025-01-01', 'Last had over a year ago'],
  ])('%s reads "%s"', (last, line) => {
    expect(contextLine(recipe('r', { last_planned_on: last }), TODAY)).toBe(line)
  })
})

describe('libraryReducer', () => {
  it('toggles a filter on and off', () => {
    const on = libraryReducer(initialLibraryQuery, { kind: 'toggleFilter', filter: 'quick' })
    expect(on.filters).toEqual(['quick'])
    expect(libraryReducer(on, { kind: 'toggleFilter', filter: 'quick' }).filters).toEqual([])
  })
})
