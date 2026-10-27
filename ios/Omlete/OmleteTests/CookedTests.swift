import Foundation
import Testing
@testable import Omlete

/// The Cooked tick as the replica queues it: the reducer mirrors the server's
/// `set_cooked`, and a run of taps on one meal is one request.
struct CookedReplicaTests {
    private static let server = ListDetail(
        id: "list", name: "Week", recipes: ["curry", "soup"],
        items: [
            ListItem(
                id: "rice", name: "rice", amount: 200, unit: "g", category: "Pantry", checked: false,
                sources: [ItemSource(recipeID: "curry", amount: 200)]),
        ])

    private static func fetched() -> ListReplica {
        var replica = ListReplica(id: "list")
        replica.rebase(onto: server)
        return replica
    }

    @Test func tickingAMealMarksItCookedAndMovesNothingElse() {
        let after = ListOp.setCooked("curry", true).applied(to: Self.server)

        #expect(after.cooked == ["curry"])
        var unchanged = after
        unchanged.cooked = []
        #expect(unchanged == Self.server)
        #expect(ListOp.setCooked("curry", false).applied(to: after) == Self.server)
    }

    @Test func onlyAMealOnTheListCanBeCooked() {
        #expect(ListOp.setCooked("pie", true).applied(to: Self.server) == Self.server)
    }

    @Test(arguments: [true, false])
    func replayingATickIsANoOp(cooked: Bool) {
        let op = ListOp.setCooked("curry", cooked)
        let once = op.applied(to: Self.server)

        #expect(op.applied(to: once) == once)
    }

    @Test func removingAMealForgetsItWasCooked() {
        let cooked = ListOp.setCooked("curry", true).applied(to: Self.server)

        let removed = ListOp.removeRecipe("curry").applied(to: cooked)
        #expect(removed.cooked.isEmpty)

        let back = ListOp.setDay(PlanDate(iso: "2026-10-17")!, .meal("curry")).applied(to: removed)
        #expect(back.cooked.isEmpty)
    }

    @Test func tickUntickTickFoldsIntoOneChange() {
        var replica = Self.fetched()
        replica.enqueue(.setCooked("curry", true), id: "op1")
        replica.enqueue(.setCooked("curry", false), id: "op2")
        replica.enqueue(.setCooked("curry", true), id: "op3")

        #expect(replica.pending.map(\.id) == ["op1"])
        #expect(replica.pending.first?.op == .setCooked("curry", true))
    }

    /// Folding across another op would send the final tick before it; across a
    /// removal that could tick a meal the server has already taken off.
    @Test func aTickFoldsOnlyIntoTheLatestChange() {
        var replica = Self.fetched()
        replica.enqueue(.setCooked("curry", true), id: "op1")
        replica.enqueue(.setCooked("soup", true), id: "op2")
        replica.enqueue(.setCooked("curry", false), id: "op3")
        replica.enqueue(.patch("rice", .checked(true)), id: "op4")
        replica.enqueue(.setCooked("curry", true), id: "op5")

        #expect(replica.pending.map(\.id) == ["op1", "op2", "op3", "op4", "op5"])
        #expect(replica.current?.cooked == ["curry", "soup"])
    }

    @Test func aTickIsNotFoldedIntoOneOnTheWire() {
        var replica = Self.fetched()
        replica.enqueue(.setCooked("curry", true), id: "op1")
        _ = replica.beginSend()

        replica.enqueue(.setCooked("curry", false), id: "op2")
        replica.finishSend(.accepted)

        #expect(replica.pending.map(\.op) == [.setCooked("curry", false)])
        #expect(replica.current?.cooked == [])
    }

    @Test func aTickIsNotFoldedIntoAHeldOne() {
        var replica = Self.fetched()
        replica.enqueue(.setCooked("curry", true), id: "op1", held: true)

        replica.enqueue(.setCooked("curry", false), id: "op2")

        #expect(replica.pending.map(\.id) == ["op1", "op2"])
    }

    /// An item change commutes with a tick, so it still folds back past one.
    @Test func anItemEditFoldsBackPastATick() {
        var replica = Self.fetched()
        replica.enqueue(.patch("rice", .checked(true)), id: "op1")
        replica.enqueue(.setCooked("curry", true), id: "op2")
        replica.enqueue(.patch("rice", .checked(false)), id: "op3")

        #expect(replica.pending.map(\.id) == ["op1", "op2"])
    }

    /// The tick waits behind a removal held by its banner: Undo lets it through
    /// as it is, and a committed removal reaches the server first, as it did here.
    @Test func aTickWaitsBehindAHeldRemovalOfItsMeal() {
        var replica = Self.fetched()
        replica.enqueue(.removeRecipe("curry"), id: "op1", held: true)
        replica.enqueue(.setCooked("curry", true), id: "op2")
        #expect(replica.current?.cooked == [])
        #expect(replica.beginSend() == nil)

        replica.cancel(["op1"])
        #expect(replica.current?.cooked == ["curry"])
        #expect(replica.beginSend()?.id == "op2")
    }

    @Test(arguments: [
        [ListOp.setCooked("curry", true), .removeRecipe("curry"), .setCooked("curry", true)],
        [.setCooked("soup", true), .rename("A"), .setCooked("curry", true), .setCooked("soup", false)],
        [.setCooked("pie", true), .setDay(PlanDate(iso: "2026-10-17")!, .meal("pie")), .setCooked("pie", true)],
    ])
    func whatTheScreenShowsIsTheChangesAppliedInOrder(ops: [ListOp]) {
        var replica = Self.fetched()
        for (index, op) in ops.enumerated() { replica.enqueue(op, id: OpID("op\(index)")) }

        #expect(replica.current == ops.reduce(Self.server) { list, op in op.applied(to: list) })
    }
}

/// What the server sends for cooked meals, and what a tick sends back.
@MainActor struct CookedWireTests {
    private let transport = ScriptedTransport()

    private var api: APIClient {
        APIClient(baseURL: URL(string: "http://phone.test")!, transport: transport)
    }

    @Test func aListArrivesWithItsCookedMeals() async throws {
        transport.reply = { _ in .status(200, #"{"id":"list","name":"Week","recipes":["curry","soup"],"items":[],"cooked":["soup"]}"#) }

        #expect(try await api.list("list").cooked == ["soup"])
    }

    @Test func aListFromAServerBeforeTheTickHasNothingCooked() async throws {
        transport.reply = { _ in .status(200, #"{"id":"list","name":"Old","recipes":["curry"],"items":[]}"#) }

        #expect(try await api.list("list").cooked.isEmpty)
    }

    @Test func listSummariesSayWhichMealsAreCooked() async throws {
        transport.reply = { _ in .status(200, """
            [{"id":"a","name":"A","item_count":0,"checked_count":0,
              "recipes":[{"id":"curry","title":"Curry","cooked":true},{"id":"soup","title":"Soup","cooked":false},
                         {"id":"pie","title":"Pie"}]}]
            """) }

        #expect(try await api.lists().first?.meals.map(\.cooked) == [true, false, false])
    }

    @Test(arguments: [true, false])
    func aTickIsAPutOfTheMealsCookedFlag(cooked: Bool) async throws {
        try await api.send(.setCooked("curry", cooked), to: "list")

        #expect(transport.calls == [ScriptedTransport.Call(method: "PUT", path: "/api/lists/list/recipes/curry/cooked")])
        #expect(transport.bodies.first?["cooked"] as? Bool == cooked)
    }
}

/// The tick through the store, as Plan, Home and Cook use it.
@MainActor struct CookedStoreTests {
    private typealias Call = ScriptedTransport.Call
    private let phone = Phone()

    private var cooked: Set<RecipeID>? {
        guard case .ready(let list) = phone.store.phase else { return nil }
        return list.cooked
    }

    private var tickCalls: [Call] {
        phone.transport.calls.filter { $0.path.hasSuffix("/cooked") }
    }

    @Test func aTickShowsAtOnceAndIsSent() async {
        phone.serverAnswers()
        phone.store.setCooked("curry", true)
        #expect(cooked == ["curry"])

        await phone.store.sync().value

        #expect(tickCalls == [Call(method: "PUT", path: "/api/lists/list/recipes/curry/cooked")])
        #expect(phone.transport.bodies.last { $0["cooked"] != nil }?["cooked"] as? Bool == true)
    }

    @Test func tickingWhatIsAlreadySetOrAMealNotOnTheListQueuesNothing() {
        phone.serverIsUnreachable()
        phone.store.setCooked("curry", false)
        phone.store.setCooked("pie", true)

        #expect(phone.store.replica.pending.isEmpty)
    }

    @Test func homeMarksACookedMealOnItsRowAndShelfInPlace() async {
        phone.serverAnswers { $0.description == "GET /api/lists/" ? .status(200, Phone.listsJSON) : nil }
        await phone.library.refresh()
        phone.serverIsUnreachable()

        phone.store.setCooked("curry", true)

        #expect(phone.library.rows.first?.meals == [ListSummary.Meal(id: "curry", title: "Curry", cooked: true)])
        #expect(phone.library.cookShelf?.meals.map(\.id) == ["curry"])
        #expect(phone.library.cookShelf?.cooked == ["curry"])
    }

    @Test func aTickWithNoSignalSurvivesARelaunchAndIsSentOnce() async {
        phone.serverIsUnreachable()
        phone.store.setCooked("curry", true)
        phone.store.setCooked("curry", false)
        phone.store.setCooked("curry", true)
        await phone.store.sync().value

        phone.relaunch()
        #expect(cooked == ["curry"])
        let before = tickCalls.count
        phone.serverAnswers()
        await phone.store.sync().value

        #expect(tickCalls[before...] == [Call(method: "PUT", path: "/api/lists/list/recipes/curry/cooked")])
        #expect(phone.transport.bodies.last { $0["cooked"] != nil }?["cooked"] as? Bool == true)
    }

    /// Cook from Home can finish a meal on a list this phone has never fetched.
    @Test func aTickOnAListNeverFetchedIsQueuedAndAppliesOnceItArrives() async {
        let fresh = Phone(fetched: false)
        fresh.serverIsUnreachable()
        fresh.store.setCooked("curry", true)
        #expect(fresh.store.replica.pending.map(\.op) == [.setCooked("curry", true)])

        fresh.serverAnswers()
        await fresh.store.sync().value

        #expect(fresh.transport.calls.filter { $0.path.hasSuffix("/cooked") }.count == 1)
        guard case .ready(let list) = fresh.store.phase else { Issue.record("list not fetched"); return }
        #expect(list.recipes == ["curry"])
    }
}

/// What older builds wrote keeps loading, with nothing cooked.
struct CookedSavedFilesTests {
    @Test func aListSavedBeforeTheTickHasNothingCooked() throws {
        let saved = #"{"id":"list","base":{"id":"list","name":"Week","recipes":["curry"],"items":[]},"pending":[]}"#

        let replica = try JSONDecoder().decode(ListReplica.self, from: Data(saved.utf8))

        #expect(replica.current?.cooked == [])
    }

    @Test func anIndexSavedBeforeTheTickHasMealsNotCooked() throws {
        let saved = """
            {"summaries":[{"meals":[{"title":"Curry","id":"curry"}],"name":"Week","id":"list","checkedCount":0,"itemCount":2}]}
            """

        let index = try JSONDecoder().decode(LibraryIndex.self, from: Data(saved.utf8))

        #expect(index.summaries.first?.meals == [ListSummary.Meal(id: "curry", title: "Curry", cooked: false)])
    }

    @Test func aTickAndCookedMealsSurviveBeingSavedAndLoaded() throws {
        var replica = ListReplica(id: "list")
        replica.rebase(onto: ListDetail(id: "list", name: "Week", recipes: ["curry"], items: [], cooked: ["curry"]))
        replica.enqueue(.setCooked("curry", false), id: "op1")
        let summary = ListSummary(
            id: "list", name: "Week", itemCount: 0, checkedCount: 0, meals: [.init(id: "curry", title: "Curry", cooked: true)])

        let loaded = try JSONDecoder().decode(ListReplica.self, from: JSONEncoder().encode(replica))

        #expect(loaded.base?.cooked == ["curry"])
        #expect(loaded.pending.map(\.op) == [.setCooked("curry", false)])
        #expect(try JSONDecoder().decode(ListSummary.self, from: JSONEncoder().encode(summary)) == summary)
    }
}
