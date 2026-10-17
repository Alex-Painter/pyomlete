import { useEffect, useMemo, useReducer, useRef } from 'react'
import type { Ref } from 'react'
import { Link } from '@tanstack/react-router'
import { useDraggable } from '@dnd-kit/core'
import { Check, Clock, Loader2, Plus, Search, Star } from 'lucide-react'
import { RecipeThumb } from '@/components/RecipeThumb'
import { formatMinutes } from '@/components/RecipeMetaRow'
import {
  FILTERS,
  SORTS,
  contextLine,
  initialLibraryQuery,
  libraryReducer,
  queryLibrary,
  withWeekHistory,
} from '@/lib/libraryQuery'
import type { LibrarySort } from '@/lib/libraryQuery'
import type { ISODate, PlanDay, RecipeSummary } from '@/lib/types'
import { cn } from '@/lib/utils'

/** How a row ends: what a tap will do, or that it's already done. */
export type RowMark = 'add' | 'added' | 'busy'

/**
 * The meal library, inline on Plan rather than in a sheet. On a week list it
 * picks the selected day's dinner; on a plain list it adds meals. Rows can be
 * dragged onto a day column on desktop.
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
}) {
  const [query, dispatch] = useReducer(libraryReducer, initialLibraryQuery)
  const rows = useMemo(
    () => queryLibrary(withWeekHistory(recipes ?? [], days), query, today),
    [recipes, days, query, today],
  )

  return (
    <section id={id} aria-labelledby={`${id}-heading`} className="scroll-mt-48 pt-5">
      <h2 id={`${id}-heading`} className="mb-3 text-lg font-semibold">
        {heading}
      </h2>

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
            const sort = SORTS.find((s) => s.id === e.target.value)
            if (sort) dispatch({ kind: 'sort', sort: sort.id satisfies LibrarySort })
          }}
          className="h-11 max-w-[42%] shrink-0 rounded-xl border border-line bg-white px-2 text-sm font-medium outline-none focus:ring-2 focus:ring-ring"
        >
          {SORTS.map((s) => (
            <option key={s.id} value={s.id}>
              {s.label}
            </option>
          ))}
        </select>
      </div>

      <div role="group" aria-label="Filters" className="no-scrollbar -mx-4 mb-3 flex gap-2 overflow-x-auto px-4">
        {FILTERS.map((f) => {
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
            context={contextLine(r, today)}
            mark={markFor(r)}
            onPick={() => onPick(r)}
            draggable={draggable}
          />
        ))}
      </ul>
    </section>
  )
}

function LibraryRow({
  recipe,
  context,
  mark,
  onPick,
  draggable,
}: {
  recipe: RecipeSummary
  context: string
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
            <span>{context}</span>
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
