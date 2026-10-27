import { useEffect, useMemo, useReducer, useRef, useState } from 'react'
import type { Ref } from 'react'
import { Link } from '@tanstack/react-router'
import { useDraggable } from '@dnd-kit/core'
import { Check, Clock, Loader2, Plus, RefreshCw, Search, Sparkles, Star } from 'lucide-react'
import { HelpMeChoose } from '@/components/HelpMeChoose'
import { MealPickCard } from '@/components/MealPickCard'
import { RecipeThumb } from '@/components/RecipeThumb'
import { formatMinutes } from '@/components/RecipeMetaRow'
import { fitContext, rankForDay, sharedWithList } from '@/lib/fitScore'
import type { FitContext, Ranked } from '@/lib/fitScore'
import {
  BEST_SORT,
  FILTERS,
  SORTS,
  USES_LIST_FILTER,
  contextLine,
  initialDayQuery,
  initialLibraryQuery,
  libraryReducer,
  queryLibrary,
  tagFilters,
  withWeekHistory,
} from '@/lib/libraryQuery'
import type { DayRanking, LibrarySort } from '@/lib/libraryQuery'
import { dayLong } from '@/lib/week'
import type { ISODate, ListItem, PlanDay, RecipeSummary } from '@/lib/types'
import { cn } from '@/lib/utils'

/** How a row ends: what a tap will do, or that it's already done. */
export type RowMark = 'add' | 'added' | 'busy'

/** How many meals Top three shows, and Something else moves on by. */
const TOP = 3

/** The evening a week's library ranks for, and what it ranks against. */
export type LibraryDay = {
  day: PlanDay
  items: ListItem[]
  varietyDays: number
}

/**
 * The meal library, inline on Plan rather than in a sheet. On a week list it
 * picks the selected day's dinner, ranked by how well each meal fits that
 * evening with the reason on each row, and the top three on top; on a plain
 * list it adds meals. Rows can be dragged onto a day column on desktop.
 */
export function DayLibrary({
  id,
  heading,
  recipes,
  isLoading,
  days,
  today,
  markFor,
  onPick,
  draggable,
  searchRef,
  forDay,
}: {
  id: string
  heading: string
  recipes: RecipeSummary[] | undefined
  isLoading: boolean
  days: PlanDay[]
  today: ISODate
  markFor: (r: RecipeSummary) => RowMark
  onPick: (r: RecipeSummary) => void
  draggable: boolean
  searchRef?: Ref<HTMLInputElement>
  /** Set on a week: rank for this evening. */
  forDay?: LibraryDay
}) {
  const [query, dispatch] = useReducer(libraryReducer, forDay ? initialDayQuery : initialLibraryQuery)
  const library = useMemo(() => withWeekHistory(recipes ?? [], days), [recipes, days])
  const ranking = useMemo(() => {
    if (!forDay) return null
    const ctx = fitContext({ ...forDay, days, recipes: library })
    const ranked = rankForDay(library, ctx)
    return { ctx, ranked, fits: new Map(ranked.map((r) => [r.recipe.id, r.fit])) }
  }, [forDay, days, library])
  const dayRanking = useMemo<DayRanking | undefined>(
    () =>
      ranking
        ? {
            rank: new Map(ranking.ranked.map((r, i) => [r.recipe.id, i])),
            usesList: (r) => sharedWithList(r, ranking.ctx).length > 0,
          }
        : undefined,
    [ranking],
  )
  const rows = useMemo(
    () => queryLibrary(library, query, today, dayRanking),
    [library, query, today, dayRanking],
  )
  const sorts = forDay ? [BEST_SORT, ...SORTS] : SORTS
  const filters = useMemo(
    () => [...FILTERS, ...(forDay ? [USES_LIST_FILTER] : []), ...tagFilters(recipes ?? [])],
    [forDay, recipes],
  )

  return (
    <section id={id} aria-labelledby={`${id}-heading`} className="scroll-mt-48 pt-5">
      <h2 id={`${id}-heading`} className="mb-3 text-lg font-semibold">
        {heading}
      </h2>

      {ranking && forDay && forDay.day.status !== 'out' && (
        <TopThree
          key={forDay.day.date}
          date={forDay.day.date}
          ranked={ranking.ranked}
          ctx={ranking.ctx}
          markFor={markFor}
          onPick={onPick}
        />
      )}

      <div className="mb-2 flex gap-2">
        <label className="relative block min-w-0 flex-1">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-ink-muted" />
          <input
            ref={searchRef}
            type="search"
            value={query.text}
            onChange={(e) => dispatch({ kind: 'search', text: e.target.value })}
            placeholder="Dish or ingredient"
            aria-label="Search meals or ingredients"
            className="h-11 w-full rounded-xl border border-line bg-white pl-9 pr-3 text-base outline-none focus:ring-2 focus:ring-ring"
          />
        </label>
        <label className="sr-only" htmlFor={`${id}-sort`}>
          Sort
        </label>
        <select
          id={`${id}-sort`}
          value={query.sort}
          onChange={(e) => {
            const sort = sorts.find((s) => s.id === e.target.value)
            if (sort) dispatch({ kind: 'sort', sort: sort.id satisfies LibrarySort })
          }}
          className="h-11 max-w-[42%] shrink-0 rounded-xl border border-line bg-white px-2 text-sm font-medium outline-none focus:ring-2 focus:ring-ring"
        >
          {sorts.map((s) => (
            <option key={s.id} value={s.id}>
              {s.label}
            </option>
          ))}
        </select>
      </div>

      <div role="group" aria-label="Filters" className="no-scrollbar -mx-4 mb-3 flex gap-2 overflow-x-auto px-4">
        {filters.map((f) => {
          const on = query.filters.includes(f.id)
          return (
            <button
              key={f.id}
              type="button"
              aria-pressed={on}
              onClick={() => dispatch({ kind: 'toggleFilter', filter: f.id })}
              className={cn(
                'flex min-h-[44px] shrink-0 items-center gap-1 rounded-full border px-4 text-sm font-medium transition-colors',
                on ? 'border-ink bg-ink text-white' : 'border-line bg-white text-ink-soft hover:bg-sand',
              )}
            >
              {on && <Check className="size-3.5" strokeWidth={3} />}
              {f.label}
            </button>
          )
        })}
      </div>

      {isLoading && <Loader2 className="mx-auto my-6 size-5 animate-spin text-ink-muted" />}

      {recipes && recipes.length === 0 && (
        <p className="rounded-xl bg-white px-4 py-5 text-sm text-ink-muted">
          No recipes yet.{' '}
          <Link to="/create" className="font-medium text-ink underline underline-offset-4">
            Add one
          </Link>{' '}
          or save something from{' '}
          <Link to="/discover" className="font-medium text-ink underline underline-offset-4">
            Discover
          </Link>
          .
        </p>
      )}

      {recipes && recipes.length > 0 && rows.length === 0 && (
        <p className="rounded-xl bg-white px-4 py-5 text-center text-sm text-ink-muted">
          No meals match. Try fewer words or filters.
        </p>
      )}

      <ul className="space-y-1">
        {rows.map((r) => (
          <LibraryRow
            key={r.id}
            recipe={r}
            context={ranking?.fits.get(r.id)?.reason ?? contextLine(r, today)}
            clash={ranking?.fits.get(r.id)?.clash ?? false}
            mark={markFor(r)}
            onPick={() => onPick(r)}
            draggable={draggable}
          />
        ))}
      </ul>
    </section>
  )
}

/**
 * The three best fits for the evening, each with its reason, so most dinners
 * are one glance and one tap. Something else shows the next three; skipping
 * one says "not tonight", never "not for me", so nothing is sent anywhere.
 * Help me choose swaps the three for Narrow it down, in the same place.
 */
function TopThree({
  date,
  ranked,
  ctx,
  markFor,
  onPick,
}: {
  date: ISODate
  ranked: Ranked[]
  ctx: FitContext
  markFor: (r: RecipeSummary) => RowMark
  onPick: (r: RecipeSummary) => void
}) {
  const [page, setPage] = useState(0)
  const [choosing, setChoosing] = useState(false)
  // The day's own meal is already chosen; the rest are what you'd swap to.
  const pool = ranked.filter((r) => r.recipe.id !== ctx.day.recipe_id)
  if (pool.length === 0) return null
  if (choosing) {
    return (
      <HelpMeChoose
        ranked={pool}
        quickNight={!!ctx.day.quick}
        markFor={markFor}
        onPick={onPick}
        onClose={() => setChoosing(false)}
      />
    )
  }
  const pages = Math.ceil(pool.length / TOP)
  const shown = pool.slice((page % pages) * TOP, (page % pages) * TOP + TOP)
  return (
    <section aria-label={`Top three for ${dayLong(date)}`} className="mb-4">
      <ul className="space-y-2">
        {shown.map(({ recipe, fit }) => (
          <MealPickCard
            key={recipe.id}
            recipe={recipe}
            fit={fit}
            mark={markFor(recipe)}
            onPick={() => onPick(recipe)}
          />
        ))}
      </ul>
      <div className="mt-2 flex flex-wrap gap-2">
        {pages > 1 && (
          <button
            type="button"
            onClick={() => setPage((p) => p + 1)}
            className="flex min-h-[44px] items-center gap-2 rounded-xl px-3 text-sm font-semibold text-ink-soft hover:bg-sand"
          >
            <RefreshCw className="size-4" />
            {(page + 1) % pages === 0 ? 'Back to the top three' : 'Something else'}
          </button>
        )}
        {pool.length > TOP && (
          <button
            type="button"
            onClick={() => setChoosing(true)}
            className="flex min-h-[44px] items-center gap-2 rounded-xl px-3 text-sm font-semibold text-ink-soft hover:bg-sand"
          >
            <Sparkles className="size-4" />
            Help me choose
          </button>
        )}
      </div>
    </section>
  )
}

function LibraryRow({
  recipe,
  context,
  clash,
  mark,
  onPick,
  draggable,
}: {
  recipe: RecipeSummary
  context: string
  clash: boolean
  mark: RowMark
  onPick: () => void
  draggable: boolean
}) {
  const { setNodeRef, listeners, isDragging } = useDraggable({
    id: `recipe:${recipe.id}`,
    data: { recipe },
    disabled: !draggable,
  })
  // dnd-kit swallows the click that ends a drag, but not once Escape has
  // cancelled it: releasing over the row would then pick it.
  const dragged = useRef(false)
  useEffect(() => {
    if (isDragging) dragged.current = true
  }, [isDragging])
  return (
    <li ref={setNodeRef} className={cn(isDragging && 'opacity-40')}>
      <button
        type="button"
        {...(draggable ? listeners : {})}
        aria-pressed={mark === 'added' ? true : undefined}
        disabled={mark === 'busy'}
        onPointerDown={() => {
          dragged.current = false
        }}
        onKeyDown={(e) => {
          // A drop leaves `dragged` set, since dnd-kit swallowed that click itself.
          if (e.key === 'Enter' || e.key === ' ') dragged.current = false
        }}
        onClick={() => {
          if (dragged.current) dragged.current = false
          else onPick()
        }}
        className={cn(
          'flex min-h-[64px] w-full items-center gap-3 rounded-xl px-2 py-1.5 text-left hover:bg-white',
          draggable && 'select-none',
          mark === 'added' && 'bg-[#fdf6e3] hover:bg-[#fdf6e3]',
        )}
      >
        <RecipeThumb src={recipe.image_url} title={recipe.title} className="size-12 shrink-0 rounded-lg" />
        <span className="min-w-0 flex-1">
          <span className="block font-medium leading-snug">{recipe.title}</span>
          <span className="flex flex-wrap items-center gap-x-2 text-sm text-ink-muted">
            {recipe.total_minutes != null && (
              <span className="flex items-center gap-1">
                <Clock className="size-3" />
                {formatMinutes(recipe.total_minutes)}
              </span>
            )}
            {recipe.rating != null && (
              <span className="flex items-center gap-0.5">
                <Star className="size-3 fill-current text-[#b7860b]" />
                {recipe.rating}
              </span>
            )}
            <span className={cn(clash && 'text-clash')}>{context}</span>
          </span>
        </span>
        {mark === 'busy' && <Loader2 className="size-5 shrink-0 animate-spin text-ink-muted" />}
        {mark === 'added' && (
          <span className="flex size-7 shrink-0 items-center justify-center rounded-full bg-primary">
            <Check className="size-4" strokeWidth={3} />
          </span>
        )}
        {mark === 'add' && <Plus className="size-5 shrink-0 text-ink-muted" />}
      </button>
    </li>
  )
}
