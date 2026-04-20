import { useEffect } from 'react'

export function useWakeLock(enabled: boolean = true) {
  useEffect(() => {
    if (!enabled) return
    if (typeof navigator === 'undefined' || !('wakeLock' in navigator)) return

    let sentinel: WakeLockSentinel | null = null
    let cancelled = false

    const request = async () => {
      try {
        const lock = await navigator.wakeLock.request('screen')
        if (cancelled) {
          lock.release().catch(() => {})
          return
        }
        sentinel = lock
        lock.addEventListener('release', () => {
          if (sentinel === lock) sentinel = null
        })
      } catch {
        // User may have denied, battery saver on, etc. — silently ignore.
      }
    }

    const onVisibilityChange = () => {
      if (document.visibilityState === 'visible' && sentinel === null) {
        request()
      }
    }

    request()
    document.addEventListener('visibilitychange', onVisibilityChange)

    return () => {
      cancelled = true
      document.removeEventListener('visibilitychange', onVisibilityChange)
      if (sentinel) {
        sentinel.release().catch(() => {})
        sentinel = null
      }
    }
  }, [enabled])
}
