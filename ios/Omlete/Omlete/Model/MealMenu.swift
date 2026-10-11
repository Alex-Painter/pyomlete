import Foundation

/// What "Add meals" offers for one list: Discover's top picks, then the
/// library, both narrowed by one search. Built in one place so the sheet
/// holds no rules and they are tested without it.
nonisolated struct MealMenu: Equatable, Sendable {
    struct Row: Equatable, Identifiable, Sendable {
        let recipe: RecipeSummary
        let isOnList: Bool

        var id: RecipeID { recipe.id }
    }

    static let mostPicks = 4

    /// Each fresh or saving, in feed order, never more than `mostPicks`. A
    /// card that is saved is in the library below, and one that failed is
    /// Discover's to retry.
    let picks: [Suggestion]
    /// Library order, newest first.
    let recipes: [Row]
    /// Nothing is saved at all, which is not the same as nothing matching the search.
    let libraryIsEmpty: Bool

    init(recipes: [RecipeSummary], cards: [Suggestion], onList: Set<RecipeID>, search: String) {
        picks = Array(
            cards.lazy
                .filter { ($0.stage == .fresh || $0.stage == .saving) && $0.title.matches(search: search) }
                .prefix(Self.mostPicks))
        self.recipes = recipes
            .filter { $0.title.matches(search: search) }
            .map { Row(recipe: $0, isOnList: onList.contains($0.id)) }
        libraryIsEmpty = recipes.isEmpty
    }
}
