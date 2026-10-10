import { AlertCircle, WifiOff } from 'lucide-react'
import { ApiError } from '@/lib/api'
import { Button } from '@/components/ui/button'

/** Shown instead of an empty or half-drawn page when a request fails. */
export function ErrorState({
  error,
  onRetry,
  notFoundMessage = "This doesn't exist any more.",
}: {
  error: unknown
  onRetry?: () => void
  notFoundMessage?: string
}) {
  const offline = !(error instanceof ApiError)
  const notFound = error instanceof ApiError && error.status === 404
  const Icon = offline ? WifiOff : AlertCircle
  return (
    <div role="alert" className="flex flex-col items-center gap-3 py-16 text-center">
      <Icon className="size-8 text-ink-muted" />
      <p className="max-w-xs text-ink-soft">
        {notFound
          ? notFoundMessage
          : offline
            ? "Couldn't reach Omlete. Check your connection."
            : 'Something went wrong loading this.'}
      </p>
      {onRetry && !notFound && (
        <Button variant="outline" onClick={onRetry} className="min-h-[44px]">
          Try again
        </Button>
      )}
    </div>
  )
}
