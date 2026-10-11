// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  applyOps,
  cancelOp,
  enqueue,
  fetchListWithPending,
  flushQueue,
  pendingOpsFor,
  readQueue,
  saveListSnapshot,
} from './offline'
import type { ListDetail, PlanDay } from './types'

const list: ListDetail = {
  id: 'L',
  name: 'Week',
  created_at: null,
  recipes: ['r1', 'r2'],
  items: [
    {
      id: 'a',
      name: 'onion',
      amount: 3,
      unit: 'whole',
      category: 'Fresh Produce',
      checked: false,
      sources: [
        { recipe_id: 'r1', amount: 1 },
        { recipe_id: 'r2', amount: 2 },
      ],
    },
    {
      id: 'b',
      name: 'eggs',
      amount: 4,
      unit: 'whole',
      category: 'Dairy & Eggs',
      checked: false,
      sources: [{ recipe_id: 'r1', amount: 4 }],
    },
  ],
  week_start: null,
  days: [],
}

const DAYS: PlanDay[] = ['2026-10-17', '2026-10-18', '2026-10-19', '2026-10-20'].map((date) => ({
  date,
  recipe_id: null,
  status: 'open',
  origin: 'user',
}))

const weekList: ListDetail = {
  ...list,
  week_start: '2026-10-17',
  days: DAYS.map((d) => (d.date === '2026-10-18' ? { ...d, recipe_id: 'r1' } : d)),
}

const dayOf = (l: ListDetail, date: string) => l.days.find((d) => d.date === date)

describe('applyOps', () => {
  it('applies patches, adds and deletes in order', () => {
    const next = applyOps(list, [
      { opId: '1', listId: 'L', kind: 'patch', itemId: 'a', updates: { checked: true } },
      { opId: '2', listId: 'L', kind: 'delete', itemId: 'b' },
      {
        opId: '3',
        listId: 'L',
        kind: 'add',
        item: { ...list.items[1], id: 'c', name: 'milk', sources: [] },
      },
    ])
    expect(next.items.map((i) => [i.id, i.checked])).toEqual([
      ['a', true],
      ['c', false],
    ])
  })

  it('removes a recipe like the server does', () => {
    const next = applyOps(list, [
      { opId: '1', listId: 'L', kind: 'removeRecipe', recipeId: 'r1' },
    ])
    expect(next.recipes).toEqual(['r2'])
    expect(next.items).toHaveLength(1)
    expect(next.items[0].amount).toBe(2)
  })

  it('takes a removed recipe off its day too', () => {
    const next = applyOps(weekList, [
      { opId: '1', listId: 'L', kind: 'removeRecipe', recipeId: 'r1' },
    ])
    expect(dayOf(next, '2026-10-18')?.recipe_id).toBeNull()
  })
})

describe('applyOps setDay', () => {
  it('sets a day, and a recipe new to the list joins it', () => {
    const next = applyOps(weekList, [
      { opId: '1', listId: 'L', kind: 'setDay', date: '2026-10-20', recipeId: 'r3', status: 'open' },
    ])
    expect(dayOf(next, '2026-10-20')).toMatchObject({ recipe_id: 'r3', status: 'open' })
    expect(next.recipes).toEqual(['r1', 'r2', 'r3'])
    expect(next.days.filter((d) => d.recipe_id != null)).toHaveLength(2)
  })

  it('clearing a day leaves the meal and its items on the list', () => {
    const next = applyOps(weekList, [
      { opId: '1', listId: 'L', kind: 'setDay', date: '2026-10-18', recipeId: null, status: 'open' },
    ])
    expect(dayOf(next, '2026-10-18')?.recipe_id).toBeNull()
    expect(next.recipes).toEqual(['r1', 'r2'])
    expect(next.items).toEqual(weekList.items)
  })

  it('status follows the last write', () => {
    const next = applyOps(weekList, [
      { opId: '1', listId: 'L', kind: 'setDay', date: '2026-10-19', recipeId: null, status: 'out' },
      { opId: '2', listId: 'L', kind: 'setDay', date: '2026-10-19', recipeId: 'r2', status: 'open' },
    ])
    expect(dayOf(next, '2026-10-19')).toMatchObject({ recipe_id: 'r2', status: 'open' })
  })
})

describe('setDay in the queue', () => {
  const fetchMock = vi.fn<typeof fetch>()

  beforeEach(() => {
    window.localStorage.clear()
    vi.stubGlobal('fetch', fetchMock)
  })

  afterEach(() => {
    fetchMock.mockReset()
    vi.unstubAllGlobals()
  })

  const offline = () => fetchMock.mockRejectedValue(new TypeError('Failed to fetch'))

  it('survives a reload with no signal and is sent once back online', async () => {
    offline()
    saveListSnapshot(weekList)
    enqueue({ kind: 'setDay', listId: 'L', date: '2026-10-20', recipeId: 'r2', status: 'open' })

    // A reload reads the saved copy and lays the queued day over it.
    const reloaded = await fetchListWithPending('L')
    expect(dayOf(reloaded, '2026-10-20')?.recipe_id).toBe('r2')
    expect(readQueue()).toHaveLength(1)

    fetchMock.mockReset()
    fetchMock.mockResolvedValue(new Response('{}', { status: 200 }))
    expect(await flushQueue()).toBe(1)
    const [url, init] = fetchMock.mock.calls[0]
    expect(url).toBe('/api/lists/L/days/2026-10-20')
    expect(init?.method).toBe('PUT')
    expect(JSON.parse(String(init?.body))).toEqual({ recipe_id: 'r2', status: 'open' })
    expect(readQueue()).toEqual([])
  })

  it('folds repeated writes to one day into the last one', () => {
    offline()
    enqueue({ kind: 'setDay', listId: 'L', date: '2026-10-20', recipeId: 'r1', status: 'open' })
    enqueue({ kind: 'setDay', listId: 'L', date: '2026-10-20', recipeId: 'r2', status: 'open' })
    expect(pendingOpsFor('L')).toMatchObject([{ kind: 'setDay', recipeId: 'r2' }])
  })

  it('does not fold across a removal queued in between', () => {
    offline()
    enqueue({ kind: 'setDay', listId: 'L', date: '2026-10-20', recipeId: 'r1', status: 'open' })
    enqueue({ kind: 'removeRecipe', listId: 'L', recipeId: 'r1', notBefore: Date.now() + 60_000 })
    enqueue({ kind: 'setDay', listId: 'L', date: '2026-10-20', recipeId: 'r1', status: 'open' })
    expect(pendingOpsFor('L').map((o) => o.kind)).toEqual(['setDay', 'removeRecipe', 'setDay'])
  })

  it('cancelling an unsent day change leaves the list as it was', async () => {
    offline()
    saveListSnapshot(weekList)
    const opId = enqueue({
      kind: 'setDay',
      listId: 'L',
      date: '2026-10-19',
      recipeId: null,
      status: 'out',
    })
    expect(cancelOp(opId)).toBe(true)
    expect(pendingOpsFor('L')).toEqual([])
    const reloaded = await fetchListWithPending('L')
    expect(dayOf(reloaded, '2026-10-19')?.status).toBe('open')
  })

  it('reads a list saved before week plans as a plain list', async () => {
    offline()
    const { week_start: _w, days: _d, ...old } = list
    window.localStorage.setItem('omlete:list:v1:L', JSON.stringify(old))
    const reloaded = await fetchListWithPending('L')
    expect(reloaded.week_start).toBeNull()
    expect(reloaded.days).toEqual([])
  })
})

describe('flushQueue', () => {
  it('can run again after a flush with nothing to send', async () => {
    await flushQueue()
    // A second call must start a new flush rather than reuse a settled one.
    const second = flushQueue()
    const third = flushQueue()
    expect(second).toBe(third)
    await second
    expect(flushQueue()).not.toBe(second)
  })
})
