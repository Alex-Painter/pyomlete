import { Check, Clock, Plus } from 'lucide-react'
import { RecipeThumb } from '@/components/RecipeThumb'
import { formatMinutes } from '@/components/RecipeMetaRow'
import type { RowMark } from '@/components/DayLibrary'
import type { Fit } from '@/lib/fitScore'
import type { RecipeSummary } from '@/lib/types'
import { cn } from '@/lib/utils'

/** A meal offered for the evening with its reason: the top three, and Narrow it down's finalists. */
export function MealPickCard({
  recipe,
  fit,
  mark,
  onPick,
}: {
  recipe: RecipeSummary
  fit: Fit
  mark: RowMark
  onPick: () => void
}) {
  return (
    <li>
      <button
        type="button"
        onClick={onPick}
        disabled={mark === 'busy'}
        aria-pressed={mark === 'added' ? true : undefined}
        className="flex min-h-[72px] w-full items-center gap-3 rounded-2xl border border-line bg-white p-2 text-left shadow-sm hover:bg-sand"
      >
        <RecipeThumb
          src={recipe.image_url}
          title={recipe.title}
          className="size-14 shrink-0 rounded-xl"
        />
        <span className="min-w-0 flex-1">
          <span className="block font-semibold leading-snug">
            {recipe.title}
          </span>
          {fit.reason && (
            <span
              className={cn(
                'block text-sm',
                fit.clash ? 'text-clash' : 'text-ink-soft',
              )}
            >
              {fit.reason}
            </span>
          )}
          {recipe.total_minutes != null && (
            <span className="flex items-center gap-1 text-sm text-ink-muted">
              <Clock className="size-3" />
              {formatMinutes(recipe.total_minutes)}
            </span>
          )}
        </span>
        {mark === 'added' ? (
          <span className="flex size-7 shrink-0 items-center justify-center rounded-full bg-primary">
            <Check className="size-4" strokeWidth={3} />
          </span>
        ) : (
          <Plus className="size-5 shrink-0 text-ink-muted" />
        )}
      </button>
    </li>
  )
}
