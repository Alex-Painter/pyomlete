import type { RecipeMetadata } from '@/components/RecipeMetaRow'

export type ItemSource = {
  recipe_id: string | null
  amount: number | null
}

export type ListItem = {
  id: string
  name: string
  amount: number | null
  unit: string | null
  category: string
  checked: boolean
  sources: ItemSource[]
}

export type ListDetail = {
  id: string
  name: string
  created_at: string | null
  recipes: string[]
  items: ListItem[]
}

export type ListSummary = {
  id: string
  name: string
  created_at: string | null
  item_count: number
  checked_count: number
  recipes: { id: string; title: string }[]
}

export type CategoryConfig = {
  name: string
  order: number
}

export type RecipeSummary = {
  id: string
  title: string
  ingredient_count: number
  rating: number | null
  created_at: string | null
  // Set only on imported recipes.
  image_url: string | null
  total_minutes: number | null
  servings: number | null
  source_name: string | null
}

export type RecipeIngredient = {
  name: string
  unit: string
  // null when the recipe never gave a quantity — "salt and pepper to taste".
  amount: number | null
  // Both set only by a URL import: preparation stripped off the name, and the
  // heading the line sat under on the source page.
  note?: string | null
  group?: string | null
  category: string
  excluded_from_list: boolean
}

export type RecipeDetail = RecipeMetadata & {
  _id: string
  title: string
  instructions: string[]
  ingredients: RecipeIngredient[]
  rating: number | null
  created_at: string
}

export type SuggestionStatus = 'new' | 'saving' | 'saved' | 'failed' | 'dismissed'

/**
 * A Discover card. Deliberately not a recipe: anything that can produce a
 * title and a reason (the suggest endpoint today, a web-searching agent later)
 * fills the same record, and saving one turns it into a recipe in the
 * background.
 */
export type Suggestion = {
  id: string
  title: string
  description: string | null
  reason: string | null
  image_url: string | null
  source_url: string | null
  source_name: string | null
  total_minutes: number | null
  section: string | null
  status: SuggestionStatus
  origin: string
  recipe_id: string | null
  error: string | null
  created_at: string | null
}
