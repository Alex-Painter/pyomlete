import { useEffect, useState } from 'react'
import { createFileRoute, Link } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { LayoutGrid, List, Loader2 } from 'lucide-react'
import { apiFetch } from '@/lib/api'
import { StarRating } from '@/components/StarRating'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import '@/index.css'

type RecipeSummary = {
  id: string
  title: string
  ingredient_count: number
  rating: number | null
  created_at: string | null
}

type ViewMode = 'list' | 'grid'

const VIEW_STORAGE_KEY = 'recipes-view'

function getInitialView(): ViewMode {
  if (typeof window === 'undefined') return 'list'
  return window.localStorage.getItem(VIEW_STORAGE_KEY) === 'grid'
    ? 'grid'
    : 'list'
}

export const Route = createFileRoute('/recipes')({ component: RecipeList })

function RecipeList() {
  const queryClient = useQueryClient()
  const [view, setView] = useState<ViewMode>(getInitialView)

  useEffect(() => {
    window.localStorage.setItem(VIEW_STORAGE_KEY, view)
  }, [view])

  const { data: recipes, isLoading } = useQuery({
    queryKey: ['recipes'],
    queryFn: async (): Promise<RecipeSummary[]> => {
      const res = await apiFetch('/api/recipes/')
      return res.json()
    },
  })

  const ratingMutation = useMutation({
    mutationFn: async ({ id, rating }: { id: string; rating: number }) => {
      const res = await apiFetch(`/api/recipes/${id}/rating`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rating }),
      })
      return res.json()
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['recipes'] })
    },
  })

  const rateRecipe = (id: string, rating: number) =>
    ratingMutation.mutate({ id, rating })

  return (
    <div className="min-h-screen bg-cream text-ink">
      <div className="max-w-5xl mx-auto px-4 py-12">
        <div className="flex items-center justify-between mb-8">
          <h1 className="text-2xl font-bold tracking-tight">My Recipes</h1>
          {recipes && recipes.length > 0 && (
            <div className="flex items-center gap-1 rounded-lg border border-line bg-white p-1">
              <Button
                type="button"
                variant="ghost"
                size="icon-sm"
                aria-label="List view"
                aria-pressed={view === 'list'}
                onClick={() => setView('list')}
                className={cn(
                  'text-ink-muted hover:text-ink',
                  view === 'list' && 'bg-sand text-ink',
                )}
              >
                <List />
              </Button>
              <Button
                type="button"
                variant="ghost"
                size="icon-sm"
                aria-label="Grid view"
                aria-pressed={view === 'grid'}
                onClick={() => setView('grid')}
                className={cn(
                  'text-ink-muted hover:text-ink',
                  view === 'grid' && 'bg-sand text-ink',
                )}
              >
                <LayoutGrid />
              </Button>
            </div>
          )}
        </div>

        {isLoading && (
          <div className="flex items-center gap-2 text-ink-muted">
            <Loader2 className="size-5 animate-spin" />
            Loading recipes...
          </div>
        )}

        {recipes && recipes.length === 0 && (
          <div className="text-center py-16">
            <p className="text-ink-muted mb-4">No recipes yet.</p>
            <Link
              to="/"
              className="text-sm text-ink-soft hover:text-ink underline underline-offset-4 transition-colors"
            >
              Create your first recipe
            </Link>
          </div>
        )}

        {recipes && recipes.length > 0 && view === 'list' && (
          <div className="space-y-3">
            {recipes.map((recipe) => (
              <RecipeListRow
                key={recipe.id}
                recipe={recipe}
                onRate={rateRecipe}
              />
            ))}
          </div>
        )}

        {recipes && recipes.length > 0 && view === 'grid' && (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
            {recipes.map((recipe) => (
              <RecipeGridCard
                key={recipe.id}
                recipe={recipe}
                onRate={rateRecipe}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  )
}

function RecipeMeta({ recipe }: { recipe: RecipeSummary }) {
  return (
    <div className="flex items-center gap-3 mt-1.5 text-sm text-ink-muted">
      <span>
        {recipe.ingredient_count} ingredient
        {recipe.ingredient_count !== 1 ? 's' : ''}
      </span>
      <span className="text-ink-subtle">·</span>
      <span>
        {recipe.created_at
          ? new Date(recipe.created_at).toLocaleDateString()
          : 'Unknown date'}
      </span>
    </div>
  )
}

type RecipeItemProps = {
  recipe: RecipeSummary
  onRate: (id: string, rating: number) => void
}

function RecipeListRow({ recipe, onRate }: RecipeItemProps) {
  return (
    <div className="bg-white border border-line rounded-xl p-5 flex items-center gap-4 shadow-sm">
      <div className="flex-1 min-w-0">
        <Link
          to="/recipe/$recipeId"
          params={{ recipeId: recipe.id }}
          className="text-ink font-medium hover:underline underline-offset-4"
        >
          {recipe.title}
        </Link>
        <RecipeMeta recipe={recipe} />
      </div>
      <StarRating
        value={recipe.rating}
        onChange={(rating) => onRate(recipe.id, rating)}
      />
    </div>
  )
}

function RecipeGridCard({ recipe, onRate }: RecipeItemProps) {
  return (
    <div className="bg-white border border-line rounded-xl p-5 flex flex-col gap-4 h-full shadow-sm">
      <div className="flex-1 min-w-0">
        <Link
          to="/recipe/$recipeId"
          params={{ recipeId: recipe.id }}
          className="text-ink font-medium hover:underline underline-offset-4"
        >
          {recipe.title}
        </Link>
        <RecipeMeta recipe={recipe} />
      </div>
      <StarRating
        value={recipe.rating}
        onChange={(rating) => onRate(recipe.id, rating)}
      />
    </div>
  )
}
