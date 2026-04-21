import { useState } from 'react'
import { createFileRoute, Link, useNavigate } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  ArrowLeft,
  ArrowDown,
  ArrowUp,
  Check,
  EyeOff,
  Eye,
  Loader2,
  Pencil,
  Plus,
  Trash2,
  X,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import { apiFetch } from '@/lib/api'
import { StarRating } from '@/components/StarRating'
import type { Recipe } from '@/components/RecipeCard'
import '@/index.css'

type IngredientRecipe = {
  name: string
  unit: string
  amount: number
  category: string
  excluded_from_list: boolean
}

type RecipeDetail = Omit<Recipe, 'ingredients'> & {
  _id: string
  rating: number | null
  created_at: string
  ingredients: IngredientRecipe[]
}

type CategoryConfig = {
  name: string
  order: number
}

export const Route = createFileRoute('/recipe/$recipeId')({
  component: RecipeDetailPage,
})

function RecipeDetailPage() {
  const { recipeId } = Route.useParams()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [editing, setEditing] = useState(false)
  const [editTitle, setEditTitle] = useState('')
  const [editInstructions, setEditInstructions] = useState<string[]>([])
  const [editIngredients, setEditIngredients] = useState<IngredientRecipe[]>([])

  const { data: recipe, isLoading } = useQuery({
    queryKey: ['recipe', recipeId],
    queryFn: async (): Promise<RecipeDetail> => {
      const res = await apiFetch(`/api/recipes/${recipeId}`)
      if (!res.ok) throw new Error('Recipe not found')
      return res.json()
    },
  })

  const { data: categories } = useQuery({
    queryKey: ['categories'],
    queryFn: async (): Promise<CategoryConfig[]> => {
      const res = await apiFetch('/api/settings/categories')
      return res.json()
    },
  })

  const { data: units } = useQuery({
    queryKey: ['units'],
    queryFn: async (): Promise<string[]> => {
      const res = await apiFetch('/api/units')
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

  const saveRecipe = useMutation({
    mutationFn: async () => {
      const res = await apiFetch(`/api/recipes/${recipeId}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          title: editTitle,
          instructions: editInstructions,
          ingredients: editIngredients,
        }),
      })
      return res.json()
    },
    onSuccess: () => {
      setEditing(false)
      queryClient.invalidateQueries({ queryKey: ['recipe', recipeId] })
      queryClient.invalidateQueries({ queryKey: ['recipes'] })
    },
  })

  const deleteRecipe = useMutation({
    mutationFn: async () => {
      await apiFetch(`/api/recipes/${recipeId}`, { method: 'DELETE' })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['recipes'] })
      navigate({ to: '/recipes' })
    },
  })

  const toggleExclude = useMutation({
    mutationFn: async ({ index, excluded }: { index: number; excluded: boolean }) => {
      const res = await apiFetch(
        `/api/recipes/${recipeId}/ingredients/${index}/exclude`,
        {
          method: 'PATCH',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ excluded }),
        }
      )
      return res.json()
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['recipe', recipeId] })
    },
  })

  const startEditing = () => {
    if (!recipe) return
    setEditTitle(recipe.title)
    setEditInstructions([...recipe.instructions])
    setEditIngredients(recipe.ingredients.map((i) => ({ ...i })))
    setEditing(true)
  }

  const cancelEditing = () => {
    setEditing(false)
  }

  const sortedCategories = categories
    ? [...categories].sort((a, b) => a.order - b.order)
    : []

  return (
    <div className="min-h-screen bg-linear-to-b from-slate-900 via-slate-800 to-slate-900 text-white">
      <div className="max-w-2xl mx-auto px-4 py-12">
        <div className="flex items-center justify-between mb-6">
          <Link
            to="/recipes"
            className="inline-flex items-center gap-1.5 text-sm text-slate-400 hover:text-white transition-colors"
          >
            <ArrowLeft className="size-4" />
            Back to recipes
          </Link>
          {recipe && !editing && (
            <div className="flex items-center gap-2">
              <Button variant="outline" size="sm" onClick={startEditing} className="gap-1.5 border-slate-700 text-slate-300">
                <Pencil className="size-3.5" />
                Edit
              </Button>
              <Button
                variant="outline"
                size="sm"
                onClick={() => {
                  if (confirm('Delete this recipe? This cannot be undone.')) {
                    deleteRecipe.mutate()
                  }
                }}
                disabled={deleteRecipe.isPending}
                className="gap-1.5 border-slate-700 text-red-400 hover:text-red-300 hover:border-red-400"
              >
                <Trash2 className="size-3.5" />
                Delete
              </Button>
            </div>
          )}
          {editing && (
            <div className="flex items-center gap-2">
              <Button variant="ghost" size="sm" onClick={cancelEditing} className="text-slate-400">
                Cancel
              </Button>
              <Button size="sm" onClick={() => saveRecipe.mutate()} disabled={saveRecipe.isPending} className="gap-1.5">
                {saveRecipe.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <Check className="size-3.5" />}
                Save
              </Button>
            </div>
          )}
        </div>

        {isLoading && (
          <div className="flex items-center gap-2 text-slate-400">
            <Loader2 className="size-5 animate-spin" />
            Loading recipe...
          </div>
        )}

        {recipe && (
          <div className="bg-slate-800 border border-slate-700 rounded-xl p-6 space-y-5">
            {/* Title */}
            {editing ? (
              <Input
                value={editTitle}
                onChange={(e) => setEditTitle(e.target.value)}
                className="text-xl font-semibold bg-slate-700 border-slate-600 text-white h-auto py-2"
              />
            ) : (
              <h2 className="text-xl font-semibold text-white">{recipe.title}</h2>
            )}

            {/* Date + Rating */}
            <div className="flex items-center justify-between">
              <div className="text-sm text-slate-400">
                {recipe.created_at
                  ? new Date(recipe.created_at).toLocaleDateString()
                  : ''}
              </div>
              <div className="flex items-center gap-3">
                <span className="text-sm text-slate-400">Rate</span>
                <StarRating
                  value={recipe.rating}
                  onChange={(rating) => ratingMutation.mutate(rating)}
                />
              </div>
            </div>

              {/* Ingredients */}
              <div>
                <h3 className="text-xs font-semibold text-slate-400 uppercase tracking-wider mb-3">
                  Ingredients
                </h3>
                {editing ? (
                  <div className="space-y-2">
                    {editIngredients.map((ing, i) => (
                      <div key={i} className="flex items-center gap-2">
                        <Input
                          value={ing.name}
                          onChange={(e) => {
                            const updated = [...editIngredients]
                            updated[i] = { ...updated[i], name: e.target.value }
                            setEditIngredients(updated)
                          }}
                          placeholder="Name"
                          className="flex-1 h-9 bg-slate-700 border-slate-600 text-white text-sm"
                        />
                        <Input
                          type="number"
                          value={ing.amount}
                          onChange={(e) => {
                            const updated = [...editIngredients]
                            updated[i] = { ...updated[i], amount: parseFloat(e.target.value) || 0 }
                            setEditIngredients(updated)
                          }}
                          placeholder="Qty"
                          className="w-20 h-9 bg-slate-700 border-slate-600 text-white text-sm"
                        />
                        <Select
                          value={ing.unit}
                          onValueChange={(val) => {
                            const updated = [...editIngredients]
                            updated[i] = { ...updated[i], unit: val }
                            setEditIngredients(updated)
                          }}
                        >
                          <SelectTrigger className="w-28 h-9 bg-slate-700 border-slate-600 text-white text-sm">
                            <SelectValue placeholder="Unit" />
                          </SelectTrigger>
                          <SelectContent>
                            {units?.map((u) => (
                              <SelectItem key={u} value={u}>{u}</SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                        <Select
                          value={ing.category}
                          onValueChange={(val) => {
                            const updated = [...editIngredients]
                            updated[i] = { ...updated[i], category: val }
                            setEditIngredients(updated)
                          }}
                        >
                          <SelectTrigger className="w-36 h-9 bg-slate-700 border-slate-600 text-white text-sm">
                            <SelectValue placeholder="Category" />
                          </SelectTrigger>
                          <SelectContent>
                            {sortedCategories.map((c) => (
                              <SelectItem key={c.name} value={c.name}>{c.name}</SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                        <Button
                          variant="ghost"
                          size="icon-xs"
                          onClick={() => setEditIngredients(editIngredients.filter((_, idx) => idx !== i))}
                          className="shrink-0 size-8 text-slate-500 hover:text-red-400"
                        >
                          <Trash2 className="size-3.5" />
                        </Button>
                      </div>
                    ))}
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() =>
                        setEditIngredients([
                          ...editIngredients,
                          { name: '', unit: '', amount: 0, category: 'Other', excluded_from_list: false },
                        ])
                      }
                      className="gap-1.5 text-slate-400 hover:text-white"
                    >
                      <Plus className="size-3.5" />
                      Add ingredient
                    </Button>
                  </div>
                ) : (
                  <ul className="space-y-1.5">
                    {recipe.ingredients.map((ing, i) => (
                      <li
                        key={i}
                        className={`text-sm flex items-center gap-2 ${
                          ing.excluded_from_list ? 'opacity-40' : 'text-slate-300'
                        }`}
                      >
                        <span className="flex-1">{ing.name}</span>
                        <span className="text-white font-medium shrink-0">
                          {ing.amount} {ing.unit}
                        </span>
                        <button
                          onClick={() =>
                            toggleExclude.mutate({
                              index: i,
                              excluded: !ing.excluded_from_list,
                            })
                          }
                          className="shrink-0 text-slate-500 hover:text-slate-300 transition-colors cursor-pointer"
                          title={ing.excluded_from_list ? 'Include in shopping list' : 'Exclude from shopping list'}
                        >
                          {ing.excluded_from_list ? (
                            <EyeOff className="size-3.5" />
                          ) : (
                            <Eye className="size-3.5" />
                          )}
                        </button>
                      </li>
                    ))}
                  </ul>
                )}
              </div>

              {/* Instructions */}
              <div>
                <h3 className="text-xs font-semibold text-slate-400 uppercase tracking-wider mb-3">
                  Instructions
                </h3>
                {editing ? (
                  <div className="space-y-2">
                    {editInstructions.map((step, i) => (
                      <div key={i} className="flex items-start gap-2">
                        <span className="text-slate-500 font-mono text-sm pt-2.5 shrink-0">{i + 1}.</span>
                        <textarea
                          value={step}
                          onChange={(e) => {
                            const updated = [...editInstructions]
                            updated[i] = e.target.value
                            setEditInstructions(updated)
                          }}
                          rows={2}
                          className="flex-1 bg-slate-700 border border-slate-600 rounded-md px-3 py-2 text-sm text-white resize-none focus:outline-none focus:ring-2 focus:ring-slate-500"
                        />
                        <div className="flex flex-col gap-0.5 shrink-0">
                          <Button
                            variant="ghost"
                            size="icon-xs"
                            onClick={() => {
                              if (i === 0) return
                              const updated = [...editInstructions]
                              ;[updated[i - 1], updated[i]] = [updated[i], updated[i - 1]]
                              setEditInstructions(updated)
                            }}
                            disabled={i === 0}
                            className="size-7 text-slate-500 hover:text-white"
                          >
                            <ArrowUp className="size-3.5" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon-xs"
                            onClick={() => {
                              if (i === editInstructions.length - 1) return
                              const updated = [...editInstructions]
                              ;[updated[i], updated[i + 1]] = [updated[i + 1], updated[i]]
                              setEditInstructions(updated)
                            }}
                            disabled={i === editInstructions.length - 1}
                            className="size-7 text-slate-500 hover:text-white"
                          >
                            <ArrowDown className="size-3.5" />
                          </Button>
                        </div>
                        <Button
                          variant="ghost"
                          size="icon-xs"
                          onClick={() => setEditInstructions(editInstructions.filter((_, idx) => idx !== i))}
                          className="shrink-0 size-7 mt-1.5 text-slate-500 hover:text-red-400"
                        >
                          <X className="size-3.5" />
                        </Button>
                      </div>
                    ))}
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => setEditInstructions([...editInstructions, ''])}
                      className="gap-1.5 text-slate-400 hover:text-white"
                    >
                      <Plus className="size-3.5" />
                      Add step
                    </Button>
                  </div>
                ) : (
                  <ol className="space-y-2.5">
                    {recipe.instructions.map((step, i) => (
                      <li key={i} className="text-sm text-slate-300 flex gap-3">
                        <span className="text-slate-500 font-mono shrink-0 pt-px">{i + 1}.</span>
                        <span>{step}</span>
                      </li>
                    ))}
                  </ol>
                )}
              </div>
          </div>
        )}
      </div>
    </div>
  )
}
