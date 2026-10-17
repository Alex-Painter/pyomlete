import Foundation
import Testing
@testable import Omlete

/// The rules of the web's `MealsSheet`, which is the spec.
struct MealMenuTests {
    /// Newest first, as the library gives them.
    private let recipes = [
        RecipeSummary(id: "cake", title: "Lemon Drizzle Cake"),
        RecipeSummary(id: "curry", title: "Thai Curry", totalMinutes: 30, rating: 4, ingredientCount: 9),
        RecipeSummary(id: "eggs", title: "Soft Egg"),
    ]

    private func card(_ id: SuggestionID, _ title: String, _ stage: Suggestion.Stage = .fresh) -> Suggestion {
        Suggestion(id: id, title: title, section: .moreIdeas, stage: stage)
    }

    private func menu(
        recipes: [RecipeSummary]? = nil, cards: [Suggestion] = [], onList: Set<RecipeID> = [], search: String = ""
    ) -> MealMenu {
        MealMenu(recipes: recipes ?? self.recipes, cards: cards, onList: onList, search: search)
    }

    @Test func picksAreTheCardsNotYetRecipesInFeedOrder() {
        let cards = [
            card("fresh", "Bean Chilli"), card("saved", "Traybake", .saved("traybake")),
            card("saving", "Noodles", .saving), card("failed", "Aubergine", .failed), card("unsent", "Dal", .unsent),
        ]

        #expect(menu(cards: cards).picks.map(\.id) == ["fresh", "saving", "unsent"])
    }

    @Test func atMostFourPicksAreOffered() {
        let cards = (1...6).map { card(SuggestionID("\($0)"), "Idea \($0)") }

        #expect(menu(cards: cards).picks.map(\.id) == ["1", "2", "3", "4"])
    }

    /// Counted after the rest: a card that cannot be a pick must not take one of the four places.
    @Test func theFourAreCountedAmongCardsThatQualifyAndMatch() {
        let cards = [
            card("1", "Soup"), card("2", "Curry one", .failed), card("3", "Curry two"), card("4", "Curry three"),
            card("5", "Curry four", .saved("r")), card("6", "Curry five"), card("7", "Curry six"), card("8", "Curry seven"),
        ]

        #expect(menu(cards: cards, search: "curry").picks.map(\.id) == ["3", "4", "6", "7"])
    }

    @Test func oneSearchNarrowsBothSectionsByAnyPartOfTheTitleWhateverTheCase() {
        let found = menu(cards: [card("a", "Egg fried rice"), card("b", "Bean Chilli")], search: "  EGG ")

        #expect(found.picks.map(\.id) == ["a"])
        #expect(found.recipes.map(\.id) == ["eggs"])
    }

    @Test func everyRecipeIsListedInLibraryOrderWithThoseOnTheListMarked() {
        let rows = menu(onList: ["eggs", "gone-from-the-library"]).recipes

        #expect(rows.map(\.id) == ["cake", "curry", "eggs"])
        #expect(rows.map(\.isOnList) == [false, false, true])
        #expect(rows[1].recipe.ingredientCount == 9)
    }

    @Test func aSearchThatFindsNothingIsNotAnEmptyLibrary() {
        let nothing = menu(search: "pizza")
        #expect(nothing.recipes.isEmpty)
        #expect(nothing.library == .stocked)

        #expect(menu(recipes: [], cards: [card("a", "Idea")]).library == .empty)
    }

    @Test func aLibraryNotYetLoadedIsNotAnEmptyOne() {
        let unknown = MealMenu(recipes: nil, cards: [card("a", "Idea")], onList: [], search: "")

        #expect(unknown.library == .loading)
        #expect(unknown.recipes.isEmpty)
        #expect(unknown.picks.map(\.id) == ["a"])
    }
}
