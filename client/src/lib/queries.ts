import { useQuery } from '@tanstack/react-query'
import { apiJson } from '@/lib/api'
import { fetchListWithPending } from '@/lib/offline'
import type {
  CategoryConfig,
  ListSummary,
  PlanSettings,
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

type WeekFields = 'ingredient_names' | 'cuisine' | 'last_planned_on'
// A server from before week plans leaves these out.
type RecipeRow = Omit<RecipeSummary, WeekFields> & Partial<Pick<RecipeSummary, WeekFields>>

export function useRecipes() {
  return useQuery({
    queryKey: ['recipes'],
    queryFn: async () =>
      (await apiJson<RecipeRow[]>('/api/recipes/')).map(
        (r): RecipeSummary => ({
          ...r,
          ingredient_names: r.ingredient_names ?? [],
          cuisine: r.cuisine ?? null,
          last_planned_on: r.last_planned_on ?? null,
        }),
      ),
  })
}

const DEFAULT_PLAN_SETTINGS: PlanSettings = { week_start_weekday: 5 }

/** Which weekday a week starts on. Falls back to Saturday when unreachable. */
export function usePlanSettings() {
  return useQuery({
    queryKey: ['settings', 'plan'],
    queryFn: () =>
      apiJson<PlanSettings>('/api/settings/plan').catch(() => DEFAULT_PLAN_SETTINGS),
    placeholderData: DEFAULT_PLAN_SETTINGS,
    staleTime: 60 * 60 * 1000,
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
