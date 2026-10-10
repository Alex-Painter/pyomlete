import { describe, expect, it } from 'vitest'
import { applyOps } from './offline'
import type { ListDetail } from './types'

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
}

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
})

describe('flushQueue', () => {
  it('can run again after a flush with nothing to send', async () => {
    const { flushQueue } = await import('./offline')
    await flushQueue()
    // A second call must start a new flush rather than reuse a settled one.
    const second = flushQueue()
    const third = flushQueue()
    expect(second).toBe(third)
    await second
    expect(flushQueue()).not.toBe(second)
  })
})
