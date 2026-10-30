import { useEffect, useState } from 'react'
import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ArrowDown, ArrowUp, CalendarDays, Check, ChefHat, GripVertical, Loader2, Pencil, Plus, Trash2, X } from 'lucide-react'
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
import { useChef } from '@/components/Chef'
import { ErrorState } from '@/components/ErrorState'
import { useUndo } from '@/components/UndoToast'
import { ApiError, apiJson } from '@/lib/api'
import { useCalendar, useCategories, usePlanSettings, usePreferences, useWeeklyPlanSettings } from '@/lib/queries'
import type { CalendarStatus, CategoryConfig, PlanSettings, Preference, Stance, WeeklyPlanSettings } from '@/lib/types'

type CalendarResult = 'connected' | 'failed' | 'cancelled'

export const Route = createFileRoute('/settings')({
  component: SettingsPage,
  // Google sends you back here with how connecting the calendar went.
  validateSearch: (search: Record<string, unknown>): { calendar?: CalendarResult } => ({
    calendar: ['connected', 'failed', 'cancelled'].includes(search.calendar as string)
      ? (search.calendar as CalendarResult)
      : undefined,
  }),
})

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
      <div className="mx-auto max-w-5xl px-4 pt-3 pb-6 sm:px-6 sm:py-10">
        <h1 className="safe-area-top mb-5 text-3xl font-bold tracking-tight sm:mb-6">Settings</h1>

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

        <PlanningTheWeek />
        <Calendar />
      <WeeklyPlan />
        <WhatChefKnows />
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

const STANCE_LABEL: Record<Stance, string> = {
  never: 'Never',
  avoid: 'Avoid',
  less: 'Less',
  more: 'More',
  prefer: 'Likes',
}

const WEEKDAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday']

const selectClass =
  'min-h-[44px] rounded-xl border border-line bg-white px-3 text-base disabled:opacity-50'

/**
 * The shop day a week starts on, and how long a base (pasta, rice...) stays
 * off the menu once it's been had, which ranks each evening's meals on Plan.
 */
function PlanningTheWeek() {
  const queryClient = useQueryClient()
  const showUndo = useUndo()
  const { data, isPlaceholderData } = usePlanSettings()

  const update = useMutation({
    mutationFn: (next: PlanSettings) =>
      apiJson<PlanSettings>('/api/settings/plan', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(next),
      }),
    onMutate: (next) => queryClient.setQueryData(['settings', 'plan'], next),
    onError: () => showUndo({ message: "Couldn't save that. Try again." }),
    onSettled: () => void queryClient.invalidateQueries({ queryKey: ['settings', 'plan'] }),
  })

  if (!data || isPlaceholderData) return null
  const set = (change: Partial<PlanSettings>) => update.mutate({ ...data, ...change })
  const until = WEEKDAYS[(data.variety_days + 1) % 7]

  return (
    <section className="mt-10 max-w-xl">
      <h2 className="mb-1 text-lg font-semibold">Planning the week</h2>
      <p className="mb-4 text-sm text-ink-muted">
        A week runs from one shop to the next. Each evening's meals are ranked so the week stays
        varied.
      </p>
      <div className="space-y-3 rounded-2xl border border-line bg-white p-4 shadow-sm">
        <label className="flex min-h-[44px] items-center justify-between gap-3">
          <span className="font-medium">Week starts on</span>
          <select
            className={selectClass}
            value={data.week_start_weekday}
            onChange={(e) => set({ week_start_weekday: Number(e.target.value) })}
          >
            {WEEKDAYS.map((d, i) => (
              <option key={d} value={i}>
                {d}
              </option>
            ))}
          </select>
        </label>
        <label className="flex min-h-[44px] items-center justify-between gap-3">
          <span className="font-medium">Same base again after</span>
          <select
            className={selectClass}
            value={data.variety_days}
            onChange={(e) => set({ variety_days: Number(e.target.value) })}
          >
            {Array.from({ length: 7 }, (_, i) => i + 1).map((n) => (
              <option key={n} value={n}>
                {n === 1 ? '1 day' : `${n} days`}
              </option>
            ))}
          </select>
        </label>
        <p className="text-sm text-ink-muted">
          Pasta on Monday ranks pasta lower until {until}.
        </p>
      </div>
    </section>
  )
}

/**
 * When Chef plans the coming week on its own. The plan waits on Home as a card
 * until you make the list, so this only chooses when the card turns up.
 */
function WeeklyPlan() {
  const queryClient = useQueryClient()
  const showUndo = useUndo()
  const { data } = useWeeklyPlanSettings()

  const update = useMutation({
    mutationFn: (next: WeeklyPlanSettings) =>
      apiJson<WeeklyPlanSettings>('/api/settings/weekly-plan', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(next),
      }),
    onMutate: (next) => queryClient.setQueryData(['settings', 'weekly-plan'], next),
    onError: () => showUndo({ message: "Couldn't save that. Try again." }),
    onSettled: () => void queryClient.invalidateQueries({ queryKey: ['settings', 'weekly-plan'] }),
  })

  if (!data) return null
  const set = (change: Partial<WeeklyPlanSettings>) => update.mutate({ ...data, ...change })

  return (
    <section className="mt-10 max-w-xl">
      <h2 className="mb-1 text-lg font-semibold">Chef's weekly plan</h2>
      <p className="mb-4 text-sm text-ink-muted">
        Chef plans five dinners for your coming week and leaves them on Home. Nothing goes on a
        list until you make it.
      </p>
      <div className="rounded-2xl border border-line bg-white p-4 shadow-sm">
        <label className="flex min-h-[44px] items-center justify-between gap-3">
          <span className="font-medium">Plan my week</span>
          <input
            type="checkbox"
            role="switch"
            className="size-5 accent-[#7a5a12]"
            checked={data.weekly_plan}
            onChange={(e) => set({ weekly_plan: e.target.checked })}
          />
        </label>
        <div className="mt-3 flex flex-wrap items-center gap-2 text-sm text-ink-muted">
          <span>Every</span>
          <select
            aria-label="Day"
            className={selectClass}
            value={data.weekly_plan_weekday}
            disabled={!data.weekly_plan}
            onChange={(e) => set({ weekly_plan_weekday: Number(e.target.value) })}
          >
            {WEEKDAYS.map((d, i) => (
              <option key={d} value={i}>
                {d}
              </option>
            ))}
          </select>
          <span>at</span>
          <select
            aria-label="Time"
            className={selectClass}
            value={data.weekly_plan_hour}
            disabled={!data.weekly_plan}
            onChange={(e) => set({ weekly_plan_hour: Number(e.target.value) })}
          >
            {Array.from({ length: 24 }, (_, h) => (
              <option key={h} value={h}>
                {String(h).padStart(2, '0')}:00
              </option>
            ))}
          </select>
          <span>UK time</span>
        </div>
      </div>
    </section>
  )
}

/**
 * What Chef goes by when it suggests and plans: what you told it, then what it
 * noticed, each with what it's based on. Forget applies at once, with Undo.
 */
function WhatChefKnows() {
  const queryClient = useQueryClient()
  const showUndo = useUndo()
  const { setHeight } = useChef()
  const { data: prefs = [], isLoading, error, refetch } = usePreferences()

  const setForgotten = useMutation({
    mutationFn: ({ id, forgotten }: { id: string; forgotten: boolean }) =>
      apiJson(`/api/preferences/${id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ forgotten }),
      }),
    onMutate: ({ id, forgotten }) => {
      if (forgotten) queryClient.setQueryData<Preference[]>(['preferences'], (old) => old?.filter((p) => p.id !== id))
    },
    onSettled: () => void queryClient.invalidateQueries({ queryKey: ['preferences'] }),
  })

  const forget = (p: Preference) => {
    setForgotten.mutate({ id: p.id, forgotten: true })
    showUndo({
      message: `Forgot ${p.subject}`,
      onUndo: () => setForgotten.mutate({ id: p.id, forgotten: false }),
    })
  }

  const told = prefs.filter((p) => p.source === 'told')
  const noticed = prefs.filter((p) => p.source === 'inferred')

  return (
    <section className="mt-10 max-w-xl">
      <h2 className="mb-1 text-lg font-semibold">What Chef knows</h2>
      <p className="mb-4 text-sm text-ink-muted">
        Chef goes by this when it suggests meals. Tell it more in chat, like "no mushrooms" or
        "more fish".
      </p>

      {isLoading && <Loader2 className="mx-auto size-6 animate-spin text-ink-muted" />}
      {error && <ErrorState error={error} onRetry={() => void refetch()} />}

      {!isLoading && !error && prefs.length === 0 && (
        <div className="rounded-2xl border border-line bg-white p-4 text-sm text-ink-muted shadow-sm">
          Nothing yet. Chef learns from what you cook and rate, and from what you tell it.
        </div>
      )}

      {told.length > 0 && <PreferenceGroup title="You told Chef" prefs={told} onForget={forget} />}
      {noticed.length > 0 && <PreferenceGroup title="Chef noticed" prefs={noticed} onForget={forget} />}

      <Button variant="outline" className="mt-1 min-h-[44px]" onClick={() => setHeight('half')}>
        <ChefHat className="size-4" />
        Tell Chef
      </Button>
    </section>
  )
}

function PreferenceGroup({
  title,
  prefs,
  onForget,
}: {
  title: string
  prefs: Preference[]
  onForget: (p: Preference) => void
}) {
  return (
    <>
      <h3 className="mb-2 text-sm font-medium text-ink-muted">{title}</h3>
      <ul className="mb-4 divide-y divide-line overflow-hidden rounded-2xl border border-line bg-white shadow-sm">
        {prefs.map((p) => (
          <li key={p.id} className="flex min-h-[52px] items-center gap-2 py-2 pr-2 pl-4">
            <div className="min-w-0 flex-1">
              <p className="text-base">
                <span className="font-medium">{STANCE_LABEL[p.stance]}</span> {p.subject}
              </p>
              <p className="text-sm text-ink-muted">{p.evidence}</p>
            </div>
            <button
              type="button"
              aria-label={`Forget ${p.subject}`}
              onClick={() => onForget(p)}
              className="flex size-10 shrink-0 items-center justify-center rounded-lg text-ink-muted hover:bg-sand hover:text-ink"
            >
              <X className="size-4" />
            </button>
          </li>
        ))}
      </ul>
    </>
  )
}

const RESULT: Record<CalendarResult, string> = {
  connected: 'Calendar connected.',
  failed: "Couldn't connect the calendar. Try again.",
  cancelled: 'Calendar not connected.',
}

/** Half hours from 4pm to 11pm, for when dinner is. */
const DINNER_TIMES = Array.from({ length: 15 }, (_, i) => {
  const minutes = 16 * 60 + i * 30
  return `${String(Math.floor(minutes / 60)).padStart(2, '0')}:${minutes % 60 ? '30' : '00'}`
})

/**
 * Google Calendar, so the week shows which evenings you're busy. Omlete sees
 * only when you're busy, never what your events are, and the calendar only
 * suggests: nothing on a list changes because of it.
 */
function Calendar() {
  const queryClient = useQueryClient()
  const showUndo = useUndo()
  const navigate = useNavigate({ from: '/settings' })
  const { calendar: result } = Route.useSearch()
  const { data } = useCalendar()
  const [connecting, setConnecting] = useState(false)
  const [shownResult] = useState(result)

  // Show how connecting went once, and take it out of the address.
  useEffect(() => {
    if (result) void navigate({ search: {}, replace: true })
  }, [result, navigate])

  const update = useMutation({
    mutationFn: (change: Partial<Pick<CalendarStatus, 'dinner_start' | 'dinner_end'>> & { calendar_ids?: string[] }) =>
      apiJson<CalendarStatus>('/api/calendar/settings', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(change),
      }),
    onSuccess: (next) => queryClient.setQueryData(['calendar'], next),
    onError: () => showUndo({ message: "Couldn't save that. Try again." }),
    onSettled: () => void queryClient.invalidateQueries({ queryKey: ['calendar'] }),
  })

  const disconnect = useMutation({
    mutationFn: () => apiJson<CalendarStatus>('/api/calendar', { method: 'DELETE' }),
    onSuccess: (next) => queryClient.setQueryData(['calendar'], next),
    onSettled: () => void queryClient.invalidateQueries({ queryKey: ['calendar'] }),
  })

  const connect = async () => {
    setConnecting(true)
    try {
      const { url } = await apiJson<{ url: string }>(
        `/api/calendar/google/start?${new URLSearchParams({ return_to: window.location.origin + '/settings' })}`,
      )
      window.location.assign(url)
    } catch {
      setConnecting(false)
      showUndo({ message: "Couldn't reach Google. Try again." })
    }
  }

  // Google refusing a read means the token was revoked or has expired.
  const health = useQuery({
    queryKey: ['calendar', 'health'],
    queryFn: () => {
      const now = new Date()
      const later = new Date(now.getTime() + 60 * 60 * 1000)
      return apiJson(
        `/api/calendar/busy?${new URLSearchParams({ start: now.toISOString(), end: later.toISOString() })}`,
      )
    },
    enabled: !!data?.connected,
    retry: false,
  })
  const reconnect = health.error instanceof ApiError && health.error.status === 409

  if (!data || !data.configured) return null
  const chosen = data.calendars.filter((c) => c.chosen).map((c) => c.id)
  const toggle = (id: string) =>
    update.mutate({ calendar_ids: chosen.includes(id) ? chosen.filter((c) => c !== id) : [...chosen, id] })

  return (
    <section className="mt-10 max-w-xl" aria-labelledby="calendar-heading">
      <h2 id="calendar-heading" className="mb-1 text-lg font-semibold">
        Calendar
      </h2>
      <p className="mb-4 text-sm text-ink-muted">
        Your week shows the evenings you're busy, so you plan only the dinners you'll eat at home.
        Omlete sees when you're busy, never what your events are.
      </p>
      {shownResult && (
        <p role="status" className="mb-3 text-sm font-medium text-ink-soft">
          {RESULT[shownResult]}
        </p>
      )}
      <div className="space-y-3 rounded-2xl border border-line bg-white p-4 shadow-sm">
        {!data.connected || reconnect ? (
          <div className="flex min-h-[44px] items-center justify-between gap-3">
            <span className="flex items-center gap-2 font-medium">
              <CalendarDays className="size-5 text-ink-muted" />
              {reconnect ? 'Google needs you to connect again' : 'Google Calendar'}
            </span>
            <Button type="button" onClick={() => void connect()} disabled={connecting}>
              {connecting && <Loader2 className="size-4 animate-spin" />}
              {reconnect ? 'Reconnect' : 'Connect'}
            </Button>
          </div>
        ) : (
          <>
            <fieldset>
              <legend className="mb-1 font-medium">Calendars that count</legend>
              {data.calendars.map((c) => (
                <label key={c.id} className="flex min-h-[44px] items-center gap-3">
                  <input
                    type="checkbox"
                    className="size-5 accent-[var(--color-ink)]"
                    checked={c.chosen}
                    onChange={() => toggle(c.id)}
                  />
                  <span className="min-w-0 truncate">{c.name}</span>
                </label>
              ))}
            </fieldset>
            <div className="flex min-h-[44px] flex-wrap items-center justify-between gap-3">
              <span className="font-medium">Dinner is between</span>
              <span className="flex items-center gap-2">
                <select
                  aria-label="Dinner starts"
                  className={selectClass}
                  value={data.dinner_start}
                  onChange={(e) => update.mutate({ dinner_start: e.target.value })}
                >
                  {DINNER_TIMES.filter((t) => t < data.dinner_end).map((t) => (
                    <option key={t}>{t}</option>
                  ))}
                </select>
                and
                <select
                  aria-label="Dinner ends"
                  className={selectClass}
                  value={data.dinner_end}
                  onChange={(e) => update.mutate({ dinner_end: e.target.value })}
                >
                  {DINNER_TIMES.filter((t) => t > data.dinner_start).map((t) => (
                    <option key={t}>{t}</option>
                  ))}
                </select>
              </span>
            </div>
            <div className="flex justify-end">
              <button
                type="button"
                onClick={() => disconnect.mutate()}
                disabled={disconnect.isPending}
                className="min-h-[44px] rounded-xl px-3 text-sm font-semibold text-ink-soft hover:bg-sand hover:text-danger"
              >
                Disconnect
              </button>
            </div>
          </>
        )}
      </div>
    </section>
  )
}
