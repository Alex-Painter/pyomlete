/**
 * Error reporting to Sentry from the browser. Off unless VITE_SENTRY_DSN was
 * set when the app was built, so dev and tests send nothing.
 *
 * It reports uncaught errors and rejected promises, and a route that fails to
 * render (the router's error boundary would otherwise swallow it). A failed
 * API call is reported by the server, which knows why.
 */
import * as Sentry from '@sentry/react'

let started = false

export function startMonitoring() {
  const dsn = import.meta.env.VITE_SENTRY_DSN as string | undefined
  if (started || !dsn || typeof window === 'undefined') return
  started = true
  Sentry.init({
    dsn,
    environment:
      (import.meta.env.VITE_SENTRY_ENVIRONMENT as string | undefined) ??
      import.meta.env.MODE,
    // Phones drop signal in the shop; that is what the offline queue is for.
    ignoreErrors: [
      'Failed to fetch',
      'Load failed',
      'NetworkError when attempting to fetch resource.',
    ],
  })
}

export function reportError(error: unknown) {
  if (started) Sentry.captureException(error)
}
