import { Link } from '@tanstack/react-router'
import { ArrowLeftRight, CalendarClock, CalendarX, ChefHat, Clock, Moon, Star, X, Zap } from 'lucide-react'
import { CookedToggle } from '@/components/Cooked'
import { RecipeThumb } from '@/components/RecipeThumb'
import { formatMinutes } from '@/components/RecipeMetaRow'
import { QUICK_MINUTES } from '@/lib/libraryQuery'
import { isBusyEvening } from '@/lib/calendarDays'
import type { Evening } from '@/lib/calendarDays'
import { dayKind, dayLong, longDate } from '@/lib/week'
import { cn } from '@/lib/utils'
import type { PlanDay, RecipeSummary } from '@/lib/types'

const actionClass =
  'flex min-h-[44px] items-center justify-center gap-1.5 rounded-xl px-3 text-sm font-semibold'

/**
 * The selected evening: its meal with Cook, Swap and Remove, an empty slot,
 * or Out. A quick night ranks dinners over 30 minutes lower; it belongs to the
 * evening, so it stays when a meal goes on. Cooked is a tick the person sets (Finish in Cook sets it too), and
 * nothing else here changes when the meal is cooked.
 *
 * With a calendar connected, the card says what it shows for the evening, and
 * only suggests: an open evening you're busy on offers Out or Plan anyway, and
 * a part-busy one ranks quick dinners first without turning Quick night on.
 */
export function DayCard({
  day,
  recipe,
  listId,
  today,
  cooked,
  onCooked,
  onSwap,
  onRemove,
  onOut,
  onQuick,
  evening,
  planAnyway = false,
  onPlanAnyway,
}: {
  day: PlanDay
  recipe: RecipeSummary | undefined
  listId: string
  today: string
  cooked: boolean
  onCooked: (cooked: boolean) => void
  onSwap: () => void
  onRemove: () => void
  onOut: (out: boolean) => void
  onQuick: (quick: boolean) => void
  evening?: Evening
  /** Plan anyway was tapped on this busy evening. */
  planAnyway?: boolean
  onPlanAnyway?: () => void
}) {
  const kind = dayKind(day)
  const busy = isBusyEvening(evening) ? evening : undefined
  let calendarNote: string | null = null
  if (evening?.kind === 'quick' && kind !== 'out')
    calendarNote = `${evening.reason} on your calendar, so quick dinners come first`
  else if (busy && (kind === 'planned' || planAnyway)) calendarNote = `${busy.reason} on your calendar`
  return (
    <section aria-labelledby="day-heading" className="rounded-2xl border border-line bg-white p-3 shadow-sm">
      <div className="mb-3 flex items-baseline justify-between gap-3 px-1">
        <h2 id="day-heading" className="text-lg font-semibold">
          {dayLong(day.date)} <span className="font-normal text-ink-muted">{longDate(day.date)}</span>
        </h2>
        <div className="flex shrink-0 items-center gap-2">
          {day.date === today && <span className="text-sm font-medium text-ink-muted">Today</span>}
          {kind !== 'out' && (
            <button
              type="button"
              aria-pressed={!!day.quick}
              aria-label="Quick night"
              onClick={() => onQuick(!day.quick)}
              title={`Dinners over ${QUICK_MINUTES} minutes sink`}
              className={cn(
                'flex min-h-[44px] items-center gap-1 rounded-full border px-3 text-sm font-medium',
                day.quick ? 'border-ink bg-ink text-white' : 'border-line bg-white text-ink-soft hover:bg-sand',
              )}
            >
              <Zap className="size-3.5" />
              <span className="sm:hidden">Quick</span>
              <span className="hidden sm:inline">Quick night</span>
            </button>
          )}
        </div>
      </div>

      {calendarNote && (
        <p className="-mt-1 mb-3 flex items-center gap-1.5 px-1 text-sm text-ink-muted">
          <CalendarClock aria-hidden className="size-4 shrink-0" />
          {calendarNote}
        </p>
      )}

      {kind === 'planned' && day.recipe_id && (
        <>
          <div className="flex items-center gap-3">
            <RecipeThumb
              src={recipe?.image_url}
              title={recipe?.title ?? ''}
              className="size-16 shrink-0 rounded-xl"
            />
            <div className="min-w-0 flex-1">
              <Link
                to="/recipe/$recipeId"
                params={{ recipeId: day.recipe_id }}
                className="line-clamp-2 font-semibold leading-snug hover:underline underline-offset-4"
              >
                {recipe?.title ?? 'Meal'}
              </Link>
              <p className="mt-0.5 flex items-center gap-3 text-sm text-ink-muted">
                {recipe?.total_minutes != null && (
                  <span className="flex items-center gap-1">
                    <Clock className="size-3.5" />
                    {formatMinutes(recipe.total_minutes)}
                  </span>
                )}
                {recipe?.rating != null && (
                  <span className="flex items-center gap-1">
                    <Star className="size-3.5 fill-current text-[#b7860b]" />
                    {recipe.rating}
                  </span>
                )}
              </p>
            </div>
            <CookedToggle cooked={cooked} title={recipe?.title ?? 'Meal'} onChange={onCooked} />
          </div>
          <div className="mt-3 grid grid-cols-3 gap-2">
            <Link
              to="/cook/$recipeId"
              params={{ recipeId: day.recipe_id }}
              search={{ list: listId }}
              className={`${actionClass} bg-ink text-white hover:bg-ink/90`}
            >
              <ChefHat className="size-4" />
              Cook
            </Link>
            <button type="button" onClick={onSwap} className={`${actionClass} bg-cream hover:bg-sand`}>
              <ArrowLeftRight className="size-4" />
              Swap
            </button>
            <button
              type="button"
              onClick={onRemove}
              className={`${actionClass} bg-cream text-ink-soft hover:bg-sand hover:text-danger`}
            >
              <X className="size-4" />
              Remove
            </button>
          </div>
        </>
      )}

      {kind === 'open' && busy && !planAnyway && (
        <div className="rounded-xl border-2 border-dashed border-line p-3 sm:flex sm:items-center sm:gap-3">
          <p className="flex flex-1 items-center gap-3 px-1 text-sm">
            <CalendarX aria-hidden className="size-5 shrink-0 text-ink-muted" />
            <span>
              <span className="block font-medium text-ink-soft">{busy.reason}</span>
              <span className="text-ink-muted">From your calendar. Out this evening?</span>
            </span>
          </p>
          <div className="mt-3 grid grid-cols-2 gap-2 sm:mt-0 sm:flex">
            <button
              type="button"
              onClick={() => onOut(true)}
              className="flex min-h-[44px] items-center justify-center gap-1.5 rounded-xl bg-ink px-3 text-sm font-semibold text-white hover:bg-ink/90"
            >
              <Moon className="size-4" />
              Out
            </button>
            <button
              type="button"
              onClick={onPlanAnyway}
              className="min-h-[44px] rounded-xl bg-cream px-3 text-sm font-semibold hover:bg-sand"
            >
              Plan anyway
            </button>
          </div>
        </div>
      )}

      {kind === 'open' && (!busy || planAnyway) && (
        <div className="flex items-stretch gap-2">
          <p className="flex min-h-[64px] flex-1 flex-col justify-center rounded-xl border-2 border-dashed border-line px-4 text-sm">
            <span className="font-medium text-ink-soft">Nothing planned yet</span>
            <span className="text-ink-muted">Pick a meal below.</span>
          </p>
          <button
            type="button"
            onClick={() => onOut(true)}
            aria-label={`Out on ${dayLong(day.date)}`}
            className="flex min-h-[64px] min-w-[64px] flex-col items-center justify-center gap-1 rounded-xl bg-cream px-3 text-sm font-medium text-ink-soft hover:bg-sand"
          >
            <Moon className="size-4" />
            Out
          </button>
        </div>
      )}

      {kind === 'out' && (
        <div className="flex min-h-[64px] items-center gap-3 rounded-xl bg-cream px-4">
          <Moon className="size-5 shrink-0 text-ink-muted" />
          <p className="flex-1 text-sm">
            <span className="block font-medium text-ink-soft">Out this evening</span>
            <span className="text-ink-muted">No dinner to plan.</span>
          </p>
          <button
            type="button"
            onClick={() => onOut(false)}
            className="min-h-[44px] shrink-0 rounded-xl bg-white px-3 text-sm font-semibold shadow-sm hover:bg-sand"
          >
            Plan anyway
          </button>
        </div>
      )}
    </section>
  )
}
