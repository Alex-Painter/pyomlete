import { useQuery } from '@tanstack/react-query'
import { apiJson } from '@/lib/api'
import { fetchListWithPending } from '@/lib/offline'
import type {
  CategoryConfig,
  ListSummary,
  RecipeDetail,
  RecipeSummary,
  Suggestion,
} from '@/lib/types'

export function useLists() {
  return useQuery({
    queryKey: ['lists'],
    queryFn: () => apiJson<ListSummary[]>('/api/lists/'),
  })
}

/**
 * One list, as the phone last saw it plus any changes still waiting to sync.
 * `networkMode: 'always'` so a phone with no signal still runs the query and
 * falls back to its saved copy instead of sitting in a paused state.
 */
export function useList(listId: string) {
  return useQuery({
    queryKey: ['list', listId],
    queryFn: () => fetchListWithPending(listId),
    networkMode: 'always',
  })
}

export function useCategories() {
  return useQuery({
    queryKey: ['categories'],
    queryFn: () => apiJson<CategoryConfig[]>('/api/settings/categories'),
    select: (cats) => [...cats].sort((a, b) => a.order - b.order),
  })
}

export function useRecipes() {
  return useQuery({
    queryKey: ['recipes'],
    queryFn: () => apiJson<RecipeSummary[]>('/api/recipes/'),
  })
}

export function useRecipe(recipeId: string) {
  return useQuery({
    queryKey: ['recipe', recipeId],
    queryFn: () => apiJson<RecipeDetail>(`/api/recipes/${recipeId}`),
  })
}

export function useUnits() {
  return useQuery({
    queryKey: ['units'],
    queryFn: () => apiJson<string[]>('/api/units'),
  })
}

export function useSuggestions() {
  return useQuery({
    queryKey: ['suggestions'],
    queryFn: () => apiJson<Suggestion[]>('/api/suggestions/'),
    // A saved card turns into a recipe in the background; keep looking until
    // every one has landed.
    refetchInterval: (query) =>
      query.state.data?.some((s) => s.status === 'saving') ? 3000 : false,
  })
}
