import Foundation
import Testing
@testable import Omlete

/// The web's `libraryQuery.test.ts`, which is the spec.
struct MealLibraryQueryTests {
    private static let today = PlanDate(iso: "2026-10-20")!

    private static func date(_ iso: String) -> PlanDate { PlanDate(iso: iso)! }

    private static func added(_ iso: String) -> Date { try! Date(iso + "T12:00:00Z", strategy: .iso8601) }

    private static let library = [
        RecipeSummary(
            id: "saag", title: "Saag paneer", totalMinutes: 40, rating: 5, lastPlannedOn: date("2026-08-01"),
            ingredientNames: ["spinach", "paneer", "garam masala"], cuisine: "Indian", createdAt: added("2026-01-10")),
        RecipeSummary(
            id: "spanakopita", title: "Spanakopita", totalMinutes: 75, rating: 4, lastPlannedOn: date("2026-10-14"),
            ingredientNames: ["Spinach", "feta", "filo pastry"], cuisine: "Greek", createdAt: added("2026-09-01")),
        RecipeSummary(
            id: "carbonara", title: "Carbonara", totalMinutes: 25, rating: 3,
            ingredientNames: ["spaghetti", "eggs", "guanciale"], cuisine: "Italian", createdAt: added("2026-05-05")),
        RecipeSummary(
            id: "omelette", title: "Crème fraîche omelette", totalMinutes: 10, lastPlannedOn: date("2026-09-25"),
            ingredientNames: ["eggs", "crème fraîche", "chives"], createdAt: added("2026-10-01")),
    ]

    private func ids(_ query: MealLibraryQuery, _ recipes: [RecipeSummary] = library) -> [RecipeID] {
        query.results(recipes, today: Self.today).map(\.id)
    }

    @Test func searchFindsARecipeByAnIngredientMissingFromItsTitle() {
        #expect(ids(MealLibraryQuery(text: "spinach")).sorted { $0.rawValue < $1.rawValue } == ["saag", "spanakopita"])
    }

    @Test func searchMatchesCuisineAndEveryWordMustMatchSomewhere() {
        #expect(ids(MealLibraryQuery(text: "greek")) == ["spanakopita"])
        #expect(ids(MealLibraryQuery(text: "eggs  italian ")) == ["carbonara"])
    }

    @Test func searchIgnoresCaseAndAccents() {
        #expect(ids(MealLibraryQuery(text: "CREME")) == ["omelette"])
    }

    @Test func searchReturnsNothingWhenNothingMatches() {
        #expect(ids(MealLibraryQuery(text: "durian")).isEmpty)
        #expect(ids(MealLibraryQuery(), []).isEmpty)
    }

    @Test(arguments: [
        (MealLibraryQuery.Sort.notLately, ["carbonara", "saag", "omelette", "spanakopita"] as [RecipeID]),
        (.favourites, ["saag", "spanakopita", "carbonara", "omelette"]),
        (.quickest, ["omelette", "carbonara", "saag", "spanakopita"]),
        (.newest, ["omelette", "spanakopita", "carbonara", "saag"]),
        (.aToZ, ["carbonara", "omelette", "saag", "spanakopita"]),
    ])
    func eachSortHasItsOrder(sort: MealLibraryQuery.Sort, expected: [RecipeID]) {
        #expect(ids(MealLibraryQuery(sort: sort)) == expected)
    }

    @Test func theDefaultIsNotHadLatelyWithNothingFiltered() {
        #expect(MealLibraryQuery() == MealLibraryQuery(text: "", sort: .notLately, filters: []))
    }

    @Test func quickKeepsThirtyMinutesOrLess() {
        #expect(ids(MealLibraryQuery(filters: [.quick])) == ["carbonara", "omelette"])
    }

    @Test func notHadLatelyDropsAnythingPlannedInTheLastThreeWeeks() {
        // Spanakopita was 6 days ago, the omelette 25 days ago.
        #expect(ids(MealLibraryQuery(filters: [.notLately])) == ["carbonara", "saag", "omelette"])
    }

    @Test func favouritesKeepsFourStarsAndUp() {
        #expect(ids(MealLibraryQuery(filters: [.favourites])) == ["saag", "spanakopita"])
    }

    @Test func filtersAndSearchCombine() {
        #expect(ids(MealLibraryQuery(text: "spinach", filters: [.favourites, .notLately])) == ["saag"])
        #expect(ids(MealLibraryQuery(filters: [.quick, .favourites])).isEmpty)
    }

    @Test func aFilterTogglesOnAndOff() {
        var query = MealLibraryQuery()
        query.toggle(.quick)
        #expect(query.filters == [.quick])
        query.toggle(.quick)
        #expect(query.filters.isEmpty)
    }

    @Test func aMealOnThisWeekCountsAsHadSoItSinksAndLeavesNotHadLately() {
        let days = [
            PlanDay(date: Self.date("2026-10-22"), plan: .meal("carbonara")),
            PlanDay(date: Self.date("2026-10-23"), plan: .out),
        ]

        let merged = MealLibraryQuery.withWeekHistory(Self.library, days: days)

        #expect(merged.first { $0.id == "carbonara" }?.lastPlannedOn == Self.date("2026-10-22"))
        #expect(ids(MealLibraryQuery(), merged).last == "carbonara")
        #expect(!ids(MealLibraryQuery(filters: [.notLately]), merged).contains("carbonara"))
    }

    @Test func aLaterDateTheServerAlreadyHasIsKept() {
        let later = [RecipeSummary(id: "x", title: "X", lastPlannedOn: Self.date("2026-11-01"))]

        let merged = MealLibraryQuery.withWeekHistory(later, days: [PlanDay(date: Self.date("2026-10-22"), plan: .meal("x"))])

        #expect(merged.first?.lastPlannedOn == Self.date("2026-11-01"))
    }

    @Test(arguments: [
        (nil as String?, "Never planned"),
        ("2026-10-22", "Planned for Thu 22 Oct"),
        ("2026-10-20", "Planned for today"),
        ("2026-10-19", "Last had yesterday"),
        ("2026-10-16", "Last had 4 days ago"),
        ("2026-10-12", "Last had a week ago"),
        ("2026-09-15", "Last had 5 weeks ago"),
        ("2026-06-01", "Last had 4 months ago"),
        ("2025-01-01", "Last had over a year ago"),
    ])
    func aRowSaysWhenTheMealWasLastHad(last: String?, line: String) {
        let recipe = RecipeSummary(id: "r", title: "R", lastPlannedOn: last.flatMap(PlanDate.init(iso:)))

        #expect(MealLibraryQuery.contextLine(recipe, today: Self.today) == line)
    }
}

/// Plan's selected evening is chosen once and then held.
struct PlanFocusTests {
    private static func date(_ iso: String) -> PlanDate { PlanDate(iso: iso)! }

    private static func week(_ plans: [DayPlan]) -> [PlanDay] {
        plans.enumerated().map { PlanDay(date: date("2026-10-17").adding(days: $0.offset), plan: $0.element) }
    }

    @Test func theDayChosenFirstIsHeldWhenTheWeekChanges() {
        let today = Self.date("2026-10-10")
        var focus = PlanFocus()
        focus.choose(in: Self.week([.meal("a"), .open, .open]), today: today)
        #expect(focus.selected == Self.date("2026-10-18"))

        let markedOut = Self.week([.meal("a"), .out, .open])
        focus.choose(in: markedOut, today: today)

        #expect(focus.day(in: markedOut, today: today)?.date == Self.date("2026-10-18"))
    }

    @Test func untilItChoosesItShowsTheDayItWouldChoose() {
        let days = Self.week([.meal("a"), .open, .open])

        #expect(PlanFocus().day(in: days, today: Self.date("2026-10-19"))?.date == Self.date("2026-10-19"))
    }

    @Test func planningAnEveningMovesOnToTheNextStillToPlan() {
        var focus = PlanFocus()
        focus.select(Self.date("2026-10-18"))

        focus.planned(Self.date("2026-10-18"), days: Self.week([.open, .meal("a"), .out, .open]))

        #expect(focus.selected == Self.date("2026-10-20"))
    }
}
