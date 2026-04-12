import {
  HeadContent,
  Link,
  Scripts,
  createRootRouteWithContext,
} from '@tanstack/react-router'
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
        content: 'width=device-width, initial-scale=1',
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
    'px-3 py-1.5 rounded-md text-sm font-medium transition-colors'
  const activeClass = 'text-white bg-slate-700'
  const inactiveClass = 'text-slate-400 hover:text-slate-200'

  return (
    <nav className="bg-slate-900 border-b border-slate-800">
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
  )
}

function RootDocument({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className="dark">
      <head>
        <HeadContent />
      </head>
      <body className="bg-slate-900">
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
