import { useRef, useState } from 'react'
import type { CSSProperties, MouseEvent, Ref, TouchEvent } from 'react'
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
 * What a tap does depends on the mode, because Plan is where the list is built
 * and Shop is where it is checked off (see docs/DESIGN.md):
 *
 * - With `onEdit` (Plan), a tap on the row opens the edit sheet. The circle is
 *   its own control and the only thing that checks or unchecks.
 * - Without `onEdit` (Shop), a tap anywhere on the row checks it.
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

  const guarded = (action: () => void) => () => {
    if (suppressClick.current || dragging) return
    action()
  }
  const toggle = guarded(onToggle)

  const qty = formatQuantity(item.amount, item.unit)
  const recipeCount = item.sources.filter((s) => s.recipe_id).length
  const large = size === 'large'

  const label = `${item.name}${qty ? `, ${qty}` : ''}`
  const padY = large ? 'py-3' : 'py-2.5'
  const focusRing = 'outline-none focus-visible:ring-2 focus-visible:ring-ring'

  const rowProps = {
    onTouchStart,
    onTouchMove,
    onTouchEnd,
    onTouchCancel: onTouchEnd,
    onMouseDown: gestureHandlers?.onMouseDown,
    style: {
      transform: offset ? `translateX(${offset}px)` : undefined,
      touchAction: 'pan-y',
    },
    className: cn(
      'touch-row relative flex items-center bg-white',
      animating && 'transition-transform duration-200',
      large ? 'min-h-[60px]' : 'min-h-[52px]',
    ),
  }

  const circle = (
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
  )

  const details = (
    <>
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
    </>
  )

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

      {onEdit ? (
        <div {...rowProps}>
          <button
            type="button"
            role="checkbox"
            aria-checked={item.checked}
            aria-label={label}
            onClick={toggle}
            className={cn('flex shrink-0 cursor-pointer items-center self-stretch px-3 focus-visible:ring-inset', focusRing)}
          >
            {circle}
          </button>
          <button
            type="button"
            aria-label={`Edit ${item.name}`}
            onClick={guarded(onEdit)}
            className={cn(
              'flex min-w-0 flex-1 cursor-pointer items-center gap-3 self-stretch pr-3 text-left focus-visible:ring-inset',
              padY,
              focusRing,
            )}
          >
            {details}
            <span
              aria-hidden
              className="-mr-2 flex size-11 shrink-0 items-center justify-center text-ink-muted"
            >
              <ChevronRight className="size-5" />
            </span>
          </button>
        </div>
      ) : (
        <div
          {...rowProps}
          role="checkbox"
          aria-checked={item.checked}
          aria-label={label}
          tabIndex={0}
          onClick={toggle}
          onKeyDown={(e) => {
            if (e.key === ' ' || e.key === 'Enter') {
              e.preventDefault()
              onToggle()
            }
          }}
          className={cn(rowProps.className, 'cursor-pointer gap-3 px-3', padY, focusRing)}
        >
          {circle}
          {details}
        </div>
      )}
    </div>
  )
}
