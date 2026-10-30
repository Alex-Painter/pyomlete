import { useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { AlertCircle, Loader2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useUndo } from '@/components/UndoToast'
import { apiFetch, apiJson } from '@/lib/api'
import { useWeekIdeas } from '@/lib/queries'
import type { WeekIdea } from '@/lib/types'
import { cn } from '@/lib/utils'
import { dayLong } from '@/lib/week'

/**
 * The new ideas from Chef's week that haven't reached their list yet. Make
 * the list has gone by the time one saves, so a failure is shown here, with
 * Try again and Skip, rather than leaving an evening quietly empty. With
 * `listId`, only that list's ideas.
 */
export function WeekIdeas({
  listId,
  className,
}: {
  listId?: string
  className?: string
}) {
  const queryClient = useQueryClient()
  const showUndo = useUndo()
  const { data } = useWeekIdeas()
  const [skipped, setSkipped] = useState<Set<string>>(new Set())

  const ideas = data?.filter(
    (i) => (!listId || i.list_id === listId) && !skipped.has(i.id),
  )
  if (!ideas?.length) return null

  const patch = (id: string, fn: (i: WeekIdea) => WeekIdea) =>
    queryClient.setQueryData<WeekIdea[]>(['week-ideas'], (old) =>
      old?.map((i) => (i.id === id ? fn(i) : i)),
    )

  const retry = (idea: WeekIdea) => {
    patch(idea.id, (i) => ({ ...i, status: 'saving' }))
    void apiJson(`/api/suggestions/${idea.id}/save`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ list_id: idea.list_id }),
    })
      .catch(() =>
        showUndo({
          message: `Couldn't start saving ${idea.title}. Try again.`,
        }),
      )
      .finally(
        () => void queryClient.invalidateQueries({ queryKey: ['week-ideas'] }),
      )
  }

  const skip = (idea: WeekIdea) => {
    setSkipped((s) => new Set(s).add(idea.id))
    showUndo({
      message: `Skipped ${idea.title}`,
      onUndo: () =>
        setSkipped((s) => {
          const next = new Set(s)
          next.delete(idea.id)
          return next
        }),
      // Cleared, not dismissed: a failed save says nothing about their taste.
      onCommit: () =>
        void apiFetch(`/api/suggestions/${idea.id}`, {
          method: 'PATCH',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ status: 'cleared' }),
          keepalive: true,
        }).then(() =>
          queryClient.invalidateQueries({ queryKey: ['week-ideas'] }),
        ),
    })
  }

  return (
    <section
      aria-label="New ideas for the week"
      className={cn('space-y-2', className)}
    >
      {ideas.map((idea) => {
        const when = idea.day ? ` for ${dayLong(idea.day)}` : ''
        return idea.status === 'saving' ? (
          <p
            key={idea.id}
            className="flex items-center gap-3 rounded-2xl border border-line bg-white px-4 py-3 text-sm text-ink-muted"
          >
            <Loader2 className="size-4 shrink-0 animate-spin" />
            <span className="min-w-0 flex-1">
              Saving <span className="font-medium text-ink">{idea.title}</span>
              {when}. It joins the list when it's ready.
            </span>
          </p>
        ) : (
          <div
            key={idea.id}
            role="alert"
            className="flex flex-wrap items-center gap-x-3 gap-y-2 rounded-2xl border border-line bg-white px-4 py-3 text-sm"
          >
            <AlertCircle className="size-4 shrink-0 text-ink-muted" />
            <span className="min-w-48 flex-1">
              Chef couldn't save{' '}
              <span className="font-medium">{idea.title}</span>
              {when}.
            </span>
            <span className="ml-auto flex gap-2">
              <Button
                variant="ghost"
                className="min-h-[44px]"
                onClick={() => skip(idea)}
              >
                Skip
              </Button>
              <Button
                variant="outline"
                className="min-h-[44px]"
                onClick={() => retry(idea)}
              >
                Try again
              </Button>
            </span>
          </div>
        )
      })}
    </section>
  )
}
