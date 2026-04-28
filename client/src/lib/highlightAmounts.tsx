const AMOUNT_RE = /(\d+(?:[./]\d+)?\s*(?:g|kg|mg|ml|l|oz|lb|lbs|tsp|tbsp|cup|cups|teaspoons?|tablespoons?|pinch(?:es)?|bunch(?:es)?|cloves?|sprigs?|slices?|pieces?|handfuls?|dash(?:es)?))\b/gi

export function highlightAmounts(text: string) {
  const parts = text.split(AMOUNT_RE)
  if (parts.length === 1) return text
  return parts.map((part, i) =>
    AMOUNT_RE.test(part) ? (
      <span key={i} className="text-white font-medium">{part}</span>
    ) : (
      part
    )
  )
}
