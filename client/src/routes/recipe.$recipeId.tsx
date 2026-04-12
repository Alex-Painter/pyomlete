import { useState } from 'react'
import { createFileRoute, Link } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ArrowLeft, Check, Loader2, ShoppingCart } from 'lucide-react'
import { Button } from '@/components/ui/button'
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

type ListSummary = {
  id: string
  name: string
}

export const Route = createFileRoute('/recipe/$recipeId')({
  component: RecipeDetailPage,
})

function RecipeDetailPage() {
  const { recipeId } = Route.useParams()
  const queryClient = useQueryClient()
  const [addedToList, setAddedToList] = useState<string | null>(null)

  const { data: recipe, isLoading } = useQuery({
    queryKey: ['recipe', recipeId],
    queryFn: async (): Promise<RecipeDetail> => {
      const res = await apiFetch(`/api/recipes/${recipeId}`)
      if (!res.ok) throw new Error('Recipe not found')
      return res.json()
    },
  })

  const { data: lists } = useQuery({
    queryKey: ['lists'],
    queryFn: async (): Promise<ListSummary[]> => {
      const res = await apiFetch('/api/lists/')
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

  const addToList = useMutation({
    mutationFn: async (listId: string) => {
      const res = await apiFetch(`/api/lists/${listId}/recipes`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ recipe_id: recipeId }),
      })
      return res.json()
    },
    onSuccess: (_data, listId) => {
      setAddedToList(listId)
      queryClient.invalidateQueries({ queryKey: ['list', listId] })
      queryClient.invalidateQueries({ queryKey: ['lists'] })
    },
  })

  const mostRecentList = lists?.[0]

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

            {/* Add to list */}
            <div className="flex items-center gap-3">
              {addedToList ? (
                <Link
                  to="/list/$listId"
                  params={{ listId: addedToList }}
                  className="inline-flex items-center gap-2 text-sm text-emerald-400 hover:text-emerald-300 transition-colors"
                >
                  <Check className="size-4" />
                  Added to {mostRecentList?.name} — view list
                </Link>
              ) : mostRecentList ? (
                <Button
                  onClick={() => addToList.mutate(mostRecentList.id)}
                  disabled={addToList.isPending}
                  className="gap-2"
                >
                  {addToList.isPending ? (
                    <Loader2 className="size-4 animate-spin" />
                  ) : (
                    <ShoppingCart className="size-4" />
                  )}
                  Add to {mostRecentList.name}
                </Button>
              ) : (
                <Link to="/">
                  <Button variant="outline" className="gap-2">
                    <ShoppingCart className="size-4" />
                    Create a list first
                  </Button>
                </Link>
              )}
            </div>

            <RecipeCard recipe={recipe} />
          </div>
        )}
      </div>
    </div>
  )
}
