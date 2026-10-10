/**
 * Turn what someone types (or pastes, or dictates) into list items.
 *
 * "2 onions"              → { amount: 2, name: "onions" }
 * "500g mince"            → { amount: 500, unit: "g", name: "mince" }
 * "milk, eggs, bread"     → three items
 * a pasted list, one item per line, with or without bullets → one per line
 *
 * Deliberately forgiving: anything it can't read as a quantity stays in the
 * name, which is what the old three-field form did anyway.
 */

export type ParsedItem = {
  name: string
  amount: number | null
  unit: string | null
}

const UNIT_ALIASES: Record<string, string> = {
  g: 'g',
  gram: 'g',
  grams: 'g',
  gr: 'g',
  kg: 'kg',
  kgs: 'kg',
  kilo: 'kg',
  kilos: 'kg',
  kilogram: 'kg',
  kilograms: 'kg',
  mg: 'mg',
  ml: 'ml',
  millilitre: 'ml',
  millilitres: 'ml',
  milliliter: 'ml',
  milliliters: 'ml',
  l: 'l',
  litre: 'l',
  litres: 'l',
  liter: 'l',
  liters: 'l',
  oz: 'oz',
  lb: 'lb',
  lbs: 'lb',
  tsp: 'tsp',
  teaspoon: 'tsp',
  teaspoons: 'tsp',
  tbsp: 'tbsp',
  tablespoon: 'tbsp',
  tablespoons: 'tbsp',
  cup: 'cup',
  cups: 'cup',
  pint: 'pint',
  pints: 'pint',
  pack: 'pack',
  packs: 'pack',
  packet: 'pack',
  packets: 'pack',
  tin: 'tin',
  tins: 'tin',
  can: 'can',
  cans: 'can',
  jar: 'jar',
  jars: 'jar',
  bottle: 'bottle',
  bottles: 'bottle',
  bag: 'bag',
  bags: 'bag',
  box: 'box',
  boxes: 'box',
  bunch: 'bunch',
  bunches: 'bunch',
  clove: 'clove',
  cloves: 'clove',
  head: 'head',
  heads: 'head',
  slice: 'slice',
  slices: 'slice',
  loaf: 'loaf',
  loaves: 'loaf',
  dozen: 'dozen',
  pinch: 'pinch',
}

const FRACTIONS: Record<string, number> = {
  '½': 0.5,
  '¼': 0.25,
  '¾': 0.75,
  '⅓': 1 / 3,
  '⅔': 2 / 3,
}

const NUMBER = String.raw`(\d+(?:[.,]\d+)?(?:\s*/\s*\d+)?|\d*\s*[½¼¾⅓⅔])`

function parseNumber(raw: string): number | null {
  const s = raw.replace(/\s+/g, '')
  const frac = s.match(/^(\d*)([½¼¾⅓⅔])$/)
  if (frac) return (frac[1] ? Number(frac[1]) : 0) + FRACTIONS[frac[2]]
  const slash = s.match(/^(\d+)\/(\d+)$/)
  if (slash) return Number(slash[1]) / Number(slash[2])
  const n = Number(s.replace(',', '.'))
  return Number.isFinite(n) ? Math.round(n * 1000) / 1000 : null
}

function unitFor(word: string | undefined): string | null {
  if (!word) return null
  return UNIT_ALIASES[word.toLowerCase().replace(/\.$/, '')] ?? null
}

function cleanName(name: string): string {
  return name
    .replace(/^of\s+/i, '')
    .replace(/\s+/g, ' ')
    .trim()
}

export function parseItem(raw: string): ParsedItem | null {
  const text = raw
    .trim()
    // Bullets and numbering from a pasted list: "- milk", "• eggs", "1. bread"
    .replace(/^(?:[-*•·▪◦]+|\d+[.)])\s+/, '')
    .trim()
  if (!text) return null

  // "2 onions", "500g mince", "1.5 kg potatoes", "2 tins of tomatoes"
  const leading = text.match(new RegExp(`^${NUMBER}\\s*([a-zA-Z]+\\.?)?\\s+(.+)$`))
  if (leading) {
    const amount = parseNumber(leading[1])
    const unit = unitFor(leading[2])
    const word = leading[2] as string | undefined
    const name = unit ? leading[3] : `${word ?? ''} ${leading[3]}`
    if (amount != null && cleanName(name)) {
      return { amount, unit, name: cleanName(name) }
    }
  }

  // "milk x2", "eggs ×12", "bananas (6)"
  const trailing = text.match(/^(.+?)\s*(?:[x×]\s*(\d+(?:\.\d+)?)|\((\d+(?:\.\d+)?)\))$/i)
  if (trailing) {
    const amount = Number((trailing[2] as string | undefined) ?? trailing[3])
    if (Number.isFinite(amount)) return { amount, unit: null, name: cleanName(trailing[1]) }
  }

  return { amount: null, unit: null, name: cleanName(text) }
}

/** Split typed or pasted text into items: newlines, commas and semicolons. */
export function parseItems(raw: string): ParsedItem[] {
  return raw
    .split(/[\n,;]+/)
    .map(parseItem)
    .filter((i): i is ParsedItem => i != null && i.name.length > 0)
}

// How recipe units read on a list: "400 grams" → "400g", "1 whole" → "1".
const DISPLAY_UNITS: Record<string, string> = {
  grams: 'g',
  gram: 'g',
  kilograms: 'kg',
  millilitres: 'ml',
  milliliters: 'ml',
  litres: 'l',
  liters: 'l',
  whole: '',
}

export function formatQuantity(amount: number | null, rawUnit: string | null): string {
  if (amount == null) return rawUnit === 'whole' ? '' : (rawUnit ?? '')
  const unit = rawUnit ? (DISPLAY_UNITS[rawUnit.toLowerCase()] ?? rawUnit) : null
  const n = Number.isInteger(amount) ? String(amount) : String(Math.round(amount * 100) / 100)
  if (!unit) return n
  // "500g", "2 tins": short metric units sit against the number.
  return /^(g|kg|mg|ml|l|oz|lb)$/.test(unit) ? `${n}${unit}` : `${n} ${unit}`
}
