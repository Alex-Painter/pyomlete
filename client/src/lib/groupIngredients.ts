/**
 * Split ingredients into the runs the source page had them in.
 *
 * URL imports carry the "For the sauce:" headings through from the origin;
 * everything else has no groups at all and collapses to a single unnamed run.
 * The original array index rides along because callers act on ingredients by
 * position (excluding one from a shopping list, for instance), and grouping
 * must not renumber them.
 */
export function groupIngredients<T extends { group?: string | null }>(
  ingredients: T[],
): Array<{ heading: string; items: Array<{ ingredient: T; index: number }> }> {
  const groups: Array<{
    heading: string
    items: Array<{ ingredient: T; index: number }>
  }> = []

  ingredients.forEach((ingredient, index) => {
    const heading = ingredient.group ?? ''
    const current = groups.at(-1)
    if (current?.heading === heading) current.items.push({ ingredient, index })
    else groups.push({ heading, items: [{ ingredient, index }] })
  })

  return groups
}
