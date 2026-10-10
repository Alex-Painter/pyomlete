/**
 * App shell. Omlete's driving principle is "eat better and reduce cognitive
 * load" (docs/PRINCIPLES.md): four modes (Explore, Plan, Shop, Cook) are
 * separate entry points the user moves between freely, and nothing here ever
 * switches mode because a step finished.
 */
import { useEffect } from 'react'
import {
  HeadContent,
  Link,
  Scripts,
  createRootRouteWithContext,
  useRouterState,
} from '@tanstack/react-router'
import { BookOpen, Compass, List, Plus, Settings } from 'lucide-react'
import { TanStackRouterDevtoolsPanel } from '@tanstack/react-router-devtools'
import { TanStackDevtools } from '@tanstack/react-devtools'

import TanStackQueryProvider from '../integrations/tanstack-query/root-provider'

import TanStackQueryDevtools from '../integrations/tanstack-query/devtools'
import type { QueryClient } from '@tanstack/react-query'
import { UndoProvider } from '@/components/UndoToast'
import { flushQueue, makeAllDue } from '@/lib/offline'
import { cn } from '@/lib/utils'

interface MyRouterContext {
  queryClient: QueryClient
}

export const Route = createRootRouteWithContext<MyRouterContext>()({
  head: () => ({
    meta: [
      {
        charSet: 'utf-8',
      },
      {
        // No maximum-scale: pinch zoom stays available. Inputs are 16px on
        // phones (index.css), which is what stops Safari zooming into them.
        name: 'viewport',
        content: 'width=device-width, initial-scale=1, viewport-fit=cover',
      },
      {
        title: 'Omlete',
      },
      {
        name: 'description',
        content: 'Eat better with less thinking: easy lists, fresh ideas, cooking made simple.',
      },
      {
        name: 'theme-color',
        content: '#f4f4f4',
      },
      {
        name: 'application-name',
        content: 'Omlete',
      },
      {
        name: 'apple-mobile-web-app-capable',
        content: 'yes',
      },
      {
        name: 'mobile-web-app-capable',
        content: 'yes',
      },
      {
        name: 'apple-mobile-web-app-title',
        content: 'Omlete',
      },
      {
        name: 'apple-mobile-web-app-status-bar-style',
        content: 'default',
      },
    ],
    links: [
      { rel: 'preconnect', href: 'https://fonts.googleapis.com' },
      { rel: 'stylesheet', href: 'https://fonts.googleapis.com/css2?family=DM+Sans:ital,opsz,wght@0,9..40,400;0,9..40,500;0,9..40,600;0,9..40,700;0,9..40,800&display=swap' },
      { rel: 'manifest', href: '/manifest.webmanifest' },
      { rel: 'icon', href: '/favicon.ico', sizes: 'any' },
      { rel: 'icon', type: 'image/svg+xml', href: '/icon.svg' },
      { rel: 'apple-touch-icon', href: '/apple-touch-icon.png' },
    ],
  }),
  shellComponent: RootDocument,
})

/** Shop and Cook take the whole screen: no tab bar, nothing else to tap. */
function useFullscreenMode() {
  const pathname = useRouterState({ select: (s) => s.location.pathname })
  return pathname.startsWith('/shop/') || pathname.startsWith('/cook/')
}

const TABS = [
  { to: '/', label: 'Lists', icon: List, exact: true },
  { to: '/discover', label: 'Discover', icon: Compass, exact: false },
  { to: '/recipes', label: 'Recipes', icon: BookOpen, exact: false },
] as const

function NavBar() {
  const desktopLink =
    'px-3 py-2 rounded-md text-sm font-medium transition-colors min-h-[44px] flex items-center'

  const mobileLink =
    'flex flex-col items-center justify-center gap-1 text-[11px] font-medium transition-colors min-h-[52px] flex-1'

  return (
    <>
      {/* Desktop top nav, the same width as the pages under it */}
      <nav className="hidden sm:block bg-white border-b border-line sticky top-0 z-40">
        <div className="max-w-5xl mx-auto px-6 flex items-center gap-2 h-14">
          <Link to="/" className="text-xl font-bold tracking-tight text-ink mr-6">
            Omlete
          </Link>
          {TABS.map((t) => (
            <Link
              key={t.to}
              to={t.to}
              activeOptions={{ exact: t.exact }}
              className={desktopLink}
              activeProps={{ className: 'text-ink bg-sand' }}
              inactiveProps={{ className: 'text-ink-muted hover:text-ink' }}
            >
              {t.label}
            </Link>
          ))}
          <div className="flex-1" />
          <Link
            to="/create"
            className="flex items-center gap-1.5 rounded-lg bg-primary px-3 min-h-[40px] text-sm font-semibold text-ink shadow-sm hover:bg-primary/90"
          >
            <Plus className="size-4" />
            Add recipe
          </Link>
          <Link
            to="/settings"
            aria-label="Settings"
            className="ml-1 flex size-10 items-center justify-center rounded-full text-ink-muted hover:bg-sand hover:text-ink"
            activeProps={{ className: 'bg-sand text-ink' }}
          >
            <Settings className="size-5" />
          </Link>
        </div>
      </nav>

      {/* Mobile tab bar: Lists, Discover, the central Add, Recipes */}
      <nav
        aria-label="Main"
        className="sm:hidden fixed bottom-0 left-0 right-0 z-50 bg-white/95 backdrop-blur border-t border-line safe-area-bottom"
      >
        <div className="flex items-center h-14">
          {TABS.slice(0, 2).map((t) => (
            <TabLink key={t.to} {...t} className={mobileLink} />
          ))}
          <TabLink to="/create" label="Add" icon={Plus} exact={false} className={mobileLink} />
          <TabLink {...TABS[2]} className={mobileLink} />
        </div>
      </nav>
    </>
  )
}

function TabLink({
  to,
  label,
  icon: Icon,
  exact,
  className,
}: {
  to: string
  label: string
  icon: typeof List
  exact: boolean
  className: string
}) {
  return (
    <Link
      to={to}
      activeOptions={{ exact }}
      className={className}
      activeProps={{ className: 'text-ink' }}
      inactiveProps={{ className: 'text-ink-muted' }}
    >
      {({ isActive }) => (
        <>
          <Icon className="size-6" strokeWidth={isActive ? 2.4 : 1.8} />
          {label}
        </>
      )}
    </Link>
  )
}

/**
 * Keep list changes flowing: send queued changes when the connection comes
 * back, and send deferred deletes (still inside their Undo window) before
 * the page closes.
 */
function OfflineSync() {
  useEffect(() => {
    const flush = () => void flushQueue()
    const onHide = () => {
      makeAllDue()
      void flushQueue({ keepalive: true })
    }
    flush()
    window.addEventListener('online', flush)
    window.addEventListener('pagehide', onHide)
    const interval = setInterval(flush, 30000)
    return () => {
      window.removeEventListener('online', flush)
      window.removeEventListener('pagehide', onHide)
      clearInterval(interval)
    }
  }, [])

  // The service worker keeps the app shell on the phone so a list opened at
  // home still opens in a shop with no signal. Production only: in dev it
  // would serve stale modules.
  useEffect(() => {
    if (import.meta.env.PROD && 'serviceWorker' in navigator) {
      navigator.serviceWorker.register('/sw.js').catch(() => {})
    }
  }, [])
  return null
}

function RootDocument({ children }: { children: React.ReactNode }) {
  const fullscreen = useFullscreenMode()
  return (
    <html lang="en">
      <head>
        <HeadContent />
      </head>
      <body className={cn('bg-cream', fullscreen ? '' : 'pb-[calc(3.5rem+env(safe-area-inset-bottom))] sm:pb-0')}>
        <TanStackQueryProvider>
          <UndoProvider fullscreen={fullscreen}>
            {!fullscreen && <NavBar />}
            {children}
            <OfflineSync />
          </UndoProvider>
          {import.meta.env.DEV && (
            <TanStackDevtools
              config={{
                position: 'bottom-right',
              }}
              plugins={[
                {
                  name: 'Tanstack Router',
                  render: <TanStackRouterDevtoolsPanel />,
                },
                TanStackQueryDevtools,
              ]}
            />
          )}
        </TanStackQueryProvider>
        <Scripts />
      </body>
    </html>
  )
}
