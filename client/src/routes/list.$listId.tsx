import { useState, useRef, useCallback } from 'react'
import { createFileRoute, Link } from '@tanstack/react-router'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import {
  ArrowLeft,
  Check,
  ChevronDown,
  ChevronRight,
  Loader2,
  Pencil,
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
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
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
  const [showCompleted, setShowCompleted] = useState(false)
  const [quickAddValue, setQuickAddValue] = useState('')
  const [quickAddAmount, setQuickAddAmount] = useState('')
  const [quickAddUnit, setQuickAddUnit] = useState('')
  const [isAdding, setIsAdding] = useState(false)
  const [showSidebar, setShowSidebar] = useState(false)

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
  })

  const { data: units } = useQuery({
    queryKey: ['units'],
    queryFn: async (): Promise<string[]> => {
      const res = await apiFetch('/api/units')
      return res.json()
    },
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

      const amount = quickAddAmount.trim() ? parseFloat(quickAddAmount) : undefined
      const unit = quickAddUnit && quickAddUnit !== '__none' ? quickAddUnit : undefined

      await apiFetch(`/api/lists/${listId}/items`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name, category, ...(amount != null && !isNaN(amount) ? { amount } : {}), ...(unit ? { unit } : {}) }),
      })

      setQuickAddValue('')
      setQuickAddAmount('')
      setQuickAddUnit('')
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

  // Group items by category
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

  // Separate checked items out of categories
  const checkedItemsList: ListItem[] = []
  for (const [, items] of orderedCategories) {
    const checked = items.filter((i) => i.checked)
    checkedItemsList.push(...checked)
  }
  // Filter categories to only unchecked items, remove empty categories
  const uncheckedCategories = orderedCategories
    .map(([cat, items]) => [cat, items.filter((i) => !i.checked)] as [string, ListItem[]])
    .filter(([, items]) => items.length > 0)

  const totalItems = list.items.length
  const checkedItems = checkedItemsList.length

  const selectedRecipeIds = new Set(list.recipes)
  const selectedRecipes = allRecipes?.filter((r) => selectedRecipeIds.has(r.id)) ?? []
  const availableRecipes = allRecipes?.filter((r) => !selectedRecipeIds.has(r.id)) ?? []

  return (
    <div className="min-h-screen bg-linear-to-b from-slate-900 via-slate-800 to-slate-900 text-white">
      <div className="flex">
        {/* Main content */}
        <div className="flex-1 min-w-0 max-w-2xl mx-auto px-4 py-6">
          {/* Header */}
          <div className="flex items-center gap-3 mb-2">
            <Link to="/" className="text-slate-400 hover:text-white transition-colors">
              <ArrowLeft className="size-5" />
            </Link>
            <h1 className="text-xl font-bold flex-1">{list.name}</h1>
            {/* Mobile toggle for sidebar */}
            <Button
              variant="outline"
              size="sm"
              className="lg:hidden border-slate-700 text-slate-300 hover:text-white"
              onClick={() => setShowSidebar(!showSidebar)}
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
            className="sticky top-0 sm:top-14 z-10 bg-slate-900/95 backdrop-blur-sm pb-4 mb-2 -mx-4 px-4 pt-2 sm:static sm:bg-transparent sm:backdrop-blur-none sm:pb-0 sm:mb-6 sm:mx-0 sm:px-0 sm:pt-0"
          >
            <div className="flex gap-2">
              <Input
                type="text"
                value={quickAddValue}
                onChange={(e) => setQuickAddValue(e.target.value)}
                placeholder="Add item..."
                className="flex-1 h-10 bg-slate-800 border-slate-700 text-white placeholder:text-slate-500"
              />
              <Input
                type="number"
                value={quickAddAmount}
                onChange={(e) => setQuickAddAmount(e.target.value)}
                placeholder="Qty"
                className="w-16 sm:w-20 h-10 bg-slate-800 border-slate-700 text-white placeholder:text-slate-500"
              />
              <Select value={quickAddUnit} onValueChange={setQuickAddUnit}>
                <SelectTrigger className="w-24 sm:w-28 h-10 bg-slate-800 border-slate-700 text-white">
                  <SelectValue placeholder="Unit" />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="__none">No unit</SelectItem>
                  {units?.map((u) => (
                    <SelectItem key={u} value={u}>{u}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <Button type="submit" disabled={isAdding || !quickAddValue.trim()} className="h-10 w-10 shrink-0 p-0">
                {isAdding ? <Loader2 className="animate-spin size-4" /> : <Plus className="size-4" />}
              </Button>
            </div>
          </form>

          {/* Mobile sidebar (toggle) */}
          {showSidebar && (
            <div className="lg:hidden mb-6">
              <RecipeSidebar
                selectedRecipes={selectedRecipes}
                availableRecipes={availableRecipes}
                allRecipes={allRecipes}
                onAdd={(id) => addRecipe.mutate(id)}
                onRemove={(id) => removeRecipe.mutate(id)}
                isAdding={addRecipe.isPending}
                isRemoving={removeRecipe.isPending}
              />
            </div>
          )}

          {/* Empty state */}
          {list.items.length === 0 && (
            <div className="text-center py-12">
              <p className="text-slate-400 mb-2">No items yet</p>
              <p className="text-sm text-slate-500">
                Add items above or add recipes from the sidebar to get started
              </p>
            </div>
          )}

          {/* Categorized items (unchecked only) */}
          <div className="space-y-2">
            {uncheckedCategories.map(([category, items]) => {
              const isCollapsed = collapsedCategories.has(category)

              return (
                <div key={category} className="bg-slate-800/50 rounded-lg overflow-hidden">
                  <button
                    onClick={() => toggleCategory(category)}
                    className="w-full flex items-center gap-2 px-4 py-3 min-h-[44px] text-sm font-medium text-slate-300 hover:text-white transition-colors cursor-pointer"
                  >
                    {isCollapsed ? (
                      <ChevronRight className="size-4 text-slate-500" />
                    ) : (
                      <ChevronDown className="size-4 text-slate-500" />
                    )}
                    <span className="flex-1 text-left">{category}</span>
                    <span className="text-xs text-slate-500">{items.length}</span>
                  </button>

                  {!isCollapsed && (
                    <div className="px-2 pb-2 space-y-0.5">
                      {items.map((item) => (
                        <ItemRow
                          key={item.id}
                          item={item}
                          units={units ?? []}
                          categories={sortedCategories.map((c) => c.name)}
                          onToggleCheck={() =>
                            updateItem.mutate({
                              itemId: item.id,
                              updates: { checked: !item.checked },
                            })
                          }
                          onUpdate={(updates) =>
                            updateItem.mutate({ itemId: item.id, updates })
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

          {/* Completed items section */}
          {checkedItems > 0 && (
            <div className="mt-4">
              <button
                onClick={() => setShowCompleted(!showCompleted)}
                className="flex items-center gap-2 px-2 py-2 text-sm text-slate-500 hover:text-slate-300 transition-colors cursor-pointer"
              >
                {showCompleted ? (
                  <ChevronDown className="size-3.5" />
                ) : (
                  <ChevronRight className="size-3.5" />
                )}
                <span>Completed ({checkedItems})</span>
              </button>

              {showCompleted && (
                <div className="mt-1 px-2 flex flex-wrap gap-1.5">
                  {checkedItemsList.map((item) => (
                    <button
                      key={item.id}
                      onClick={() =>
                        updateItem.mutate({
                          itemId: item.id,
                          updates: { checked: false },
                        })
                      }
                      className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-slate-800/60 text-xs text-slate-500 line-through hover:bg-slate-700 hover:text-slate-300 transition-colors cursor-pointer"
                    >
                      <Check className="size-3" />
                      {item.name}
                    </button>
                  ))}
                </div>
              )}
            </div>
          )}
        </div>

        {/* Desktop sidebar — fixed to right edge, full height */}
        <div className="hidden lg:block fixed right-0 top-14 bottom-0 w-80 border-l border-slate-700/50 overflow-y-auto">
          <RecipeSidebar
            selectedRecipes={selectedRecipes}
            availableRecipes={availableRecipes}
            allRecipes={allRecipes}
            onAdd={(id) => addRecipe.mutate(id)}
            onRemove={(id) => removeRecipe.mutate(id)}
            isAdding={addRecipe.isPending}
            isRemoving={removeRecipe.isPending}
          />
        </div>
      </div>
    </div>
  )
}

function RecipeSidebar({
  selectedRecipes,
  availableRecipes,
  allRecipes,
  onAdd,
  onRemove,
  isAdding,
  isRemoving,
}: {
  selectedRecipes: RecipeSummary[]
  availableRecipes: RecipeSummary[]
  allRecipes: RecipeSummary[] | undefined
  onAdd: (id: string) => void
  onRemove: (id: string) => void
  isAdding: boolean
  isRemoving: boolean
}) {
  return (
    <div className="bg-slate-800/50 overflow-hidden lg:rounded-none lg:bg-transparent rounded-lg">
      <div className="px-4 py-3 border-b border-slate-700/50">
        <h2 className="text-sm font-semibold flex items-center gap-2">
          <UtensilsCrossed className="size-4 text-slate-400" />
          Recipes
        </h2>
      </div>

      {/* Selected recipes */}
      {selectedRecipes.length > 0 && (
        <div className="p-3 border-b border-slate-700/50">
          <h3 className="text-xs font-medium text-slate-500 uppercase tracking-wider mb-2 px-1">
            On this list
          </h3>
          <div className="space-y-1">
            {selectedRecipes.map((recipe) => (
              <div
                key={recipe.id}
                className="flex items-center gap-2 px-2 py-2 rounded-md bg-slate-800"
              >
                <Check className="size-3.5 text-emerald-500 shrink-0" />
                <div className="flex-1 min-w-0">
                  <Link
                    to="/recipe/$recipeId"
                    params={{ recipeId: recipe.id }}
                    className="text-sm truncate block hover:text-emerald-400 transition-colors"
                  >
                    {recipe.title}
                  </Link>
                  <p className="text-xs text-slate-500">{recipe.ingredient_count} ingredients</p>
                </div>
                <Button
                  variant="ghost"
                  size="icon-xs"
                  onClick={() => onRemove(recipe.id)}
                  disabled={isRemoving}
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
      <div className="p-3">
        <h3 className="text-xs font-medium text-slate-500 uppercase tracking-wider mb-2 px-1">
          {selectedRecipes.length > 0 ? 'Add more' : 'Add recipes'}
        </h3>
        {!allRecipes && (
          <div className="flex justify-center py-4">
            <Loader2 className="size-5 animate-spin text-slate-400" />
          </div>
        )}
        {allRecipes && availableRecipes.length === 0 && (
          <p className="text-xs text-slate-500 py-3 text-center">
            {allRecipes.length === 0
              ? 'No recipes yet. Create some first!'
              : 'All recipes added'}
          </p>
        )}
        <div className="space-y-0.5">
          {availableRecipes.map((recipe) => (
            <button
              key={recipe.id}
              onClick={() => onAdd(recipe.id)}
              disabled={isAdding}
              className="w-full flex items-center gap-2 px-2 py-2.5 min-h-[44px] rounded-md hover:bg-slate-800 transition-colors cursor-pointer text-left"
            >
              <Plus className="size-3.5 text-slate-500 shrink-0" />
              <div className="flex-1 min-w-0">
                <p className="text-sm truncate">{recipe.title}</p>
                <div className="flex items-center gap-2">
                  <span className="text-xs text-slate-500">
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
    </div>
  )
}

function ItemRow({
  item,
  units,
  categories,
  onToggleCheck,
  onUpdate,
  onDelete,
}: {
  item: ListItem
  units: string[]
  categories: string[]
  onToggleCheck: () => void
  onUpdate: (updates: Record<string, unknown>) => void
  onDelete: () => void
}) {
  const [editing, setEditing] = useState(false)
  const [editName, setEditName] = useState(item.name)
  const [editAmount, setEditAmount] = useState(item.amount?.toString() ?? '')
  const [editUnit, setEditUnit] = useState(item.unit ?? '__none')
  const [editCategory, setEditCategory] = useState(item.category)

  const handleSave = () => {
    const updates: Record<string, unknown> = {}
    const newName = editName.trim()
    if (newName && newName !== item.name) updates.name = newName
    const newAmount = editAmount.trim() ? parseFloat(editAmount) : null
    if (newAmount !== item.amount) updates.amount = newAmount
    const newUnit = editUnit && editUnit !== '__none' ? editUnit : null
    if (newUnit !== item.unit) updates.unit = newUnit
    if (editCategory !== item.category) updates.category = editCategory
    if (Object.keys(updates).length > 0) onUpdate(updates)
    setEditing(false)
  }

  const handleCancel = () => {
    setEditName(item.name)
    setEditAmount(item.amount?.toString() ?? '')
    setEditUnit(item.unit ?? '__none')
    setEditCategory(item.category)
    setEditing(false)
  }

  // Swipe-to-delete state
  const swipeRef = useRef<HTMLDivElement>(null)
  const touchStartX = useRef(0)
  const [swipeOffset, setSwipeOffset] = useState(0)
  const [swiping, setSwiping] = useState(false)

  const handleTouchStart = useCallback((e: React.TouchEvent) => {
    touchStartX.current = e.touches[0].clientX
    setSwiping(true)
  }, [])

  const handleTouchMove = useCallback((e: React.TouchEvent) => {
    if (!swiping) return
    const diff = touchStartX.current - e.touches[0].clientX
    // Only allow swiping left (positive diff)
    setSwipeOffset(Math.max(0, Math.min(diff, 80)))
  }, [swiping])

  const handleTouchEnd = useCallback(() => {
    setSwiping(false)
    if (swipeOffset > 60) {
      onDelete()
    }
    setSwipeOffset(0)
  }, [swipeOffset, onDelete])

  if (editing) {
    return (
      <div className="px-2 py-2 rounded-md bg-slate-800 space-y-2">
        <div className="flex flex-col sm:flex-row gap-2">
          <Input
            value={editName}
            onChange={(e) => setEditName(e.target.value)}
            placeholder="Name"
            className="flex-1 h-10 bg-slate-700 border-slate-600 text-white text-sm"
            autoFocus
            onKeyDown={(e) => {
              if (e.key === 'Enter') handleSave()
              if (e.key === 'Escape') handleCancel()
            }}
          />
          <div className="flex gap-2">
            <Input
              type="number"
              value={editAmount}
              onChange={(e) => setEditAmount(e.target.value)}
              placeholder="Qty"
              className="w-20 h-10 bg-slate-700 border-slate-600 text-white text-sm"
              onKeyDown={(e) => {
                if (e.key === 'Enter') handleSave()
                if (e.key === 'Escape') handleCancel()
              }}
            />
            <Select value={editUnit} onValueChange={setEditUnit}>
              <SelectTrigger className="w-28 h-10 bg-slate-700 border-slate-600 text-white text-sm">
                <SelectValue placeholder="Unit" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="__none">No unit</SelectItem>
                {units.map((u) => (
                  <SelectItem key={u} value={u}>{u}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        </div>
        <div className="flex items-center gap-2">
          <Select value={editCategory} onValueChange={setEditCategory}>
            <SelectTrigger className="w-40 h-10 bg-slate-700 border-slate-600 text-white text-sm">
              <SelectValue placeholder="Category" />
            </SelectTrigger>
            <SelectContent>
              {categories.map((c) => (
                <SelectItem key={c} value={c}>{c}</SelectItem>
              ))}
            </SelectContent>
          </Select>
          <div className="flex-1" />
          <Button variant="ghost" size="sm" onClick={handleCancel} className="h-9 px-3 text-slate-400 hover:text-white">
            Cancel
          </Button>
          <Button size="sm" onClick={handleSave} className="h-9 px-3">
            Save
          </Button>
        </div>
      </div>
    )
  }

  return (
    <div className="relative overflow-hidden rounded-md">
      {/* Delete background revealed on swipe */}
      <div className="absolute inset-y-0 right-0 flex items-center justify-center w-20 bg-red-600 text-white">
        <Trash2 className="size-4" />
      </div>
      <div
        ref={swipeRef}
        onTouchStart={handleTouchStart}
        onTouchMove={handleTouchMove}
        onTouchEnd={handleTouchEnd}
        style={{ transform: `translateX(-${swipeOffset}px)` }}
        className={`relative flex items-center gap-3 px-2 py-2.5 rounded-md group bg-slate-900 transition-opacity ${
          !swiping ? 'transition-transform duration-200' : ''
        } ${item.checked ? 'opacity-50' : ''}`}
      >
        <Checkbox
          checked={item.checked}
          onCheckedChange={onToggleCheck}
          className="shrink-0 size-5 border-slate-600 data-[state=checked]:bg-emerald-600 data-[state=checked]:border-emerald-600"
        />

        <div className={`flex-1 min-w-0 ${item.checked ? 'line-through text-slate-400' : ''}`}>
          <span className="text-sm">{item.name}</span>
          {(item.amount != null || item.unit) && (
            <span className="text-xs text-slate-400 ml-2">
              {item.amount != null ? item.amount : ''}{item.unit ? ` ${item.unit}` : ''}
            </span>
          )}
          {item.sources.filter((s) => s.recipe_id).length > 1 && (
            <span className="ml-2 text-[10px] text-slate-500 bg-slate-800 px-1.5 py-0.5 rounded-full">
              {item.sources.filter((s) => s.recipe_id).length} recipes
            </span>
          )}
        </div>

        <Button
          variant="ghost"
          size="icon-xs"
          onClick={() => setEditing(true)}
          className="shrink-0 size-8 text-slate-600 hover:text-slate-300 sm:opacity-0 sm:group-hover:opacity-100 transition-opacity"
        >
          <Pencil className="size-3.5" />
        </Button>
        <Button
          variant="ghost"
          size="icon-xs"
          onClick={onDelete}
          className="shrink-0 size-8 text-slate-600 hover:text-red-400 sm:opacity-0 sm:group-hover:opacity-100 transition-opacity"
        >
          <Trash2 className="size-3.5" />
        </Button>
      </div>
    </div>
  )
}
