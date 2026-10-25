/**
 * The on-screen keyboard. Mobile Safari, and Chrome on Android by default,
 * open it over the page without shrinking the layout viewport, so anything
 * `position: fixed` to the bottom stays under it or floats a band above it.
 * Only the visual viewport shrinks, so that's what this reads.
 */
import { useEffect, useState } from 'react'

/** The part of the layout viewport left visible above the keyboard, in CSS px. */
export type VisibleArea = { top: number; height: number }

// Taller than any browser toolbar collapsing, shorter than any keyboard.
const KEYBOARD_MIN_PX = 150

type Viewport = Pick<VisualViewport, 'height' | 'offsetTop' | 'scale'>

/** The area above the keyboard, or null when no keyboard is open. */
export function areaAboveKeyboard(
  innerHeight: number,
  vv: Viewport,
): VisibleArea | null {
  // Pinch zoom shrinks the visual viewport too; scale undoes that.
  if (innerHeight - vv.height * vv.scale < KEYBOARD_MIN_PX) return null
  return { top: vv.offsetTop, height: vv.height }
}

export function useAreaAboveKeyboard(): VisibleArea | null {
  const [area, setArea] = useState<VisibleArea | null>(null)

  useEffect(() => {
    const vv = window.visualViewport
    if (!vv) return
    const update = () => {
      const next = areaAboveKeyboard(window.innerHeight, vv)
      setArea((prev) =>
        prev?.top === next?.top && prev?.height === next?.height ? prev : next,
      )
    }
    update()
    vv.addEventListener('resize', update)
    vv.addEventListener('scroll', update)
    return () => {
      vv.removeEventListener('resize', update)
      vv.removeEventListener('scroll', update)
    }
  }, [])

  return area
}
