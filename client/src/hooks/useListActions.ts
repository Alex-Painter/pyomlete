import { useCallback, useRef } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { ApiError, apiFetch, apiJson } from '@/lib/api'
import {
  applyOps,
  cancelOp,
  enqueue,
  flushQueue,
  newId,
  pendingOpsFor,
  pendingRemoval,
} from '@/lib/offline'
import type { NewOp, QueuedOp } from '@/lib/offline'
import { guessCategory } from '@/lib/guessCategory'
import type { ParsedItem } from '@/lib/parseItems'
import type { DayStatus, ISODate, ListDetail, ListItem, PlanDay } from '@/lib/types'
import { dayLong } from '@/lib/week'
import { useUndo } from '@/components/UndoToast'

const UNDO_WINDOW_MS = 5000

/**
 * Every change to a list's items, shared by Plan and Shop.
 *
 * Changes apply to the screen at once, are queued on the phone, and are sent
 * when there's a connection (see lib/offline). Removals wait out the Undo
 * toast before they're sent at all.
 */
export function useListActions(listId: string) {
  const queryClient = useQueryClient()
  const showUndo = useUndo()
  const key = ['list', listId]

  const current = () => queryClient.getQueryData<ListDetail>(key)
  /** The list as it was before each meal removal, by the removal's op. */
  const beforeRemoval = useRef(new Map<string, ListDetail | undefined>())

  const setList = useCallback(
    (fn: (l: ListDetail) => ListDetail) =>
      queryClient.setQueryData<ListDetail>(['list', listId], (old) => (old ? fn(old) : old)),
    [queryClient, listId],
  )

  const apply = useCallback(
    (op: NewOp) => {
      const opId = enqueue(op)
      setList((l) => applyOps(l, [{ ...op, opId } as QueuedOp]))
      void flushQueue()
      return opId
    },
    [setList],
  )

  const restore = useCallback(
    (opIds: string[], previous: ListDetail | undefined) => {
      opIds.forEach(cancelOp)
      if (previous) {
        queryClient.setQueryData<ListDetail>(['list', listId], applyOps(previous, pendingOpsFor(listId)))
      }
      void queryClient.invalidateQueries({ queryKey: ['list', listId] })
    },
    [queryClient, listId],
  )

  const setChecked = useCallback(
    (item: ListItem, checked: boolean, withUndo = false) => {
      apply({ kind: 'patch', listId, itemId: item.id, updates: { checked } })
      if (withUndo) {
        showUndo({
          message: checked ? `Got ${item.name}` : `${item.name} back on the list`,
          onUndo: () =>
            apply({ kind: 'patch', listId, itemId: item.id, updates: { checked: !checked } }),
        })
      }
    },
    [apply, listId, showUndo],
  )

  const update = useCallback(
    (itemId: string, updates: Partial<ListItem>) =>
      apply({ kind: 'patch', listId, itemId, updates }),
    [apply, listId],
  )

  const addItems = useCallback(
    (parsed: ParsedItem[], categories: string[]) => {
      const existing = current()?.items ?? []
      for (const p of parsed) {
        const guess = guessCategory(p.name, categories, existing)
        const item: ListItem = {
          id: newId(),
          name: p.name,
          amount: p.amount,
          unit: p.unit,
          category: guess,
          checked: false,
          sources: [{ recipe_id: null, amount: p.amount }],
        }
        apply({ kind: 'add', listId, item })
        // The server's answer (its ingredient cache, then Haiku) wins over
        // the guess. With no signal the guess simply stays.
        apiJson<{ category: string }>('/api/categorize', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name: p.name }),
        })
          .then(({ category }) => {
            const now = current()?.items.find((i) => i.id === item.id)
            if (now && now.category === guess && category !== guess) {
              apply({ kind: 'patch', listId, itemId: item.id, updates: { category } })
            }
          })
          .catch(() => {})
      }
    },
    [apply, listId],
  )

  /** Remove items now, send the delete only once Undo has had its chance. */
  const removeItems = useCallback(
    (items: ListItem[], message: string) => {
      if (items.length === 0) return
      const previous = current()
      const notBefore = Date.now() + UNDO_WINDOW_MS + 500
      const opIds = items.map((item) =>
        apply({ kind: 'delete', listId, itemId: item.id, notBefore }),
      )
      showUndo({ message, onUndo: () => restore(opIds, previous), duration: UNDO_WINDOW_MS })
    },
    [apply, listId, restore, showUndo],
  )

  const removeRecipe = useCallback(
    (recipeId: string, title: string) => {
      const previous = current()
      const opId = apply({
        kind: 'removeRecipe',
        listId,
        recipeId,
        notBefore: Date.now() + UNDO_WINDOW_MS + 500,
      })
      beforeRemoval.current.set(opId, previous)
      showUndo({
        message: `Removed ${title} and its ingredients`,
        onUndo: () => restore([opId], previous),
        duration: UNDO_WINDOW_MS,
      })
    },
    [apply, listId, restore, showUndo],
  )

  /**
   * Putting a meal back while its removal can still be undone is that Undo.
   * The server still has the meal, so adding it again would be refused and
   * the removal would go through anyway. Returns the list as it was before
   * the removal, or null if there was no removal to undo.
   */
  const undoRemoval = useCallback(
    (recipeId: string): { previous: ListDetail | undefined } | null => {
      const removal = pendingRemoval(listId, recipeId)
      if (!removal) return null
      const previous = beforeRemoval.current.get(removal.opId)
      restore([removal.opId], previous)
      return { previous }
    },
    [listId, restore],
  )

  /** Put a meal on a day, or clear it. Works offline; last write wins. */
  const setDay = useCallback(
    ({ date, recipeId, status }: { date: ISODate; recipeId: string | null; status?: DayStatus }) => {
      const undone = recipeId ? undoRemoval(recipeId) : null
      // The meal was taken off its days, and planning it now says where it
      // goes instead: the server never saw the removal, so clear them there.
      for (const d of undone?.previous?.days ?? []) {
        if (d.recipe_id === recipeId && d.date !== date) {
          apply({ kind: 'setDay', listId, date: d.date, recipeId: null, status: d.status })
        }
      }
      return apply({ kind: 'setDay', listId, date, recipeId, status: status ?? 'open' })
    },
    [apply, listId, undoRemoval],
  )

  /** Out for the evening, or back in. Keeps whatever meal the day had. */
  const markOut = useCallback(
    (day: PlanDay, out: boolean) =>
      setDay({ date: day.date, recipeId: day.recipe_id, status: out ? 'out' : 'open' }),
    [setDay],
  )

  /**
   * Take a meal off its day at once, with Undo. The meal and its items stay
   * on the list as an any-day meal, so Undo only has to put the day back.
   */
  const clearDay = useCallback(
    (day: PlanDay, title: string) => {
      setDay({ date: day.date, recipeId: null, status: day.status })
      showUndo({
        message: `Took ${title} off ${dayLong(day.date)}`,
        onUndo: () => setDay({ date: day.date, recipeId: day.recipe_id, status: day.status }),
      })
    },
    [setDay, showUndo],
  )

  /** Put a meal and its ingredients on a plain list. Needs signal. */
  const addRecipe = useCallback(
    async (recipeId: string, title: string) => {
      if (undoRemoval(recipeId)) {
        showUndo({ message: `Added ${title}`, onUndo: () => removeRecipe(recipeId, title) })
        return
      }
      try {
        await apiJson(`/api/lists/${listId}/recipes`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ recipe_id: recipeId }),
        })
      } catch (err) {
        // A 400 means it's already on the list, which is what was asked for.
        if (!(err instanceof ApiError && err.status === 400)) {
          showUndo({ message: `Couldn't add ${title}. Check your connection.` })
          return
        }
      }
      await queryClient.invalidateQueries({ queryKey: ['list', listId] })
      void queryClient.invalidateQueries({ queryKey: ['lists'] })
      showUndo({ message: `Added ${title}`, onUndo: () => removeRecipe(recipeId, title) })
    },
    [queryClient, listId, showUndo, removeRecipe, undoRemoval],
  )

  const reorder = useCallback(
    (category: string, itemIds: string[]) => {
      setList((l) => {
        const byId = new Map(l.items.map((i) => [i.id, i]))
        const ordered = itemIds
          .map((id) => byId.get(id))
          .filter((i): i is ListItem => i != null && i.category === category)
        const ids = new Set(ordered.map((i) => i.id))
        const queue = [...ordered]
        return { ...l, items: l.items.map((i) => (ids.has(i.id) ? queue.shift()! : i)) }
      })
      void apiFetch(`/api/lists/${listId}/items/reorder`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ category, item_ids: itemIds }),
      }).catch(() => {})
    },
    [setList, listId],
  )

  return {
    setChecked,
    update,
    addItems,
    removeItems,
    removeRecipe,
    addRecipe,
    setDay,
    markOut,
    clearDay,
    reorder,
  }
}
