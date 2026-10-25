import { useNavigate } from '@tanstack/react-router'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { CalendarHeart, Loader2, Sparkles } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { RecipeThumb } from '@/components/RecipeThumb'
import { useUndo } from '@/components/UndoToast'
import { ApiError, apiFetch, apiJson } from '@/lib/api'
import { undoChange } from '@/lib/chef'
import { useWeekPlan } from '@/lib/queries'
import type { WeekPlan } from '@/lib/types'
import { cn } from '@/lib/utils'
import { dayShort, longDate } from '@/lib/week'

/**
 * Chef's week: five dinners on one card, three of yours and two new ideas.
 * Nothing changes until Make the list, which applies at once with Undo and
 * never navigates on its own. Not this week hides the card and teaches Chef
 * nothing. With `offerToPlan`, and no week waiting, it offers to plan one.
 */
export function WeekCard({
  offerToPlan = false,
  className,
}: {
  offerToPlan?: boolean
  className?: string
}) {
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const showUndo = useUndo()
  const { data: week } = useWeekPlan()

  const plan = useMutation({
    mutationFn: () =>
      apiJson<WeekPlan>('/api/weeks/plan', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({}),
      }),
    onSuccess: (planned) => queryClient.setQueryData(['week'], planned),
    onError: () =>
      showUndo({
        message: "Chef couldn't plan a week right now. Try again in a bit.",
      }),
  })

  const make = useMutation({
    mutationFn: (w: WeekPlan) =>
      apiJson<{ list_id: string; name: string; undo: string }>(
        `/api/weeks/${w.id}/make`,
        {
          method: 'POST',
        },
      ),
    onSuccess: (made) => {
      queryClient.setQueryData(['week'], null)
      void queryClient.invalidateQueries({ queryKey: ['lists'] })
      showUndo({
        message: `Made ${made.name}. New ideas join it as they're ready.`,
        duration: 8000,
        action: {
          label: 'Open',
          onSelect: () =>
            void navigate({
              to: '/list/$listId',
              params: { listId: made.list_id },
            }),
        },
        onUndo: () =>
          void undoChange(made.undo)
            .catch((err: unknown) =>
              showUndo({
                message:
                  err instanceof ApiError && err.status === 409
                    ? 'That list has changed since, so it was kept.'
                    : "Couldn't undo that. Try again.",
              }),
            )
            .finally(() => void queryClient.invalidateQueries()),
      })
    },
    onError: () => {
      showUndo({ message: "Couldn't make the list. Try again." })
      void queryClient.invalidateQueries({ queryKey: ['week'] })
    },
  })

  const skip = (w: WeekPlan) => {
    queryClient.setQueryData(['week'], null)
    showUndo({
      message: 'Skipped this week',
      onUndo: () => queryClient.setQueryData(['week'], w),
      onCommit: () =>
        void apiFetch(`/api/weeks/${w.id}/skip`, {
          method: 'POST',
          keepalive: true,
        }),
    })
  }

  if (!week) {
    if (!offerToPlan) return null
    return (
      <section
        className={cn(
          'mb-6 flex flex-wrap items-center gap-3 rounded-2xl border border-dashed border-line px-4 py-4',
          className,
        )}
      >
        <CalendarHeart className="size-6 shrink-0 text-ink-faint" />
        <p className="min-w-0 flex-1 text-sm text-ink-muted">
          {plan.isPending
            ? 'Chef is planning your week. This takes a minute.'
            : 'Let Chef plan five dinners for this week: three you love and two new ones.'}
        </p>
        <Button
          variant="outline"
          onClick={() => plan.mutate()}
          disabled={plan.isPending}
          className="min-h-[44px]"
        >
          {plan.isPending ? (
            <Loader2 className="animate-spin" />
          ) : (
            <Sparkles className="size-4" />
          )}
          Plan my week
        </Button>
      </section>
    )
  }

  return (
    <section
      aria-labelledby="your-week"
      className={cn(
        'mb-6 overflow-hidden rounded-2xl border border-line bg-white shadow-sm',
        className,
      )}
    >
      <div className="px-4 pt-4 pb-3">
        <h2
          id="your-week"
          className="flex items-center gap-2 text-lg font-semibold"
        >
          <Sparkles className="size-4 text-[#7a5a12]" />
          Your week from {longDate(week.week_of)}
        </h2>
        <p className="mt-1 text-sm text-ink-muted">{week.note}</p>
      </div>
      <ul className="divide-y divide-line border-y border-line">
        {week.meals.map((m) => (
          <li key={m.day} className="flex items-center gap-3 px-4 py-2">
            <span className="w-9 shrink-0 text-sm font-semibold text-ink-soft">
              {dayShort(m.day)}
            </span>
            <RecipeThumb
              src={m.image_url}
              title={m.title}
              className="size-11 shrink-0 rounded-lg"
            />
            <span className="min-w-0 flex-1">
              <span className="flex items-center gap-2">
                <span className="line-clamp-1 font-medium">{m.title}</span>
                {m.is_new && (
                  <span className="shrink-0 rounded-full bg-sand px-2 py-0.5 text-xs font-medium text-ink-soft">
                    New
                  </span>
                )}
              </span>
              <span className="line-clamp-1 text-sm text-ink-muted">
                {m.reason}
              </span>
            </span>
          </li>
        ))}
      </ul>
      <div className="flex flex-wrap justify-end gap-2 px-4 py-3">
        <Button
          variant="ghost"
          className="min-h-[44px]"
          onClick={() => skip(week)}
          disabled={make.isPending}
        >
          Not this week
        </Button>
        <Button
          className="min-h-[44px] font-semibold"
          onClick={() => make.mutate(week)}
          disabled={make.isPending}
        >
          {make.isPending && <Loader2 className="animate-spin" />}
          Make the list
        </Button>
      </div>
    </section>
  )
}
