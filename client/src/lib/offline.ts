/**
 * Lists that keep working with no signal.
 *
 * Shops often have no reception, so every change to a list goes through a
 * small queue kept in localStorage instead of straight to the API: the change
 * shows at once, is saved on the phone, and is sent when the network allows.
 * The last copy of each list the phone fetched is kept too, so a list opened
 * at home still opens in the shop.
 *
 * Deletes ride the same queue with a `notBefore` time. Until then they hide
 * the item locally but haven't reached the server, so Undo just drops the op.
 *
 * Setting a day of a week list rides the queue too. Last write wins per day,
 * the same rule as items. So does marking a meal cooked, last write per meal.
 *
 * Ops for one list reach the server in the order they were made: a later op
 * waits behind an earlier one that isn't due yet.
 */
import { ApiError, apiFetch, apiJson } from '@/lib/api'
import type { DayStatus, ISODate, ListDetail, ListItem } from '@/lib/types'

export type QueuedOp = { opId: string; listId: string; notBefore?: number } & (
  | { kind: 'add'; item: ListItem }
  | { kind: 'patch'; itemId: string; updates: Partial<ListItem> }
  | { kind: 'delete'; itemId: string }
  | { kind: 'removeRecipe'; recipeId: string }
  | { kind: 'setDay'; date: ISODate; recipeId: string | null; status: DayStatus }
  | { kind: 'setCooked'; recipeId: string; cooked: boolean }
)

// Distributive, so each variant keeps its own fields.
export type NewOp = QueuedOp extends infer O
  ? O extends QueuedOp
    ? Omit<O, 'opId'>
    : never
  : never

const QUEUE_KEY = 'omlete:queue:v1'
const SNAPSHOT_PREFIX = 'omlete:list:v1:'

const isBrowser = () => typeof window !== 'undefined'

function readJson<T>(key: string): T | null {
  if (!isBrowser()) return null
  try {
    const raw = window.localStorage.getItem(key)
    return raw ? (JSON.parse(raw) as T) : null
  } catch {
    return null
  }
}

function writeJson(key: string, value: unknown) {
  if (!isBrowser()) return
  try {
    window.localStorage.setItem(key, JSON.stringify(value))
  } catch {
    // Storage full or blocked: the change still applies for this session.
  }
}

// --- snapshots ---

export function saveListSnapshot(list: ListDetail) {
  writeJson(SNAPSHOT_PREFIX + list.id, list)
}

export function loadListSnapshot(listId: string): StoredList | null {
  return readJson<StoredList>(SNAPSHOT_PREFIX + listId)
}

// --- queue ---

type Listener = () => void
const listeners = new Set<Listener>()

export function subscribeQueue(fn: Listener) {
  listeners.add(fn)
  return () => {
    listeners.delete(fn)
  }
}

function notify() {
  listeners.forEach((fn) => fn())
}

export function readQueue(): QueuedOp[] {
  return readJson<QueuedOp[]>(QUEUE_KEY) ?? []
}

function writeQueue(ops: QueuedOp[]) {
  writeJson(QUEUE_KEY, ops)
  notify()
}

export function newId(): string {
  if (isBrowser() && 'randomUUID' in crypto) return crypto.randomUUID()
  return `${Date.now()}-${Math.random().toString(16).slice(2)}`
}

/** The op `sendDue` is sending. It can no longer change or be cancelled. */
let inFlight: string | null = null

export function enqueue(op: NewOp): string {
  const queued = { ...op, opId: newId() } as QueuedOp
  let queue = readQueue()

  // Planning a meal whose removal is still waiting out its Undo is that Undo:
  // otherwise the removal, sent later, would take the meal off its new day.
  if (queued.kind === 'setDay' && queued.recipeId != null) {
    const removal = pendingRemoval(queued.listId, queued.recipeId)
    if (removal) queue = queue.filter((o) => o.opId !== removal.opId)
  }

  // Fold a patch into an earlier, not-yet-sent patch or add of the same item,
  // so a row checked and unchecked ten times offline sends one request.
  if (queued.kind === 'patch') {
    const target = [...queue]
      .reverse()
      .find(
        (o) =>
          o.listId === queued.listId &&
          ((o.kind === 'patch' && o.itemId === queued.itemId) ||
            (o.kind === 'add' && o.item.id === queued.itemId)),
      )
    if (target?.kind === 'patch' && target.opId !== inFlight) {
      target.updates = { ...target.updates, ...queued.updates }
      writeQueue(queue)
      return target.opId
    }
    if (target?.kind === 'add' && target.opId !== inFlight) {
      target.item = { ...target.item, ...queued.updates }
      writeQueue(queue)
      return target.opId
    }
  }

  // Tapping through meals for one day offline sends one request. Only fold
  // into the list's latest op, so a removal queued in between keeps its order.
  if (queued.kind === 'setDay') {
    const target = queue.filter((o) => o.listId === queued.listId).at(-1)
    if (
      target?.kind === 'setDay' &&
      target.date === queued.date &&
      !target.notBefore &&
      target.opId !== inFlight
    ) {
      target.recipeId = queued.recipeId
      target.status = queued.status
      writeQueue(queue)
      return target.opId
    }
  }

  // Ticking a meal cooked and back sends one request. As with days, only
  // fold into the list's latest op, so nothing queued in between reorders.
  if (queued.kind === 'setCooked') {
    const target = queue.filter((o) => o.listId === queued.listId).at(-1)
    if (
      target?.kind === 'setCooked' &&
      target.recipeId === queued.recipeId &&
      target.opId !== inFlight
    ) {
      target.cooked = queued.cooked
      writeQueue(queue)
      return target.opId
    }
  }

  queue.push(queued)
  writeQueue(queue)
  if (queued.notBefore) {
    setTimeout(() => void flushQueue(), queued.notBefore - Date.now() + 50)
  }
  return queued.opId
}

/** A meal's removal that hasn't been sent and can still be undone. */
export function pendingRemoval(listId: string, recipeId: string): QueuedOp | undefined {
  const now = Date.now()
  return readQueue().find(
    (o) =>
      o.kind === 'removeRecipe' &&
      o.listId === listId &&
      o.recipeId === recipeId &&
      o.opId !== inFlight &&
      o.notBefore != null &&
      o.notBefore > now,
  )
}

/** Drop an op that hasn't been sent yet. Returns false if it already went. */
export function cancelOp(opId: string): boolean {
  const queue = readQueue()
  const next = queue.filter((o) => o.opId !== opId)
  if (next.length === queue.length) return false
  writeQueue(next)
  return true
}

/** Send deferred ops now, e.g. when the page is being closed. */
export function makeAllDue() {
  const queue = readQueue()
  if (!queue.some((o) => o.notBefore)) return
  writeQueue(queue.map(({ notBefore: _ignored, ...o }) => o as QueuedOp))
}

export function pendingOpsFor(listId: string): QueuedOp[] {
  return readQueue().filter((o) => o.listId === listId)
}

function json(body: unknown, keepalive = false): RequestInit {
  return {
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    keepalive,
  }
}

async function send(op: QueuedOp, keepalive: boolean): Promise<Response> {
  const base = `/api/lists/${op.listId}`
  switch (op.kind) {
    case 'add': {
      const { id, name, amount, unit, category } = op.item
      return apiFetch(`${base}/items`, {
        method: 'POST',
        ...json({ id, name, amount, unit, category }, keepalive),
      })
    }
    case 'patch':
      return apiFetch(`${base}/items/${op.itemId}`, {
        method: 'PATCH',
        ...json(op.updates, keepalive),
      })
    case 'delete':
      return apiFetch(`${base}/items/${op.itemId}`, {
        method: 'DELETE',
        keepalive,
      })
    case 'removeRecipe':
      return apiFetch(`${base}/recipes/${op.recipeId}`, {
        method: 'DELETE',
        keepalive,
      })
    case 'setDay':
      return apiFetch(`${base}/days/${op.date}`, {
        method: 'PUT',
        ...json({ recipe_id: op.recipeId, status: op.status }, keepalive),
      })
    case 'setCooked':
      return apiFetch(`${base}/recipes/${op.recipeId}/cooked`, {
        method: 'PUT',
        ...json({ cooked: op.cooked }, keepalive),
      })
  }
}

type SentListener = (ops: QueuedOp[]) => void
const sentListeners = new Set<SentListener>()

/** Hear about ops that reached the server, after each flush that sent any. */
export function onSent(fn: SentListener) {
  sentListeners.add(fn)
  return () => {
    sentListeners.delete(fn)
  }
}

let flushing: Promise<number> | null = null
/** Flushes asked for while one was running, which may have read the queue already. */
let flushRequests = 0

/**
 * Send every op that is due, in order. Stops at the first network failure and
 * leaves the rest for next time. Resolves to the number of ops sent.
 */
export function flushQueue(opts: { keepalive?: boolean } = {}): Promise<number> {
  if (flushing) {
    flushRequests++
    return flushing
  }
  flushing = (async () => {
    const sent: QueuedOp[] = []
    try {
      for (;;) {
        const requests = flushRequests
        await sendDue(opts.keepalive ?? false, sent)
        if (flushRequests === requests) break
      }
    } finally {
      // After an await, so `flushing` has been assigned, and with none after
      // the last check, so no caller can slip in between.
      flushing = null
    }
    if (sent.length > 0) sentListeners.forEach((fn) => fn(sent))
    return sent.length
  })()
  return flushing
}

/** The first op that is due and has nothing for its list still waiting before it. */
function nextDue(queue: QueuedOp[], now: number): QueuedOp | undefined {
  const waiting = new Set<string>()
  return queue.find((o) => {
    if (waiting.has(o.listId)) return false
    if (o.notBefore && o.notBefore > now) {
      waiting.add(o.listId)
      return false
    }
    return true
  })
}

async function sendDue(keepalive: boolean, sent: QueuedOp[]) {
  for (;;) {
    const op = nextDue(readQueue(), Date.now())
    if (!op) break
    let res: Response
    inFlight = op.opId
    try {
      res = await send(op, keepalive)
    } catch {
      break // offline: try again later
    } finally {
      inFlight = null
    }
    if (res.status >= 500) break
    // 2xx, or a 4xx that retrying can't fix (the item or list is gone).
    cancelOp(op.opId)
    sent.push(op)
  }
}

// --- applying pending ops on top of a list ---

function totalAmount(item: ListItem): number | null {
  const amounts = item.sources
    .map((s) => s.amount)
    .filter((a): a is number => a != null)
  if (amounts.length === 0) return null
  return Math.round(amounts.reduce((a, b) => a + b, 0) * 100) / 100
}

export function applyOps(list: ListDetail, ops: QueuedOp[]): ListDetail {
  let items = list.items
  let recipes = list.recipes
  let days = list.days
  let cooked = list.cooked
  for (const op of ops) {
    switch (op.kind) {
      case 'add':
        if (!items.some((i) => i.id === op.item.id)) items = [...items, op.item]
        break
      case 'patch':
        items = items.map((i) => (i.id === op.itemId ? { ...i, ...op.updates } : i))
        break
      case 'delete':
        items = items.filter((i) => i.id !== op.itemId)
        break
      case 'removeRecipe':
        // Mirrors the server: drop this recipe's share of each item, and any
        // item nothing else asked for.
        recipes = recipes.filter((r) => r !== op.recipeId)
        cooked = cooked.filter((r) => r !== op.recipeId)
        days = days.map((d) => (d.recipe_id === op.recipeId ? { ...d, recipe_id: null } : d))
        items = items.flatMap((i) => {
          if (!i.sources.some((s) => s.recipe_id === op.recipeId)) return [i]
          const sources = i.sources.filter((s) => s.recipe_id !== op.recipeId)
          if (sources.length === 0) return []
          const next = { ...i, sources }
          return [{ ...next, amount: totalAmount(next) }]
        })
        break
      case 'setDay':
        // Mirrors the server: a meal set on a day joins the list (its
        // ingredients arrive with the server's answer), and clearing a day
        // leaves the meal on the list for any day.
        days = days.map((d) =>
          d.date === op.date
            ? { ...d, recipe_id: op.recipeId, status: op.status, origin: 'user' as const }
            : d,
        )
        if (op.recipeId && !recipes.includes(op.recipeId)) recipes = [...recipes, op.recipeId]
        break
      case 'setCooked':
        // Mirrors the server: only a meal still on the list can be cooked.
        cooked = cooked.filter((r) => r !== op.recipeId)
        if (op.cooked && recipes.includes(op.recipeId)) cooked = [...cooked, op.recipeId]
        break
    }
  }
  return { ...list, items, recipes, days, cooked }
}

type WeekFields = 'week_start' | 'days' | 'cooked'
/** A list from a server, or a phone, from before week plans or the cooked flag. */
type StoredList = Omit<ListDetail, WeekFields> & Partial<Pick<ListDetail, WeekFields>>

function normalizeList(list: StoredList): ListDetail {
  return {
    ...list,
    week_start: list.week_start ?? null,
    days: list.days ?? [],
    cooked: list.cooked ?? [],
  }
}

/**
 * Fetch a list, falling back to the phone's saved copy when there is no
 * network, with any unsent changes laid over the top.
 */
export async function fetchListWithPending(listId: string): Promise<ListDetail> {
  await flushQueue()
  let list: ListDetail
  try {
    list = normalizeList(await apiJson<StoredList>(`/api/lists/${listId}`))
    saveListSnapshot(list)
  } catch (err) {
    // The server answered (404, 500): that's the truth, not a signal problem.
    if (err instanceof ApiError) throw err
    const snapshot = loadListSnapshot(listId)
    if (!snapshot) throw err
    list = normalizeList(snapshot)
  }
  return applyOps(list, pendingOpsFor(listId))
}
