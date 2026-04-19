import {
  HeadContent,
  Link,
  Scripts,
  createRootRouteWithContext,
} from '@tanstack/react-router'
import { List, BookOpen, PlusCircle, Settings } from 'lucide-react'
import { TanStackRouterDevtoolsPanel } from '@tanstack/react-router-devtools'
import { TanStackDevtools } from '@tanstack/react-devtools'

import TanStackQueryProvider from '../integrations/tanstack-query/root-provider'

import TanStackQueryDevtools from '../integrations/tanstack-query/devtools'
import type { QueryClient } from '@tanstack/react-query'

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
        name: 'viewport',
        content: 'width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover',
      },
      {
        title: 'Omlete',
      },
    ],
  }),
  shellComponent: RootDocument,
})

function NavBar() {
  const linkClass =
    'px-3 py-2 rounded-md text-sm font-medium transition-colors min-h-[44px] flex items-center'
  const activeClass = 'text-white bg-slate-700'
  const inactiveClass = 'text-slate-400 hover:text-slate-200'

  const mobileLinkClass =
    'flex flex-col items-center justify-center gap-1 text-xs font-medium transition-colors min-h-[44px] flex-1'
  const mobileActiveClass = 'text-white'
  const mobileInactiveClass = 'text-slate-500'

  return (
    <>
      {/* Desktop top nav */}
      <nav className="hidden sm:block bg-slate-900 border-b border-slate-800">
        <div className="max-w-2xl mx-auto px-4 flex items-center gap-6 h-14">
          <Link to="/" className="text-xl font-bold tracking-tight text-white mr-4">
            Omlete
          </Link>
          <Link
            to="/"
            className={linkClass}
            activeProps={{ className: `${linkClass} ${activeClass}` }}
            inactiveProps={{ className: `${linkClass} ${inactiveClass}` }}
            activeOptions={{ exact: true }}
          >
            Lists
          </Link>
          <Link
            to="/recipes"
            className={linkClass}
            activeProps={{ className: `${linkClass} ${activeClass}` }}
            inactiveProps={{ className: `${linkClass} ${inactiveClass}` }}
          >
            Recipes
          </Link>
          <Link
            to="/create"
            className={linkClass}
            activeProps={{ className: `${linkClass} ${activeClass}` }}
            inactiveProps={{ className: `${linkClass} ${inactiveClass}` }}
          >
            Create
          </Link>
          <div className="flex-1" />
          <Link
            to="/settings"
            className={linkClass}
            activeProps={{ className: `${linkClass} ${activeClass}` }}
            inactiveProps={{ className: `${linkClass} ${inactiveClass}` }}
          >
            Settings
          </Link>
        </div>
      </nav>

      {/* Mobile bottom tab bar */}
      <nav className="sm:hidden fixed bottom-0 left-0 right-0 z-50 bg-slate-900 border-t border-slate-800 safe-area-bottom">
        <div className="flex items-center h-14">
          <Link
            to="/"
            className={mobileLinkClass}
            activeProps={{ className: `${mobileLinkClass} ${mobileActiveClass}` }}
            inactiveProps={{ className: `${mobileLinkClass} ${mobileInactiveClass}` }}
            activeOptions={{ exact: true }}
          >
            <List className="size-5" />
            Lists
          </Link>
          <Link
            to="/recipes"
            className={mobileLinkClass}
            activeProps={{ className: `${mobileLinkClass} ${mobileActiveClass}` }}
            inactiveProps={{ className: `${mobileLinkClass} ${mobileInactiveClass}` }}
          >
            <BookOpen className="size-5" />
            Recipes
          </Link>
          <Link
            to="/create"
            className={mobileLinkClass}
            activeProps={{ className: `${mobileLinkClass} ${mobileActiveClass}` }}
            inactiveProps={{ className: `${mobileLinkClass} ${mobileInactiveClass}` }}
          >
            <PlusCircle className="size-5" />
            Create
          </Link>
          <Link
            to="/settings"
            className={mobileLinkClass}
            activeProps={{ className: `${mobileLinkClass} ${mobileActiveClass}` }}
            inactiveProps={{ className: `${mobileLinkClass} ${mobileInactiveClass}` }}
          >
            <Settings className="size-5" />
            Settings
          </Link>
        </div>
      </nav>
    </>
  )
}

function RootDocument({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className="dark">
      <head>
        <HeadContent />
      </head>
      <body className="bg-slate-900 pb-16 sm:pb-0">
        <TanStackQueryProvider>
          <NavBar />
          {children}
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
        </TanStackQueryProvider>
        <Scripts />
      </body>
    </html>
  )
}
