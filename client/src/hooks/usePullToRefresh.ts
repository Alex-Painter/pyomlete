import { useEffect, useRef, useState } from 'react'

const THRESHOLD = 70

/**
 * Pull down from the top of the page to refresh, like a UIRefreshControl.
 * Returns how far the user has pulled (0..1) for the indicator.
 */
export function usePullToRefresh(onRefresh: () => void, enabled = true) {
  const [pull, setPull] = useState(0)
  const startY = useRef<number | null>(null)
  const distance = useRef(0)
  const refresh = useRef(onRefresh)
  refresh.current = onRefresh

  useEffect(() => {
    if (!enabled) return
    const onStart = (e: TouchEvent) => {
      startY.current = window.scrollY <= 0 ? e.touches[0].clientY : null
      distance.current = 0
    }
    const onMove = (e: TouchEvent) => {
      if (startY.current == null) return
      distance.current = Math.max(0, e.touches[0].clientY - startY.current)
      setPull(Math.min(1, distance.current / THRESHOLD))
    }
    const onEnd = () => {
      if (startY.current != null && distance.current >= THRESHOLD) refresh.current()
      startY.current = null
      distance.current = 0
      setPull(0)
    }
    window.addEventListener('touchstart', onStart, { passive: true })
    window.addEventListener('touchmove', onMove, { passive: true })
    window.addEventListener('touchend', onEnd)
    return () => {
      window.removeEventListener('touchstart', onStart)
      window.removeEventListener('touchmove', onMove)
      window.removeEventListener('touchend', onEnd)
    }
  }, [enabled])

  return pull
}
