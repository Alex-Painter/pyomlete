import type { ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import { Settings } from 'lucide-react'

/**
 * A tab's large title, with its actions and the settings button on the right.
 * The iOS large-title navigation bar; Settings lives behind the cog.
 */
export function PageHeader({
  title,
  subtitle,
  actions,
}: {
  title: string
  subtitle?: ReactNode
  actions?: ReactNode
}) {
  return (
    <header className="safe-area-top mb-5 sm:mb-6">
      {/* Title and buttons share a row; the subtitle gets the full width
          below, so it doesn't wrap into a narrow column on phones. */}
      <div className="flex items-center gap-2">
        <h1 className="min-w-0 flex-1 truncate text-3xl font-bold tracking-tight">
          {title}
        </h1>
        {actions}
        <Link
          to="/settings"
          aria-label="Settings"
          className="flex size-11 shrink-0 items-center justify-center rounded-full bg-white text-ink-soft shadow-sm ring-1 ring-line hover:text-ink sm:hidden"
        >
          <Settings className="size-5" />
        </Link>
      </div>
      {subtitle && <p className="mt-1 text-sm text-ink-muted">{subtitle}</p>}
    </header>
  )
}
