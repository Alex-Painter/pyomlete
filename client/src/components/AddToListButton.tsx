import { useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Check, ChevronDown, ListPlus, Loader2, Plus } from 'lucide-react'
import { BottomSheet } from '@/components/BottomSheet'
import { createList, useCurrentList } from '@/hooks/useAddToList'
import { useLists } from '@/lib/queries'
import { cn } from '@/lib/utils'

type ListRef = { id: string; name: string }

/**
 * The one "Add to list" control, used on Discover cards, recipe pages and
 * Create results. The main part adds to the current list straight away; the
 * chevron opens a picker for another list or a new one.
 *
 * Props mirror a SwiftUI view: `title` for the confirmation and an async
 * `onAdd(list)` that does the adding (a recipe and a suggestion add
 * differently) and shows its own Undo.
 */
export function AddToListButton({
  onAdd,
  disabled = false,
  size = 'default',
  className,
}: {
  onAdd: (list: ListRef) => Promise<void> | void
  disabled?: boolean
  size?: 'default' | 'sm'
  className?: string
}) {
  const queryClient = useQueryClient()
  const current = useCurrentList()
  const { data: lists } = useLists()
  const [pickerOpen, setPickerOpen] = useState(false)
  const [busy, setBusy] = useState(false)

  const run = async (list: ListRef | 'new') => {
    setBusy(true)
    try {
      const target =
        list === 'new'
          ? await createList().then((l) => {
              void queryClient.invalidateQueries({ queryKey: ['lists'] })
              return l
            })
          : list
      await onAdd(target)
    } finally {
      setBusy(false)
    }
  }

  const height = size === 'sm' ? 'min-h-[40px]' : 'min-h-[44px]'

  return (
    <>
      <div className={cn('inline-flex rounded-lg bg-primary text-ink shadow-sm', className)}>
        <button
          type="button"
          disabled={disabled || busy}
          onClick={() => void run(current ?? 'new')}
          className={cn(
            'flex min-w-0 flex-1 items-center justify-center gap-1.5 rounded-l-lg px-3 text-sm font-semibold hover:bg-black/5 disabled:opacity-50',
            height,
          )}
        >
          {busy ? (
            <Loader2 className="size-4 shrink-0 animate-spin" />
          ) : (
            <ListPlus className="size-4 shrink-0" />
          )}
          <span className="truncate">Add to list</span>
        </button>
        <button
          type="button"
          aria-label="Choose a list"
          disabled={disabled || busy}
          onClick={() => setPickerOpen(true)}
          className={cn(
            'flex shrink-0 items-center rounded-r-lg border-l border-black/10 px-2 hover:bg-black/5 disabled:opacity-50',
            height,
          )}
        >
          <ChevronDown className="size-4" />
        </button>
      </div>

      <BottomSheet open={pickerOpen} onOpenChange={setPickerOpen} title="Add to which list?">
        <div className="space-y-1">
          {lists?.map((l) => (
            <button
              key={l.id}
              type="button"
              onClick={() => {
                setPickerOpen(false)
                void run(l)
              }}
              className="flex min-h-[52px] w-full items-center gap-3 rounded-xl px-3 text-left hover:bg-sand"
            >
              <div className="min-w-0 flex-1">
                <p className="truncate font-medium">{l.name}</p>
                <p className="text-sm text-ink-muted">
                  {l.recipes.length} meal{l.recipes.length === 1 ? '' : 's'} · {l.item_count} item
                  {l.item_count === 1 ? '' : 's'}
                </p>
              </div>
              {current?.id === l.id && (
                <span className="flex items-center gap-1 text-sm text-ink-muted">
                  <Check className="size-4" /> Current
                </span>
              )}
            </button>
          ))}
          <button
            type="button"
            onClick={() => {
              setPickerOpen(false)
              void run('new')
            }}
            className="flex min-h-[52px] w-full items-center gap-3 rounded-xl px-3 text-left font-medium hover:bg-sand"
          >
            <Plus className="size-5 text-ink-muted" />
            New list
          </button>
        </div>
      </BottomSheet>
    </>
  )
}
