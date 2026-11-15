import { useEffect, useState } from 'react'
import type { KeyboardEvent, PointerEvent } from 'react'
import {
  DEFAULT_CHEF_WIDTH,
  MAX_CHEF_WIDTH,
  MIN_CHEF_WIDTH,
  applyChefWidth,
  saveChefWidth,
  storedChefWidth,
} from '@/lib/chefWidth'

/** Set on <html> during a drag, so the page's padding follows without easing. */
const RESIZING = 'chef-resizing'
const STEP = 16

/**
 * The left edge of Chef's sidebar. Drag it to resize, or focus it and use the
 * arrow keys. Double-click puts the default width back.
 */
export function ChefResizeHandle() {
  const [width, setWidth] = useState(DEFAULT_CHEF_WIDTH)

  useEffect(() => {
    setWidth(applyChefWidth(storedChefWidth()))
  }, [])

  function onPointerDown(e: PointerEvent<HTMLDivElement>) {
    if (e.button !== 0) return
    e.preventDefault()
    const handle = e.currentTarget
    handle.setPointerCapture(e.pointerId)
    const root = document.documentElement
    root.classList.add(RESIZING)
    // The sidebar is pinned to the right, so its width is the distance from
    // the pointer to the window's right edge.
    const widthAt = (x: number) => window.innerWidth - x
    let last = width
    const move = (ev: globalThis.PointerEvent) => {
      last = applyChefWidth(widthAt(ev.clientX))
    }
    const end = () => {
      handle.removeEventListener('pointermove', move)
      handle.removeEventListener('pointerup', end)
      handle.removeEventListener('pointercancel', end)
      root.classList.remove(RESIZING)
      setWidth(saveChefWidth(last))
    }
    handle.addEventListener('pointermove', move)
    handle.addEventListener('pointerup', end)
    handle.addEventListener('pointercancel', end)
  }

  function onKeyDown(e: KeyboardEvent<HTMLDivElement>) {
    // The handle is on the sidebar's left edge: left makes Chef wider. Start
    // from the width on screen, which a narrow window caps at half its width.
    const shown = Math.min(width, Math.floor(window.innerWidth / 2))
    const next =
      e.key === 'ArrowLeft'
        ? shown + STEP
        : e.key === 'ArrowRight'
          ? shown - STEP
          : e.key === 'Home'
            ? MIN_CHEF_WIDTH
            : e.key === 'End'
              ? MAX_CHEF_WIDTH
              : null
    if (next === null) return
    e.preventDefault()
    setWidth(saveChefWidth(next))
  }

  return (
    <div
      role="separator"
      aria-orientation="vertical"
      aria-label="Resize Chef"
      aria-valuenow={width}
      aria-valuemin={MIN_CHEF_WIDTH}
      aria-valuemax={MAX_CHEF_WIDTH}
      tabIndex={0}
      onPointerDown={onPointerDown}
      onKeyDown={onKeyDown}
      onDoubleClick={() => setWidth(saveChefWidth(DEFAULT_CHEF_WIDTH))}
      className="group absolute inset-y-0 -left-1.5 z-10 w-3 cursor-col-resize touch-none outline-none"
    >
      <div className="mx-auto h-full w-0.5 bg-transparent transition-colors group-hover:bg-line group-focus-visible:bg-ink-muted group-active:bg-ink-muted" />
    </div>
  )
}
