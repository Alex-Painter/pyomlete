import { createFileRoute, Link } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Loader2 } from 'lucide-react'
import { apiFetch } from '@/lib/api'
import { StarRating } from '@/components/StarRating'
import '@/index.css'

type RecipeSummary = {
  id: string
  title: string
  ingredient_count: number
  rating: number | null
  created_at: string | null
}

export const Route = createFileRoute('/recipes')({ component: RecipeList })

function RecipeList() {
  const queryClient = useQueryClient()

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

  return (
    <div className="min-h-screen bg-linear-to-b from-slate-900 via-slate-800 to-slate-900 text-white">
      <div className="max-w-2xl mx-auto px-4 py-12">
        <h1 className="text-2xl font-bold tracking-tight mb-8">My Recipes</h1>

        {isLoading && (
          <div className="flex items-center gap-2 text-slate-400">
            <Loader2 className="size-5 animate-spin" />
            Loading recipes...
          </div>
        )}

        {recipes && recipes.length === 0 && (
          <div className="text-center py-16">
            <p className="text-slate-400 mb-4">No recipes yet.</p>
            <Link
              to="/"
              className="text-sm text-slate-300 hover:text-white underline underline-offset-4 transition-colors"
            >
              Create your first recipe
            </Link>
          </div>
        )}

        {recipes && recipes.length > 0 && (
          <div className="space-y-3">
            {recipes.map((recipe) => (
              <div
                key={recipe.id}
                className="bg-slate-800 border border-slate-700 rounded-xl p-5 flex items-center gap-4"
              >
                <div className="flex-1 min-w-0">
                  <Link
                    to="/recipe/$recipeId"
                    params={{ recipeId: recipe.id }}
                    className="text-white font-medium hover:underline underline-offset-4"
                  >
                    {recipe.title}
                  </Link>
                  <div className="flex items-center gap-3 mt-1.5 text-sm text-slate-400">
                    <span>{recipe.ingredient_count} ingredient{recipe.ingredient_count !== 1 ? 's' : ''}</span>
                    <span className="text-slate-600">·</span>
                    <span>
                      {recipe.created_at
                        ? new Date(recipe.created_at).toLocaleDateString()
                        : 'Unknown date'}
                    </span>
                  </div>
                </div>
                <StarRating
                  value={recipe.rating}
                  onChange={(rating) =>
                    ratingMutation.mutate({ id: recipe.id, rating })
                  }
                />
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
