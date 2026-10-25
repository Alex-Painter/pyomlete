import { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { cn } from '@/lib/utils'

/**
 * One toast at a time, with Undo. Mirrors an iOS "undo" banner.
 *
 * Two ways to use it:
 * - The change already happened (a check-off): pass `onUndo` to reverse it.
 * - The change should wait (a delete): pass `onCommit` too. It runs when the
 *   toast times out, when another toast replaces it, or when the page closes,
 *   and never if Undo was pressed.
 */
type UndoOptions = {
  message: string
  /** Leave out for a plain confirmation with no Undo. */
  onUndo?: () => void
  onCommit?: () => void
  /** A second button beside Undo, such as Open. */
  action?: { label: string; onSelect: () => void }
  /** Defaults to 5s. */
  duration?: number
}

type Entry = UndoOptions & { key: number }

const UndoContext = createContext<(opts: UndoOptions) => void>(() => {})

export function useUndo() {
  return useContext(UndoContext)
}

export function UndoProvider({
  children,
  fullscreen = false,
}: {
  children: ReactNode
  /** No tab bar on screen, so the toast can sit lower. */
  fullscreen?: boolean
}) {
  const [entry, setEntry] = useState<Entry | null>(null)
  const entryRef = useRef<Entry | null>(null)
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const keyRef = useRef(0)

  const settle = useCallback((commit: boolean) => {
    const current = entryRef.current
    if (timer.current) clearTimeout(timer.current)
    timer.current = null
    entryRef.current = null
    setEntry(null)
    if (current && commit) current.onCommit?.()
  }, [])

  const show = useCallback(
    (opts: UndoOptions) => {
      // A new action commits the one before it.
      if (entryRef.current) settle(true)
      const next = { ...opts, key: ++keyRef.current }
      entryRef.current = next
      setEntry(next)
      timer.current = setTimeout(() => settle(true), opts.duration ?? 5000)
    },
    [settle],
  )

  useEffect(() => {
    const onHide = () => settle(true)
    window.addEventListener('pagehide', onHide)
    return () => window.removeEventListener('pagehide', onHide)
  }, [settle])

  return (
    <UndoContext.Provider value={show}>
      {children}
      <div
        aria-live="polite"
        className={cn(
          'pointer-events-none fixed inset-x-0 z-[60] flex justify-center px-4',
          fullscreen
            ? 'bottom-[calc(1rem+env(safe-area-inset-bottom))]'
            : 'bottom-[calc(4.5rem+env(safe-area-inset-bottom))] sm:bottom-6',
        )}
      >
        {entry && (
          <div
            key={entry.key}
            role="status"
            className="pointer-events-auto flex w-full max-w-md items-center gap-3 rounded-xl bg-ink px-4 py-3 text-sm text-white shadow-lg animate-in fade-in slide-in-from-bottom-2"
          >
            <span className="min-w-0 flex-1 line-clamp-2">{entry.message}</span>
            {entry.action && (
              <button
                type="button"
                onClick={() => {
                  const current = entryRef.current
                  settle(true)
                  current?.action?.onSelect()
                }}
                className="-my-2 min-h-[44px] rounded-md px-3 font-semibold text-white"
              >
                {entry.action.label}
              </button>
            )}
            {entry.onUndo && (
              <button
                type="button"
                onClick={() => {
                  const current = entryRef.current
                  settle(false)
                  current?.onUndo?.()
                }}
                className="-my-2 -mr-2 min-h-[44px] rounded-md px-3 font-semibold text-primary"
              >
                Undo
              </button>
            )}
          </div>
        )}
      </div>
    </UndoContext.Provider>
  )
}
