import type { ListItem } from '@/lib/types'

/**
 * A best guess at an item's aisle, so a new item can appear in the right
 * place the moment it's typed. The server's /categorize answer replaces it a
 * moment later; when it disagrees the row simply moves.
 */
const KEYWORDS: Array<[string, RegExp]> = [
  [
    'Fresh Produce',
    /\b(apple|banana|lemon|lime|orange|onion|shallot|garlic|ginger|potato|tomato|pepper|chilli|chili|carrot|celery|leek|spinach|lettuce|salad|rocket|kale|cabbage|broccoli|cauliflower|courgette|zucchini|aubergine|eggplant|mushroom|avocado|cucumber|herb|parsley|coriander|cilantro|basil|mint|thyme|rosemary|berr|grape|pear|peach|plum|mango|melon|squash|pumpkin|beetroot|sweetcorn|pea|bean sprout|spring onion|fruit|veg)/i,
  ],
  [
    'Meat & Fish',
    /\b(chicken|beef|pork|lamb|mince|bacon|sausage|ham|chorizo|steak|turkey|duck|salmon|cod|haddock|tuna|prawn|shrimp|fish|mackerel|anchov)/i,
  ],
  [
    'Dairy & Eggs',
    /\b(milk|cream|butter|cheese|cheddar|parmesan|mozzarella|feta|halloumi|yog(h)?urt|egg|crème|creme|ricotta|mascarpone)/i,
  ],
  ['Bakery', /\b(bread|loaf|baguette|roll|bagel|wrap|tortilla|pitta|pita|naan|croissant|bun)/i],
  ['Frozen', /\b(frozen|ice cream|ice)/i],
  [
    'Drinks',
    /\b(juice|wine|beer|cider|coffee|tea\b|squash|cola|lemonade|water|gin|vodka|whisky)/i,
  ],
  [
    'Household',
    /\b(soap|detergent|bleach|bin bag|foil|cling|toilet|kitchen roll|tissue|sponge|washing|shampoo|toothpaste|battery|batteries)/i,
  ],
  [
    'Pantry & Dry Goods',
    /\b(rice|pasta|spaghetti|penne|noodle|flour|sugar|salt|oil|vinegar|stock|tin|can|beans|lentil|chickpea|oats|cereal|honey|jam|sauce|ketchup|mayo|mustard|spice|cumin|paprika|cinnamon|nut|seed|chocolate|biscuit|crisps|coconut milk|passata|puree)/i,
  ],
]

export function guessCategory(
  name: string,
  categories: string[],
  existing: ListItem[] = [],
): string {
  const lower = name.trim().toLowerCase()
  const same = existing.find((i) => i.name.toLowerCase() === lower)
  if (same) return same.category

  const has = new Set(categories)
  for (const [category, re] of KEYWORDS) {
    if (has.has(category) && re.test(lower)) return category
  }
  return has.has('Other') || categories.length === 0 ? 'Other' : categories[categories.length - 1]
}
