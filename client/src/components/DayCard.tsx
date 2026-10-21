import { Link } from '@tanstack/react-router'
import { ArrowLeftRight, ChefHat, Clock, Moon, Star, X } from 'lucide-react'
import { CookedToggle } from '@/components/Cooked'
import { RecipeThumb } from '@/components/RecipeThumb'
import { formatMinutes } from '@/components/RecipeMetaRow'
import { dayKind, dayLong, longDate } from '@/lib/week'
import type { PlanDay, RecipeSummary } from '@/lib/types'

const actionClass =
  'flex min-h-[44px] items-center justify-center gap-1.5 rounded-xl px-3 text-sm font-semibold'

/**
 * The selected evening: its meal with Cook, Swap and Remove, an empty slot,
 * or Out. Cooked is a tick the person sets (Finish in Cook sets it too), and
 * nothing else here changes when the meal is cooked.
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
}) {
  const kind = dayKind(day)
  return (
    <section aria-labelledby="day-heading" className="rounded-2xl border border-line bg-white p-3 shadow-sm">
      <div className="mb-3 flex items-baseline justify-between gap-3 px-1">
        <h2 id="day-heading" className="text-lg font-semibold">
          {dayLong(day.date)} <span className="font-normal text-ink-muted">{longDate(day.date)}</span>
        </h2>
        {day.date === today && <span className="text-sm font-medium text-ink-muted">Today</span>}
      </div>

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

      {kind === 'open' && (
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
