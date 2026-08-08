import { highlightAmounts } from '@/lib/highlightAmounts'
import { groupIngredients } from '@/lib/groupIngredients'
import { RecipeHeroImage, RecipeMetaRow } from '@/components/RecipeMetaRow'
import type { RecipeMetadata } from '@/components/RecipeMetaRow'

type IngredientRecipe = {
  name: string
  unit: string
  // null when the recipe never gave a quantity — "salt and pepper to taste".
  amount: number | null
  note?: string | null
  group?: string | null
  category?: string
  excluded_from_list?: boolean
}

export type Recipe = RecipeMetadata & {
  title: string
  instructions: string[]
  ingredients: IngredientRecipe[]
}

function formatAmount(ing: IngredientRecipe): string {
  if (ing.amount == null) return ing.unit
  return `${ing.amount} ${ing.unit}`.trim()
}

export function RecipeCard({ recipe }: { recipe: Recipe }) {
  const groups = groupIngredients(recipe.ingredients)

  return (
    <div className="bg-white border border-line rounded-xl overflow-hidden shadow-sm">
      {recipe.image_url && (
        <RecipeHeroImage
          src={recipe.image_url}
          alt={recipe.title}
          className="h-48 sm:h-56"
        />
      )}

      <div className="p-6 space-y-5">
        <div className="space-y-2">
          <h2 className="text-xl font-semibold text-ink">{recipe.title}</h2>
          <RecipeMetaRow recipe={recipe} />
        </div>

        <div>
          <h3 className="text-xs font-semibold text-ink-muted uppercase tracking-wider mb-3">
            Ingredients
          </h3>
          <div className="space-y-4">
            {groups.map((group) => (
              <div key={group.heading || 'ungrouped'}>
                {group.heading && (
                  <h4 className="text-xs font-medium text-ink-soft mb-2">
                    {group.heading}
                  </h4>
                )}
                <ul className="space-y-1.5">
                  {group.items.map(({ ingredient, index }) => (
                    <li key={index} className="text-sm text-ink-soft flex gap-2">
                      <span className="flex-1">
                        {ingredient.name}
                        {ingredient.note && (
                          <span className="text-ink-faint">, {ingredient.note}</span>
                        )}
                      </span>
                      <span className="text-ink font-medium shrink-0">
                        {formatAmount(ingredient)}
                      </span>
                    </li>
                  ))}
                </ul>
              </div>
            ))}
          </div>
        </div>

        <div>
          <h3 className="text-xs font-semibold text-ink-muted uppercase tracking-wider mb-3">
            Instructions
          </h3>
          <ol className="space-y-2.5">
            {recipe.instructions.map((step, i) => (
              <li key={i} className="text-sm text-ink-soft flex gap-3">
                <span className="text-ink-faint font-mono shrink-0 pt-px">
                  {i + 1}.
                </span>
                <span>{highlightAmounts(step)}</span>
              </li>
            ))}
          </ol>
        </div>
      </div>
    </div>
  )
}
