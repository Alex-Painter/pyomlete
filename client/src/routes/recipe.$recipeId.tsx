import { useState } from 'react'
import { createFileRoute, Link, useNavigate } from '@tanstack/react-router'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import {
  ArrowDown,
  ArrowLeft,
  ArrowUp,
  Check,
  ChefHat,
  Loader2,
  MoreHorizontal,
  Pencil,
  Plus,
  Trash2,
  X,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { ActionSheet } from '@/components/BottomSheet'
import { AddToListButton } from '@/components/AddToListButton'
import { BackLink } from '@/components/BackLink'
import { ErrorState } from '@/components/ErrorState'
import { StarRating } from '@/components/StarRating'
import { RecipeHeroImage, RecipeMetaRow } from '@/components/RecipeMetaRow'
import { useUndo } from '@/components/UndoToast'
import { useAddRecipeToList } from '@/hooks/useAddToList'
import { apiFetch, apiJson } from '@/lib/api'
import { groupIngredients } from '@/lib/groupIngredients'
import { highlightAmounts } from '@/lib/highlightAmounts'
import { formatQuantity } from '@/lib/parseItems'
import { useCategories, useRecipe, useUnits } from '@/lib/queries'
import type { RecipeIngredient, RecipeSummary } from '@/lib/types'
import { cn } from '@/lib/utils'
import '@/index.css'

// While editing, amount is kept as a raw string so the field can be cleared
// (otherwise an empty input snaps back to 0 and can't be deleted).
type EditIngredient = Omit<RecipeIngredient, 'amount'> & { amount: string }

export const Route = createFileRoute('/recipe/$recipeId')({
  component: RecipeDetailPage,
})

function RecipeDetailPage() {
  const { recipeId } = Route.useParams()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const showUndo = useUndo()
  const addRecipeToList = useAddRecipeToList()
  const [editing, setEditing] = useState(false)
  const [menuOpen, setMenuOpen] = useState(false)
  const [editTitle, setEditTitle] = useState('')
  const [editInstructions, setEditInstructions] = useState<string[]>([])
  const [editIngredients, setEditIngredients] = useState<EditIngredient[]>([])

  const { data: recipe, isLoading, error, refetch } = useRecipe(recipeId)
  const { data: categories } = useCategories()
  const { data: units } = useUnits()

  const ratingMutation = useMutation({
    mutationFn: (rating: number) =>
      apiJson(`/api/recipes/${recipeId}/rating`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rating }),
      }),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['recipe', recipeId] })
      void queryClient.invalidateQueries({ queryKey: ['recipes'] })
    },
  })

  const saveRecipe = useMutation({
    mutationFn: () =>
      apiJson(`/api/recipes/${recipeId}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          title: editTitle,
          instructions: editInstructions.filter((s) => s.trim()),
          ingredients: editIngredients
            .filter((ing) => ing.name.trim())
            .map((ing) => ({
              ...ing,
              // An empty field means the ingredient has no quantity ("salt, to
              // taste"), which the API stores as null. Coercing it to 0 here
              // would overwrite that with a number nobody typed.
              amount: ing.amount.trim() === '' ? null : parseFloat(ing.amount) || 0,
            })),
        }),
      }),
    onSuccess: () => {
      setEditing(false)
      void queryClient.invalidateQueries({ queryKey: ['recipe', recipeId] })
      void queryClient.invalidateQueries({ queryKey: ['recipes'] })
    },
  })

  const toggleExclude = useMutation({
    mutationFn: ({ index, excluded }: { index: number; excluded: boolean }) =>
      apiJson(`/api/recipes/${recipeId}/ingredients/${index}/exclude`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ excluded }),
      }),
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: ['recipe', recipeId] }),
  })

  const deleteRecipe = () => {
    if (!recipe) return
    queryClient.setQueryData<RecipeSummary[]>(['recipes'], (old) =>
      old?.filter((r) => r.id !== recipeId),
    )
    void navigate({ to: '/recipes' })
    showUndo({
      message: `Deleted ${recipe.title}`,
      onUndo: () => void queryClient.invalidateQueries({ queryKey: ['recipes'] }),
      onCommit: () =>
        void apiFetch(`/api/recipes/${recipeId}`, { method: 'DELETE', keepalive: true }).then(() =>
          queryClient.invalidateQueries({ queryKey: ['recipes'] }),
        ),
    })
  }

  const startEditing = () => {
    if (!recipe) return
    setEditTitle(recipe.title)
    setEditInstructions([...recipe.instructions])
    setEditIngredients(
      recipe.ingredients.map((i) => ({ ...i, amount: i.amount == null ? '' : String(i.amount) })),
    )
    setEditing(true)
  }

  const updateIngredient = (i: number, patch: Partial<EditIngredient>) =>
    setEditIngredients((prev) => prev.map((ing, idx) => (idx === i ? { ...ing, ...patch } : ing)))

  return (
    <main className="min-h-screen bg-cream pb-24 text-ink">
      <div className="mx-auto max-w-5xl px-4 py-4 sm:px-6 sm:py-8">
        <div className="mb-4 flex items-center justify-between">
          <BackLink
            to="/recipes"
            className="-ml-2 flex min-h-[44px] items-center gap-1.5 rounded-lg px-2 text-sm font-medium text-ink-soft hover:bg-sand hover:text-ink"
          >
            <ArrowLeft className="size-4" />
            Back
          </BackLink>
          {recipe && !editing && (
            <button
              type="button"
              aria-label="More actions"
              onClick={() => setMenuOpen(true)}
              className="flex size-11 items-center justify-center rounded-full text-ink-soft hover:bg-sand hover:text-ink"
            >
              <MoreHorizontal className="size-5" />
            </button>
          )}
        </div>

        {isLoading && (
          <div className="flex items-center gap-2 text-ink-muted">
            <Loader2 className="size-5 animate-spin" />
            Loading recipe…
          </div>
        )}

        {error && (
          <ErrorState
            error={error}
            onRetry={() => void refetch()}
            notFoundMessage="This recipe doesn't exist any more. It may have been deleted."
          />
        )}

        {recipe && (
          <article className="space-y-6">
            {recipe.image_url && !editing && (
              <RecipeHeroImage
                src={recipe.image_url}
                alt={recipe.title}
                className="h-56 rounded-2xl sm:h-80"
              />
            )}

            <div className="space-y-3">
              {editing ? (
                <input
                  value={editTitle}
                  onChange={(e) => setEditTitle(e.target.value)}
                  aria-label="Title"
                  className="h-12 w-full rounded-xl border border-line bg-white px-3 text-xl font-semibold outline-none focus:ring-2 focus:ring-ring"
                />
              ) : (
                <h1 className="text-3xl font-bold tracking-tight">{recipe.title}</h1>
              )}
              {!editing && <RecipeMetaRow recipe={recipe} />}
              {!editing && recipe.created_at && (
                <p className="text-sm text-ink-muted">
                  Added{' '}
                  {new Date(recipe.created_at).toLocaleDateString(undefined, {
                    day: 'numeric',
                    month: 'short',
                    year: 'numeric',
                  })}
                </p>
              )}
            </div>

            {!editing && (
              <div className="flex flex-wrap items-center gap-3">
                <Link
                  to="/cook/$recipeId"
                  params={{ recipeId }}
                  className="flex min-h-[48px] items-center gap-2 rounded-xl bg-ink px-5 text-base font-semibold text-white shadow-sm hover:bg-ink/90"
                >
                  <ChefHat className="size-5" />
                  Cook
                </Link>
                <AddToListButton
                  className="min-h-[48px]"
                  onAdd={(list) => addRecipeToList(recipeId, recipe.title, list)}
                />
                <div className="flex items-center gap-1 sm:ml-auto">
                  <span className="text-sm text-ink-muted">Your rating</span>
                  <StarRating
                    value={recipe.rating}
                    label="Your rating"
                    onChange={(rating) => ratingMutation.mutate(rating)}
                  />
                </div>
              </div>
            )}

            <div className="grid gap-6 lg:grid-cols-[minmax(0,2fr)_minmax(0,3fr)] lg:items-start">
              {/* Ingredients */}
              <section className="rounded-2xl border border-line bg-white p-4 shadow-sm sm:p-5">
                <h2 className="text-lg font-semibold">Ingredients</h2>
                {editing ? (
                  <div className="mt-3 space-y-3">
                    <datalist id="unit-options">
                      {(units ?? []).concat(['to taste', 'whole', 'pinch']).map((u) => (
                        <option key={u} value={u} />
                      ))}
                    </datalist>
                    {editIngredients.map((ing, i) => (
                      <div key={i} className="space-y-2 rounded-xl bg-cream p-3">
                        <div className="flex items-center gap-2">
                          <input
                            value={ing.name}
                            onChange={(e) => updateIngredient(i, { name: e.target.value })}
                            placeholder="Ingredient"
                            aria-label="Ingredient name"
                            className="h-11 min-w-0 flex-1 rounded-lg border border-line bg-white px-3 text-sm outline-none focus:ring-2 focus:ring-ring"
                          />
                          <button
                            type="button"
                            onClick={() => setEditIngredients(editIngredients.filter((_, idx) => idx !== i))}
                            aria-label={`Remove ${ing.name || 'ingredient'}`}
                            className="flex size-11 shrink-0 items-center justify-center rounded-lg text-ink-muted hover:bg-white hover:text-danger"
                          >
                            <X className="size-4" />
                          </button>
                        </div>
                        <div className="flex flex-wrap gap-2">
                          <input
                            inputMode="decimal"
                            value={ing.amount}
                            onChange={(e) => {
                              const v = e.target.value
                              if (v === '' || /^\d*\.?\d*$/.test(v)) updateIngredient(i, { amount: v })
                            }}
                            placeholder="Qty"
                            aria-label="Quantity"
                            className="h-11 w-20 rounded-lg border border-line bg-white px-3 text-sm outline-none focus:ring-2 focus:ring-ring"
                          />
                          <input
                            list="unit-options"
                            value={ing.unit}
                            onChange={(e) => updateIngredient(i, { unit: e.target.value })}
                            placeholder="Unit"
                            aria-label="Unit"
                            className="h-11 w-28 rounded-lg border border-line bg-white px-3 text-sm outline-none focus:ring-2 focus:ring-ring"
                          />
                          <select
                            value={ing.category}
                            onChange={(e) => updateIngredient(i, { category: e.target.value })}
                            aria-label="Aisle"
                            className="h-11 min-w-0 flex-1 rounded-lg border border-line bg-white px-2 text-sm"
                          >
                            {(categories ?? []).map((c) => (
                              <option key={c.name} value={c.name}>
                                {c.name}
                              </option>
                            ))}
                          </select>
                        </div>
                      </div>
                    ))}
                    <Button
                      variant="ghost"
                      onClick={() =>
                        setEditIngredients([
                          ...editIngredients,
                          { name: '', unit: '', amount: '', category: 'Other', excluded_from_list: false },
                        ])
                      }
                      className="min-h-[44px] text-ink-soft"
                    >
                      <Plus className="size-4" />
                      Add ingredient
                    </Button>
                  </div>
                ) : (
                  <>
                    <p className="mb-3 mt-1 text-sm text-ink-muted">
                      Turn off anything you always have, like salt. It won't go on shopping lists.
                    </p>
                    <div className="space-y-4">
                      {groupIngredients(recipe.ingredients).map((group) => (
                        <div key={group.heading || 'ungrouped'}>
                          {group.heading && (
                            <h3 className="mb-1 text-sm font-semibold text-ink-soft">{group.heading}</h3>
                          )}
                          <ul className="divide-y divide-line">
                            {group.items.map(({ ingredient: ing, index }) => (
                              <li key={index} className="flex items-center gap-3 py-2">
                                <span className={cn('min-w-0 flex-1', ing.excluded_from_list && 'text-ink-muted')}>
                                  {ing.name}
                                  {ing.note && <span className="text-ink-muted">, {ing.note}</span>}
                                </span>
                                <span className="shrink-0 text-sm font-medium tabular-nums">
                                  {formatQuantity(ing.amount, ing.unit || null)}
                                </span>
                                <button
                                  type="button"
                                  aria-pressed={!ing.excluded_from_list}
                                  aria-label={`${ing.name}: ${ing.excluded_from_list ? 'not on shopping lists' : 'on shopping lists'}`}
                                  onClick={() =>
                                    toggleExclude.mutate({ index, excluded: !ing.excluded_from_list })
                                  }
                                  className={cn(
                                    'min-h-[36px] shrink-0 rounded-full border px-2.5 text-xs font-medium',
                                    ing.excluded_from_list
                                      ? 'border-line text-ink-muted'
                                      : 'border-transparent bg-[#fdf6e3] text-[#7a5a12]',
                                  )}
                                >
                                  {ing.excluded_from_list ? 'Not on list' : 'On list'}
                                </button>
                              </li>
                            ))}
                          </ul>
                        </div>
                      ))}
                    </div>
                  </>
                )}
              </section>

              {/* Method */}
              <section className="rounded-2xl border border-line bg-white p-4 shadow-sm sm:p-5">
                <h2 className="mb-3 text-lg font-semibold">Method</h2>
                {editing ? (
                  <div className="space-y-3">
                    {editInstructions.map((step, i) => (
                      <div key={i} className="flex gap-2">
                        <span className="pt-2.5 text-sm font-semibold text-ink-muted">{i + 1}</span>
                        <textarea
                          value={step}
                          onChange={(e) =>
                            setEditInstructions(editInstructions.map((s, idx) => (idx === i ? e.target.value : s)))
                          }
                          rows={3}
                          aria-label={`Step ${i + 1}`}
                          className="min-w-0 flex-1 resize-y rounded-lg border border-line bg-cream px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-ring"
                        />
                        <div className="flex flex-col">
                          <button
                            type="button"
                            aria-label={`Move step ${i + 1} up`}
                            disabled={i === 0}
                            onClick={() => {
                              const u = [...editInstructions]
                              ;[u[i - 1], u[i]] = [u[i], u[i - 1]]
                              setEditInstructions(u)
                            }}
                            className="flex size-9 items-center justify-center rounded-lg text-ink-muted hover:bg-sand disabled:opacity-30"
                          >
                            <ArrowUp className="size-4" />
                          </button>
                          <button
                            type="button"
                            aria-label={`Move step ${i + 1} down`}
                            disabled={i === editInstructions.length - 1}
                            onClick={() => {
                              const u = [...editInstructions]
                              ;[u[i], u[i + 1]] = [u[i + 1], u[i]]
                              setEditInstructions(u)
                            }}
                            className="flex size-9 items-center justify-center rounded-lg text-ink-muted hover:bg-sand disabled:opacity-30"
                          >
                            <ArrowDown className="size-4" />
                          </button>
                          <button
                            type="button"
                            aria-label={`Remove step ${i + 1}`}
                            onClick={() => setEditInstructions(editInstructions.filter((_, idx) => idx !== i))}
                            className="flex size-9 items-center justify-center rounded-lg text-ink-muted hover:bg-sand hover:text-danger"
                          >
                            <X className="size-4" />
                          </button>
                        </div>
                      </div>
                    ))}
                    <Button
                      variant="ghost"
                      onClick={() => setEditInstructions([...editInstructions, ''])}
                      className="min-h-[44px] text-ink-soft"
                    >
                      <Plus className="size-4" />
                      Add step
                    </Button>
                  </div>
                ) : (
                  <ol className="space-y-4">
                    {recipe.instructions.map((step, i) => (
                      <li key={i} className="flex gap-3">
                        <span className="flex size-7 shrink-0 items-center justify-center rounded-full bg-cream text-sm font-semibold text-ink-soft">
                          {i + 1}
                        </span>
                        <span className="pt-0.5 leading-relaxed text-ink-soft">{highlightAmounts(step)}</span>
                      </li>
                    ))}
                  </ol>
                )}
              </section>
            </div>
          </article>
        )}
      </div>

      {/* Save / Cancel stay in reach however far down the edit goes. */}
      {editing && (
        <div className="fixed inset-x-0 bottom-[calc(3.5rem+env(safe-area-inset-bottom))] z-40 border-t border-line bg-white/95 px-4 py-3 backdrop-blur sm:bottom-0">
          <div className="mx-auto flex max-w-5xl justify-end gap-2">
            <Button variant="ghost" onClick={() => setEditing(false)} className="min-h-[44px] text-ink-soft">
              Cancel
            </Button>
            <Button
              onClick={() => saveRecipe.mutate()}
              disabled={saveRecipe.isPending}
              className="min-h-[44px] px-6 font-semibold"
            >
              {saveRecipe.isPending ? <Loader2 className="size-4 animate-spin" /> : <Check className="size-4" />}
              Save
            </Button>
          </div>
        </div>
      )}

      <ActionSheet
        open={menuOpen}
        onOpenChange={setMenuOpen}
        title={recipe?.title ?? ''}
        actions={[
          { label: 'Edit recipe', icon: <Pencil className="size-5 text-ink-muted" />, onSelect: startEditing },
          {
            label: 'Delete recipe',
            destructive: true,
            icon: <Trash2 className="size-5" />,
            onSelect: deleteRecipe,
          },
        ]}
      />
    </main>
  )
}
