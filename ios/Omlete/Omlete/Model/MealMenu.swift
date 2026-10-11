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
    let library: LibraryState

    /// Nothing loaded yet, nothing saved at all, and something saved are three
    /// things; "nothing matches the search" is a fourth, told by `recipes`.
    enum LibraryState: Equatable, Sendable {
        case loading, empty, stocked
    }

    /// `recipes` is nil until the library has loaded once.
    init(recipes: [RecipeSummary]?, cards: [Suggestion], onList: Set<RecipeID>, search: String) {
        library = recipes.map { $0.isEmpty ? .empty : .stocked } ?? .loading
        let recipes = recipes ?? []
        picks = Array(
            cards.lazy
                .filter { ($0.stage == .fresh || $0.stage == .saving) && $0.title.matches(search: search) }
                .prefix(Self.mostPicks))
        self.recipes = recipes
            .filter { $0.title.matches(search: search) }
            .map { Row(recipe: $0, isOnList: onList.contains($0.id)) }
    }
}
