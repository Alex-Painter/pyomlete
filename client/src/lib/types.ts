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
  /** A quick night: dinners over 30 minutes sink. Kept when a meal goes on the day. */
  quick?: boolean
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

/** The household's Google Calendar connection, from `GET /api/calendar`. */
export type CalendarStatus = {
  /** False when the server has no Google client: the calendar isn't offered. */
  configured: boolean
  connected: boolean
  calendars: { id: string; name: string; chosen: boolean }[]
  /** "HH:MM", local. */
  dinner_start: string
  dinner_end: string
}

export type PlanSettings = {
  /** 0 is Monday. Defaults to 5, Saturday: the week runs from one shop to the next. */
  week_start_weekday: number
  /** How many days a base (pasta, rice...) stays off the menu after it's had. Defaults to 3. */
  variety_days: number
}

/** When Chef plans the coming week on its own, in UK time. */
export type WeeklyPlanSettings = {
  weekly_plan: boolean
  /** 0 is Monday. Sunday by default. */
  weekly_plan_weekday: number
  weekly_plan_hour: number
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
  /** Set by Claude after the recipe is saved; null until then. */
  tags: RecipeTags | null
  /** The latest day this recipe was planned on, across every list. */
  last_planned_on: ISODate | null
}

export type RecipeBase = 'rice' | 'pasta' | 'potatoes' | 'bread' | 'noodles' | 'none'
export type RecipeMain = 'chicken' | 'beef' | 'pork' | 'lamb' | 'fish' | 'veggie' | 'beans'
export type RecipeMood = 'comforting' | 'fresh' | 'different'
export type CuisineFamily =
  | 'british'
  | 'french'
  | 'italian'
  | 'spanish'
  | 'greek'
  | 'middle_eastern'
  | 'north_african'
  | 'indian'
  | 'chinese'
  | 'japanese'
  | 'korean'
  | 'south_east_asian'
  | 'mexican'
  | 'latin_american'
  | 'american'
  | 'other'

/** What a dinner is built on, for the week's variety rules (`server/recipe_tagger.py`). */
export type RecipeTags = {
  base: RecipeBase
  main: RecipeMain
  mood: RecipeMood
  cuisine: CuisineFamily
  traits: { oily_fish: boolean; red_meat: boolean; veg_led: boolean; legumes: boolean }
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

export type Stance = 'never' | 'avoid' | 'prefer' | 'more' | 'less'

/** Something Chef knows about the household's taste, told or inferred. */
export type Preference = {
  id: string
  subject: string
  stance: Stance
  /** What it's based on, shown under it: "You said so on 18 Oct". */
  evidence: string
  source: 'told' | 'inferred'
  forgotten: boolean
}

/** One dinner on Chef's week card: one of their recipes, or a new idea. */
export type WeekMeal = {
  day: ISODate
  title: string
  reason: string
  recipe_id: string | null
  is_new: boolean
  image_url: string | null
  source_url: string | null
}

/** A week of dinners Chef proposes. Nothing changes until Make the list. */
export type WeekPlan = {
  id: string
  week_of: ISODate
  note: string
  status: 'new' | 'made' | 'skipped'
  list_id: string | null
  meals: WeekMeal[]
}
