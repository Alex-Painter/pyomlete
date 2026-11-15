/**
 * One tool call in Chef's reply: what Chef reached for, what it asked and,
 * once it's back, what it got. Collapsed to a muted line so the reply still
 * reads as a reply; tap to see the input and result in full.
 */
import { AlertCircle, Check, ChevronRight, Globe, Loader2 } from 'lucide-react'
import { inputHint } from '@/lib/chef'
import type { ChefPart } from '@/lib/chef'
import { cn } from '@/lib/utils'

type ToolPart = Extract<ChefPart, { type: 'tool' }>

export function ChefToolCall({ part }: { part: ToolPart }) {
  const hint = inputHint(part.input)
  return (
    <details className="group text-xs text-ink-muted">
      <summary className="flex min-h-[28px] cursor-pointer list-none items-center gap-1.5 rounded-md hover:text-ink-soft [&::-webkit-details-marker]:hidden">
        <StatusIcon part={part} />
        <span className="shrink-0 font-mono">{part.toolName}</span>
        {hint && <span className="min-w-0 truncate">{hint}</span>}
        <ChevronRight
          className="ml-auto size-3.5 shrink-0 transition-transform group-open:rotate-90"
          aria-hidden
        />
      </summary>
      <div className="mt-1 space-y-1.5 rounded-lg bg-cream p-2">
        <Payload label="Input" value={part.input ?? {}} />
        {part.state === 'running' ? (
          <p>Waiting for the result…</p>
        ) : (
          <Payload
            label={part.state === 'error' ? 'Error' : 'Result'}
            value={part.output}
            error={part.state === 'error'}
          />
        )}
      </div>
    </details>
  )
}

function StatusIcon({ part }: { part: ToolPart }) {
  if (part.state === 'running')
    return part.toolName === 'web_search' ? (
      <Globe className="size-3.5 shrink-0 animate-pulse" aria-label="Running" />
    ) : (
      <Loader2
        className="size-3.5 shrink-0 animate-spin"
        aria-label="Running"
      />
    )
  if (part.state === 'error')
    return (
      <AlertCircle
        className="size-3.5 shrink-0 text-danger"
        aria-label="Failed"
      />
    )
  return <Check className="size-3.5 shrink-0" aria-label="Done" />
}

function Payload({
  label,
  value,
  error,
}: {
  label: string
  value: unknown
  error?: boolean
}) {
  const text =
    value === undefined
      ? ''
      : typeof value === 'string'
        ? value
        : JSON.stringify(value, null, 2)
  return (
    <div>
      <p className="font-semibold text-ink-soft">{label}</p>
      <pre
        className={cn(
          'max-h-48 overflow-auto whitespace-pre-wrap break-words font-mono text-[11px] leading-snug',
          error && 'text-danger',
        )}
      >
        {text}
      </pre>
    </div>
  )
}
