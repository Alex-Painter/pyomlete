import { useCallback } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { apiJson } from '@/lib/api'
import type { Suggestion } from '@/lib/types'
import { useUndo } from '@/components/UndoToast'
import { rememberCurrentList, useAddRecipeToList } from '@/hooks/useAddToList'

/**
 * The three things a Discover card can do. Each one is also a taste signal
 * the server keeps: what you save, what you shop for, what's not for you.
 */
export function useSuggestionActions() {
  const queryClient = useQueryClient()
  const showUndo = useUndo()
  const addRecipeToList = useAddRecipeToList()

  const patchCache = useCallback(
    (id: string, fn: (s: Suggestion) => Suggestion | null) =>
      queryClient.setQueryData<Suggestion[]>(['suggestions'], (old) =>
        old?.flatMap((s) => {
          if (s.id !== id) return [s]
          const next = fn(s)
          return next ? [next] : []
        }),
      ),
    [queryClient],
  )

  const save = useCallback(
    async (s: Suggestion, listId?: string) => {
      patchCache(s.id, (x) => ({ ...x, status: x.status === 'saved' ? 'saved' : 'saving' }))
      try {
        const updated = await apiJson<Suggestion>(`/api/suggestions/${s.id}/save`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ list_id: listId ?? null }),
        })
        patchCache(s.id, () => updated)
      } finally {
        void queryClient.invalidateQueries({ queryKey: ['suggestions'] })
      }
    },
    [patchCache, queryClient],
  )

  const addToList = useCallback(
    async (s: Suggestion, list: { id: string; name: string }) => {
      if (s.status === 'saved' && s.recipe_id) {
        await addRecipeToList(s.recipe_id, s.title, list)
        return
      }
      await save(s, list.id)
      rememberCurrentList(list.id)
      showUndo({ message: `Saving ${s.title}. It goes on ${list.name} when it's ready.` })
      // The recipe lands on the list in the background; refresh it then.
      setTimeout(() => {
        void queryClient.invalidateQueries({ queryKey: ['list', list.id] })
        void queryClient.invalidateQueries({ queryKey: ['lists'] })
      }, 15000)
    },
    [addRecipeToList, save, showUndo, queryClient],
  )

  const dismiss = useCallback(
    (s: Suggestion) => {
      patchCache(s.id, () => null)
      showUndo({
        message: `Hid ${s.title}. You'll see less like it.`,
        onUndo: () => void queryClient.invalidateQueries({ queryKey: ['suggestions'] }),
        onCommit: () =>
          void apiJson(`/api/suggestions/${s.id}`, {
            method: 'PATCH',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ status: 'dismissed' }),
            keepalive: true,
          }).catch(() => {}),
      })
    },
    [patchCache, queryClient, showUndo],
  )

  return { save, addToList, dismiss }
}
