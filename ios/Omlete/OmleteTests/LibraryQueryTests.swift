import Foundation
import Testing
@testable import Omlete

struct LibraryQueryTests {
    /// Newest first, as the server sends them.
    private let recipes = [
        RecipeSummary(id: "stew", title: "Slow stew", totalMinutes: 180, rating: 5),
        RecipeSummary(id: "toast", title: "beans on toast", totalMinutes: 10),
        RecipeSummary(id: "curry", title: "Thai Curry", totalMinutes: 30, rating: 4, sourceName: "bbcgoodfood.com"),
        RecipeSummary(id: "cake", title: "Apple cake", rating: 2, sourceName: "example.com"),
        RecipeSummary(id: "eggs", title: "Eggs", totalMinutes: 10, rating: 4),
    ]

    private func ids(_ query: LibraryQuery) -> [RecipeID] {
        query.apply(to: recipes).map(\.id)
    }

    @Test func theDefaultKeepsEveryRecipeNewestFirst() {
        #expect(ids(LibraryQuery()) == ["stew", "toast", "curry", "cake", "eggs"])
    }

    @Test func searchMatchesAnyPartOfTheTitleWhateverTheCase() {
        #expect(ids(LibraryQuery(search: "  CUR ")) == ["curry"])
        #expect(ids(LibraryQuery(search: "t")) == ["stew", "toast", "curry"])
        #expect(ids(LibraryQuery(search: "pizza")).isEmpty)
    }

    @Test func favouritesAreFourStarsAndUp() {
        #expect(ids(LibraryQuery(filter: .favourites)) == ["stew", "curry", "eggs"])
    }

    @Test func quickIsThirtyMinutesOrLessAndNeedsATime() {
        #expect(ids(LibraryQuery(filter: .quick)) == ["toast", "curry", "eggs"])
    }

    @Test func fromTheWebNeedsASource() {
        #expect(ids(LibraryQuery(filter: .fromTheWeb)) == ["curry", "cake"])
    }

    @Test func topRatedPutsUnratedLastAndKeepsNewestFirstAmongEquals() {
        #expect(ids(LibraryQuery(sort: .topRated)) == ["stew", "curry", "eggs", "cake", "toast"])
    }

    @Test func quickestPutsRecipesWithNoTimeLast() {
        #expect(ids(LibraryQuery(sort: .quickest)) == ["toast", "eggs", "curry", "stew", "cake"])
    }

    @Test func alphabeticalIgnoresCase() {
        #expect(ids(LibraryQuery(sort: .alphabetical)) == ["cake", "toast", "eggs", "stew", "curry"])
    }

    @Test func searchFilterAndSortCombine() {
        let query = LibraryQuery(search: "e", sort: .quickest, filter: .favourites)
        #expect(ids(query) == ["eggs", "stew"])
    }
}
