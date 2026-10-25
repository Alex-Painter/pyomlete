import { Check } from 'lucide-react'
import { cn } from '@/lib/utils'

/**
 * Cooked, or not yet, for a meal on a list. The same size either way, so
 * marking a meal cooked never moves anything (see docs/DESIGN.md).
 */
export function CookedToggle({
  cooked,
  title,
  onChange,
  className,
}: {
  cooked: boolean
  title: string
  onChange: (cooked: boolean) => void
  className?: string
}) {
  return (
    <button
      type="button"
      aria-pressed={cooked}
      aria-label={`${title} cooked`}
      onClick={() => onChange(!cooked)}
      className={cn(
        'flex min-h-[44px] shrink-0 items-center gap-1.5 rounded-xl px-3 text-sm font-semibold',
        cooked ? 'bg-sand text-ink' : 'text-ink-soft hover:bg-sand hover:text-ink',
        className,
      )}
    >
      <CookedMark cooked={cooked} />
      Cooked
    </button>
  )
}

/** The round mark, shared with the badge, in the style of a list item's check. */
function CookedMark({ cooked, className }: { cooked: boolean; className?: string }) {
  return (
    <span
      aria-hidden
      className={cn(
        'flex size-5 shrink-0 items-center justify-center rounded-full border-2',
        cooked ? 'border-primary bg-primary text-ink' : 'border-ink-faint bg-white',
        className,
      )}
    >
      {cooked && <Check className="size-3" strokeWidth={3} />}
    </span>
  )
}

/**
 * A small mark over a meal's photo once it's cooked, with the word unless
 * `compact`. Shows nothing otherwise. Its parent must be `relative`.
 */
export function CookedBadge({
  cooked,
  compact = false,
  className,
}: {
  cooked: boolean
  compact?: boolean
  className?: string
}) {
  if (!cooked) return null
  if (compact) {
    return (
      <span className={cn('pointer-events-none absolute left-1 top-1 rounded-full bg-white p-0.5 shadow-sm', className)}>
        <CookedMark cooked className="size-4 border-0" />
        <span className="sr-only">Cooked</span>
      </span>
    )
  }
  return (
    <span
      className={cn(
        'pointer-events-none absolute left-1 top-1 flex items-center gap-1 rounded-full bg-white/95 py-0.5 pl-0.5 pr-2 text-xs font-semibold text-ink shadow-sm',
        className,
      )}
    >
      <CookedMark cooked className="size-4 border-0" />
      Cooked
    </span>
  )
}
