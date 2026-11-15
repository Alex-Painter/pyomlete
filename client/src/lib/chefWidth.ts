/**
 * The width of Chef's sidebar on a wide window. Dragging its left edge sets
 * it, and it's kept for the next visit. The width lives in the
 * `--chef-width` CSS variable on <html> rather than in React state, so a drag
 * repaints the sidebar and the page's padding without re-rendering the app.
 */

export const DEFAULT_CHEF_WIDTH = 380
export const MIN_CHEF_WIDTH = 320
export const MAX_CHEF_WIDTH = 720

/** The sidebar's width in CSS. It never takes more than half the window. */
export const CHEF_WIDTH_CSS = `min(var(--chef-width,${DEFAULT_CHEF_WIDTH}px),50vw)`

const KEY = 'omlete.chef.width'

export function clampChefWidth(px: number): number {
  if (!Number.isFinite(px)) return DEFAULT_CHEF_WIDTH
  return Math.round(Math.min(MAX_CHEF_WIDTH, Math.max(MIN_CHEF_WIDTH, px)))
}

/** Shows the width without saving it, for each step of a drag. */
export function applyChefWidth(px: number): number {
  const width = clampChefWidth(px)
  document.documentElement.style.setProperty('--chef-width', `${width}px`)
  return width
}

/** Shows the width and keeps it for the next visit. */
export function saveChefWidth(px: number): number {
  const width = applyChefWidth(px)
  try {
    if (width === DEFAULT_CHEF_WIDTH) localStorage.removeItem(KEY)
    else localStorage.setItem(KEY, String(width))
  } catch {
    // Storage can be off (private windows); the width lasts until reload.
  }
  return width
}

/** The kept width, or the default. */
export function storedChefWidth(): number {
  try {
    const raw = localStorage.getItem(KEY)
    return raw === null ? DEFAULT_CHEF_WIDTH : clampChefWidth(Number(raw))
  } catch {
    return DEFAULT_CHEF_WIDTH
  }
}
