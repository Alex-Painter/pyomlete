import { useEffect, useMemo, useReducer, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { createFileRoute, Link, useNavigate, useRouter } from '@tanstack/react-router'
import {
  ArrowLeft,
  CalendarPlus,
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
  DragOverlay,
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
import { BackLink } from '@/components/BackLink'
import type { SheetAction } from '@/components/BottomSheet'
import { DayCard } from '@/components/DayCard'
import { DayLibrary } from '@/components/DayLibrary'
import type { RowMark } from '@/components/DayLibrary'
import { ErrorState } from '@/components/ErrorState'
import { ItemSheet } from '@/components/ItemSheet'
import { ListRow } from '@/components/ListRow'
import { QuickAdd } from '@/components/QuickAdd'
import { RecipeThumb } from '@/components/RecipeThumb'
import { RenameListSheet } from '@/components/RenameListSheet'
import { WeekStrip } from '@/components/WeekStrip'
import { useListActions } from '@/hooks/useListActions'
import { rememberCurrentList } from '@/hooks/useAddToList'
import { useOnline } from '@/hooks/useOnline'
import { useCategories, useList, useRecipes, useUnits } from '@/lib/queries'
import { dayLong, defaultDay, nextOpenDay, todayISO } from '@/lib/week'
import type { ISODate, ListDetail, ListItem, PlanDay, RecipeSummary } from '@/lib/types'
import { cn } from '@/lib/utils'

type PlanSearch = {
  sheet?: 'rename'
  item?: string
}

export const Route = createFileRoute('/list/$listId')({
  component: PlanPage,
  // Open sheets live in the URL, so they survive a reload and can be linked
  // to, the way an iOS app restores its scenes.
  validateSearch: (search: Record<string, unknown>): PlanSearch => ({
    sheet: search.sheet === 'rename' ? search.sheet : undefined,
    item: typeof search.item === 'string' ? search.item : undefined,
  }),
})

type PlanView = 'week' | 'list'

/** Everything Plan shows that isn't the list itself. */
type PlanState = {
  view: PlanView
  /**
   * null until the week loads, then today or the first day to plan, held so
   * that planning or marking days Out doesn't move it.
   */
  selected: ISODate | null
}

type PlanAction =
  | { kind: 'show'; view: PlanView }
  | { kind: 'select'; date: ISODate }
  /** A meal went on `date`: move on to the next evening still to plan. */
  | { kind: 'planned'; date: ISODate; days: PlanDay[] }

function planReducer(state: PlanState, action: PlanAction): PlanState {
  switch (action.kind) {
    case 'show':
      return { ...state, view: action.view }
    case 'select':
      return { ...state, selected: action.date }
    case 'planned':
      return { ...state, selected: nextOpenDay(action.days, action.date) }
  }
}

/**
 * Plan: decide the week's dinners and build the list, on one screen.
 *
 * A week list opens on its seven evenings, with the meal library inline under
 * the selected day, so a dinner is one tap. List shows the items. A plain
 * list (no week) keeps meals and items side by side. Nothing here changes
 * because something else happened: cooking a meal, checking items off or
 * going shopping never moves a meal or moves you to another mode.
 */
function PlanPage() {
  const { listId } = Route.useParams()
  const search = Route.useSearch()
  const navigate = useNavigate({ from: Route.fullPath })
  const router = useRouter()
  const online = useOnline()
  const { data: list, isLoading, error, refetch } = useList(listId)
  const { data: categories } = useCategories()
  const { data: recipes, isLoading: recipesLoading } = useRecipes()
  const { data: units } = useUnits()
  const actions = useListActions(listId)
  const [state, dispatch] = useReducer(planReducer, { view: 'week', selected: null })
  const [today] = useState(todayISO)
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

  const firstDay =
    list && list.week_start != null && list.days.length > 0 ? defaultDay(list.days, today) : null
  useEffect(() => {
    if (state.selected == null && firstDay) dispatch({ kind: 'select', date: firstDay })
  }, [state.selected, firstDay])

  const categoryNames = useMemo(() => (categories ?? []).map((c) => c.name), [categories])
  const recipesById = useMemo(() => new Map((recipes ?? []).map((r) => [r.id, r])), [recipes])

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
        <BackButton />
        <ErrorState
          error={error}
          onRetry={() => void refetch()}
          notFoundMessage="This list has been deleted."
        />
      </main>
    )
  }

  const days = list.days
  const isWeek = list.week_start != null && days.length > 0
  const selectedDay = isWeek
    ? days.find((d) => d.date === (state.selected ?? firstDay)) ?? days[0]
    : null

  const meals = list.recipes
    .map((id) => recipesById.get(id))
    .filter((r): r is RecipeSummary => r != null)

  const editingItem = search.item ? (list.items.find((i) => i.id === search.item) ?? null) : null

  const removeMeal = (r: RecipeSummary) => actions.removeRecipe(r.id, r.title)

  const planOn = (day: PlanDay, r: RecipeSummary) => {
    if (day.recipe_id === r.id) return actions.clearDay(day, r.title)
    actions.setDay({ date: day.date, recipeId: r.id })
    dispatch({ kind: 'planned', date: day.date, days })
  }

  const items = (
    <ItemsSection
      list={list}
      categoryNames={categoryNames}
      actions={actions}
      onEdit={(item) => setSearch({ item: item.id })}
    />
  )

  const sheetActions: SheetAction[] = mealActions
    ? [
        ...(selectedDay
          ? [
              {
                label: `Plan for ${dayLong(selectedDay.date)}`,
                icon: <CalendarPlus className="size-5 text-ink-muted" />,
                onSelect: () => planOn(selectedDay, mealActions),
              },
            ]
          : []),
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

  return (
    <main className="min-h-screen bg-cream text-ink">
      {/* Header */}
      <header className="sticky top-0 z-30 border-b border-line bg-cream/95 backdrop-blur safe-area-top sm:top-14">
        <div
          className={cn(
            'mx-auto flex max-w-5xl items-center gap-2 px-2 py-2 sm:px-6',
            isWeek && 'lg:max-w-6xl',
          )}
        >
          <BackButton />
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
        {selectedDay && (
          <div className="mx-auto max-w-5xl space-y-2 px-4 pb-2 sm:px-6 lg:hidden">
            <ViewSwitch view={state.view} onChange={(view) => dispatch({ kind: 'show', view })} />
            {state.view === 'week' && (
              <WeekStrip
                variant="strip"
                days={days}
                selected={selectedDay.date}
                today={today}
                recipes={recipesById}
                onSelect={(date) => dispatch({ kind: 'select', date })}
              />
            )}
          </div>
        )}
        {!online && (
          <p className="flex items-center justify-center gap-2 bg-sand py-1.5 text-sm text-ink-soft">
            <WifiOff className="size-4" />
            Offline. Changes are saved on this phone and sync later.
          </p>
        )}
      </header>

      {selectedDay ? (
        <WeekPlan
          list={list}
          day={selectedDay}
          today={today}
          view={state.view}
          recipes={recipes}
          recipesLoading={recipesLoading}
          recipesById={recipesById}
          actions={actions}
          onSelect={(date) => dispatch({ kind: 'select', date })}
          onPick={(r) => planOn(selectedDay, r)}
          onMealActions={setMealActions}
          items={items}
        />
      ) : (
        <PlainPlan
          listId={listId}
          meals={meals}
          recipes={recipes}
          recipesLoading={recipesLoading}
          today={today}
          actions={actions}
          onMealActions={setMealActions}
          items={items}
        />
      )}

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
        actions={sheetActions}
      />
    </main>
  )
}

type ListActions = ReturnType<typeof useListActions>

function ViewSwitch({ view, onChange }: { view: PlanView; onChange: (view: PlanView) => void }) {
  const options: { id: PlanView; label: string }[] = [
    { id: 'week', label: 'Week' },
    { id: 'list', label: 'List' },
  ]
  return (
    <div role="group" aria-label="Show" className="grid grid-cols-2 gap-1 rounded-xl bg-mist p-1">
      {options.map((o) => (
        <button
          key={o.id}
          type="button"
          aria-pressed={view === o.id}
          onClick={() => onChange(o.id)}
          className={cn(
            'min-h-[44px] rounded-lg text-sm font-semibold text-ink-muted transition-colors',
            view === o.id && 'bg-white text-ink shadow-sm',
          )}
        >
          {o.label}
        </button>
      ))}
    </div>
  )
}

/**
 * A week list: the selected day and its library on the left (or the whole
 * screen on a phone), the shopping list on the right from 1024px. On a
 * phone, Week and List swap the two.
 */
function WeekPlan({
  list,
  day,
  today,
  view,
  recipes,
  recipesLoading,
  recipesById,
  actions,
  onSelect,
  onPick,
  onMealActions,
  items,
}: {
  list: ListDetail
  day: PlanDay
  today: ISODate
  view: PlanView
  recipes: RecipeSummary[] | undefined
  recipesLoading: boolean
  recipesById: Map<string, RecipeSummary>
  actions: ListActions
  onSelect: (date: ISODate) => void
  onPick: (r: RecipeSummary) => void
  onMealActions: (r: RecipeSummary) => void
  items: ReactNode
}) {
  const searchRef = useRef<HTMLInputElement>(null)
  const [dragging, setDragging] = useState<RecipeSummary | null>(null)
  // Mouse only: on a phone a held finger scrolls the library.
  const sensors = useSensors(useSensor(MouseSensor, { activationConstraint: { distance: 6 } }))

  const recipe = day.recipe_id ? recipesById.get(day.recipe_id) : undefined
  const planned = new Set(list.days.map((d) => d.recipe_id))
  const anyDay = list.recipes
    .filter((id) => !planned.has(id))
    .map((id) => recipesById.get(id))
    .filter((r): r is RecipeSummary => r != null)

  const swap = () => {
    searchRef.current?.focus({ preventScroll: true })
    document.getElementById('day-library')?.scrollIntoView({ behavior: 'smooth', block: 'start' })
  }

  const onDragStart = ({ active }: DragStartEvent) => {
    setDragging(recipesById.get(String(active.id).replace(/^recipe:/, '')) ?? null)
  }

  const onDragEnd = ({ active, over }: DragEndEvent) => {
    setDragging(null)
    const overId = over ? String(over.id) : ''
    const recipeId = String(active.id).replace(/^recipe:/, '')
    if (!overId.startsWith('day:')) return
    actions.setDay({ date: overId.slice(4), recipeId })
  }

  const markFor = (r: RecipeSummary): RowMark => (r.id === day.recipe_id ? 'added' : 'add')

  return (
    <DndContext
      sensors={sensors}
      onDragStart={onDragStart}
      onDragEnd={onDragEnd}
      onDragCancel={() => setDragging(null)}
    >
      <div className="mx-auto max-w-5xl px-4 pb-10 sm:px-6 lg:grid lg:max-w-6xl lg:grid-cols-[minmax(0,1fr)_340px] lg:items-start lg:gap-8">
        <div className={cn(view === 'week' ? 'block' : 'hidden', 'lg:block')}>
          {/* Pinned, so a meal deep in the library can still be dragged onto a day. */}
          <div className="sticky top-[7.3rem] z-20 hidden bg-cream pb-2 pt-6 lg:block">
            <WeekStrip
              variant="columns"
              days={list.days}
              selected={day.date}
              today={today}
              recipes={recipesById}
              onSelect={onSelect}
            />
          </div>

          <AnyDayRow meals={anyDay} onOpen={onMealActions} />

          <div className="pt-4">
            <DayCard
              day={day}
              recipe={recipe}
              listId={list.id}
              today={today}
              onSwap={swap}
              onRemove={() => actions.clearDay(day, recipe?.title ?? 'the meal')}
              onOut={(out) => actions.markOut(day, out)}
            />
          </div>

          <DayLibrary
            id="day-library"
            heading={`Pick for ${dayLong(day.date)}`}
            recipes={recipes}
            isLoading={recipesLoading}
            days={list.days}
            today={today}
            markFor={markFor}
            onPick={onPick}
            draggable
            searchRef={searchRef}
          />
        </div>

        <aside
          aria-label="Shopping list"
          className={cn(
            view === 'list' ? 'block' : 'hidden',
            'lg:sticky lg:top-36 lg:block lg:max-h-[calc(100vh-10rem)] lg:overflow-y-auto lg:pr-1',
          )}
        >
          {items}
        </aside>
      </div>

      <DragOverlay dropAnimation={null}>
        {dragging && (
          <div className="flex w-64 items-center gap-2 rounded-xl border border-primary bg-white p-2 shadow-lg">
            <RecipeThumb
              src={dragging.image_url}
              title={dragging.title}
              className="size-10 shrink-0 rounded-lg"
            />
            <span className="line-clamp-2 text-sm font-medium">{dragging.title}</span>
          </div>
        )}
      </DragOverlay>
    </DndContext>
  )
}

/** Meals on the week with no day yet. They're on the list all the same. */
function AnyDayRow({
  meals,
  onOpen,
}: {
  meals: RecipeSummary[]
  onOpen: (r: RecipeSummary) => void
}) {
  if (meals.length === 0) return null
  return (
    <section aria-labelledby="any-day-heading" className="pt-4">
      <h2 id="any-day-heading" className="mb-2 text-sm font-semibold text-ink-soft">
        This week, any day
      </h2>
      <ul className="no-scrollbar -mx-4 flex snap-x scroll-px-4 gap-2 overflow-x-auto px-4 pb-1 sm:mx-0 sm:flex-wrap sm:px-0">
        {meals.map((r) => (
          <li key={r.id} className="shrink-0 snap-start">
            <MealChip recipe={r} onClick={() => onOpen(r)} />
          </li>
        ))}
      </ul>
    </section>
  )
}

function MealChip({ recipe, onClick }: { recipe: RecipeSummary; onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="flex h-14 max-w-[15rem] items-center gap-2 rounded-xl border border-line bg-white pr-3 text-left shadow-sm"
    >
      <RecipeThumb src={recipe.image_url} title={recipe.title} className="h-full w-14 shrink-0 rounded-l-xl" />
      <span className="line-clamp-2 text-sm font-medium leading-tight">{recipe.title}</span>
    </button>
  )
}

/**
 * A plain list: its meals and the library to add more on the left, items on
 * the right from 1024px. On a phone the library comes after the items, and
 * Add meals jumps to it.
 */
function PlainPlan({
  listId,
  meals,
  recipes,
  recipesLoading,
  today,
  actions,
  onMealActions,
  items,
}: {
  listId: string
  meals: RecipeSummary[]
  recipes: RecipeSummary[] | undefined
  recipesLoading: boolean
  today: ISODate
  actions: ListActions
  onMealActions: (r: RecipeSummary) => void
  items: ReactNode
}) {
  const searchRef = useRef<HTMLInputElement>(null)
  const [adding, setAdding] = useState<ReadonlySet<string>>(new Set())
  const onList = new Set(meals.map((m) => m.id))

  const showLibrary = () => {
    searchRef.current?.focus({ preventScroll: true })
    document.getElementById('meal-library')?.scrollIntoView({ behavior: 'smooth', block: 'start' })
  }

  const add = async (r: RecipeSummary) => {
    setAdding((s) => new Set(s).add(r.id))
    await actions.addRecipe(r.id, r.title)
    setAdding((s) => {
      const next = new Set(s)
      next.delete(r.id)
      return next
    })
  }

  const markFor = (r: RecipeSummary): RowMark =>
    adding.has(r.id) ? 'busy' : onList.has(r.id) ? 'added' : 'add'

  return (
    <div className="mx-auto max-w-5xl px-4 pb-10 sm:px-6 lg:grid lg:grid-cols-[minmax(0,340px)_minmax(0,1fr)] lg:grid-rows-[auto_1fr] lg:gap-x-8">
      <div className="lg:col-start-1 lg:row-start-1">
        <MealsPanel
          meals={meals}
          onAdd={showLibrary}
          onMealActions={onMealActions}
          onRemove={(r) => actions.removeRecipe(r.id, r.title)}
          listId={listId}
        />
      </div>
      <div className="lg:col-start-2 lg:row-span-2 lg:row-start-1">{items}</div>
      <div className="lg:col-start-1 lg:row-start-2">
        <DayLibrary
          id="meal-library"
          heading="Add meals"
          recipes={recipes}
          isLoading={recipesLoading}
          days={[]}
          today={today}
          markFor={markFor}
          onPick={(r) =>
            onList.has(r.id) ? actions.removeRecipe(r.id, r.title) : void add(r)
          }
          draggable={false}
          searchRef={searchRef}
        />
      </div>
    </div>
  )
}

function ItemsSection({
  list,
  categoryNames,
  actions,
  onEdit,
}: {
  list: ListDetail
  categoryNames: string[]
  actions: ListActions
  onEdit: (item: ListItem) => void
}) {
  const unchecked = list.items.filter((i) => !i.checked)
  const checked = list.items.filter((i) => i.checked)
  return (
    <section aria-labelledby="items-heading" className="pt-4 lg:pt-6">
      <div className="mb-3 flex items-baseline justify-between">
        <h2 id="items-heading" className="text-lg font-semibold">
          Items <span className="font-normal text-ink-muted">({unchecked.length})</span>
        </h2>
      </div>
      <QuickAdd onAdd={(parsed) => actions.addItems(parsed, categoryNames)} className="mb-4" />

      {list.items.length === 0 && (
        <p className="rounded-xl bg-white px-4 py-6 text-center text-ink-muted">
          Add meals and their ingredients appear here, or type items above. Paste a whole list if
          you have one.
        </p>
      )}

      <ItemsByCategory
        items={unchecked}
        categories={categoryNames}
        onToggle={(item) => actions.setChecked(item, !item.checked)}
        onEdit={onEdit}
        onDelete={(item) => actions.removeItems([item], `Removed ${item.name}`)}
        onMove={(item, category) => actions.update(item.id, { category })}
        onReorder={actions.reorder}
      />

      {checked.length > 0 && (
        <GotItSection
          items={checked}
          onToggle={(item) => actions.setChecked(item, false)}
          onEdit={onEdit}
          onClear={() =>
            actions.removeItems(
              checked,
              `Cleared ${checked.length} checked item${checked.length === 1 ? '' : 's'}`,
            )
          }
        />
      )}
    </section>
  )
}

function BackButton() {
  return (
    <BackLink
      to="/"
      aria-label="Back"
      className="flex size-11 shrink-0 items-center justify-center rounded-full text-ink-soft hover:bg-sand hover:text-ink"
    >
      <ArrowLeft className="size-5" />
    </BackLink>
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
          Add meals from your recipes
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
  onEdit,
  onClear,
}: {
  items: ListItem[]
  onToggle: (item: ListItem) => void
  onEdit: (item: ListItem) => void
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
            <ListRow
              key={item.id}
              item={item}
              onToggle={() => onToggle(item)}
              onEdit={() => onEdit(item)}
            />
          ))}
        </div>
      )}
    </section>
  )
}
