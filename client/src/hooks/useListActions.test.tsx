// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactNode } from 'react'
import { UndoProvider } from '@/components/UndoToast'
import { fetchListWithPending, readQueue, saveListSnapshot } from '@/lib/offline'
import type { ListDetail } from '@/lib/types'
import { useListActions } from './useListActions'

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

function setup() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  queryClient.setQueryData(['list', 'L'], server)
  // What Plan does: the list query reads through the queue.
  queryClient.setQueryDefaults(['list', 'L'], { queryFn: () => fetchListWithPending('L') })
  const wrapper = ({ children }: { children: ReactNode }) => (
    <QueryClientProvider client={queryClient}>
      <UndoProvider>{children}</UndoProvider>
    </QueryClientProvider>
  )
  const { result } = renderHook(() => useListActions('L'), { wrapper })
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
})
