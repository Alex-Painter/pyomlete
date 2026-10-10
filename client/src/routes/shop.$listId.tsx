import { useMemo } from 'react'
import { createFileRoute, Link } from '@tanstack/react-router'
import { CloudOff, Loader2, PartyPopper, X } from 'lucide-react'
import { ErrorState } from '@/components/ErrorState'
import { ListRow } from '@/components/ListRow'
import { QuickAdd } from '@/components/QuickAdd'
import { useListActions } from '@/hooks/useListActions'
import { useOnline, usePendingCount } from '@/hooks/useOnline'
import { useWakeLock } from '@/hooks/useWakeLock'
import { useCategories, useList } from '@/lib/queries'
import type { ListItem } from '@/lib/types'

export const Route = createFileRoute('/shop/$listId')({ component: ShopPage })

/**
 * Shop: the list as you walk the aisles.
 *
 * Full screen, screen kept awake, items in your aisle order with big rows you
 * can tap anywhere. Only quick add stays, for something you spot. Works with
 * no signal: the list is the copy saved on the phone and checks sync when
 * you're back online. Leaving changes nothing; there's no "done shopping"
 * step, and anything left unchecked just stays on the list.
 */
function ShopPage() {
  const { listId } = Route.useParams()
  const { data: list, isLoading, error, refetch } = useList(listId)
  const { data: categories } = useCategories()
  const actions = useListActions(listId)
  const online = useOnline()
  const pending = usePendingCount(listId)
  useWakeLock()

  const categoryNames = useMemo(() => (categories ?? []).map((c) => c.name), [categories])

  if (isLoading) {
    return (
      <div className="flex min-h-screen justify-center bg-cream pt-24">
        <Loader2 className="size-6 animate-spin text-ink-muted" />
      </div>
    )
  }

  if (error || !list) {
    return (
      <main className="min-h-screen bg-cream px-4">
        <CloseLink listId={listId} />
        <ErrorState error={error} onRetry={() => void refetch()} notFoundMessage="This list has been deleted." />
      </main>
    )
  }

  const order = new Map(categoryNames.map((c, i) => [c, i]))
  const unchecked = list.items.filter((i) => !i.checked)
  const checked = list.items.filter((i) => i.checked)
  const aisles = new Map<string, ListItem[]>()
  for (const item of unchecked) {
    const cat = item.category || 'Other'
    if (!aisles.has(cat)) aisles.set(cat, [])
    aisles.get(cat)!.push(item)
  }
  const sortedAisles = [...aisles.entries()].sort(
    ([a], [b]) => (order.get(a) ?? 999) - (order.get(b) ?? 999),
  )

  return (
    <main className="min-h-screen bg-cream pb-[calc(6rem+env(safe-area-inset-bottom))] text-ink">
      <header className="sticky top-0 z-30 border-b border-line bg-cream/95 backdrop-blur safe-area-top">
        <div className="mx-auto flex max-w-2xl items-center gap-2 px-2 py-2">
          <CloseLink listId={listId} />
          <div className="min-w-0 flex-1">
            <h1 className="truncate text-xl font-bold">{list.name}</h1>
            <p className="text-sm text-ink-muted">
              {unchecked.length === 0 ? 'Nothing left to get' : `${unchecked.length} left to get`}
            </p>
          </div>
          {(!online || pending > 0) && (
            <span
              role="status"
              className="flex items-center gap-1.5 rounded-full bg-sand px-3 py-1.5 text-xs font-medium text-ink-soft"
            >
              <CloudOff className="size-3.5" />
              {online ? 'Syncing' : 'Offline, saved here'}
            </span>
          )}
        </div>
      </header>

      <div className="mx-auto max-w-2xl px-4 pt-4">
        <QuickAdd
          onAdd={(parsed) => actions.addItems(parsed, categoryNames)}
          placeholder="Spotted something? Add it"
          className="mb-5"
        />

        {unchecked.length === 0 && (
          <div className="flex flex-col items-center gap-2 py-10 text-center">
            <PartyPopper className="size-8 text-[#b7860b]" />
            <p className="font-medium">Everything's in the basket.</p>
          </div>
        )}

        <div className="space-y-5">
          {sortedAisles.map(([aisle, items]) => (
            <section key={aisle} aria-label={aisle}>
              <h2 className="mb-1.5 px-1 text-sm font-semibold uppercase tracking-wide text-ink-soft">
                {aisle}
              </h2>
              <div className="divide-y divide-line overflow-hidden rounded-2xl border border-line bg-white shadow-sm">
                {items.map((item) => (
                  <ListRow
                    key={item.id}
                    item={item}
                    size="large"
                    onToggle={() => actions.setChecked(item, true, true)}
                  />
                ))}
              </div>
            </section>
          ))}
        </div>

        {checked.length > 0 && (
          <section className="mt-8" aria-label="Got it">
            <h2 className="mb-1.5 px-1 text-sm font-semibold uppercase tracking-wide text-ink-soft">
              Got it ({checked.length})
            </h2>
            <div className="divide-y divide-line overflow-hidden rounded-2xl border border-line bg-white/70">
              {checked.map((item) => (
                <ListRow
                  key={item.id}
                  item={item}
                  size="large"
                  onToggle={() => actions.setChecked(item, false, true)}
                />
              ))}
            </div>
          </section>
        )}
      </div>
    </main>
  )
}

function CloseLink({ listId }: { listId: string }) {
  return (
    <Link
      to="/list/$listId"
      params={{ listId }}
      aria-label="Leave shopping mode"
      className="flex size-11 shrink-0 items-center justify-center rounded-full text-ink-soft hover:bg-sand hover:text-ink"
    >
      <X className="size-6" />
    </Link>
  )
}
