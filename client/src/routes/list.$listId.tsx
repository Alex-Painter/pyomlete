import { useState } from 'react'
import { createFileRoute, Link } from '@tanstack/react-router'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import {
  ArrowLeft,
  Check,
  ChevronDown,
  ChevronRight,
  Loader2,
  Plus,
  Star,
  Trash2,
  UtensilsCrossed,
  X,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import { Input } from '@/components/ui/input'
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
  SheetDescription,
} from '@/components/ui/sheet'
import { apiFetch } from '@/lib/api'

type ItemSource = {
  recipe_id: string | null
  amount: number
}

type ListItem = {
  id: string
  name: string
  amount: number | null
  unit: string | null
  category: string
  checked: boolean
  sources: ItemSource[]
}

type ListDetail = {
  id: string
  name: string
  created_at: string | null
  recipes: string[]
  items: ListItem[]
}

type CategoryConfig = {
  name: string
  order: number
}

type RecipeSummary = {
  id: string
  title: string
  ingredient_count: number
  rating: number | null
}

export const Route = createFileRoute('/list/$listId')({ component: ListDetailPage })

function ListDetailPage() {
  const { listId } = Route.useParams()
  const queryClient = useQueryClient()
  const [collapsedCategories, setCollapsedCategories] = useState<Set<string>>(new Set())
  const [quickAddValue, setQuickAddValue] = useState('')
  const [isAdding, setIsAdding] = useState(false)
  const [drawerOpen, setDrawerOpen] = useState(false)

  const { data: list, isLoading } = useQuery({
    queryKey: ['list', listId],
    queryFn: async (): Promise<ListDetail> => {
      const res = await apiFetch(`/api/lists/${listId}`)
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

  const { data: allRecipes } = useQuery({
    queryKey: ['recipes'],
    queryFn: async (): Promise<RecipeSummary[]> => {
      const res = await apiFetch('/api/recipes/')
      return res.json()
    },
    enabled: drawerOpen,
  })

  const updateItem = useMutation({
    mutationFn: async ({ itemId, updates }: { itemId: string; updates: Record<string, unknown> }) => {
      const res = await apiFetch(`/api/lists/${listId}/items/${itemId}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(updates),
      })
      return res.json()
    },
    onMutate: async ({ itemId, updates }) => {
      await queryClient.cancelQueries({ queryKey: ['list', listId] })
      const previous = queryClient.getQueryData<ListDetail>(['list', listId])
      queryClient.setQueryData<ListDetail>(['list', listId], (old) => {
        if (!old) return old
        return {
          ...old,
          items: old.items.map((item) =>
            item.id === itemId ? { ...item, ...updates } : item
          ),
        }
      })
      return { previous }
    },
    onError: (_err, _vars, context) => {
      if (context?.previous) {
        queryClient.setQueryData(['list', listId], context.previous)
      }
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['list', listId] })
    },
  })

  const deleteItem = useMutation({
    mutationFn: async (itemId: string) => {
      await apiFetch(`/api/lists/${listId}/items/${itemId}`, { method: 'DELETE' })
    },
    onMutate: async (itemId) => {
      await queryClient.cancelQueries({ queryKey: ['list', listId] })
      const previous = queryClient.getQueryData<ListDetail>(['list', listId])
      queryClient.setQueryData<ListDetail>(['list', listId], (old) => {
        if (!old) return old
        return { ...old, items: old.items.filter((item) => item.id !== itemId) }
      })
      return { previous }
    },
    onError: (_err, _vars, context) => {
      if (context?.previous) {
        queryClient.setQueryData(['list', listId], context.previous)
      }
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['list', listId] })
    },
  })

  const addRecipe = useMutation({
    mutationFn: async (recipeId: string) => {
      const res = await apiFetch(`/api/lists/${listId}/recipes`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ recipe_id: recipeId }),
      })
      return res.json()
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['list', listId] })
      queryClient.invalidateQueries({ queryKey: ['lists'] })
    },
  })

  const removeRecipe = useMutation({
    mutationFn: async (recipeId: string) => {
      const res = await apiFetch(`/api/lists/${listId}/recipes/${recipeId}`, {
        method: 'DELETE',
      })
      return res.json()
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['list', listId] })
      queryClient.invalidateQueries({ queryKey: ['lists'] })
    },
  })

  const handleQuickAdd = async () => {
    const name = quickAddValue.trim()
    if (!name) return
    setIsAdding(true)
    try {
      const catRes = await apiFetch('/api/categorize', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name }),
      })
      const { category } = await catRes.json()

      await apiFetch(`/api/lists/${listId}/items`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name, category }),
      })

      setQuickAddValue('')
      queryClient.invalidateQueries({ queryKey: ['list', listId] })
    } finally {
      setIsAdding(false)
    }
  }

  const toggleCategory = (cat: string) => {
    setCollapsedCategories((prev) => {
      const next = new Set(prev)
      if (next.has(cat)) next.delete(cat)
      else next.add(cat)
      return next
    })
  }

  if (isLoading) {
    return (
      <div className="min-h-screen bg-linear-to-b from-slate-900 via-slate-800 to-slate-900 text-white flex justify-center pt-24">
        <Loader2 className="size-6 animate-spin text-slate-400" />
      </div>
    )
  }

  if (!list) {
    return (
      <div className="min-h-screen bg-linear-to-b from-slate-900 via-slate-800 to-slate-900 text-white">
        <div className="max-w-2xl mx-auto px-4 py-12">
          <p className="text-slate-400">List not found</p>
        </div>
      </div>
    )
  }

  // Group items by category, sorted by category order
  const sortedCategories = categories
    ? [...categories].sort((a, b) => a.order - b.order)
    : []
  const categoryOrder = new Map(sortedCategories.map((c, i) => [c.name, i]))

  const itemsByCategory = new Map<string, ListItem[]>()
  for (const item of list.items) {
    const cat = item.category || 'Other'
    if (!itemsByCategory.has(cat)) itemsByCategory.set(cat, [])
    itemsByCategory.get(cat)!.push(item)
  }

  const orderedCategories = [...itemsByCategory.entries()].sort(([a], [b]) => {
    const orderA = categoryOrder.get(a) ?? 999
    const orderB = categoryOrder.get(b) ?? 999
    return orderA - orderB
  })

  for (const [, items] of orderedCategories) {
    items.sort((a, b) => Number(a.checked) - Number(b.checked))
  }

  const totalItems = list.items.length
  const checkedItems = list.items.filter((i) => i.checked).length

  // Recipe drawer data
  const selectedRecipeIds = new Set(list.recipes)
  const selectedRecipes = allRecipes?.filter((r) => selectedRecipeIds.has(r.id)) ?? []
  const availableRecipes = allRecipes?.filter((r) => !selectedRecipeIds.has(r.id)) ?? []

  return (
    <div className="min-h-screen bg-linear-to-b from-slate-900 via-slate-800 to-slate-900 text-white">
      <div className="max-w-2xl mx-auto px-4 py-6">
        {/* Header */}
        <div className="flex items-center gap-3 mb-2">
          <Link to="/" className="text-slate-400 hover:text-white transition-colors">
            <ArrowLeft className="size-5" />
          </Link>
          <h1 className="text-xl font-bold flex-1">{list.name}</h1>
          <Button
            variant="outline"
            size="sm"
            className="border-slate-700 text-slate-300 hover:text-white"
            onClick={() => setDrawerOpen(true)}
          >
            <UtensilsCrossed className="size-4" />
            Recipes
            {list.recipes.length > 0 && (
              <span className="ml-1 bg-slate-700 text-xs px-1.5 py-0.5 rounded-full">
                {list.recipes.length}
              </span>
            )}
          </Button>
        </div>

        {/* Progress */}
        {totalItems > 0 && (
          <div className="mb-6 ml-8">
            <div className="flex items-center gap-2 mb-1">
              <div className="flex-1 h-1.5 bg-slate-700 rounded-full">
                <div
                  className="h-full bg-emerald-500 rounded-full transition-all"
                  style={{ width: `${(checkedItems / totalItems) * 100}%` }}
                />
              </div>
              <span className="text-xs text-slate-400">
                {checkedItems}/{totalItems}
              </span>
            </div>
          </div>
        )}

        {/* Quick add */}
        <form
          onSubmit={(e) => {
            e.preventDefault()
            handleQuickAdd()
          }}
          className="flex gap-2 mb-6"
        >
          <Input
            type="text"
            value={quickAddValue}
            onChange={(e) => setQuickAddValue(e.target.value)}
            placeholder="Add an item..."
            className="flex-1 bg-slate-800 border-slate-700 text-white placeholder:text-slate-500"
          />
          <Button type="submit" disabled={isAdding || !quickAddValue.trim()}>
            {isAdding ? <Loader2 className="animate-spin size-4" /> : <Plus className="size-4" />}
          </Button>
        </form>

        {/* Empty state */}
        {list.items.length === 0 && (
          <div className="text-center py-12">
            <p className="text-slate-400 mb-2">No items yet</p>
            <p className="text-sm text-slate-500">
              Add items above or{' '}
              <button
                onClick={() => setDrawerOpen(true)}
                className="text-slate-300 underline underline-offset-2 hover:text-white cursor-pointer"
              >
                add recipes
              </button>{' '}
              to get started
            </p>
          </div>
        )}

        {/* Categorized items */}
        <div className="space-y-2">
          {orderedCategories.map(([category, items]) => {
            const isCollapsed = collapsedCategories.has(category)
            const checkedCount = items.filter((i) => i.checked).length

            return (
              <div key={category} className="bg-slate-800/50 rounded-lg overflow-hidden">
                <button
                  onClick={() => toggleCategory(category)}
                  className="w-full flex items-center gap-2 px-4 py-2.5 text-sm font-medium text-slate-300 hover:text-white transition-colors cursor-pointer"
                >
                  {isCollapsed ? (
                    <ChevronRight className="size-4 text-slate-500" />
                  ) : (
                    <ChevronDown className="size-4 text-slate-500" />
                  )}
                  <span className="flex-1 text-left">{category}</span>
                  <span className="text-xs text-slate-500">
                    {checkedCount}/{items.length}
                  </span>
                </button>

                {!isCollapsed && (
                  <div className="px-2 pb-2 space-y-0.5">
                    {items.map((item) => (
                      <ItemRow
                        key={item.id}
                        item={item}
                        onToggleCheck={() =>
                          updateItem.mutate({
                            itemId: item.id,
                            updates: { checked: !item.checked },
                          })
                        }
                        onDelete={() => deleteItem.mutate(item.id)}
                      />
                    ))}
                  </div>
                )}
              </div>
            )
          })}
        </div>
      </div>

      {/* Recipe drawer */}
      <Sheet open={drawerOpen} onOpenChange={setDrawerOpen}>
        <SheetContent
          side="right"
          className="bg-slate-900 border-slate-800 text-white w-full sm:max-w-md overflow-y-auto"
        >
          <SheetHeader>
            <SheetTitle className="text-white">Recipes</SheetTitle>
            <SheetDescription className="text-slate-400">
              Add or remove recipes from this list
            </SheetDescription>
          </SheetHeader>

          {/* Selected recipes */}
          {selectedRecipes.length > 0 && (
            <div className="px-4 pb-4">
              <h3 className="text-xs font-medium text-slate-500 uppercase tracking-wider mb-2">
                On this list
              </h3>
              <div className="space-y-1">
                {selectedRecipes.map((recipe) => (
                  <div
                    key={recipe.id}
                    className="flex items-center gap-3 px-3 py-2.5 rounded-md bg-slate-800"
                  >
                    <Check className="size-4 text-emerald-500 shrink-0" />
                    <div className="flex-1 min-w-0">
                      <p className="text-sm font-medium truncate">{recipe.title}</p>
                      <p className="text-xs text-slate-400">
                        {recipe.ingredient_count} ingredients
                      </p>
                    </div>
                    <Button
                      variant="ghost"
                      size="icon-xs"
                      onClick={() => removeRecipe.mutate(recipe.id)}
                      disabled={removeRecipe.isPending}
                      className="shrink-0 text-slate-500 hover:text-red-400"
                    >
                      <X className="size-3.5" />
                    </Button>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Available recipes */}
          <div className="px-4 pb-4">
            <h3 className="text-xs font-medium text-slate-500 uppercase tracking-wider mb-2">
              {selectedRecipes.length > 0 ? 'Add more' : 'Add recipes'}
            </h3>
            {!allRecipes && (
              <div className="flex justify-center py-4">
                <Loader2 className="size-5 animate-spin text-slate-400" />
              </div>
            )}
            {allRecipes && availableRecipes.length === 0 && (
              <p className="text-sm text-slate-500 py-4 text-center">
                {allRecipes.length === 0
                  ? 'No recipes yet. Create some first!'
                  : 'All recipes are already on this list'}
              </p>
            )}
            <div className="space-y-1">
              {availableRecipes.map((recipe) => (
                <button
                  key={recipe.id}
                  onClick={() => addRecipe.mutate(recipe.id)}
                  disabled={addRecipe.isPending}
                  className="w-full flex items-center gap-3 px-3 py-2.5 rounded-md hover:bg-slate-800 transition-colors cursor-pointer text-left"
                >
                  <Plus className="size-4 text-slate-500 shrink-0" />
                  <div className="flex-1 min-w-0">
                    <p className="text-sm font-medium truncate">{recipe.title}</p>
                    <div className="flex items-center gap-2">
                      <span className="text-xs text-slate-400">
                        {recipe.ingredient_count} ingredients
                      </span>
                      {recipe.rating && (
                        <span className="flex items-center gap-0.5 text-xs text-amber-500">
                          <Star className="size-3 fill-current" />
                          {recipe.rating}
                        </span>
                      )}
                    </div>
                  </div>
                </button>
              ))}
            </div>
          </div>
        </SheetContent>
      </Sheet>
    </div>
  )
}

function ItemRow({
  item,
  onToggleCheck,
  onDelete,
}: {
  item: ListItem
  onToggleCheck: () => void
  onDelete: () => void
}) {
  return (
    <div
      className={`flex items-center gap-3 px-2 py-2 rounded-md group transition-opacity ${
        item.checked ? 'opacity-50' : ''
      }`}
    >
      <Checkbox
        checked={item.checked}
        onCheckedChange={onToggleCheck}
        className="shrink-0 border-slate-600 data-[state=checked]:bg-emerald-600 data-[state=checked]:border-emerald-600"
      />

      <div className={`flex-1 min-w-0 ${item.checked ? 'line-through text-slate-400' : ''}`}>
        <span className="text-sm">{item.name}</span>
        {item.amount != null && item.unit && (
          <span className="text-xs text-slate-400 ml-2">
            {item.amount} {item.unit}
          </span>
        )}
      </div>

      <Button
        variant="ghost"
        size="icon-xs"
        onClick={onDelete}
        className="shrink-0 text-slate-600 hover:text-red-400 opacity-0 group-hover:opacity-100 transition-opacity"
      >
        <Trash2 className="size-3.5" />
      </Button>
    </div>
  )
}
