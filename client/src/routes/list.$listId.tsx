import { useEffect, useMemo, useState } from 'react'
import { createFileRoute, Link, useNavigate, useRouter } from '@tanstack/react-router'
import {
  ArrowLeft,
  ChefHat,
  ChevronDown,
  ChevronUp,
  ExternalLink,
  Loader2,
  Plus,
  ShoppingCart,
  Trash2,
  WifiOff,
  X,
} from 'lucide-react'
import {
  DndContext,
  MouseSensor,
  TouchSensor,
  closestCenter,
  useDroppable,
  useSensor,
  useSensors,
} from '@dnd-kit/core'
import type { DragEndEvent, DragStartEvent } from '@dnd-kit/core'
import { restrictToVerticalAxis } from '@dnd-kit/modifiers'
import { SortableContext, arrayMove, useSortable, verticalListSortingStrategy } from '@dnd-kit/sortable'
import { CSS } from '@dnd-kit/utilities'
import { ActionSheet } from '@/components/BottomSheet'
import { ErrorState } from '@/components/ErrorState'
import { ItemSheet } from '@/components/ItemSheet'
import { ListRow } from '@/components/ListRow'
import { MealsSheet } from '@/components/MealsSheet'
import { QuickAdd } from '@/components/QuickAdd'
import { RecipeThumb } from '@/components/RecipeThumb'
import { RenameListSheet } from '@/components/RenameListSheet'
import { useListActions } from '@/hooks/useListActions'
import { rememberCurrentList } from '@/hooks/useAddToList'
import { useOnline } from '@/hooks/useOnline'
import { useCategories, useList, useRecipes, useUnits } from '@/lib/queries'
import type { ListItem, RecipeSummary } from '@/lib/types'
import { cn } from '@/lib/utils'

type PlanSearch = {
  sheet?: 'meals' | 'rename'
  item?: string
}

export const Route = createFileRoute('/list/$listId')({
  component: PlanPage,
  // Open sheets live in the URL, so they survive a reload and can be linked
  // to, the way an iOS app restores its scenes.
  validateSearch: (search: Record<string, unknown>): PlanSearch => ({
    sheet: search.sheet === 'meals' || search.sheet === 'rename' ? search.sheet : undefined,
    item: typeof search.item === 'string' ? search.item : undefined,
  }),
})

/**
 * Plan: pick meals and build the list, on one screen.
 *
 * Meals and items are both always visible (a strip above the items on a
 * phone, two columns on desktop). Nothing here changes because something
 * else happened: adding a meal, checking items off or going shopping never
 * moves you to another mode. Shop and Cook are buttons you press.
 */
function PlanPage() {
  const { listId } = Route.useParams()
  const search = Route.useSearch()
  const navigate = useNavigate({ from: Route.fullPath })
  const router = useRouter()
  const online = useOnline()
  const { data: list, isLoading, error, refetch } = useList(listId)
  const { data: categories } = useCategories()
  const { data: recipes } = useRecipes()
  const { data: units } = useUnits()
  const actions = useListActions(listId)
  const [mealActions, setMealActions] = useState<RecipeSummary | null>(null)

  const setSearch = (next: PlanSearch) =>
    void navigate({ search: (prev) => ({ ...prev, ...next }), replace: true })

  useEffect(() => {
    rememberCurrentList(listId)
    // Load Shop ahead of time so it opens with no signal in the store.
    void router.preloadRoute({ to: '/shop/$listId', params: { listId } }).catch(() => {})
    if (import.meta.env.PROD && 'caches' in window) {
      void caches
        .open('omlete-pages-v1')
        .then((c) => c.add(`/shop/${listId}`))
        .catch(() => {})
    }
  }, [listId, router])

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
      <main className="mx-auto min-h-screen max-w-5xl bg-cream px-4">
        <BackLink />
        <ErrorState
          error={error}
          onRetry={() => void refetch()}
          notFoundMessage="This list has been deleted."
        />
      </main>
    )
  }

  const meals = list.recipes
    .map((id) => recipes?.find((r) => r.id === id))
    .filter((r): r is RecipeSummary => r != null)

  const unchecked = list.items.filter((i) => !i.checked)
  const checked = list.items.filter((i) => i.checked)
  const editingItem = search.item ? (list.items.find((i) => i.id === search.item) ?? null) : null

  const removeMeal = (r: RecipeSummary) => actions.removeRecipe(r.id, r.title)

  return (
    <main className="min-h-screen bg-cream text-ink">
      {/* Header */}
      <header className="sticky top-0 z-30 border-b border-line bg-cream/95 backdrop-blur safe-area-top sm:top-14">
        <div className="mx-auto flex max-w-5xl items-center gap-2 px-2 py-2 sm:px-6">
          <BackLink />
          <button
            type="button"
            onClick={() => setSearch({ sheet: 'rename' })}
            className="min-w-0 flex-1 truncate rounded-lg px-1 py-1 text-left text-xl font-bold hover:bg-sand"
            aria-label={`${list.name}, rename`}
          >
            {list.name}
          </button>
          <Link
            to="/shop/$listId"
            params={{ listId }}
            className="flex min-h-[44px] shrink-0 items-center gap-2 rounded-xl bg-ink px-4 text-sm font-semibold text-white shadow-sm hover:bg-ink/90"
          >
            <ShoppingCart className="size-4" />
            Start shopping
          </Link>
        </div>
        {!online && (
          <p className="flex items-center justify-center gap-2 bg-sand py-1.5 text-sm text-ink-soft">
            <WifiOff className="size-4" />
            Offline. Changes are saved on this phone and sync later.
          </p>
        )}
      </header>

      <div className="mx-auto max-w-5xl px-4 pb-10 sm:px-6 lg:grid lg:grid-cols-[minmax(0,340px)_minmax(0,1fr)] lg:gap-8">
        {/* Meals */}
        <MealsPanel
          meals={meals}
          onAdd={() => setSearch({ sheet: 'meals' })}
          onMealActions={setMealActions}
          onRemove={removeMeal}
          listId={listId}
        />

        {/* Items */}
        <section aria-labelledby="items-heading" className="pt-4 lg:pt-6">
          <div className="mb-3 flex items-baseline justify-between">
            <h2 id="items-heading" className="text-lg font-semibold">
              Items <span className="font-normal text-ink-muted">({unchecked.length})</span>
            </h2>
          </div>
          <QuickAdd onAdd={(parsed) => actions.addItems(parsed, categoryNames)} className="mb-4" />

          {list.items.length === 0 && (
            <p className="rounded-xl bg-white px-4 py-6 text-center text-ink-muted">
              Add meals and their ingredients appear here, or type items above. Paste a whole
              list if you have one.
            </p>
          )}

          <ItemsByCategory
            items={unchecked}
            categories={categoryNames}
            onToggle={(item) => actions.setChecked(item, !item.checked)}
            onEdit={(item) => setSearch({ item: item.id })}
            onDelete={(item) => actions.removeItems([item], `Removed ${item.name}`)}
            onMove={(item, category) => actions.update(item.id, { category })}
            onReorder={actions.reorder}
          />

          {checked.length > 0 && (
            <GotItSection
              items={checked}
              onToggle={(item) => actions.setChecked(item, false)}
              onClear={() =>
                actions.removeItems(
                  checked,
                  `Cleared ${checked.length} checked item${checked.length === 1 ? '' : 's'}`,
                )
              }
            />
          )}
        </section>
      </div>

      <MealsSheet
        open={search.sheet === 'meals'}
        onOpenChange={(o) => setSearch({ sheet: o ? 'meals' : undefined })}
        listId={listId}
        listName={list.name}
        onList={new Set(list.recipes)}
        onRemove={removeMeal}
      />

      <ItemSheet
        item={editingItem}
        open={editingItem != null}
        onOpenChange={(o) => !o && setSearch({ item: undefined })}
        categories={categoryNames}
        units={units ?? []}
        onSave={(updates) => editingItem && actions.update(editingItem.id, updates)}
        onDelete={() =>
          editingItem && actions.removeItems([editingItem], `Removed ${editingItem.name}`)
        }
      />

      <RenameListSheet
        list={search.sheet === 'rename' ? list : null}
        onClose={() => setSearch({ sheet: undefined })}
      />

      <ActionSheet
        open={mealActions != null}
        onOpenChange={(o) => !o && setMealActions(null)}
        title={mealActions?.title ?? ''}
        actions={
          mealActions
            ? [
                {
                  label: 'Cook this',
                  icon: <ChefHat className="size-5 text-ink-muted" />,
                  onSelect: () =>
                    void navigate({
                      to: '/cook/$recipeId',
                      params: { recipeId: mealActions.id },
                      search: { list: listId },
                    }),
                },
                {
                  label: 'Open recipe',
                  icon: <ExternalLink className="size-5 text-ink-muted" />,
                  onSelect: () =>
                    void navigate({ to: '/recipe/$recipeId', params: { recipeId: mealActions.id } }),
                },
                {
                  label: 'Remove from list',
                  destructive: true,
                  icon: <Trash2 className="size-5" />,
                  onSelect: () => removeMeal(mealActions),
                },
              ]
            : []
        }
      />
    </main>
  )
}

function BackLink() {
  return (
    <Link
      to="/"
      aria-label="Back to lists"
      className="flex size-11 shrink-0 items-center justify-center rounded-full text-ink-soft hover:bg-sand hover:text-ink"
    >
      <ArrowLeft className="size-5" />
    </Link>
  )
}

function MealsPanel({
  meals,
  onAdd,
  onMealActions,
  onRemove,
  listId,
}: {
  meals: RecipeSummary[]
  onAdd: () => void
  onMealActions: (r: RecipeSummary) => void
  onRemove: (r: RecipeSummary) => void
  listId: string
}) {
  return (
    <section aria-labelledby="meals-heading" className="pt-4 lg:pt-6">
      <div className="mb-3 flex items-center justify-between">
        <h2 id="meals-heading" className="text-lg font-semibold">
          Meals <span className="font-normal text-ink-muted">({meals.length})</span>
        </h2>
        <button
          type="button"
          onClick={onAdd}
          className="flex min-h-[40px] items-center gap-1.5 rounded-lg px-3 text-sm font-semibold text-ink hover:bg-sand"
        >
          <Plus className="size-4" />
          Add meals
        </button>
      </div>

      {meals.length === 0 ? (
        <button
          type="button"
          onClick={onAdd}
          className="flex min-h-[64px] w-full items-center justify-center gap-2 rounded-2xl border-2 border-dashed border-line px-4 text-sm text-ink-muted hover:border-primary hover:text-ink"
        >
          <Plus className="size-4" />
          Pick this week's meals
        </button>
      ) : (
        <>
          {/* Phone: a compact strip */}
          <ul className="no-scrollbar -mx-4 flex snap-x scroll-px-4 gap-2 overflow-x-auto px-4 pb-1 lg:hidden">
            {meals.map((r) => (
              <li key={r.id} className="shrink-0 snap-start">
                <button
                  type="button"
                  onClick={() => onMealActions(r)}
                  className="flex h-14 max-w-[15rem] items-center gap-2 rounded-xl border border-line bg-white pr-3 text-left shadow-sm"
                >
                  <RecipeThumb src={r.image_url} title={r.title} className="h-full w-14 shrink-0 rounded-l-xl" />
                  <span className="line-clamp-2 text-sm font-medium leading-tight">{r.title}</span>
                </button>
              </li>
            ))}
          </ul>

          {/* Desktop: a column of meal cards */}
          <ul className="hidden space-y-2 lg:block">
            {meals.map((r) => (
              <li
                key={r.id}
                className="flex items-center gap-3 rounded-xl border border-line bg-white p-2 shadow-sm"
              >
                <RecipeThumb src={r.image_url} title={r.title} className="size-14 shrink-0 rounded-lg" />
                <div className="min-w-0 flex-1">
                  <Link
                    to="/recipe/$recipeId"
                    params={{ recipeId: r.id }}
                    className="block font-medium leading-snug hover:underline underline-offset-4"
                  >
                    {r.title}
                  </Link>
                  <p className="text-sm text-ink-muted">{r.ingredient_count} ingredients</p>
                </div>
                <Link
                  to="/cook/$recipeId"
                  params={{ recipeId: r.id }}
                  search={{ list: listId }}
                  className="flex min-h-[40px] items-center gap-1.5 rounded-lg px-2.5 text-sm font-medium text-ink-soft hover:bg-sand hover:text-ink"
                >
                  <ChefHat className="size-4" />
                  Cook
                </Link>
                <button
                  type="button"
                  aria-label={`Remove ${r.title}`}
                  onClick={() => onRemove(r)}
                  className="flex size-10 items-center justify-center rounded-lg text-ink-muted hover:bg-sand hover:text-danger"
                >
                  <X className="size-4" />
                </button>
              </li>
            ))}
          </ul>
        </>
      )}
    </section>
  )
}

function ItemsByCategory({
  items,
  categories,
  onToggle,
  onEdit,
  onDelete,
  onMove,
  onReorder,
}: {
  items: ListItem[]
  categories: string[]
  onToggle: (item: ListItem) => void
  onEdit: (item: ListItem) => void
  onDelete: (item: ListItem) => void
  onMove: (item: ListItem, category: string) => void
  onReorder: (category: string, ids: string[]) => void
}) {
  const [activeId, setActiveId] = useState<string | null>(null)
  const order = new Map(categories.map((c, i) => [c, i]))
  const groups = new Map<string, ListItem[]>()
  for (const item of items) {
    const cat = item.category || 'Other'
    if (!groups.has(cat)) groups.set(cat, [])
    groups.get(cat)!.push(item)
  }
  const sorted = [...groups.entries()].sort(
    ([a], [b]) => (order.get(a) ?? 999) - (order.get(b) ?? 999),
  )
  const byId = new Map(items.map((i) => [i.id, i]))

  // A mouse drags after moving a few pixels. A finger drags after a short
  // hold, so swipes and scrolling stay free; a hold released without moving
  // is a long-press, which opens the edit sheet.
  const sensors = useSensors(
    useSensor(MouseSensor, { activationConstraint: { distance: 6 } }),
    useSensor(TouchSensor, { activationConstraint: { delay: 380, tolerance: 8 } }),
  )

  const onDragStart = (e: DragStartEvent) => {
    setActiveId(String(e.active.id))
    if ('vibrate' in navigator) navigator.vibrate(10)
  }

  const onDragEnd = ({ active, over, delta }: DragEndEvent) => {
    setActiveId(null)
    const item = byId.get(String(active.id))
    if (!item) return
    if (Math.abs(delta.x) < 8 && Math.abs(delta.y) < 8) {
      onEdit(item)
      return
    }
    if (!over) return
    const overId = String(over.id)
    const target = overId.startsWith('cat:') ? overId.slice(4) : byId.get(overId)?.category
    if (!target) return
    if (target !== item.category) {
      onMove(item, target)
      return
    }
    const ids = (groups.get(target) ?? []).map((i) => i.id)
    const from = ids.indexOf(item.id)
    const to = ids.indexOf(overId)
    if (from !== -1 && to !== -1 && from !== to) onReorder(target, arrayMove(ids, from, to))
  }

  return (
    <DndContext
      sensors={sensors}
      collisionDetection={closestCenter}
      modifiers={[restrictToVerticalAxis]}
      onDragStart={onDragStart}
      onDragEnd={onDragEnd}
      onDragCancel={() => setActiveId(null)}
    >
      <div className="space-y-4">
        {sorted.map(([category, catItems]) => (
          <CategoryGroup key={category} category={category} highlight={activeId != null}>
            <SortableContext items={catItems.map((i) => i.id)} strategy={verticalListSortingStrategy}>
              <div className="divide-y divide-line overflow-hidden rounded-2xl border border-line bg-white shadow-sm">
                {catItems.map((item) => (
                  <SortableRow
                    key={item.id}
                    item={item}
                    onToggle={() => onToggle(item)}
                    onEdit={() => onEdit(item)}
                    onDelete={() => onDelete(item)}
                  />
                ))}
              </div>
            </SortableContext>
          </CategoryGroup>
        ))}
      </div>
    </DndContext>
  )
}

function CategoryGroup({
  category,
  highlight,
  children,
}: {
  category: string
  highlight: boolean
  children: React.ReactNode
}) {
  // The header is a drop target: drag an item onto it to re-file it.
  const { setNodeRef, isOver } = useDroppable({ id: `cat:${category}` })
  return (
    <section>
      <h3
        ref={setNodeRef}
        className={cn(
          'mb-1.5 rounded-lg px-1 py-1 text-sm font-semibold text-ink-soft transition-colors',
          highlight && 'border border-dashed border-line',
          isOver && 'border-primary bg-[#fdf6e3]',
        )}
      >
        {category}
      </h3>
      {children}
    </section>
  )
}

function SortableRow({
  item,
  onToggle,
  onEdit,
  onDelete,
}: {
  item: ListItem
  onToggle: () => void
  onEdit: () => void
  onDelete: () => void
}) {
  const { listeners, setNodeRef, transform, transition, isDragging } = useSortable({
    id: item.id,
  })
  return (
    <ListRow
      item={item}
      rowRef={setNodeRef}
      style={{ transform: CSS.Translate.toString(transform), transition }}
      gestureHandlers={listeners as never}
      dragging={isDragging}
      onToggle={onToggle}
      onEdit={onEdit}
      onDelete={onDelete}
    />
  )
}

function GotItSection({
  items,
  onToggle,
  onClear,
}: {
  items: ListItem[]
  onToggle: (item: ListItem) => void
  onClear: () => void
}) {
  const [open, setOpen] = useState(true)
  return (
    <section className="mt-6">
      <div className="mb-1.5 flex items-center justify-between">
        <button
          type="button"
          onClick={() => setOpen(!open)}
          aria-expanded={open}
          className="flex min-h-[40px] items-center gap-1.5 px-1 text-sm font-semibold text-ink-soft"
        >
          Got it ({items.length})
          {open ? <ChevronUp className="size-4" /> : <ChevronDown className="size-4" />}
        </button>
        <button
          type="button"
          onClick={onClear}
          className="min-h-[40px] rounded-lg px-3 text-sm font-medium text-ink-muted hover:bg-sand hover:text-ink"
        >
          Clear checked
        </button>
      </div>
      {open && (
        <div className="divide-y divide-line overflow-hidden rounded-2xl border border-line bg-white/70">
          {items.map((item) => (
            <ListRow key={item.id} item={item} onToggle={() => onToggle(item)} />
          ))}
        </div>
      )}
    </section>
  )
}
