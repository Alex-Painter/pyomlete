/**
 * Search, filters and sorts for the meal library on Plan.
 *
 * Pure functions over recipe summaries, so the week view and the plain-list
 * library rank meals the same way and the rules can be tested without a
 * screen. The default sort puts the meals you haven't had for longest first:
 * variety without having to remember what you ate.
 */
import { addDays, daysBetween, shortLabel } from '@/lib/week'
import type { ISODate, PlanDay, RecipeSummary } from '@/lib/types'

export type LibrarySort = 'not-lately' | 'favourites' | 'quickest' | 'newest' | 'az'
export type LibraryFilter = 'quick' | 'not-lately' | 'favourites'

export const SORTS: { id: LibrarySort; label: string }[] = [
  { id: 'not-lately', label: 'Not had lately' },
  { id: 'favourites', label: 'Your favourites' },
  { id: 'quickest', label: 'Quickest' },
  { id: 'newest', label: 'Newest' },
  { id: 'az', label: 'A to Z' },
]

export const FILTERS: { id: LibraryFilter; label: string }[] = [
  { id: 'quick', label: 'Quick' },
  { id: 'not-lately', label: 'Not had lately' },
  { id: 'favourites', label: 'Favourites' },
]

export const QUICK_MINUTES = 30
export const NOT_LATELY_DAYS = 21
export const FAVOURITE_RATING = 4

export type LibraryQuery = {
  text: string
  sort: LibrarySort
  filters: LibraryFilter[]
}

export const initialLibraryQuery: LibraryQuery = { text: '', sort: 'not-lately', filters: [] }

export type LibraryAction =
  | { kind: 'search'; text: string }
  | { kind: 'sort'; sort: LibrarySort }
  | { kind: 'toggleFilter'; filter: LibraryFilter }

export function libraryReducer(q: LibraryQuery, action: LibraryAction): LibraryQuery {
  switch (action.kind) {
    case 'search':
      return { ...q, text: action.text }
    case 'sort':
      return { ...q, sort: action.sort }
    case 'toggleFilter':
      return {
        ...q,
        filters: q.filters.includes(action.filter)
          ? q.filters.filter((f) => f !== action.filter)
          : [...q.filters, action.filter],
      }
  }
}

/**
 * Lay this week's days over each recipe's `last_planned_on`, so a meal just
 * put on Tuesday counts as had at once, before the server has heard of it.
 */
export function withWeekHistory(recipes: RecipeSummary[], days: PlanDay[]): RecipeSummary[] {
  const latest = new Map<string, ISODate>()
  for (const d of days) {
    if (!d.recipe_id) continue
    const prev = latest.get(d.recipe_id)
    if (!prev || d.date > prev) latest.set(d.recipe_id, d.date)
  }
  if (latest.size === 0) return recipes
  return recipes.map((r) => {
    const week = latest.get(r.id)
    if (!week || (r.last_planned_on && r.last_planned_on >= week)) return r
    return { ...r, last_planned_on: week }
  })
}

// Case- and accent-insensitive, so "creme" finds "Crème fraîche".
function fold(s: string): string {
  return s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
}

function matchesText(r: RecipeSummary, words: string[]): boolean {
  if (words.length === 0) return true
  const haystack = fold([r.title, r.cuisine ?? '', ...r.ingredient_names].join('\n'))
  return words.every((w) => haystack.includes(w))
}

const passes: Record<LibraryFilter, (r: RecipeSummary, today: ISODate) => boolean> = {
  quick: (r) => r.total_minutes != null && r.total_minutes <= QUICK_MINUTES,
  'not-lately': (r, today) =>
    r.last_planned_on == null || r.last_planned_on < addDays(today, -NOT_LATELY_DAYS),
  favourites: (r) => r.rating != null && r.rating >= FAVOURITE_RATING,
}

const byTitle = (a: RecipeSummary, b: RecipeSummary) =>
  a.title.localeCompare(b.title, undefined, { sensitivity: 'base' })

// Missing values sort last in every order except Not had lately, where
// never planned is the point and comes first.
function nullsLast<T>(a: T | null, b: T | null, cmp: (a: T, b: T) => number): number {
  if (a == null && b == null) return 0
  if (a == null) return 1
  if (b == null) return -1
  return cmp(a, b)
}

const comparators: Record<LibrarySort, (a: RecipeSummary, b: RecipeSummary) => number> = {
  'not-lately': (a, b) => {
    if (a.last_planned_on == null || b.last_planned_on == null) {
      return (a.last_planned_on == null ? 0 : 1) - (b.last_planned_on == null ? 0 : 1)
    }
    return a.last_planned_on.localeCompare(b.last_planned_on)
  },
  favourites: (a, b) => nullsLast(a.rating, b.rating, (x, y) => y - x),
  quickest: (a, b) => nullsLast(a.total_minutes, b.total_minutes, (x, y) => x - y),
  newest: (a, b) => nullsLast(a.created_at, b.created_at, (x, y) => y.localeCompare(x)),
  az: () => 0,
}

export function queryLibrary(
  recipes: RecipeSummary[],
  query: LibraryQuery,
  today: ISODate,
): RecipeSummary[] {
  const words = fold(query.text).split(/\s+/).filter(Boolean)
  const cmp = comparators[query.sort]
  return recipes
    .filter((r) => matchesText(r, words) && query.filters.every((f) => passes[f](r, today)))
    .sort((a, b) => cmp(a, b) || byTitle(a, b))
}

/** One line of context for a library row, in place of the ingredient count. */
export function contextLine(r: RecipeSummary, today: ISODate): string {
  const last = r.last_planned_on
  if (last == null) return 'Never planned'
  const ago = daysBetween(last, today)
  if (ago < 0) return `Planned for ${shortLabel(last)}`
  if (ago === 0) return 'Planned for today'
  if (ago === 1) return 'Last had yesterday'
  if (ago < 7) return `Last had ${ago} days ago`
  const weeks = Math.floor(ago / 7)
  if (weeks === 1) return 'Last had a week ago'
  if (weeks < 9) return `Last had ${weeks} weeks ago`
  if (ago < 365) return `Last had ${Math.floor(ago / 30)} months ago`
  return 'Last had over a year ago'
}
