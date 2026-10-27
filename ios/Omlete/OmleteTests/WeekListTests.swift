import Foundation
import Testing
@testable import Omlete

private func date(_ iso: String) -> PlanDate { PlanDate(iso: iso)! }

/// A list's week as the server sends it, and the day changes the phone queues for it.
struct WeekReplicaTests {
    private static let server = ListDetail(
        id: "list", name: "Week", recipes: ["curry", "soup"],
        items: [
            ListItem(
                id: "rice", name: "rice", amount: 200, unit: "g", category: "Pantry", checked: false,
                sources: [ItemSource(recipeID: "curry", amount: 200)]),
        ],
        weekStart: date("2026-10-17"),
        days: (0..<7).map { PlanDay(date: date("2026-10-17").adding(days: $0), plan: $0 == 1 ? .meal("curry") : .open) })

    private static func fetched() -> ListReplica {
        var replica = ListReplica(id: "list")
        replica.rebase(onto: server)
        return replica
    }

    private func plan(_ replica: ListReplica, _ iso: String) -> DayPlan? {
        replica.current?.days.first { $0.date == date(iso) }?.plan
    }

    @Test func settingADayChangesOnlyThatDay() {
        let after = ListOp.setDay(date("2026-10-20"), .out).applied(to: Self.server)

        #expect(after.days.map(\.plan) == [.open, .meal("curry"), .open, .out, .open, .open, .open])
        #expect(after.recipes == Self.server.recipes)
    }

    @Test func aMealPlannedThatIsNotOnTheListJoinsIt() {
        let after = ListOp.setDay(date("2026-10-17"), .meal("pie")).applied(to: Self.server)

        #expect(after.recipes == ["curry", "soup", "pie"])
        #expect(after.days[0].plan == .meal("pie"))
        #expect(after.items == Self.server.items)
    }

    @Test func clearingADayKeepsItsMealOnTheList() {
        let after = ListOp.setDay(date("2026-10-18"), .open).applied(to: Self.server)

        #expect(after.days[1].plan == .open)
        #expect(after.recipes == ["curry", "soup"])
    }

    @Test(arguments: ["2026-10-24", "2026-10-16"])
    func aDayOutsideTheWeekChangesNothing(iso: String) {
        #expect(ListOp.setDay(date(iso), .meal("pie")).applied(to: Self.server) == Self.server)
    }

    @Test func aPlainListHasNoDaysToSet() {
        var plain = Self.server
        (plain.weekStart, plain.days) = (nil, [])

        #expect(ListOp.setDay(date("2026-10-17"), .meal("pie")).applied(to: plain) == plain)
    }

    @Test func removingAMealTakesItOffItsDays() {
        var list = Self.server
        list.days[4].plan = .meal("curry")

        let after = ListOp.removeRecipe("curry").applied(to: list)

        #expect(after.days.allSatisfy { $0.plan == .open })
        #expect(after.recipes == ["soup"])
    }

    @Test func replayingADayChangeIsANoOp() {
        let op = ListOp.setDay(date("2026-10-17"), .meal("pie"))
        let once = op.applied(to: Self.server)

        #expect(op.applied(to: once) == once)
    }

    @Test func tappingThroughMealsForOneDayFoldsIntoOneChange() {
        var replica = Self.fetched()
        replica.enqueue(.setDay(date("2026-10-17"), .meal("curry")), id: "op1")
        replica.enqueue(.setDay(date("2026-10-17"), .meal("soup")), id: "op2")
        replica.enqueue(.setDay(date("2026-10-17"), .out), id: "op3")

        #expect(replica.pending.map(\.id) == ["op1"])
        #expect(replica.pending.first?.op == .setDay(date("2026-10-17"), .out))
    }

    @Test func aDayChangeFoldsOnlyIntoTheLatestChange() {
        var replica = Self.fetched()
        replica.enqueue(.setDay(date("2026-10-17"), .meal("soup")), id: "op1")
        replica.enqueue(.setDay(date("2026-10-19"), .out), id: "op2")
        replica.enqueue(.setDay(date("2026-10-17"), .open), id: "op3")
        replica.enqueue(.rename("Weekend"), id: "op4")
        replica.enqueue(.setDay(date("2026-10-17"), .out), id: "op5")

        #expect(replica.pending.map(\.id) == ["op1", "op2", "op3", "op4", "op5"])
    }

    @Test func aDayChangeIsNotFoldedIntoOneOnTheWire() {
        var replica = Self.fetched()
        replica.enqueue(.setDay(date("2026-10-17"), .meal("soup")), id: "op1")
        _ = replica.beginSend()

        replica.enqueue(.setDay(date("2026-10-17"), .out), id: "op2")
        replica.finishSend(.accepted)

        #expect(replica.pending.map(\.op) == [.setDay(date("2026-10-17"), .out)])
        #expect(plan(replica, "2026-10-17") == .out)
    }

    @Test func aDayChangeIsNotFoldedIntoAHeldOne() {
        var replica = Self.fetched()
        replica.enqueue(.setDay(date("2026-10-17"), .meal("soup")), id: "op1", held: true)

        replica.enqueue(.setDay(date("2026-10-17"), .out), id: "op2")

        #expect(replica.pending.map(\.id) == ["op1", "op2"])
    }

    /// The server merges a planned meal's ingredients into matching items, so
    /// an edit to an item must reach it after the meal it came after.
    @Test func anItemEditIsNotFoldedBackPastAPlannedMealButIsPastAnEmptyDay() {
        var replica = Self.fetched()
        replica.enqueue(.patch("rice", .checked(true)), id: "op1")
        replica.enqueue(.setDay(date("2026-10-17"), .out), id: "op2")
        replica.enqueue(.patch("rice", .checked(false)), id: "op3")
        #expect(replica.pending.map(\.id) == ["op1", "op2"])

        replica.enqueue(.setDay(date("2026-10-19"), .meal("pie")), id: "op4")
        replica.enqueue(.patch("rice", .checked(true)), id: "op5")
        #expect(replica.pending.map(\.id) == ["op1", "op2", "op4", "op5"])
    }

    /// A removal the server applied after a later change could undo it there.
    @Test func nothingIsSentAheadOfAHeldChange() {
        var replica = Self.fetched()
        replica.enqueue(.removeRecipe("soup"), id: "op1", held: true)
        replica.enqueue(.setDay(date("2026-10-17"), .meal("soup")), id: "op2")

        #expect(replica.beginSend() == nil)

        replica.release(["op1"])
        #expect(replica.beginSend()?.id == "op1")
    }

    @Test(arguments: [
        [ListOp.setDay(date("2026-10-17"), .meal("pie")), .removeRecipe("pie"), .setDay(date("2026-10-18"), .out)],
        [.setDay(date("2026-10-17"), .out), .rename("A"), .setDay(date("2026-10-17"), .meal("soup")), .patch("rice", .checked(true))],
        [.patch("rice", .checked(true)), .setDay(date("2026-10-19"), .meal("pie")), .patch("rice", .checked(false))],
    ])
    func whatTheScreenShowsIsTheChangesAppliedInOrder(ops: [ListOp]) {
        var replica = Self.fetched()
        for (index, op) in ops.enumerated() { replica.enqueue(op, id: OpID("op\(index)")) }

        #expect(replica.current == ops.reduce(Self.server) { list, op in op.applied(to: list) })
    }
}

/// What the server sends for weeks, and what a day change sends back.
@MainActor struct WeekWireTests {
    private let transport = ScriptedTransport()

    private var api: APIClient {
        APIClient(baseURL: URL(string: "http://phone.test")!, transport: transport)
    }

    @Test func aWeekListArrivesWithItsDaysAndAMealWinsOverOut() async throws {
        transport.reply = { _ in .status(200, """
            {"id":"list","name":"Week","recipes":["curry"],"items":[],"week_start":"2026-10-17","cooked":[],
             "days":[{"date":"2026-10-17","recipe_id":"curry","status":"out","origin":"chef"},
                     {"date":"2026-10-18","recipe_id":null,"status":"out","origin":"user"},
                     {"date":"2026-10-19","recipe_id":null,"status":"open","origin":"user"}]}
            """) }

        let list = try await api.list("list")

        #expect(list.weekStart == date("2026-10-17"))
        #expect(list.days.map(\.plan) == [.meal("curry"), .out, .open])
        #expect(list.days.map(\.date.iso) == ["2026-10-17", "2026-10-18", "2026-10-19"])
        #expect(list.isWeek)
    }

    @Test func aListFromAServerBeforeWeeksIsAPlainList() async throws {
        transport.reply = { _ in .status(200, #"{"id":"list","name":"Old","recipes":[],"items":[]}"#) }

        let list = try await api.list("list")

        #expect(list.weekStart == nil)
        #expect(list.days.isEmpty)
        #expect(!list.isWeek)
    }

    @Test func aDayThatIsNotADateIsNotAList() async {
        transport.reply = { _ in .status(200, """
            {"id":"list","name":"Week","recipes":[],"items":[],"week_start":"2026-10-17",
             "days":[{"date":"Saturday","recipe_id":null,"status":"open"}]}
            """) }

        await #expect(throws: APIError.self) { try await api.list("list") }
    }

    @Test func listSummariesCarryTheirWeek() async throws {
        transport.reply = { _ in .status(200, """
            [{"id":"a","name":"A","item_count":0,"checked_count":0,"recipes":[],"week_start":"2026-10-17","days":[]},
             {"id":"b","name":"B","item_count":0,"checked_count":0,"recipes":[],"week_start":null}]
            """) }

        #expect(try await api.lists().map(\.weekStart) == [date("2026-10-17"), nil])
    }

    @Test func recipeSummariesCarryWhatTheLibraryRanksBy() async throws {
        transport.reply = { _ in .status(200, """
            [{"id":"a","title":"A","ingredient_names":["spinach","feta"],"cuisine":"Greek",
              "last_planned_on":"2026-10-14","created_at":"2026-09-01T12:00:00"},
             {"id":"b","title":"B"}]
            """) }

        let recipes = try await api.recipes()

        #expect(recipes[0].ingredientNames == ["spinach", "feta"])
        #expect(recipes[0].cuisine == "Greek")
        #expect(recipes[0].lastPlannedOn == date("2026-10-14"))
        #expect(recipes[0].createdAt == (try Date("2026-09-01T12:00:00Z", strategy: .iso8601)))
        #expect(recipes[1] == RecipeSummary(id: "b", title: "B"))
    }

    @Test(arguments: [
        (DayPlan.meal("curry"), "curry" as String?, "open"),
        (.open, nil, "open"),
        (.out, nil, "out"),
    ])
    func aDayChangeIsAPutOfItsMealAndStatus(plan: DayPlan, recipe: String?, status: String) async throws {
        try await api.send(.setDay(date("2026-10-20"), plan), to: "list")

        #expect(transport.calls == [ScriptedTransport.Call(method: "PUT", path: "/api/lists/list/days/2026-10-20")])
        let body = try #require(transport.bodies.first)
        #expect(body["status"] as? String == status)
        if let recipe {
            #expect(body["recipe_id"] as? String == recipe)
        } else {
            // null, which clears the day, and not left out.
            #expect(body["recipe_id"] is NSNull)
        }
    }
}

/// Planning on Plan: the store's day changes, with Undo where something is taken away.
@MainActor struct WeekStoreTests {
    private typealias Call = ScriptedTransport.Call
    private let phone: Phone

    private static let weekJSON = """
        {"id":"list","name":"Week","recipes":["curry"],"items":[],"week_start":"2026-10-17",
         "days":[{"date":"2026-10-17","recipe_id":"curry","status":"open"},{"date":"2026-10-18","recipe_id":null,"status":"open"},
                 {"date":"2026-10-19","recipe_id":null,"status":"open"},{"date":"2026-10-20","recipe_id":null,"status":"open"},
                 {"date":"2026-10-21","recipe_id":null,"status":"open"},{"date":"2026-10-22","recipe_id":null,"status":"open"},
                 {"date":"2026-10-23","recipe_id":"curry","status":"open"}]}
        """

    init() async {
        phone = Phone(fetched: false)
        phone.serverAnswers { call in
            call == Call(method: "GET", path: "/api/lists/list") ? .status(200, Self.weekJSON) : nil
        }
        await phone.store.refresh()
    }

    private var days: [DayPlan] {
        guard case .ready(let list) = phone.store.phase else { return [] }
        return list.days.map(\.plan)
    }

    private var dayCalls: [Call] {
        phone.transport.calls.filter { $0.method == "PUT" || $0.method == "DELETE" }
    }

    @Test func planningAMealSendsTheDay() async {
        phone.store.plan("soup", on: date("2026-10-18"))
        #expect(days[1] == .meal("soup"))

        await phone.store.sync().value

        #expect(dayCalls == [Call(method: "PUT", path: "/api/lists/list/days/2026-10-18")])
    }

    @Test func clearingADayOffersUndoWhichPutsTheMealBack() async {
        phone.store.clearDay(date("2026-10-17"), title: "Curry")

        #expect(days[0] == .open)
        #expect(phone.undo.banner?.message == "Took Curry off Saturday")

        phone.undo.undoTapped()
        #expect(days[0] == .meal("curry"))
    }

    @Test func outOnlyAppliesToAnEveningWithNoMeal() {
        phone.store.setOut(date("2026-10-17"), true)
        phone.store.setOut(date("2026-10-18"), true)
        #expect(days[0] == .meal("curry"))
        #expect(days[1] == .out)

        phone.store.setOut(date("2026-10-18"), false)
        #expect(days[1] == .open)
    }

    @Test func aDayPlannedOfflineIsSentOnceTheServerAnswers() async {
        phone.serverIsUnreachable()
        phone.store.plan("soup", on: date("2026-10-18"))
        phone.store.plan("pie", on: date("2026-10-18"))
        await phone.store.sync().value
        #expect(phone.store.replica.pending.map(\.op) == [.setDay(date("2026-10-18"), .meal("pie"))])

        phone.relaunch()
        phone.serverAnswers { call in
            call == Call(method: "GET", path: "/api/lists/list") ? .status(200, Self.weekJSON) : nil
        }
        let before = phone.transport.calls.count
        await phone.store.sync().value

        #expect(phone.transport.calls[before...].filter { $0.method == "PUT" } == [
            Call(method: "PUT", path: "/api/lists/list/days/2026-10-18"),
        ])
        #expect(phone.transport.bodies.last { $0["recipe_id"] != nil }?["recipe_id"] as? String == "pie")
    }

    /// The server never saw the removal, so it still has the meal on its old
    /// days: planning it elsewhere has to clear them there too.
    @Test func planningAMealWhoseRemovalCanStillBeUndoneIsThatUndoAndMovesIt() async {
        phone.store.removeMeal("curry", title: "Curry")
        #expect(days[0] == .open)

        phone.store.plan("curry", on: date("2026-10-20"))

        #expect(phone.undo.banner == nil)
        #expect(days == [.open, .open, .open, .meal("curry"), .open, .open, .open])
        #expect(!phone.store.replica.pending.contains { $0.op == .removeRecipe("curry") })
        await phone.store.sync().value
        #expect(dayCalls == [
            Call(method: "PUT", path: "/api/lists/list/days/2026-10-17"),
            Call(method: "PUT", path: "/api/lists/list/days/2026-10-23"),
            Call(method: "PUT", path: "/api/lists/list/days/2026-10-20"),
        ])
    }

    @Test func removingAMealSendsOnlyTheRemovalWhichClearsItsDays() async {
        phone.store.removeMeal("curry", title: "Curry")
        #expect(days.allSatisfy { $0 == .open })
        phone.undo.commitNow()
        await phone.store.sync().value

        #expect(dayCalls == [Call(method: "DELETE", path: "/api/lists/list/recipes/curry")])
    }
}
