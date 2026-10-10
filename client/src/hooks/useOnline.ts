import { useSyncExternalStore } from 'react'
import { readQueue, subscribeQueue } from '@/lib/offline'

function subscribeOnline(cb: () => void) {
  window.addEventListener('online', cb)
  window.addEventListener('offline', cb)
  return () => {
    window.removeEventListener('online', cb)
    window.removeEventListener('offline', cb)
  }
}

/** Whether the phone thinks it has a connection. Assumed online on the server. */
export function useOnline(): boolean {
  return useSyncExternalStore(
    subscribeOnline,
    () => navigator.onLine,
    () => true,
  )
}

/** How many list changes are waiting to be sent for this list. */
export function usePendingCount(listId: string): number {
  return useSyncExternalStore(
    subscribeQueue,
    () => readQueue().filter((o) => o.listId === listId && !o.notBefore).length,
    () => 0,
  )
}
