import { useState } from 'react'
import { createFileRoute, Link } from '@tanstack/react-router'
import { useMutation, useQuery } from '@tanstack/react-query'
import {
  Loader2,
  RefreshCw,
  ChevronDown,
  ShoppingBasket,
  ArrowLeft,
  RotateCcw,
} from 'lucide-react'
import { apiFetch } from '@/lib/api'
import { StarRating } from '@/components/StarRating'
import { Button } from '@/components/ui/button'
import '@/index.css'

type MealRecipe = {
  _id: string
  title: string
  ingredients: { name: string; unit: string; amount: number }[]
  rating: number | null
}

type ShoppingItem = {
  name: string
  unit: string
  amount: number
}

type RecipeSummary = {
  id: string
  title: string
  ingredient_count: number
  rating: number | null
  created_at: string | null
}

type Step = 'pick-days' | 'review' | 'shopping-list'

export const Route = createFileRoute('/meal-plan')({ component: MealPlan })

function MealPlan() {
  const [step, setStep] = useState<Step>('pick-days')
  const [days, setDays] = useState(0)
  const [recipes, setRecipes] = useState<MealRecipe[]>([])
  const [shoppingList, setShoppingList] = useState<ShoppingItem[]>([])
  const [browseOpenIndex, setBrowseOpenIndex] = useState<number | null>(null)

  const { data: allRecipes } = useQuery({
    queryKey: ['recipes'],
    queryFn: async (): Promise<RecipeSummary[]> => {
      const res = await apiFetch('/api/recipes/')
      return res.json()
    },
  })

  const suggestMutation = useMutation({
    mutationFn: async ({
      numDays,
      excludeIds,
    }: {
      numDays: number
      excludeIds: string[]
    }): Promise<MealRecipe[]> => {
      const res = await apiFetch('/api/meal-plan/suggest/', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ days: numDays, exclude_ids: excludeIds }),
      })
      return res.json()
    },
  })

  const shoppingMutation = useMutation({
    mutationFn: async (recipeIds: string[]): Promise<ShoppingItem[]> => {
      const res = await apiFetch('/api/meal-plan/shopping-list/', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ recipe_ids: recipeIds }),
      })
      return res.json()
    },
  })

  const handlePickDays = async (n: number) => {
    setDays(n)
    const result = await suggestMutation.mutateAsync({
      numDays: n,
      excludeIds: [],
    })
    setRecipes(result)
    setStep('review')
  }

  const handleSwap = async (index: number) => {
    const excludeIds = recipes.map((r) => r._id)
    const result = await suggestMutation.mutateAsync({
      numDays: 1,
      excludeIds,
    })
    if (result.length > 0) {
      setRecipes((prev) => prev.map((r, i) => (i === index ? result[0] : r)))
    }
  }

  const handleBrowseSelect = (index: number, recipeId: string) => {
    const picked = allRecipes?.find((r) => r.id === recipeId)
    if (!picked) return
    const asRecipe: MealRecipe = {
      _id: picked.id,
      title: picked.title,
      ingredients: [],
      rating: picked.rating,
    }
    setRecipes((prev) => prev.map((r, i) => (i === index ? asRecipe : r)))
    setBrowseOpenIndex(null)
  }

  const handleGenerateList = async () => {
    const ids = recipes.map((r) => r._id)
    const result = await shoppingMutation.mutateAsync(ids)
    setShoppingList(result)
    setStep('shopping-list')
  }

  const handleStartOver = () => {
    setStep('pick-days')
    setDays(0)
    setRecipes([])
    setShoppingList([])
    setBrowseOpenIndex(null)
  }

  return (
    <div className="min-h-screen bg-linear-to-b from-slate-900 via-slate-800 to-slate-900 text-white">
      <div className="max-w-2xl mx-auto px-4 py-12">
        <h1 className="text-2xl font-bold tracking-tight mb-8">Meal Plan</h1>

        {/* Step 1: Pick Days */}
        {step === 'pick-days' && (
          <div className="space-y-6">
            <p className="text-slate-400">
              How many dinners do you need this week?
            </p>
            <div className="flex gap-3">
              {[3, 4, 5, 6, 7].map((n) => (
                <Button
                  key={n}
                  variant="outline"
                  size="lg"
                  className="border-slate-600 text-white hover:bg-slate-700 text-lg w-14 h-14"
                  onClick={() => handlePickDays(n)}
                  disabled={suggestMutation.isPending}
                >
                  {n}
                </Button>
              ))}
            </div>
            {suggestMutation.isPending && (
              <div className="flex items-center gap-2 text-slate-400">
                <Loader2 className="size-5 animate-spin" />
                Finding recipes...
              </div>
            )}
          </div>
        )}

        {/* Step 2: Review Plan */}
        {step === 'review' && (
          <div className="space-y-4">
            {recipes.length < days && (
              <p className="text-amber-400 text-sm">
                You have {recipes.length} recipe
                {recipes.length !== 1 ? 's' : ''} saved, but need {days}.{' '}
                <Link
                  to="/"
                  className="underline underline-offset-4 hover:text-amber-300"
                >
                  Create more recipes
                </Link>{' '}
                to fill your plan.
              </p>
            )}

            {recipes.length === 0 && (
              <div className="text-center py-16">
                <p className="text-slate-400 mb-4">
                  No recipes available to plan with.
                </p>
                <Link
                  to="/"
                  className="text-sm text-slate-300 hover:text-white underline underline-offset-4 transition-colors"
                >
                  Create your first recipe
                </Link>
              </div>
            )}

            {recipes.map((recipe, index) => {
              const currentIds = recipes.map((r) => r._id)
              const browsableRecipes = allRecipes?.filter(
                (r) => !currentIds.includes(r.id) || r.id === recipe._id,
              )
              const noAlternatives =
                allRecipes && allRecipes.length <= recipes.length

              return (
                <div
                  key={`${recipe._id}-${index}`}
                  className="bg-slate-800 border border-slate-700 rounded-xl p-5"
                >
                  <div className="flex items-center gap-4">
                    <span className="text-xs font-mono text-slate-500 shrink-0">
                      Day {index + 1}
                    </span>
                    <div className="flex-1 min-w-0">
                      <p className="text-white font-medium truncate">
                        {recipe.title}
                      </p>
                      <div className="flex items-center gap-3 mt-1 text-sm text-slate-400">
                        <span>
                          {recipe.ingredients.length} ingredient
                          {recipe.ingredients.length !== 1 ? 's' : ''}
                        </span>
                        <StarRating value={recipe.rating} />
                      </div>
                    </div>
                    <div className="flex gap-2 shrink-0">
                      <Button
                        variant="ghost"
                        size="sm"
                        className="text-slate-400 hover:text-white"
                        onClick={() => handleSwap(index)}
                        disabled={
                          suggestMutation.isPending || !!noAlternatives
                        }
                        title="Random swap"
                      >
                        <RefreshCw className="size-4" />
                      </Button>
                      <Button
                        variant="ghost"
                        size="sm"
                        className="text-slate-400 hover:text-white"
                        onClick={() =>
                          setBrowseOpenIndex(
                            browseOpenIndex === index ? null : index,
                          )
                        }
                        title="Browse recipes"
                      >
                        <ChevronDown
                          className={`size-4 transition-transform ${browseOpenIndex === index ? 'rotate-180' : ''}`}
                        />
                      </Button>
                    </div>
                  </div>

                  {browseOpenIndex === index && browsableRecipes && (
                    <div className="mt-3 border-t border-slate-700 pt-3 max-h-48 overflow-y-auto space-y-1">
                      {browsableRecipes.map((r) => (
                        <button
                          key={r.id}
                          type="button"
                          className={`w-full text-left px-3 py-2 rounded-lg text-sm transition-colors cursor-pointer ${
                            r.id === recipe._id
                              ? 'bg-slate-600 text-white'
                              : 'text-slate-300 hover:bg-slate-700 hover:text-white'
                          }`}
                          onClick={() => handleBrowseSelect(index, r.id)}
                        >
                          {r.title}
                        </button>
                      ))}
                    </div>
                  )}
                </div>
              )
            })}

            {recipes.length > 0 && (
              <div className="flex gap-3 pt-4">
                <Button
                  variant="outline"
                  className="border-slate-600 text-slate-300 hover:text-white"
                  onClick={handleStartOver}
                >
                  <RotateCcw className="size-4 mr-2" />
                  Start Over
                </Button>
                <Button
                  className="bg-white text-slate-900 hover:bg-slate-200 flex-1"
                  onClick={handleGenerateList}
                  disabled={shoppingMutation.isPending}
                >
                  {shoppingMutation.isPending ? (
                    <Loader2 className="size-4 mr-2 animate-spin" />
                  ) : (
                    <ShoppingBasket className="size-4 mr-2" />
                  )}
                  Generate Shopping List
                </Button>
              </div>
            )}
          </div>
        )}

        {/* Step 3: Shopping List */}
        {step === 'shopping-list' && (
          <div className="space-y-6">
            <div className="bg-slate-800 border border-slate-700 rounded-xl p-6">
              <h2 className="text-xs font-semibold text-slate-400 uppercase tracking-wider mb-4">
                Shopping List
              </h2>
              {shoppingList.length === 0 ? (
                <p className="text-slate-400 text-sm">No ingredients needed.</p>
              ) : (
                <ul className="space-y-2">
                  {shoppingList.map((item, i) => (
                    <li
                      key={i}
                      className="text-sm text-slate-300 flex gap-2"
                    >
                      <span className="text-white font-medium shrink-0">
                        {item.amount} {item.unit}
                      </span>
                      <span>{item.name}</span>
                    </li>
                  ))}
                </ul>
              )}
            </div>

            <div className="flex gap-3">
              <Button
                variant="outline"
                className="border-slate-600 text-slate-300 hover:text-white"
                onClick={() => setStep('review')}
              >
                <ArrowLeft className="size-4 mr-2" />
                Back to Plan
              </Button>
              <Button
                variant="outline"
                className="border-slate-600 text-slate-300 hover:text-white"
                onClick={handleStartOver}
              >
                <RotateCcw className="size-4 mr-2" />
                Start Over
              </Button>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}
