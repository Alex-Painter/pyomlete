import { useMemo, useState } from 'react'
import { Link } from '@tanstack/react-router'
import { useQueryClient } from '@tanstack/react-query'
import { Check, Clock, Loader2, Plus, Search, Sparkles, Star } from 'lucide-react'
import { BottomSheet } from '@/components/BottomSheet'
import { RecipeThumb } from '@/components/RecipeThumb'
import { formatMinutes } from '@/components/RecipeMetaRow'
import { useUndo } from '@/components/UndoToast'
import { useSuggestionActions } from '@/hooks/useSuggestionActions'
import { apiJson } from '@/lib/api'
import { useRecipes, useSuggestions } from '@/lib/queries'
import type { RecipeSummary, Suggestion } from '@/lib/types'
import { cn } from '@/lib/utils'

/**
 * "Add meals": pick several meals for a list without the sheet closing.
 * Discover's top picks come first, then the library, with search over both.
 * Coming up with new ideas is Discover's job; this only receives them.
 */
export function MealsSheet({
  open,
  onOpenChange,
  listId,
  listName,
  onList,
  onRemove,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  listId: string
  listName: string
  onList: Set<string>
  onRemove: (recipe: RecipeSummary) => void
}) {
  const queryClient = useQueryClient()
  const showUndo = useUndo()
  const { data: recipes, isLoading } = useRecipes()
  const { data: suggestions } = useSuggestions()
  const { addToList } = useSuggestionActions()
  const [query, setQuery] = useState('')
  const [pending, setPending] = useState<Set<string>>(new Set())

  const q = query.trim().toLowerCase()
  const matches = (title: string) => !q || title.toLowerCase().includes(q)

  const picks = useMemo(
    () =>
      (suggestions ?? [])
        .filter((s) => s.status === 'new' || s.status === 'saving')
        .filter((s) => matches(s.title))
        .slice(0, 4),
    [suggestions, q],
  )
  const library = (recipes ?? []).filter((r) => matches(r.title))

  const add = async (recipe: RecipeSummary) => {
    setPending((p) => new Set(p).add(recipe.id))
    try {
      await apiJson(`/api/lists/${listId}/recipes`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ recipe_id: recipe.id }),
      })
      await queryClient.invalidateQueries({ queryKey: ['list', listId] })
      void queryClient.invalidateQueries({ queryKey: ['lists'] })
      showUndo({
        message: `Added ${recipe.title}`,
        onUndo: () => onRemove(recipe),
      })
    } catch {
      showUndo({ message: `Couldn't add ${recipe.title}. Check your connection.` })
    } finally {
      setPending((p) => {
        const next = new Set(p)
        next.delete(recipe.id)
        return next
      })
    }
  }

  const addPick = (s: Suggestion) => void addToList(s, { id: listId, name: listName })

  return (
    <BottomSheet
      open={open}
      onOpenChange={onOpenChange}
      title="Add meals"
      description={`Tap meals to put their ingredients on ${listName}.`}
      height="full"
      footer={
        <button
          type="button"
          onClick={() => onOpenChange(false)}
          className="min-h-[48px] w-full rounded-xl bg-ink text-base font-semibold text-white"
        >
          Done
        </button>
      }
    >
      <label className="relative mb-4 block">
        <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-ink-muted" />
        <input
          type="search"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search meals"
          aria-label="Search meals"
          className="h-11 w-full rounded-xl border border-line bg-cream pl-9 pr-3 text-base outline-none focus:ring-2 focus:ring-ring"
        />
      </label>

      {picks.length > 0 && (
        <section className="mb-5">
          <h3 className="mb-2 flex items-center gap-1.5 text-sm font-semibold text-ink-soft">
            <Sparkles className="size-4 text-[#7a5a12]" />
            Discover picks
          </h3>
          <ul className="space-y-1">
            {picks.map((s) => (
              <li key={s.id}>
                <button
                  type="button"
                  onClick={() => addPick(s)}
                  disabled={s.status === 'saving'}
                  className="flex min-h-[56px] w-full items-center gap-3 rounded-xl px-2 text-left hover:bg-sand disabled:opacity-60"
                >
                  <RecipeThumb src={s.image_url} title={s.title} className="size-12 shrink-0 rounded-lg" />
                  <span className="min-w-0 flex-1">
                    <span className="block font-medium">{s.title}</span>
                    {s.reason && <span className="block truncate text-sm text-ink-muted">{s.reason}</span>}
                  </span>
                  {s.status === 'saving' ? (
                    <Loader2 className="size-5 animate-spin text-ink-muted" />
                  ) : (
                    <Plus className="size-5 text-ink-muted" />
                  )}
                </button>
              </li>
            ))}
          </ul>
        </section>
      )}

      <section>
        <h3 className="mb-2 text-sm font-semibold text-ink-soft">Your recipes</h3>
        {isLoading && <Loader2 className="mx-auto size-5 animate-spin text-ink-muted" />}
        {recipes && recipes.length === 0 && (
          <p className="py-4 text-sm text-ink-muted">
            No recipes yet.{' '}
            <Link to="/create" className="font-medium text-ink underline underline-offset-4">
              Add one
            </Link>{' '}
            or save something from{' '}
            <Link to="/discover" className="font-medium text-ink underline underline-offset-4">
              Discover
            </Link>
            .
          </p>
        )}
        <ul className="space-y-1">
          {library.map((r) => {
            const added = onList.has(r.id)
            const busy = pending.has(r.id)
            return (
              <li key={r.id}>
                <button
                  type="button"
                  aria-pressed={added}
                  disabled={busy}
                  onClick={() => (added ? onRemove(r) : void add(r))}
                  className={cn(
                    'flex min-h-[56px] w-full items-center gap-3 rounded-xl px-2 text-left hover:bg-sand',
                    added && 'bg-[#fdf6e3]',
                  )}
                >
                  <RecipeThumb src={r.image_url} title={r.title} className="size-12 shrink-0 rounded-lg" />
                  <span className="min-w-0 flex-1">
                    <span className="block font-medium">{r.title}</span>
                    <span className="flex items-center gap-2 text-sm text-ink-muted">
                      {r.ingredient_count} ingredients
                      {r.total_minutes != null && (
                        <span className="flex items-center gap-1">
                          <Clock className="size-3" />
                          {formatMinutes(r.total_minutes)}
                        </span>
                      )}
                      {r.rating != null && (
                        <span className="flex items-center gap-0.5">
                          <Star className="size-3 fill-current text-[#b7860b]" />
                          {r.rating}
                        </span>
                      )}
                    </span>
                  </span>
                  {busy ? (
                    <Loader2 className="size-5 animate-spin text-ink-muted" />
                  ) : added ? (
                    <span className="flex size-7 items-center justify-center rounded-full bg-primary">
                      <Check className="size-4" strokeWidth={3} />
                    </span>
                  ) : (
                    <Plus className="size-5 text-ink-muted" />
                  )}
                </button>
              </li>
            )
          })}
        </ul>
      </section>
    </BottomSheet>
  )
}
