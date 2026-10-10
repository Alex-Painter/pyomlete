import { useRef, useState } from 'react'
import type { CSSProperties, KeyboardEvent, MouseEvent, Ref, TouchEvent } from 'react'
import { Check, ChevronRight, Pencil, Trash2 } from 'lucide-react'
import { formatQuantity } from '@/lib/parseItems'
import type { ListItem } from '@/lib/types'
import { cn } from '@/lib/utils'

const SWIPE_COMMIT = 88

type GestureHandlers = {
  onTouchStart?: (e: TouchEvent) => void
  onMouseDown?: (e: MouseEvent) => void
}

/**
 * One shopping-list row: a native list row in web clothes.
 *
 * - Tap anywhere on it to check it off (not just the circle).
 * - The chevron (Plan only) opens the edit sheet.
 * - Swipe left for Delete and right for Edit, like iOS swipe actions, when
 *   those handlers are given. A short swipe snaps back; nothing is deleted
 *   without the Undo toast that follows.
 *
 * Mirrors a SwiftUI row: `item`, `onToggle`, optional `onEdit` / `onDelete`.
 */
export function ListRow({
  item,
  onToggle,
  onEdit,
  onDelete,
  size = 'default',
  rowRef,
  style,
  gestureHandlers,
  dragging = false,
}: {
  item: ListItem
  onToggle: () => void
  onEdit?: () => void
  onDelete?: () => void
  size?: 'default' | 'large'
  rowRef?: Ref<HTMLDivElement>
  style?: CSSProperties
  /** From a drag-and-drop wrapper; merged with the swipe handlers. */
  gestureHandlers?: GestureHandlers
  dragging?: boolean
}) {
  const start = useRef<{ x: number; y: number } | null>(null)
  const mode = useRef<'idle' | 'swipe' | 'scroll'>('idle')
  const suppressClick = useRef(false)
  const [offset, setOffset] = useState(0)
  const [animating, setAnimating] = useState(false)

  const canSwipeLeft = !!onDelete
  const canSwipeRight = !!onEdit

  const onTouchStart = (e: TouchEvent) => {
    gestureHandlers?.onTouchStart?.(e)
    const t = e.touches[0]
    start.current = { x: t.clientX, y: t.clientY }
    mode.current = 'idle'
    setAnimating(false)
  }

  const onTouchMove = (e: TouchEvent) => {
    if (!start.current || dragging) return
    const t = e.touches[0]
    const dx = t.clientX - start.current.x
    const dy = t.clientY - start.current.y
    if (mode.current === 'idle') {
      if (Math.abs(dy) > 10 && Math.abs(dy) > Math.abs(dx)) mode.current = 'scroll'
      else if (Math.abs(dx) > 10) mode.current = 'swipe'
    }
    if (mode.current !== 'swipe') return
    let next = dx
    if (next < 0 && !canSwipeLeft) next = 0
    if (next > 0 && !canSwipeRight) next = 0
    setOffset(Math.max(-140, Math.min(140, next)))
  }

  const onTouchEnd = () => {
    if (mode.current === 'swipe') {
      suppressClick.current = true
      setTimeout(() => (suppressClick.current = false), 350)
    }
    setAnimating(true)
    if (offset <= -SWIPE_COMMIT && onDelete) {
      setOffset(-480)
      setTimeout(onDelete, 160)
    } else if (offset >= SWIPE_COMMIT && onEdit) {
      setOffset(0)
      onEdit()
    } else {
      setOffset(0)
    }
    start.current = null
    mode.current = 'idle'
  }

  const toggle = () => {
    if (suppressClick.current || dragging) return
    onToggle()
  }

  const onKeyDown = (e: KeyboardEvent) => {
    if (e.key === ' ' || e.key === 'Enter') {
      e.preventDefault()
      onToggle()
    }
  }

  const qty = formatQuantity(item.amount, item.unit)
  const recipeCount = item.sources.filter((s) => s.recipe_id).length
  const large = size === 'large'

  return (
    <div
      ref={rowRef}
      style={style}
      className={cn('relative overflow-hidden', dragging && 'z-10 rounded-xl shadow-lg')}
    >
      {/* Swipe action backgrounds, only while swiping so nothing peeks out. */}
      {offset < 0 && (
        <div className="absolute inset-0 flex items-center justify-end bg-danger pr-5 text-white">
          <Trash2 className="size-5" />
          <span className="ml-2 text-sm font-semibold">Delete</span>
        </div>
      )}
      {offset > 0 && (
        <div className="absolute inset-0 flex items-center bg-ink-soft pl-5 text-white">
          <Pencil className="size-5" />
          <span className="ml-2 text-sm font-semibold">Edit</span>
        </div>
      )}

      <div
        role="checkbox"
        aria-checked={item.checked}
        aria-label={`${item.name}${qty ? `, ${qty}` : ''}`}
        tabIndex={0}
        onClick={toggle}
        onKeyDown={onKeyDown}
        onTouchStart={onTouchStart}
        onTouchMove={onTouchMove}
        onTouchEnd={onTouchEnd}
        onTouchCancel={onTouchEnd}
        onMouseDown={gestureHandlers?.onMouseDown}
        style={{
          transform: offset ? `translateX(${offset}px)` : undefined,
          touchAction: 'pan-y',
        }}
        className={cn(
          'touch-row relative flex cursor-pointer items-center gap-3 bg-white px-3 outline-none focus-visible:ring-2 focus-visible:ring-ring',
          animating && 'transition-transform duration-200',
          large ? 'min-h-[60px] py-3' : 'min-h-[52px] py-2.5',
        )}
      >
        <span
          aria-hidden
          className={cn(
            'flex shrink-0 items-center justify-center rounded-full border-2 transition-colors',
            large ? 'size-7' : 'size-6',
            item.checked ? 'border-primary bg-primary text-ink' : 'border-ink-faint bg-white',
          )}
        >
          {item.checked && <Check className={large ? 'size-4' : 'size-3.5'} strokeWidth={3} />}
        </span>

        <span className="flex min-w-0 flex-1 flex-wrap items-baseline gap-x-2">
          <span
            className={cn(
              'break-words',
              large ? 'text-lg' : 'text-base',
              item.checked ? 'text-ink-muted line-through decoration-ink-muted/60' : 'text-ink',
            )}
          >
            {item.name}
          </span>
          {recipeCount > 1 && (
            <span className="rounded-full bg-cream px-2 py-0.5 text-xs text-ink-muted">
              {recipeCount} meals
            </span>
          )}
        </span>

        {qty && (
          <span className={cn('shrink-0 tabular-nums text-ink-muted', large ? 'text-base' : 'text-sm')}>
            {qty}
          </span>
        )}

        {onEdit && (
          <button
            type="button"
            aria-label={`Edit ${item.name}`}
            onClick={(e) => {
              e.stopPropagation()
              onEdit()
            }}
            onTouchStart={(e) => e.stopPropagation()}
            onMouseDown={(e) => e.stopPropagation()}
            className="-mr-2 flex size-11 shrink-0 items-center justify-center rounded-full text-ink-muted hover:bg-sand hover:text-ink"
          >
            <ChevronRight className="size-5" />
          </button>
        )}
      </div>
    </div>
  )
}
