import Foundation

/// What a save sends: the three things `PUT /recipes/{id}` replaces. The
/// ingredients are whole, because the server swaps the list and keeps nothing
/// that is not sent back.
nonisolated struct RecipeEdit: Equatable, Sendable {
    /// Which ingredient of the recipe a saved ingredient began as.
    struct Origin: Equatable, Sendable {
        let index: Int
        let name: String
    }

    var title: String
    var steps: [String]
    var ingredients: [Recipe.Ingredient]
    /// One per ingredient, nil for one that was added. Empty when the edit was not made from a draft.
    var origins: [Origin?] = []

    /// The same edit with the fields no editor touches (note, group and the
    /// on-list flag) as `current` has them now. A draft copies them when it
    /// is made, and the flag can change, or fail to, before the save goes out.
    /// An ingredient that has moved or been renamed since keeps the draft's copy.
    func carryingUntouched(from current: Recipe) -> RecipeEdit {
        var edit = self
        for (place, origin) in origins.enumerated() {
            guard let origin, edit.ingredients.indices.contains(place),
                  current.ingredients.indices.contains(origin.index)
            else { continue }
            let now = current.ingredients[origin.index]
            guard now.name == origin.name else { continue }
            edit.ingredients[place].note = now.note
            edit.ingredients[place].group = now.group
            edit.ingredients[place].isOnList = now.isOnList
        }
        return edit
    }
}

/// A recipe while it is being edited. Apart from `Recipe` so a quantity can be
/// an empty field and a half-typed row can exist; `outcome` is the only way
/// back, and holds every rule about what is saved.
///
/// Invariant: row ids are unique within a draft and never reused, so a row
/// keeps its identity when others are added, removed or moved. Rows are made
/// only here: by `init`, `addIngredient()` and `addStep()`.
nonisolated struct RecipeDraft: Equatable, Sendable, Identifiable {
    typealias RowID = Int

    struct IngredientRow: Equatable, Sendable, Identifiable {
        let id: RowID
        var name: String
        /// As typed. Empty means the recipe gives no quantity.
        var quantity: String
        var unit: String
        /// nil until an aisle is picked for an ingredient the server sent without one.
        var aisle: String?
        /// The ingredient this row began as, nil for an added row. Its note,
        /// group and on-list flag are not editable here and are saved as they were.
        fileprivate let origin: Recipe.Ingredient?
        /// Where `origin` sits in the recipe.
        fileprivate let originIndex: Int?
    }

    struct StepRow: Equatable, Sendable, Identifiable {
        let id: RowID
        var text: String
    }

    enum Outcome: Equatable, Sendable {
        case save(RecipeEdit)
        /// These rows hold a quantity that is not a number. Nothing is saved
        /// until they are fixed or emptied: guessing 0 would put a number
        /// nobody typed on every shopping list the recipe goes on.
        case fix(quantities: [RowID])
    }

    /// The units the web's editor offers on top of the ones recipes already use.
    static let extraUnits = ["to taste", "whole", "pinch"]

    var title: String
    var ingredients: [IngredientRow]
    var steps: [StepRow]

    private let original: Recipe
    private var lastID: RowID

    var id: RecipeID { original.id }

    init(_ recipe: Recipe) {
        original = recipe
        title = recipe.title
        ingredients = recipe.ingredients.enumerated().map { index, ingredient in
            IngredientRow(
                id: index, name: ingredient.name, quantity: Self.text(ingredient.amount),
                unit: ingredient.unit ?? "", aisle: ingredient.category.flatMap { $0.isEmpty ? nil : $0 },
                origin: ingredient, originIndex: index)
        }
        steps = recipe.steps.enumerated().map { StepRow(id: recipe.ingredients.count + $0, text: $1) }
        lastID = recipe.ingredients.count + recipe.steps.count - 1
    }

    /// Whether this draft was made from exactly this recipe, untouched fields included.
    func isBased(on recipe: Recipe) -> Bool {
        original == recipe
    }

    /// A blank row at the end, on the fallback aisle and on shopping lists, as the web adds it.
    @discardableResult
    mutating func addIngredient() -> RowID {
        lastID += 1
        ingredients.append(IngredientRow(
            id: lastID, name: "", quantity: "", unit: "", aisle: ListLayout.fallbackAisle, origin: nil, originIndex: nil))
        return lastID
    }

    @discardableResult
    mutating func addStep() -> RowID {
        lastID += 1
        steps.append(StepRow(id: lastID, text: ""))
        return lastID
    }

    /// What Save would send. Rows with a blank name and blank steps are
    /// dropped, an empty quantity is nil and never 0, and an emptied title
    /// keeps the recipe's own.
    var outcome: Outcome {
        let kept = ingredients.filter { !$0.name.trimmed.isEmpty }
        let unreadable = kept.filter { $0.amount == .unreadable }.map(\.id)
        guard unreadable.isEmpty else { return .fix(quantities: unreadable) }
        return .save(RecipeEdit(
            title: title.oneLine.isEmpty ? original.title : title.oneLine,
            steps: steps.map(\.text.trimmed).filter { !$0.isEmpty },
            ingredients: kept.map(\.saved),
            origins: kept.map { row in
                row.originIndex.flatMap { index in row.origin.map { RecipeEdit.Origin(index: index, name: $0.name) } }
            }))
    }

    /// Whether saving would change the recipe. Compared as outcomes, so a
    /// blank row added and left empty, or a field retyped as it was, is no change.
    var hasChanges: Bool {
        outcome != RecipeDraft(original).outcome
    }

    /// The units to offer: the server's, then the web's extra three, each once.
    static func unitChoices(server: [String]) -> [String] {
        var seen: Set<String> = []
        return (server + extraUnits).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    fileprivate static func text(_ amount: Double?) -> String {
        amount.map(formatAmount) ?? ""
    }
}

nonisolated extension RecipeDraft.IngredientRow {
    fileprivate enum Amount: Equatable {
        case none
        case number(Double)
        case unreadable
    }

    /// A quantity left as it was shown keeps the server's number: the field
    /// shows two decimal places, and 0.333 must not be saved back as 0.33.
    fileprivate var amount: Amount {
        let typed = quantity.trimmed
        if let origin, typed == RecipeDraft.text(origin.amount) { return origin.amount.map { .number($0) } ?? .none }
        if typed.isEmpty { return .none }
        guard let number = parseAmount(typed), number >= 0 else { return .unreadable }
        return .number(number)
    }

    fileprivate var saved: Recipe.Ingredient {
        var ingredient = origin ?? Recipe.Ingredient(name: "")
        ingredient.name = name.trimmed
        ingredient.amount = if case .number(let number) = amount { number } else { nil }
        ingredient.unit = unit.trimmed.isEmpty ? nil : unit.trimmed
        ingredient.category = aisle
        return ingredient
    }
}
