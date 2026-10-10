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
 */
import { ApiError, apiFetch, apiJson } from '@/lib/api'
import type { ListDetail, ListItem } from '@/lib/types'

export type QueuedOp = { opId: string; listId: string; notBefore?: number } & (
  | { kind: 'add'; item: ListItem }
  | { kind: 'patch'; itemId: string; updates: Partial<ListItem> }
  | { kind: 'delete'; itemId: string }
  | { kind: 'removeRecipe'; recipeId: string }
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

export function loadListSnapshot(listId: string): ListDetail | null {
  return readJson<ListDetail>(SNAPSHOT_PREFIX + listId)
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

export function enqueue(op: NewOp): string {
  const queued = { ...op, opId: newId() } as QueuedOp
  const queue = readQueue()

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
    if (target?.kind === 'patch') {
      target.updates = { ...target.updates, ...queued.updates }
      writeQueue(queue)
      return target.opId
    }
    if (target?.kind === 'add') {
      target.item = { ...target.item, ...queued.updates }
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
  }
}

let flushing: Promise<number> | null = null

/**
 * Send every op that is due, in order. Stops at the first network failure and
 * leaves the rest for next time. Resolves to the number of ops sent.
 */
export function flushQueue(opts: { keepalive?: boolean } = {}): Promise<number> {
  // `.finally` always runs asynchronously, so `flushing` is cleared after it
  // has been assigned, even when there was nothing to send.
  flushing ??= sendDue(opts.keepalive ?? false).finally(() => {
    flushing = null
  })
  return flushing
}

async function sendDue(keepalive: boolean): Promise<number> {
  let sent = 0
  for (;;) {
    const now = Date.now()
    const op = readQueue().find((o) => !o.notBefore || o.notBefore <= now)
    if (!op) break
    let res: Response
    try {
      res = await send(op, keepalive)
    } catch {
      break // offline: try again later
    }
    if (res.status >= 500) break
    // 2xx, or a 4xx that retrying can't fix (the item or list is gone).
    cancelOp(op.opId)
    sent++
  }
  return sent
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
        items = items.flatMap((i) => {
          if (!i.sources.some((s) => s.recipe_id === op.recipeId)) return [i]
          const sources = i.sources.filter((s) => s.recipe_id !== op.recipeId)
          if (sources.length === 0) return []
          const next = { ...i, sources }
          return [{ ...next, amount: totalAmount(next) }]
        })
        break
    }
  }
  return { ...list, items, recipes }
}

/**
 * Fetch a list, falling back to the phone's saved copy when there is no
 * network, with any unsent changes laid over the top.
 */
export async function fetchListWithPending(listId: string): Promise<ListDetail> {
  await flushQueue()
  let list: ListDetail
  try {
    list = await apiJson<ListDetail>(`/api/lists/${listId}`)
    saveListSnapshot(list)
  } catch (err) {
    // The server answered (404, 500): that's the truth, not a signal problem.
    if (err instanceof ApiError) throw err
    const snapshot = loadListSnapshot(listId)
    if (!snapshot) throw err
    list = snapshot
  }
  return applyOps(list, pendingOpsFor(listId))
}
