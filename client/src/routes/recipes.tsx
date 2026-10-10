import { useEffect, useState } from 'react'
import { createFileRoute, Link, useNavigate } from '@tanstack/react-router'
import { BookOpen, Clock, LayoutGrid, List, Loader2, Search, Star } from 'lucide-react'
import { ErrorState } from '@/components/ErrorState'
import { PageHeader } from '@/components/PageHeader'
import { RecipeThumb } from '@/components/RecipeThumb'
import { formatMinutes } from '@/components/RecipeMetaRow'
import { useRecipes } from '@/lib/queries'
import type { RecipeSummary } from '@/lib/types'
import { cn } from '@/lib/utils'

type Sort = 'newest' | 'rating' | 'quickest' | 'az'
type Filter = 'favourites' | 'quick' | 'web'

type LibrarySearch = { q?: string; sort?: Sort; filter?: Filter }

const SORTS: Record<Sort, string> = {
  newest: 'Newest',
  rating: 'Top rated',
  quickest: 'Quickest',
  az: 'A–Z',
}

const FILTERS: Record<Filter, string> = {
  favourites: '4★ and up',
  quick: 'Under 30 min',
  web: 'From the web',
}

export const Route = createFileRoute('/recipes')({
  component: RecipeLibrary,
  // Search, filter and sort live in the URL so they restore and can be shared.
  validateSearch: (s: Record<string, unknown>): LibrarySearch => ({
    q: typeof s.q === 'string' && s.q ? s.q : undefined,
    sort: typeof s.sort === 'string' && s.sort in SORTS ? (s.sort as Sort) : undefined,
    filter: typeof s.filter === 'string' && s.filter in FILTERS ? (s.filter as Filter) : undefined,
  }),
})

type ViewMode = 'list' | 'grid'
const VIEW_STORAGE_KEY = 'recipes-view'

function applyLibrary(recipes: RecipeSummary[], { q, sort = 'newest', filter }: LibrarySearch) {
  const needle = q?.trim().toLowerCase()
  let out = recipes.filter((r) => !needle || r.title.toLowerCase().includes(needle))
  if (filter === 'favourites') out = out.filter((r) => (r.rating ?? 0) >= 4)
  if (filter === 'quick') out = out.filter((r) => r.total_minutes != null && r.total_minutes <= 30)
  if (filter === 'web') out = out.filter((r) => r.source_name != null)
  const sorted = [...out]
  if (sort === 'rating') sorted.sort((a, b) => (b.rating ?? 0) - (a.rating ?? 0))
  if (sort === 'quickest')
    sorted.sort((a, b) => (a.total_minutes ?? Infinity) - (b.total_minutes ?? Infinity))
  if (sort === 'az') sorted.sort((a, b) => a.title.localeCompare(b.title))
  return sorted
}

function RecipeLibrary() {
  const search = Route.useSearch()
  const navigate = useNavigate({ from: Route.fullPath })
  const { data: recipes, isLoading, error, refetch } = useRecipes()
  const [view, setView] = useState<ViewMode>('grid')
  const [query, setQuery] = useState(search.q ?? '')

  useEffect(() => {
    try {
      if (window.localStorage.getItem(VIEW_STORAGE_KEY) === 'list') setView('list')
    } catch {
      // Defaults to grid.
    }
  }, [])

  const setSearch = (next: LibrarySearch) =>
    void navigate({ search: (prev) => ({ ...prev, ...next }), replace: true })

  const chooseView = (v: ViewMode) => {
    setView(v)
    try {
      window.localStorage.setItem(VIEW_STORAGE_KEY, v)
    } catch {
      // Not remembered; fine.
    }
  }

  const shown = recipes ? applyLibrary(recipes, search) : []

  return (
    <main className="min-h-screen bg-cream text-ink">
      <div className="mx-auto max-w-5xl px-4 py-6 sm:px-6 sm:py-10">
        <PageHeader title="Recipes" subtitle={recipes ? `${recipes.length} saved` : undefined} />

        {recipes && recipes.length > 0 && (
          <div className="mb-5 space-y-3">
            <div className="flex gap-2">
              <label className="relative min-w-0 flex-1">
                <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-ink-muted" />
                <input
                  type="search"
                  value={query}
                  onChange={(e) => {
                    setQuery(e.target.value)
                    setSearch({ q: e.target.value || undefined })
                  }}
                  placeholder="Search recipes"
                  aria-label="Search recipes"
                  className="h-11 w-full rounded-xl border border-line bg-white pl-9 pr-3 text-base outline-none focus:ring-2 focus:ring-ring"
                />
              </label>
              <select
                value={search.sort ?? 'newest'}
                onChange={(e) => setSearch({ sort: e.target.value as Sort })}
                aria-label="Sort"
                className="h-11 rounded-xl border border-line bg-white px-3 text-sm"
              >
                {Object.entries(SORTS).map(([v, label]) => (
                  <option key={v} value={v}>
                    {label}
                  </option>
                ))}
              </select>
              <div className="hidden items-center gap-1 rounded-xl border border-line bg-white p-1 sm:flex">
                {(['grid', 'list'] as const).map((v) => (
                  <button
                    key={v}
                    type="button"
                    aria-label={v === 'grid' ? 'Grid view' : 'List view'}
                    aria-pressed={view === v}
                    onClick={() => chooseView(v)}
                    className={cn(
                      'flex size-9 items-center justify-center rounded-lg text-ink-muted hover:text-ink',
                      view === v && 'bg-sand text-ink',
                    )}
                  >
                    {v === 'grid' ? <LayoutGrid className="size-4" /> : <List className="size-4" />}
                  </button>
                ))}
              </div>
            </div>
            <div className="no-scrollbar -mx-4 flex gap-2 overflow-x-auto px-4 sm:mx-0 sm:px-0">
              {(Object.keys(FILTERS) as Filter[]).map((f) => (
                <button
                  key={f}
                  type="button"
                  aria-pressed={search.filter === f}
                  onClick={() => setSearch({ filter: search.filter === f ? undefined : f })}
                  className={cn(
                    'min-h-[36px] shrink-0 rounded-full border px-3.5 text-sm',
                    search.filter === f
                      ? 'border-ink bg-ink text-white'
                      : 'border-line bg-white text-ink-soft hover:bg-sand',
                  )}
                >
                  {FILTERS[f]}
                </button>
              ))}
            </div>
          </div>
        )}

        {isLoading && (
          <div className="flex items-center gap-2 text-ink-muted">
            <Loader2 className="size-5 animate-spin" />
            Loading recipes…
          </div>
        )}

        {error && <ErrorState error={error} onRetry={() => void refetch()} />}

        {recipes && recipes.length === 0 && (
          <div className="py-16 text-center">
            <BookOpen className="mx-auto mb-4 size-10 text-ink-faint" />
            <p className="mb-1 font-medium text-ink-soft">No recipes yet</p>
            <p className="mb-5 text-sm text-ink-muted">
              Paste a link, describe a dish, or save one from Discover.
            </p>
            <div className="flex justify-center gap-2">
              <Link to="/create" className="flex min-h-[44px] items-center rounded-lg bg-primary px-4 font-semibold">
                Add a recipe
              </Link>
              <Link to="/discover" className="flex min-h-[44px] items-center rounded-lg border border-line bg-white px-4 font-medium">
                Browse Discover
              </Link>
            </div>
          </div>
        )}

        {recipes && recipes.length > 0 && shown.length === 0 && (
          <p className="py-10 text-center text-ink-muted">Nothing matches. Try another search or filter.</p>
        )}

        {shown.length > 0 && view === 'grid' && (
          <ul className="grid grid-cols-2 gap-3 sm:gap-4 lg:grid-cols-3">
            {shown.map((r) => (
              <li key={r.id}>
                <Link
                  to="/recipe/$recipeId"
                  params={{ recipeId: r.id }}
                  className="flex h-full flex-col overflow-hidden rounded-2xl border border-line bg-white shadow-sm transition-shadow hover:shadow-md"
                >
                  <RecipeThumb src={r.image_url} title={r.title} className="aspect-[4/3] w-full" />
                  <div className="flex flex-1 flex-col gap-1 p-3">
                    <h2 className="line-clamp-2 font-semibold leading-snug">{r.title}</h2>
                    <Meta recipe={r} />
                  </div>
                </Link>
              </li>
            ))}
          </ul>
        )}

        {shown.length > 0 && view === 'list' && (
          <ul className="space-y-2">
            {shown.map((r) => (
              <li key={r.id}>
                <Link
                  to="/recipe/$recipeId"
                  params={{ recipeId: r.id }}
                  className="flex items-center gap-3 rounded-2xl border border-line bg-white p-2 pr-4 shadow-sm hover:shadow-md"
                >
                  <RecipeThumb src={r.image_url} title={r.title} className="size-16 shrink-0 rounded-xl" />
                  <div className="min-w-0 flex-1">
                    <h2 className="font-semibold leading-snug">{r.title}</h2>
                    <Meta recipe={r} />
                  </div>
                </Link>
              </li>
            ))}
          </ul>
        )}
      </div>
    </main>
  )
}

function Meta({ recipe }: { recipe: RecipeSummary }) {
  return (
    <p className="flex flex-wrap items-center gap-x-2.5 gap-y-0.5 text-sm text-ink-muted">
      {recipe.rating != null && (
        <span className="flex items-center gap-0.5" aria-label={`${recipe.rating} stars`}>
          <Star className="size-3.5 fill-[#e0a800] text-[#e0a800]" />
          {recipe.rating}
        </span>
      )}
      {recipe.total_minutes != null && (
        <span className="flex items-center gap-1">
          <Clock className="size-3.5" />
          {formatMinutes(recipe.total_minutes)}
        </span>
      )}
      {recipe.source_name && <span className="truncate">{recipe.source_name}</span>}
    </p>
  )
}
