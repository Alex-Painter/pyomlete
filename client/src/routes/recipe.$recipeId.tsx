import { createFileRoute, Link } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ArrowLeft, Loader2 } from 'lucide-react'
import { apiFetch } from '@/lib/api'
import { RecipeCard } from '@/components/RecipeCard'
import { StarRating } from '@/components/StarRating'
import type { Recipe } from '@/components/RecipeCard'
import '@/index.css'

type RecipeDetail = Recipe & {
  _id: string
  rating: number | null
  created_at: string
}

export const Route = createFileRoute('/recipe/$recipeId')({
  component: RecipeDetailPage,
})

function RecipeDetailPage() {
  const { recipeId } = Route.useParams()
  const queryClient = useQueryClient()

  const { data: recipe, isLoading } = useQuery({
    queryKey: ['recipe', recipeId],
    queryFn: async (): Promise<RecipeDetail> => {
      const res = await apiFetch(`/api/recipes/${recipeId}`)
      if (!res.ok) throw new Error('Recipe not found')
      return res.json()
    },
  })

  const ratingMutation = useMutation({
    mutationFn: async (rating: number) => {
      const res = await apiFetch(`/api/recipes/${recipeId}/rating`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rating }),
      })
      return res.json()
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['recipe', recipeId] })
      queryClient.invalidateQueries({ queryKey: ['recipes'] })
    },
  })

  return (
    <div className="min-h-screen bg-linear-to-b from-slate-900 via-slate-800 to-slate-900 text-white">
      <div className="max-w-2xl mx-auto px-4 py-12">
        <Link
          to="/recipes"
          className="inline-flex items-center gap-1.5 text-sm text-slate-400 hover:text-white transition-colors mb-8"
        >
          <ArrowLeft className="size-4" />
          Back to recipes
        </Link>

        {isLoading && (
          <div className="flex items-center gap-2 text-slate-400">
            <Loader2 className="size-5 animate-spin" />
            Loading recipe...
          </div>
        )}

        {recipe && (
          <div className="space-y-6">
            <div className="flex items-center justify-between">
              <div className="text-sm text-slate-400">
                {recipe.created_at
                  ? new Date(recipe.created_at).toLocaleDateString()
                  : ''}
              </div>
              <div className="flex items-center gap-3">
                <span className="text-sm text-slate-400">Rate this recipe</span>
                <StarRating
                  value={recipe.rating}
                  onChange={(rating) => ratingMutation.mutate(rating)}
                />
              </div>
            </div>
            <RecipeCard recipe={recipe} />
          </div>
        )}
      </div>
    </div>
  )
}
