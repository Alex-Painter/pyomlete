import Foundation
import Testing
@testable import Omlete

private func date(_ iso: String) -> PlanDate { PlanDate(iso: iso)! }

/// Quick nights on a week's days: what the phone keeps and what it sends.
struct QuickNightTests {
    private static let server = ListDetail(
        id: "list", name: "Week", recipes: ["curry"], items: [],
        weekStart: date("2026-10-17"),
        days: (0..<7).map { PlanDay(date: date("2026-10-17").adding(days: $0), plan: $0 == 1 ? .meal("curry") : .open) })

    @Test func aQuickNightChangesOnlyThatEvening() {
        let after = ListOp.setQuick(date("2026-10-18"), .meal("curry"), true).applied(to: Self.server)
        #expect(after.days.map(\.quick) == [false, true, false, false, false, false, false])
        #expect(after.days[1].plan == .meal("curry"))
    }

    @Test func aMealGoingOnKeepsTheQuickNight() {
        let quick = ListOp.setQuick(date("2026-10-19"), .open, true).applied(to: Self.server)
        let planned = ListOp.setDay(date("2026-10-19"), .meal("soup")).applied(to: quick)
        #expect(planned.days[2].quick)
        #expect(planned.days[2].plan == .meal("soup"))
    }

    @Test func tappingQuickOnAndOffFoldsIntoOneChange() {
        var replica = ListReplica(id: "list")
        replica.rebase(onto: Self.server)
        replica.enqueue(.setQuick(date("2026-10-19"), .open, true), id: "op1")
        replica.enqueue(.setQuick(date("2026-10-19"), .open, false), id: "op2")
        #expect(replica.pending.map(\.id) == ["op1"])
        #expect(replica.pending.first?.op == .setQuick(date("2026-10-19"), .open, false))
    }

    @Test func aDaySavedBeforeQuickNightsLoads() throws {
        let old = #"{"date":"2026-10-17","plan":{"open":{}}}"#
        let day = try JSONDecoder().decode(PlanDay.self, from: Data(old.utf8))
        #expect(day.quick == false)
    }
}

@MainActor struct QuickNightWireTests {
    private let transport = ScriptedTransport()
    private var api: APIClient { APIClient(baseURL: URL(string: "http://phone.test")!, transport: transport) }

    @Test func aQuickNightSendsTheDayAsItIsWithQuick() async throws {
        try await api.send(.setQuick(date("2026-10-18"), .meal("curry"), true), to: "list")
        #expect(transport.calls == [.init(method: "PUT", path: "/api/lists/list/days/2026-10-18")])
        #expect(transport.bodies.first?["recipe_id"] as? String == "curry")
        #expect(transport.bodies.first?["status"] as? String == "open")
        #expect(transport.bodies.first?["quick"] as? Bool == true)
    }

    @Test func aDayChangeLeavesQuickOutSoTheServerKeepsIt() async throws {
        try await api.send(.setDay(date("2026-10-18"), .meal("curry")), to: "list")
        #expect(transport.bodies.first?.keys.contains("quick") == false)
    }

    @Test func aWeekArrivesWithItsQuickNights() async throws {
        transport.reply = { _ in .status(200, """
            {"id":"list","name":"Week","recipes":[],"items":[],"week_start":"2026-10-17",
             "days":[{"date":"2026-10-17","recipe_id":null,"status":"open","quick":true},
                     {"date":"2026-10-18","recipe_id":null,"status":"open"}]}
            """) }
        let list = try await api.list("list")
        #expect(list.days.map(\.quick) == [true, false])
    }

    @Test func recipesArriveWithTheirTags() async throws {
        transport.reply = { _ in .status(200, """
            [{"id":"r1","title":"Carbonara","tags":{"base":"pasta","main":"pork","mood":"comforting","cuisine":"italian",
              "traits":{"oily_fish":false,"red_meat":true,"veg_led":false,"legumes":false}}},
             {"id":"r2","title":"New","tags":null}]
            """) }
        let recipes = try await api.recipes()
        #expect(recipes[0].tags == RecipeTags(base: "pasta", main: "pork", mood: "comforting", cuisine: "italian"))
        #expect(recipes[1].tags == nil)
    }

    @Test func planSettingsCarryTheVarietyWindowAndAnOldServerMeansThree() async throws {
        transport.reply = { _ in .status(200, #"{"week_start_weekday":5,"variety_days":4}"#) }
        #expect(try await api.planSettings() == PlanSettings(weekStartWeekday: 5, varietyDays: 4))
        transport.reply = { _ in .status(200, #"{"week_start_weekday":0}"#) }
        #expect(try await api.planSettings() == PlanSettings(weekStartWeekday: 0, varietyDays: 3))
    }

    @Test func savingPlanSettingsSendsBoth() async throws {
        transport.reply = { _ in .status(200, #"{"week_start_weekday":2,"variety_days":5}"#) }
        let saved = try await api.savePlanSettings(PlanSettings(weekStartWeekday: 2, varietyDays: 5))
        #expect(saved == PlanSettings(weekStartWeekday: 2, varietyDays: 5))
        #expect(transport.calls == [.init(method: "PUT", path: "/api/settings/plan")])
        #expect(transport.bodies.first?["variety_days"] as? Int == 5)
        #expect(transport.bodies.first?["week_start_weekday"] as? Int == 2)
    }

    @Test func untilNamesTheDayABaseIsBack() {
        #expect(PlanSettings(weekStartWeekday: 5, varietyDays: 3).untilWeekday == "Friday")
        #expect(PlanSettings(weekStartWeekday: 5, varietyDays: 6).untilWeekday == "Monday")
    }
}

/// Best for this day, Uses the list and the tag chips, as the web's libraryQuery has them.
struct DayLibraryQueryTests {
    private static let today = date("2026-10-20")
    private static let library = [
        RecipeSummary(id: "carbonara", title: "Carbonara", tags: RecipeTags(base: "pasta", main: "pork", mood: "comforting", cuisine: "italian")),
        RecipeSummary(id: "pesto", title: "Pesto pasta", ingredientNames: ["basil"], tags: RecipeTags(base: "pasta", main: "veggie", mood: "fresh", cuisine: "italian")),
        RecipeSummary(id: "curry", title: "Chicken curry", tags: RecipeTags(base: "rice", main: "chicken", mood: "comforting", cuisine: "indian")),
        RecipeSummary(id: "untagged", title: "Toast"),
    ]
    private static let days = [
        PlanDay(date: date("2026-10-19"), plan: .meal("carbonara")),
        PlanDay(date: date("2026-10-20"), plan: .open),
    ]

    private func ranking(items: [ListItem] = []) -> DayRanking {
        DayRanking(library: Self.library, day: Self.days[1], days: Self.days, items: items, varietyDays: 3)
    }

    @Test func bestForThisDayIsTheFitScoresOrder() {
        let day = ranking()
        let rows = MealLibraryQuery(sort: .best).results(Self.library, today: Self.today, day: day)
        #expect(rows.map(\.id) == day.ranked.map(\.recipe.id))
        #expect(rows.suffix(2).map(\.id) == ["carbonara", "pesto"])
    }

    @Test func tagChipsOfferOnlyWhatTheLibraryHasBasesThenMainsThenCuisines() {
        #expect(MealLibraryQuery.Filter.tags(in: Self.library).map(\.id) == [
            "base.pasta", "base.rice", "main.chicken", "main.pork", "main.veggie", "cuisine.indian", "cuisine.italian",
        ])
        #expect(MealLibraryQuery.Filter.tag(.cuisine, "south_east_asian").title == "South-east Asian")
        #expect(MealLibraryQuery.Filter.tag(.main, "beans").title == "Beans and lentils")
    }

    @Test func chipsInOneGroupWidenAndGroupsNarrow() {
        let wide = MealLibraryQuery(sort: .aToZ, filters: [.tag(.base, "pasta"), .tag(.base, "rice")])
        #expect(wide.results(Self.library, today: Self.today).map(\.id) == ["carbonara", "curry", "pesto"])
        let narrow = MealLibraryQuery(sort: .aToZ, filters: [.tag(.base, "pasta"), .tag(.main, "veggie")])
        #expect(narrow.results(Self.library, today: Self.today).map(\.id) == ["pesto"])
    }

    @Test func usesTheListKeepsMealsThatShareAPerishableWithIt() {
        let basil = ListItem(id: "b", name: "Basil", amount: nil, unit: nil, category: "Fresh Produce", checked: false, sources: [])
        let rows = MealLibraryQuery(filters: [.usesList]).results(Self.library, today: Self.today, day: ranking(items: [basil]))
        #expect(rows.map(\.id) == ["pesto"])
    }
}
