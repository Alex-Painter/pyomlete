/**
 * PostHog in the browser: page views, clicks and errors. Off unless
 * VITE_POSTHOG_KEY was set when the app was built, so dev and tests send
 * nothing. What the household does (recipes, lists, weeks, Chef) is recorded
 * by the server, which sees Chef's changes too.
 *
 * It reports uncaught errors and rejected promises, and a route that fails to
 * render (the router's error boundary would otherwise swallow it).
 */
import posthog from 'posthog-js'

let started = false

export function startAnalytics() {
  const key = import.meta.env.VITE_POSTHOG_KEY as string | undefined
  if (started || !key || typeof window === 'undefined') return
  started = true
  posthog.init(key, {
    api_host:
      (import.meta.env.VITE_POSTHOG_HOST as string | undefined) ??
      'https://eu.i.posthog.com',
    // Pins behaviour to this snapshot of PostHog's defaults, which counts a
    // route change as a page view.
    defaults: '2026-08-30',
    capture_exceptions: true,
    // No accounts, so no person profiles.
    person_profiles: 'identified_only',
  })
}

export function reportError(error: unknown) {
  if (started) posthog.captureException(error)
}
