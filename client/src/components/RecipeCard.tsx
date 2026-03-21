type IngredientRecipe = { name: string; unit: string; amount: number }
export type Recipe = { title: string; instructions: string[]; ingredients: IngredientRecipe[] }

export function RecipeCard({ recipe }: { recipe: Recipe }) {
  return (
    <div className="bg-slate-800 border border-slate-700 rounded-xl p-6 space-y-5">
      <h2 className="text-xl font-semibold text-white">{recipe.title}</h2>

      <div>
        <h3 className="text-xs font-semibold text-slate-400 uppercase tracking-wider mb-3">
          Ingredients
        </h3>
        <ul className="space-y-1.5">
          {recipe.ingredients.map((ing, i) => (
            <li key={i} className="text-sm text-slate-300 flex gap-2">
              <span className="text-white font-medium shrink-0">
                {ing.amount} {ing.unit}
              </span>
              <span>{ing.name}</span>
            </li>
          ))}
        </ul>
      </div>

      <div>
        <h3 className="text-xs font-semibold text-slate-400 uppercase tracking-wider mb-3">
          Instructions
        </h3>
        <ol className="space-y-2.5">
          {recipe.instructions.map((step, i) => (
            <li key={i} className="text-sm text-slate-300 flex gap-3">
              <span className="text-slate-500 font-mono shrink-0 pt-px">{i + 1}.</span>
              <span>{step}</span>
            </li>
          ))}
        </ol>
      </div>
    </div>
  )
}
