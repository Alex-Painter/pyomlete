import { highlightAmounts } from '@/lib/highlightAmounts'

type IngredientRecipe = { name: string; unit: string; amount: number; category?: string; excluded_from_list?: boolean }
export type Recipe = { title: string; instructions: string[]; ingredients: IngredientRecipe[] }

export function RecipeCard({ recipe }: { recipe: Recipe }) {
  return (
    <div className="bg-white border border-[#E8E4DC] rounded-xl p-6 space-y-5 shadow-sm">
      <h2 className="text-xl font-semibold text-[#222]">{recipe.title}</h2>

      <div>
        <h3 className="text-xs font-semibold text-[#8E8E8E] uppercase tracking-wider mb-3">
          Ingredients
        </h3>
        <ul className="space-y-1.5">
          {recipe.ingredients.map((ing, i) => (
            <li key={i} className="text-sm text-[#444] flex gap-2">
              <span className="flex-1">{ing.name}</span>
              <span className="text-[#222] font-medium shrink-0">
                {ing.amount} {ing.unit}
              </span>
            </li>
          ))}
        </ul>
      </div>

      <div>
        <h3 className="text-xs font-semibold text-[#8E8E8E] uppercase tracking-wider mb-3">
          Instructions
        </h3>
        <ol className="space-y-2.5">
          {recipe.instructions.map((step, i) => (
            <li key={i} className="text-sm text-[#444] flex gap-3">
              <span className="text-[#ADADAD] font-mono shrink-0 pt-px">{i + 1}.</span>
              <span>{highlightAmounts(step)}</span>
            </li>
          ))}
        </ol>
      </div>
    </div>
  )
}
