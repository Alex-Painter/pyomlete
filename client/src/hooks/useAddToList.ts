import { useCallback, useEffect, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { ApiError, apiFetch, apiJson } from '@/lib/api'
import { useLists } from '@/lib/queries'
import type { ISODate, ListSummary } from '@/lib/types'
import { useUndo } from '@/components/UndoToast'

const CURRENT_KEY = 'omlete:current-list'

/** Remember the list last opened, so "Add to list" knows where to go. */
export function rememberCurrentList(listId: string) {
  try {
    window.localStorage.setItem(CURRENT_KEY, listId)
  } catch {
    // Storage blocked: "current" falls back to the newest list.
  }
}

/** The list "Add to list" adds to: the last one opened, else the newest. */
export function useCurrentList(): ListSummary | null {
  const { data: lists } = useLists()
  const [remembered, setRemembered] = useState<string | null>(null)
  useEffect(() => {
    try {
      setRemembered(window.localStorage.getItem(CURRENT_KEY))
    } catch {
      setRemembered(null)
    }
  }, [])
  if (!lists || lists.length === 0) return null
  return lists.find((l) => l.id === remembered) ?? lists[0]
}

/** A plain list, or with `week_start` a week list with seven open days. */
export async function createList(
  body: { week_start?: ISODate } = {},
): Promise<{ id: string; name: string }> {
  return apiJson<{ id: string; name: string }>('/api/lists/', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
}

/** Put a saved recipe on a list, confirming with Undo. */
export function useAddRecipeToList() {
  const queryClient = useQueryClient()
  const showUndo = useUndo()

  return useCallback(
    async (recipeId: string, title: string, list: { id: string; name: string }) => {
      try {
        await apiJson(`/api/lists/${list.id}/recipes`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ recipe_id: recipeId }),
        })
      } catch (err) {
        if (err instanceof ApiError && err.status === 400) {
          showUndo({ message: `${title} is already on ${list.name}` })
          return
        }
        throw err
      }
      rememberCurrentList(list.id)
      void queryClient.invalidateQueries({ queryKey: ['list', list.id] })
      void queryClient.invalidateQueries({ queryKey: ['lists'] })
      showUndo({
        message: `Added ${title} to ${list.name}`,
        onUndo: () => {
          void apiFetch(`/api/lists/${list.id}/recipes/${recipeId}`, { method: 'DELETE' }).then(
            () => {
              void queryClient.invalidateQueries({ queryKey: ['list', list.id] })
              void queryClient.invalidateQueries({ queryKey: ['lists'] })
            },
          )
        },
      })
    },
    [queryClient, showUndo],
  )
}
