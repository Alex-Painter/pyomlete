import { useDroppable } from '@dnd-kit/core'
import { Moon } from 'lucide-react'
import { RecipeThumb } from '@/components/RecipeThumb'
import { dayKind, dayLong, dayOfMonth, dayShort, longDate } from '@/lib/week'
import type { DayKind } from '@/lib/week'
import type { ISODate, PlanDay, RecipeSummary } from '@/lib/types'
import { cn } from '@/lib/utils'

type StripProps = {
  days: PlanDay[]
  selected: ISODate
  today: ISODate
  recipes: Map<string, RecipeSummary>
  onSelect: (date: ISODate) => void
}

function describe(day: PlanDay, recipe: RecipeSummary | undefined, today: ISODate): string {
  const when = `${day.date === today ? 'Today, ' : ''}${dayLong(day.date)} ${longDate(day.date)}`
  const what: Record<DayKind, string> = {
    planned: recipe?.title ?? 'meal planned',
    open: 'nothing planned',
    out: 'out',
  }
  return `${when}, ${what[dayKind(day)]}`
}

/**
 * The week at a glance: one button per evening. On a phone it's a compact
 * strip pinned under the header; at 1024px and wider the same days become
 * columns showing each meal, and a meal dragged onto a column plans it.
 */
export function WeekStrip({
  variant,
  ...props
}: StripProps & { variant: 'strip' | 'columns' }) {
  if (variant === 'columns') {
    return (
      <ol aria-label="This week" className="grid grid-cols-7 gap-2">
        {props.days.map((day) => (
          <li key={day.date}>
            <DayColumn day={day} {...props} />
          </li>
        ))}
      </ol>
    )
  }
  const { days, selected, today, recipes, onSelect } = props
  return (
    <ol aria-label="This week" className="grid grid-cols-7 gap-1">
      {days.map((day) => {
        const isSelected = day.date === selected
        return (
          <li key={day.date}>
            <button
              type="button"
              aria-pressed={isSelected}
              aria-label={describe(day, recipes.get(day.recipe_id ?? ''), today)}
              onClick={() => onSelect(day.date)}
              className={cn(
                'flex min-h-[60px] w-full flex-col items-center justify-center gap-0.5 rounded-xl border-2 border-transparent py-1 transition-colors hover:bg-sand',
                isSelected && 'border-primary bg-white shadow-sm hover:bg-white',
              )}
            >
              <span
                className={cn(
                  'text-[11px] leading-none text-ink-muted',
                  day.date === today && 'font-bold text-ink',
                )}
              >
                {day.date === today ? 'Today' : dayShort(day.date)}
              </span>
              <span className="text-base font-semibold leading-tight">{dayOfMonth(day.date)}</span>
              <DayIndicator kind={dayKind(day)} />
            </button>
          </li>
        )
      })}
    </ol>
  )
}

function DayIndicator({ kind }: { kind: DayKind }) {
  switch (kind) {
    case 'planned':
      return <span aria-hidden className="size-2 rounded-full bg-[#b7860b]" />
    case 'open':
      return <span aria-hidden className="size-2 rounded-full border border-ink-muted" />
    case 'out':
      return <Moon aria-hidden className="size-3 text-ink-muted" />
  }
}

function DayColumn({ day, selected, today, recipes, onSelect }: StripProps & { day: PlanDay }) {
  const { setNodeRef, isOver } = useDroppable({ id: `day:${day.date}`, data: { date: day.date } })
  const kind = dayKind(day)
  const recipe = day.recipe_id ? recipes.get(day.recipe_id) : undefined
  const isSelected = day.date === selected
  return (
    <button
      ref={setNodeRef}
      type="button"
      aria-pressed={isSelected}
      aria-label={describe(day, recipe, today)}
      onClick={() => onSelect(day.date)}
      className={cn(
        'flex h-full min-h-[150px] w-full flex-col overflow-hidden rounded-2xl border-2 border-line bg-white text-left shadow-sm transition-colors hover:border-ink-faint',
        isSelected && 'border-primary hover:border-primary',
        isOver && 'border-primary bg-[#fdf6e3]',
      )}
    >
      <span className="flex items-baseline justify-between gap-1 px-2 pb-1 pt-2">
        <span className={cn('text-xs text-ink-muted', day.date === today && 'font-bold text-ink')}>
          {day.date === today ? 'Today' : dayShort(day.date)}
        </span>
        <span className="text-base font-semibold">{dayOfMonth(day.date)}</span>
      </span>
      {kind === 'planned' && (
        <>
          <RecipeThumb
            src={recipe?.image_url}
            title={recipe?.title ?? ''}
            className="aspect-[4/3] w-full"
          />
          <span className="line-clamp-3 px-2 py-1.5 text-xs font-medium leading-snug">
            {recipe?.title ?? 'Meal'}
          </span>
        </>
      )}
      {kind === 'open' && (
        <span className="mx-2 mb-2 flex flex-1 items-center justify-center rounded-xl border border-dashed border-line text-xs text-ink-muted">
          Open
        </span>
      )}
      {kind === 'out' && (
        <span className="mx-2 mb-2 flex flex-1 flex-col items-center justify-center gap-1 rounded-xl bg-cream text-xs text-ink-muted">
          <Moon aria-hidden className="size-4" />
          Out
        </span>
      )}
    </button>
  )
}
