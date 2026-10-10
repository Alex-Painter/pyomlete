import { useState } from 'react'
import { createFileRoute, Link, useNavigate } from '@tanstack/react-router'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { Copy, Loader2, MoreHorizontal, Pencil, Plus, ShoppingCart, Trash2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { ActionSheet } from '@/components/BottomSheet'
import { ErrorState } from '@/components/ErrorState'
import { PageHeader } from '@/components/PageHeader'
import { useUndo } from '@/components/UndoToast'
import { RenameListSheet } from '@/components/RenameListSheet'
import { createList } from '@/hooks/useAddToList'
import { apiFetch, apiJson } from '@/lib/api'
import { useLists } from '@/lib/queries'
import type { ListSummary } from '@/lib/types'

export const Route = createFileRoute('/')({ component: ListsPage })

function ListsPage() {
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const showUndo = useUndo()
  const { data: lists, isLoading, error, refetch } = useLists()
  const [actionsFor, setActionsFor] = useState<ListSummary | null>(null)
  const [renaming, setRenaming] = useState<ListSummary | null>(null)
  const [hidden, setHidden] = useState<Set<string>>(new Set())

  const newList = useMutation({
    mutationFn: createList,
    onSuccess: (data) => {
      void queryClient.invalidateQueries({ queryKey: ['lists'] })
      void navigate({ to: '/list/$listId', params: { listId: data.id } })
    },
  })

  const duplicateList = useMutation({
    mutationFn: (listId: string) =>
      apiJson<{ id: string }>(`/api/lists/${listId}/duplicate`, { method: 'POST' }),
    onSuccess: (data) => {
      void queryClient.invalidateQueries({ queryKey: ['lists'] })
      void navigate({ to: '/list/$listId', params: { listId: data.id } })
    },
  })

  const deleteList = (list: ListSummary) => {
    setHidden((h) => new Set(h).add(list.id))
    showUndo({
      message: `Deleted ${list.name}`,
      onUndo: () =>
        setHidden((h) => {
          const next = new Set(h)
          next.delete(list.id)
          return next
        }),
      onCommit: () =>
        void apiFetch(`/api/lists/${list.id}`, { method: 'DELETE', keepalive: true }).then(() =>
          queryClient.invalidateQueries({ queryKey: ['lists'] }),
        ),
    })
  }

  const visible = lists?.filter((l) => !hidden.has(l.id))

  return (
    <main className="min-h-screen bg-cream text-ink">
      <div className="mx-auto max-w-5xl px-4 py-6 sm:px-6 sm:py-10">
        <PageHeader
          title="Lists"
          subtitle="Pick meals, build the list, shop."
          actions={
            <Button
              onClick={() => newList.mutate()}
              disabled={newList.isPending}
              className="min-h-[44px] font-semibold"
            >
              {newList.isPending ? <Loader2 className="animate-spin" /> : <Plus className="size-4" />}
              New list
            </Button>
          }
        />

        {isLoading && (
          <div className="flex justify-center py-12">
            <Loader2 className="size-6 animate-spin text-ink-muted" />
          </div>
        )}

        {error && <ErrorState error={error} onRetry={() => void refetch()} />}

        {visible && visible.length === 0 && (
          <div className="py-16 text-center">
            <ShoppingCart className="mx-auto mb-4 size-12 text-ink-faint" />
            <p className="mb-1 font-medium text-ink-soft">No shopping lists yet</p>
            <p className="mb-5 text-sm text-ink-muted">
              Start one, add a few meals, and the ingredients collect themselves.
            </p>
            <Button onClick={() => newList.mutate()} disabled={newList.isPending} className="min-h-[44px]">
              <Plus className="size-4" />
              Start a list
            </Button>
          </div>
        )}

        {visible && visible.length > 0 && (
          <ul className="grid gap-3 sm:grid-cols-2">
            {visible.map((list) => (
              <li key={list.id} className="relative">
                <Link
                  to="/list/$listId"
                  params={{ listId: list.id }}
                  className="block rounded-2xl border border-line bg-white p-4 pr-14 shadow-sm transition-all hover:border-primary hover:shadow-md"
                >
                  <div className="mb-1 flex items-baseline justify-between gap-3">
                    <h2 className="truncate text-lg font-semibold">{list.name}</h2>
                  </div>
                  <p className="text-sm text-ink-muted">
                    {list.recipes.length} meal{list.recipes.length === 1 ? '' : 's'} ·{' '}
                    {list.item_count - list.checked_count} to get
                    {list.checked_count > 0 && ` · ${list.checked_count} got`}
                  </p>
                  {list.item_count > 0 && (
                    <div className="mt-3 h-1.5 w-full rounded-full bg-line">
                      <div
                        className="h-full rounded-full bg-primary transition-all"
                        style={{ width: `${(list.checked_count / list.item_count) * 100}%` }}
                      />
                    </div>
                  )}
                  {list.recipes.length > 0 && (
                    <p className="mt-3 line-clamp-2 text-sm text-ink-soft">
                      {list.recipes.map((r) => r.title).join(' · ')}
                    </p>
                  )}
                </Link>
                <button
                  type="button"
                  aria-label={`More for ${list.name}`}
                  onClick={() => setActionsFor(list)}
                  className="absolute right-2 top-2 flex size-11 items-center justify-center rounded-full text-ink-muted hover:bg-sand hover:text-ink"
                >
                  <MoreHorizontal className="size-5" />
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>

      <ActionSheet
        open={actionsFor != null}
        onOpenChange={(o) => !o && setActionsFor(null)}
        title={actionsFor?.name ?? ''}
        actions={
          actionsFor
            ? [
                {
                  label: 'Rename',
                  icon: <Pencil className="size-5 text-ink-muted" />,
                  onSelect: () => setRenaming(actionsFor),
                },
                {
                  label: 'Duplicate',
                  icon: <Copy className="size-5 text-ink-muted" />,
                  onSelect: () => duplicateList.mutate(actionsFor.id),
                },
                {
                  label: 'Delete list',
                  destructive: true,
                  icon: <Trash2 className="size-5" />,
                  onSelect: () => deleteList(actionsFor),
                },
              ]
            : []
        }
      />

      <RenameListSheet list={renaming} onClose={() => setRenaming(null)} />
    </main>
  )
}
