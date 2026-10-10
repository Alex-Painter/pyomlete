import type { ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import { UserRound } from 'lucide-react'

/**
 * A tab's large title, with its actions and the profile button on the right.
 * The iOS large-title navigation bar; Settings lives behind the profile button.
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
    <header className="mb-6 flex items-end gap-3 pt-4 sm:pt-0">
      <div className="min-w-0 flex-1">
        <h1 className="text-3xl font-bold tracking-tight">{title}</h1>
        {subtitle && <p className="mt-1 text-sm text-ink-muted">{subtitle}</p>}
      </div>
      {actions}
      <Link
        to="/settings"
        aria-label="Settings"
        className="flex size-11 shrink-0 items-center justify-center rounded-full bg-white text-ink-soft shadow-sm ring-1 ring-line hover:text-ink sm:hidden"
      >
        <UserRound className="size-5" />
      </Link>
    </header>
  )
}
