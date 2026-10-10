import type { ReactNode } from 'react'
import { Dialog } from 'radix-ui'
import { X } from 'lucide-react'
import { cn } from '@/lib/utils'

/**
 * Every overlay in the app. On a phone it's a bottom sheet with a grabber,
 * at half or full height (a SwiftUI `.sheet` with `.presentationDetents`);
 * on a wider screen it's a centred panel.
 */
export function BottomSheet({
  open,
  onOpenChange,
  title,
  description,
  children,
  footer,
  height = 'auto',
  hideTitle = false,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  title: string
  description?: string
  children: ReactNode
  /** Pinned under the scrolling body, e.g. Save / Delete. */
  footer?: ReactNode
  height?: 'auto' | 'half' | 'full'
  hideTitle?: boolean
}) {
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-50 bg-black/40 data-[state=open]:animate-in data-[state=open]:fade-in-0 data-[state=closed]:animate-out data-[state=closed]:fade-out-0" />
        <Dialog.Content
          className={cn(
            'fixed z-50 flex flex-col bg-white text-ink shadow-xl outline-none',
            // Phone: pinned to the bottom edge.
            'inset-x-0 bottom-0 rounded-t-2xl pb-[env(safe-area-inset-bottom)]',
            'data-[state=open]:animate-in data-[state=open]:slide-in-from-bottom data-[state=closed]:animate-out data-[state=closed]:slide-out-to-bottom',
            height === 'full' && 'h-[92dvh]',
            height === 'half' && 'max-h-[92dvh] min-h-[50dvh]',
            height === 'auto' && 'max-h-[92dvh]',
            // Wider screens: a centred panel.
            'sm:inset-x-auto sm:bottom-auto sm:left-1/2 sm:top-[8vh] sm:w-full sm:max-w-lg sm:-translate-x-1/2 sm:rounded-2xl sm:pb-0 sm:data-[state=open]:slide-in-from-bottom-4',
            height === 'full' && 'sm:h-[84vh]',
            height !== 'full' && 'sm:max-h-[84vh]',
          )}
        >
          <div className="mx-auto mt-2 h-1.5 w-10 shrink-0 rounded-full bg-line sm:hidden" aria-hidden />
          <div className={cn('flex items-start gap-3 px-4 pt-3 pb-2', hideTitle && 'sr-only')}>
            <div className="min-w-0 flex-1">
              <Dialog.Title className="text-lg font-semibold">{title}</Dialog.Title>
              {description ? (
                <Dialog.Description className="text-sm text-ink-muted">{description}</Dialog.Description>
              ) : (
                <Dialog.Description className="sr-only">{title}</Dialog.Description>
              )}
            </div>
            <Dialog.Close
              aria-label="Close"
              className="-mr-2 -mt-1 flex size-11 shrink-0 items-center justify-center rounded-full text-ink-muted hover:bg-sand hover:text-ink"
            >
              <X className="size-5" />
            </Dialog.Close>
          </div>
          <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-4 pb-4">{children}</div>
          {footer && <div className="border-t border-line px-4 py-3">{footer}</div>}
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}

export type SheetAction = {
  label: string
  onSelect: () => void
  destructive?: boolean
  icon?: ReactNode
}

/**
 * A list of choices, with destructive ones in red: an iOS action sheet.
 * Replaces every browser `confirm()`.
 */
export function ActionSheet({
  open,
  onOpenChange,
  title,
  message,
  actions,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  title: string
  message?: string
  actions: SheetAction[]
}) {
  return (
    <BottomSheet open={open} onOpenChange={onOpenChange} title={title} description={message}>
      <div className="space-y-2 pt-1">
        {actions.map((a) => (
          <button
            key={a.label}
            type="button"
            onClick={() => {
              onOpenChange(false)
              a.onSelect()
            }}
            className={cn(
              'flex min-h-[48px] w-full items-center gap-3 rounded-xl bg-cream px-4 text-left text-base font-medium hover:bg-sand',
              a.destructive ? 'text-danger' : 'text-ink',
            )}
          >
            {a.icon}
            {a.label}
          </button>
        ))}
        <button
          type="button"
          onClick={() => onOpenChange(false)}
          className="flex min-h-[48px] w-full items-center justify-center rounded-xl px-4 text-base font-semibold text-ink-soft hover:bg-sand"
        >
          Cancel
        </button>
      </div>
    </BottomSheet>
  )
}
