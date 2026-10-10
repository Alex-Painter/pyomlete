import { useState } from 'react'
import { createFileRoute } from '@tanstack/react-router'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { ArrowDown, ArrowUp, Check, GripVertical, Loader2, Pencil, Plus, Trash2, X } from 'lucide-react'
import {
  DndContext,
  KeyboardSensor,
  MouseSensor,
  TouchSensor,
  closestCenter,
  useSensor,
  useSensors,
} from '@dnd-kit/core'
import type { DragEndEvent } from '@dnd-kit/core'
import { restrictToVerticalAxis } from '@dnd-kit/modifiers'
import {
  SortableContext,
  arrayMove,
  sortableKeyboardCoordinates,
  useSortable,
  verticalListSortingStrategy,
} from '@dnd-kit/sortable'
import { CSS } from '@dnd-kit/utilities'
import { Button } from '@/components/ui/button'
import { ActionSheet } from '@/components/BottomSheet'
import { ErrorState } from '@/components/ErrorState'
import { apiJson } from '@/lib/api'
import { useCategories } from '@/lib/queries'
import type { CategoryConfig } from '@/lib/types'

export const Route = createFileRoute('/settings')({ component: SettingsPage })

function SettingsPage() {
  const queryClient = useQueryClient()
  const [newCategoryName, setNewCategoryName] = useState('')
  const [editingName, setEditingName] = useState<string | null>(null)
  const [editName, setEditName] = useState('')
  const [deleting, setDeleting] = useState<string | null>(null)

  const { data: sorted = [], isLoading, error, refetch } = useCategories()

  const updateCategories = useMutation({
    mutationFn: (cats: CategoryConfig[]) =>
      apiJson('/api/settings/categories', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ categories: cats }),
      }),
    onMutate: (cats) => {
      queryClient.setQueryData(['categories'], cats)
    },
    onSettled: () => void queryClient.invalidateQueries({ queryKey: ['categories'] }),
  })

  const save = (names: string[]) => updateCategories.mutate(names.map((name, order) => ({ name, order })))
  const names = sorted.map((c) => c.name)

  const handleAdd = () => {
    const name = newCategoryName.trim()
    if (!name || names.some((n) => n.toLowerCase() === name.toLowerCase())) return
    save([...names, name])
    setNewCategoryName('')
  }

  const move = (index: number, to: number) => {
    if (to < 0 || to >= names.length) return
    save(arrayMove(names, index, to))
  }

  const sensors = useSensors(
    useSensor(MouseSensor, { activationConstraint: { distance: 4 } }),
    useSensor(TouchSensor, { activationConstraint: { delay: 150, tolerance: 6 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  )

  const onDragEnd = ({ active, over }: DragEndEvent) => {
    if (!over || active.id === over.id) return
    move(names.indexOf(String(active.id)), names.indexOf(String(over.id)))
  }

  return (
    <main className="min-h-screen bg-cream text-ink">
      <div className="mx-auto max-w-5xl px-4 py-6 sm:px-6 sm:py-10">
        <h1 className="mb-6 pt-4 text-3xl font-bold tracking-tight sm:pt-0">Settings</h1>

        <section className="max-w-xl">
          <h2 className="mb-1 text-lg font-semibold">Aisles</h2>
          <p className="mb-4 text-sm text-ink-muted">
            Lists are grouped in this order. Put them in the order you walk your shop. Drag the
            handle or use the arrows.
          </p>

          {isLoading && <Loader2 className="mx-auto size-6 animate-spin text-ink-muted" />}
          {error && <ErrorState error={error} onRetry={() => void refetch()} />}

          <DndContext
            sensors={sensors}
            collisionDetection={closestCenter}
            modifiers={[restrictToVerticalAxis]}
            onDragEnd={onDragEnd}
          >
            <SortableContext items={names} strategy={verticalListSortingStrategy}>
              <ul className="mb-4 divide-y divide-line overflow-hidden rounded-2xl border border-line bg-white shadow-sm">
                {names.map((name, index) => (
                  <CategoryRow
                    key={name}
                    name={name}
                    first={index === 0}
                    last={index === names.length - 1}
                    editing={editingName === name}
                    editName={editName}
                    setEditName={setEditName}
                    onStartEdit={() => {
                      setEditingName(name)
                      setEditName(name)
                    }}
                    onCancelEdit={() => setEditingName(null)}
                    onRename={() => {
                      const next = editName.trim()
                      if (next) save(names.map((n) => (n === name ? next : n)))
                      setEditingName(null)
                    }}
                    onUp={() => move(index, index - 1)}
                    onDown={() => move(index, index + 1)}
                    onDelete={() => setDeleting(name)}
                  />
                ))}
              </ul>
            </SortableContext>
          </DndContext>

          <form
            onSubmit={(e) => {
              e.preventDefault()
              handleAdd()
            }}
            className="flex gap-2"
          >
            <input
              value={newCategoryName}
              onChange={(e) => setNewCategoryName(e.target.value)}
              placeholder="New aisle, e.g. World foods"
              aria-label="New aisle name"
              className="h-11 min-w-0 flex-1 rounded-xl border border-line bg-white px-3 text-base outline-none placeholder:text-ink-muted focus:ring-2 focus:ring-ring"
            />
            <Button type="submit" disabled={!newCategoryName.trim()} className="min-h-[44px]">
              <Plus className="size-4" />
              Add
            </Button>
          </form>
        </section>
      </div>

      <ActionSheet
        open={deleting != null}
        onOpenChange={(o) => !o && setDeleting(null)}
        title={`Delete "${deleting ?? ''}"?`}
        message="Items already in this aisle keep it until you move them."
        actions={[
          {
            label: 'Delete aisle',
            destructive: true,
            icon: <Trash2 className="size-5" />,
            onSelect: () => save(names.filter((n) => n !== deleting)),
          },
        ]}
      />
    </main>
  )
}

function CategoryRow({
  name,
  first,
  last,
  editing,
  editName,
  setEditName,
  onStartEdit,
  onCancelEdit,
  onRename,
  onUp,
  onDown,
  onDelete,
}: {
  name: string
  first: boolean
  last: boolean
  editing: boolean
  editName: string
  setEditName: (v: string) => void
  onStartEdit: () => void
  onCancelEdit: () => void
  onRename: () => void
  onUp: () => void
  onDown: () => void
  onDelete: () => void
}) {
  const { attributes, listeners, setNodeRef, setActivatorNodeRef, transform, transition, isDragging } =
    useSortable({ id: name })
  const icon = 'flex size-10 items-center justify-center rounded-lg text-ink-muted hover:bg-sand hover:text-ink disabled:opacity-30'

  return (
    <li
      ref={setNodeRef}
      style={{ transform: CSS.Translate.toString(transform), transition }}
      className={`flex min-h-[52px] items-center gap-1 bg-white px-2 ${isDragging ? 'relative z-10 shadow-lg' : ''}`}
    >
      <button
        type="button"
        ref={setActivatorNodeRef}
        aria-label={`Reorder ${name}`}
        className="flex size-10 cursor-grab touch-none items-center justify-center text-ink-muted active:cursor-grabbing"
        {...attributes}
        {...listeners}
      >
        <GripVertical className="size-5" />
      </button>

      {editing ? (
        <form
          className="flex flex-1 gap-1"
          onSubmit={(e) => {
            e.preventDefault()
            onRename()
          }}
        >
          <input
            value={editName}
            onChange={(e) => setEditName(e.target.value)}
            aria-label="Aisle name"
            autoFocus
            onKeyDown={(e) => e.key === 'Escape' && onCancelEdit()}
            className="h-10 min-w-0 flex-1 rounded-lg border border-line bg-cream px-2 text-base outline-none focus:ring-2 focus:ring-ring"
          />
          <button type="submit" aria-label="Save name" className={icon}>
            <Check className="size-4" />
          </button>
          <button type="button" aria-label="Cancel" onClick={onCancelEdit} className={icon}>
            <X className="size-4" />
          </button>
        </form>
      ) : (
        <>
          <span className="flex-1 text-base">{name}</span>
          <button type="button" aria-label={`Move ${name} up`} disabled={first} onClick={onUp} className={icon}>
            <ArrowUp className="size-4" />
          </button>
          <button type="button" aria-label={`Move ${name} down`} disabled={last} onClick={onDown} className={icon}>
            <ArrowDown className="size-4" />
          </button>
          <button type="button" aria-label={`Rename ${name}`} onClick={onStartEdit} className={icon}>
            <Pencil className="size-4" />
          </button>
          <button type="button" aria-label={`Delete ${name}`} onClick={onDelete} className={`${icon} hover:text-danger`}>
            <Trash2 className="size-4" />
          </button>
        </>
      )}
    </li>
  )
}
