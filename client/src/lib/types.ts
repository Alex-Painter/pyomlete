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

/** A calendar date as the API sends it, `YYYY-MM-DD`, with no time zone. */
export type ISODate = string

export type DayStatus = 'open' | 'out'

/**
 * One evening of a week list. Every `recipe_id` here is also in the list's
 * `recipes`; a recipe on the list with no day is an any-day meal.
 */
export type PlanDay = {
  date: ISODate
  recipe_id: string | null
  status: DayStatus
  origin: 'user' | 'calendar' | 'chef'
}

export type ListDetail = {
  id: string
  name: string
  created_at: string | null
  recipes: string[]
  /** The meals on the list that have been cooked, a subset of `recipes`. */
  cooked: string[]
  items: ListItem[]
  /** Set on a week list, null on a plain list. */
  week_start: ISODate | null
  /** Seven consecutive days on a week list, empty on a plain list. */
  days: PlanDay[]
}

export type ListSummary = {
  id: string
  name: string
  created_at: string | null
  item_count: number
  checked_count: number
  recipes: { id: string; title: string; cooked: boolean }[]
  week_start: ISODate | null
  days: PlanDay[]
}

export type PlanSettings = {
  /** 0 is Monday. Defaults to 5, Saturday: the week runs from one shop to the next. */
  week_start_weekday: number
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
  ingredient_names: string[]
  cuisine: string | null
  /** The latest day this recipe was planned on, across every list. */
  last_planned_on: ISODate | null
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

export type SuggestionStatus = 'new' | 'saving' | 'saved' | 'failed' | 'dismissed' | 'cleared'

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
