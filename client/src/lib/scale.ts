/**
 * Scale amounts for a different number of servings.
 */
export function scaleAmount(amount: number | null, factor: number): number | null {
  if (amount == null) return null
  const scaled = amount * factor
  // Keep it readable: whole numbers stay whole, small ones keep a decimal.
  if (scaled >= 10) return Math.round(scaled)
  return Math.round(scaled * 10) / 10
}

const AMOUNT_IN_TEXT =
  /(\d+(?:\.\d+)?)(\s*(?:g|kg|mg|ml|l|oz|lb|lbs|tsp|tbsp|cups?|teaspoons?|tablespoons?)\b)/gi

/** Scale the quantities written into a step: "add the 500g pasta". */
export function scaleText(text: string, factor: number): string {
  if (factor === 1) return text
  return text.replace(AMOUNT_IN_TEXT, (_m, n: string, unit: string) => {
    const scaled = scaleAmount(Number(n), factor)
    return `${scaled}${unit}`
  })
}
