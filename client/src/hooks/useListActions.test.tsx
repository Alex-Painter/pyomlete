// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider, useQuery } from '@tanstack/react-query'
import type { ReactNode } from 'react'
import { UndoProvider } from '@/components/UndoToast'
import { fetchListWithPending, readQueue, saveListSnapshot } from '@/lib/offline'
import type { ListDetail, PlanDay } from '@/lib/types'
import { useListActions } from './useListActions'
import { useRefreshOnSend } from './useRefreshOnSend'

const server: ListDetail = {
  id: 'L',
  name: 'Groceries',
  created_at: null,
  recipes: ['r1'],
  items: [
    {
      id: 'a',
      name: 'onion',
      amount: 1,
      unit: 'whole',
      category: 'Fresh Produce',
      checked: false,
      sources: [{ recipe_id: 'r1', amount: 1 }],
    },
  ],
  week_start: null,
  days: [],
}

const fetchMock = vi.fn<typeof fetch>()
const calls = () =>
  fetchMock.mock.calls.map(([url, init]) => `${init?.method ?? 'GET'} ${String(url).replace(/^https?:\/\/[^/]+/, '')}`)

const day = (date: string, recipe_id: string | null): PlanDay => ({
  date,
  recipe_id,
  status: 'open',
  origin: 'user',
})

/** A week list with Soup (r1) on Tuesday. */
const week: ListDetail = {
  ...server,
  week_start: '2026-10-17',
  days: [day('2026-10-17', null), day('2026-10-20', 'r1'), day('2026-10-21', null)],
}

/**
 * The API for one list, enough of it to see what the phone ends up showing:
 * planning a meal that isn't on the list brings its ingredient.
 */
function serve(initial: ListDetail) {
  const state = structuredClone(initial)
  fetchMock.mockImplementation(async (url, init) => {
    const path = String(url).replace(/^https?:\/\/[^/]+/, '')
    const method = init?.method ?? 'GET'
    let m
    if (method === 'PUT' && (m = path.match(/\/days\/([\d-]+)$/))) {
      const body = JSON.parse(String(init?.body)) as { recipe_id: string | null }
      const date = m[1]
      state.days = state.days.map((d) => (d.date === date ? { ...d, recipe_id: body.recipe_id } : d))
      const id = body.recipe_id
      if (id && !state.recipes.includes(id)) {
        state.recipes = [...state.recipes, id]
        state.items = [
          ...state.items,
          { ...server.items[0], id: `${id}-item`, name: `${id} ingredient`, sources: [{ recipe_id: id, amount: 1 }] },
        ]
      }
    } else if (method === 'DELETE' && (m = path.match(/\/recipes\/(\w+)$/))) {
      const id = m[1]
      state.recipes = state.recipes.filter((r) => r !== id)
      state.days = state.days.map((d) => (d.recipe_id === id ? { ...d, recipe_id: null } : d))
      state.items = state.items.filter((i) => !i.sources.some((s) => s.recipe_id === id))
    } else if (method === 'DELETE' && (m = path.match(/\/items\/([\w-]+)$/))) {
      const id = m[1]
      state.items = state.items.filter((i) => i.id !== id)
    } else if (method !== 'GET') {
      return new Response('{}', { status: 400 })
    }
    return new Response(JSON.stringify(state), { status: 200 })
  })
  return () => state
}

const dinners = (l: ListDetail | undefined) => l?.days.map((d) => [d.date, d.recipe_id])

function setup(initial: ListDetail = server) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  queryClient.setQueryData(['list', 'L'], initial)
  // What Plan does: the list query reads through the queue.
  queryClient.setQueryDefaults(['list', 'L'], { queryFn: () => fetchListWithPending('L') })
  const wrapper = ({ children }: { children: ReactNode }) => (
    <QueryClientProvider client={queryClient}>
      <UndoProvider>{children}</UndoProvider>
    </QueryClientProvider>
  )
  const { result } = renderHook(
    () => {
      useRefreshOnSend()
      // Plan on screen: it refetches the list when it's invalidated.
      useQuery({ queryKey: ['list', 'L'], staleTime: Infinity })
      return useListActions('L')
    },
    { wrapper },
  )
  const list = () => queryClient.getQueryData<ListDetail>(['list', 'L'])
  return { result, list, queryClient }
}

describe('useListActions', () => {
  beforeEach(() => {
    window.localStorage.clear()
    saveListSnapshot(server)
    vi.stubGlobal('fetch', fetchMock)
    fetchMock.mockImplementation(async (_url, init) =>
      init?.method === 'POST'
        ? new Response(JSON.stringify({ detail: 'already on the list' }), { status: 400 })
        : new Response(JSON.stringify(server), { status: 200 }),
    )
  })

  afterEach(() => {
    fetchMock.mockReset()
    vi.unstubAllGlobals()
  })

  it('adding a meal back during its removal Undo is that Undo', async () => {
    const { result, list } = setup()
    act(() => result.current.removeRecipe('r1', 'Soup'))
    expect(list()?.recipes).toEqual([])

    await act(() => result.current.addRecipe('r1', 'Soup'))

    expect(readQueue()).toEqual([])
    expect(calls().filter((c) => !c.startsWith('GET'))).toEqual([])
    await waitFor(() => expect(list()?.recipes).toEqual(['r1']))
    expect(list()?.items.map((i) => i.name)).toEqual(['onion'])
  })

  it('planning a meal on a day during its removal Undo keeps it and plans it', async () => {
    const { result, list } = setup()
    act(() => result.current.removeRecipe('r1', 'Soup'))
    act(() => {
      result.current.setDay({ date: '2026-10-20', recipeId: 'r1' })
    })
    await waitFor(() => expect(readQueue()).toEqual([]))
    const writes = calls().filter((c) => !c.startsWith('GET'))
    expect(writes).toEqual(['PUT /api/lists/L/days/2026-10-20'])
    expect(list()?.items.map((i) => i.name)).toEqual(['onion'])
  })

  it('refreshes the library once a cleared day reaches the server', async () => {
    const { result, queryClient } = setup()
    queryClient.setQueryData(['recipes'], [])
    act(() => {
      result.current.setDay({ date: '2026-10-20', recipeId: null })
    })
    await waitFor(() => expect(readQueue()).toEqual([]))
    await waitFor(() => expect(queryClient.getQueryState(['recipes'])?.isInvalidated).toBe(true))
  })

  it('planning a removed meal during its Undo keeps it off the day it was taken from', async () => {
    saveListSnapshot(week)
    const onServer = serve(week)
    const { result, list } = setup(week)
    act(() => result.current.removeRecipe('r1', 'Soup'))
    act(() => {
      result.current.setDay({ date: '2026-10-21', recipeId: 'r1' })
    })
    await waitFor(() => expect(readQueue()).toEqual([]))

    const planned = [
      ['2026-10-17', null],
      ['2026-10-20', null],
      ['2026-10-21', 'r1'],
    ]
    await waitFor(() => expect(dinners(list())).toEqual(planned))
    expect(dinners(onServer())).toEqual(planned)
    expect(list()?.recipes).toEqual(['r1'])
    expect(list()?.items.map((i) => i.name)).toEqual(['onion'])
  })

  describe('once a change held behind a deferred delete is sent', () => {
    beforeEach(() => {
      vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'Date'] })
    })
    afterEach(() => {
      vi.useRealTimers()
    })

    it.each([
      ['an item delete', (a: ReturnType<typeof useListActions>) => a.removeItems([week.items[0]], 'Removed onion')],
      ['a meal removal', (a: ReturnType<typeof useListActions>) => a.removeRecipe('r1', 'Soup')],
    ])('shows the planned meal’s ingredients after %s', async (_name, remove) => {
      saveListSnapshot(week)
      serve(week)
      const { result, list, queryClient } = setup(week)
      queryClient.setQueryData(['recipes'], [])
      act(() => remove(result.current))
      act(() => {
        result.current.setDay({ date: '2026-10-17', recipeId: 'r2' })
      })
      await act(() => vi.advanceTimersByTimeAsync(100))
      // Held until the delete is due.
      expect(readQueue()).toHaveLength(2)

      await act(() => vi.advanceTimersByTimeAsync(6000))

      expect(readQueue()).toEqual([])
      expect(list()?.items.map((i) => i.name)).toContain('r2 ingredient')
      expect(queryClient.getQueryState(['recipes'])?.isInvalidated).toBe(true)
    })
  })
})
