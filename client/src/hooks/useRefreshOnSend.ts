import { useEffect } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { onSent } from '@/lib/offline'

/**
 * Refetch what the server works out from queued changes once they reach it,
 * whichever flush sent them: a meal's ingredients after it's planned, and the
 * library's "Last had" line after a day changes. Mount once, by the
 * QueryClient.
 */
export function useRefreshOnSend() {
  const queryClient = useQueryClient()
  useEffect(
    () =>
      onSent((ops) => {
        for (const listId of new Set(ops.map((o) => o.listId))) {
          void queryClient.invalidateQueries({ queryKey: ['list', listId] })
        }
        void queryClient.invalidateQueries({ queryKey: ['lists'] })
        if (ops.some((o) => o.kind === 'setDay' || o.kind === 'removeRecipe')) {
          void queryClient.invalidateQueries({ queryKey: ['recipes'] })
        }
      }),
    [queryClient],
  )
}
