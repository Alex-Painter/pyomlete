import Foundation
import Testing
@testable import Omlete

@MainActor struct ListStoreSyncTests {
    private typealias Call = ScriptedTransport.Call
    private let phone = Phone()

    private func item(_ id: ItemID) -> ListItem? {
        guard case .ready(let list) = phone.store.phase else { return nil }
        return list.items.first { $0.id == id }
    }

    @Test func offlineChangesStayOnThePhoneAcrossARelaunch() async {
        phone.serverIsUnreachable()

        phone.store.setChecked("bread", true)
        phone.store.rename("Weekend")
        await phone.store.sync().value

        #expect(phone.store.syncStatus == .offline)
        #expect(phone.store.replica.pending.count == 2)

        phone.relaunch()

        #expect(item("bread")?.checked == true)
        #expect(phone.library.rows.isEmpty)
        #expect(phone.store.replica.pending.count == 2)
        guard case .ready(let list) = phone.store.phase else { Issue.record("list not on the phone"); return }
        #expect(list.name == "Weekend")
    }

    @Test func aDeleteHeldByTheBannerIsCommittedByARelaunch() async {
        phone.serverIsUnreachable()
        phone.store.remove(["milk"], saying: "Removed milk")
        #expect(phone.store.replica.unsentCount == 0)

        phone.relaunch()

        #expect(item("milk") == nil)
        #expect(phone.store.replica.unsentCount == 1)
    }

    @Test func backOnlineTheQueueIsSentInOrderThenTheListIsFetched() async {
        phone.serverIsUnreachable()
        phone.store.setChecked("bread", true)
        phone.store.remove(["milk"], saying: "Removed milk")
        phone.undo.commitNow()
        phone.store.rename("Weekend")
        await phone.store.sync().value
        phone.relaunch()
        let before = phone.transport.calls.count

        phone.serverAnswers()
        phone.library.syncAll()
        await phone.store.sync().value

        #expect(Array(phone.transport.calls[before...]) == [
            Call(method: "PATCH", path: "/api/lists/list/items/bread"),
            Call(method: "DELETE", path: "/api/lists/list/items/milk"),
            Call(method: "PATCH", path: "/api/lists/list"),
            Call(method: "GET", path: "/api/lists/list"),
        ])
        #expect(phone.transport.bodies[before] as? [String: Bool] == ["checked": true])
        #expect(phone.transport.bodies[before + 2] as? [String: String] == ["name": "Weekend"])
        #expect(phone.store.replica.pending.isEmpty)
        #expect(phone.store.syncStatus == .synced)
    }

    @Test(arguments: [500, 503, 408, 429])
    func aRetryableStatusStopsTheDrainAndKeepsEveryOp(status: Int) async {
        phone.serverAnswers { $0.path.hasSuffix("items/bread") ? .status(status) : nil }

        phone.store.setChecked("bread", true)
        phone.store.setChecked("milk", true)
        await phone.store.sync().value

        #expect(phone.transport.calls == [Call(method: "PATCH", path: "/api/lists/list/items/bread")])
        #expect(phone.store.replica.pending.count == 2)
        #expect(phone.store.syncStatus == .syncing(2))
        #expect(item("bread")?.checked == true)
    }

    @Test(arguments: [400, 404, 422])
    func anyOther4xxDropsTheOpCarriesOnAndFetches(status: Int) async {
        phone.serverAnswers { $0.path.hasSuffix("items/bread") ? .status(status) : nil }

        phone.store.setChecked("bread", true)
        phone.store.setChecked("milk", true)
        await phone.store.sync().value

        #expect(phone.transport.calls == [
            Call(method: "PATCH", path: "/api/lists/list/items/bread"),
            Call(method: "PATCH", path: "/api/lists/list/items/milk"),
            Call(method: "GET", path: "/api/lists/list"),
        ])
        #expect(phone.store.replica.pending.isEmpty)
        #expect(item("bread")?.checked == false)
    }

    @Test func noFetchGoesOutWhileASendIsOutstanding() async {
        phone.serverAnswers()
        phone.transport.holding = true

        phone.store.setChecked("bread", true)
        let refreshing = Task { await phone.store.refresh() }
        await eventually { phone.transport.calls.count == 1 }
        phone.store.setChecked("milk", true)
        for _ in 0..<50 { await Task.yield() }

        #expect(phone.transport.calls == [Call(method: "PATCH", path: "/api/lists/list/items/bread")])

        phone.transport.release()
        await refreshing.value
        await phone.store.sync().value

        #expect(phone.transport.calls.map(\.method) == ["PATCH", "PATCH", "GET"])
        #expect(phone.transport.peakInFlight == 1)
    }

    @Test func aChangeMadeDuringAFetchStaysOnScreenAfterIt() async {
        phone.serverAnswers { $0.method == "PATCH" ? .status(503) : nil }
        phone.transport.holding = true
        let refreshing = Task { await phone.store.refresh() }
        await eventually { phone.transport.calls.count == 1 }

        phone.store.setChecked("milk", true)
        phone.transport.release()
        await refreshing.value

        #expect(phone.transport.calls.map(\.method) == ["GET", "PATCH"])
        #expect(item("milk")?.checked == true)
    }

    @Test func aTypedLineBecomesOnePostPerItemWithAPhoneMintedID() async throws {
        phone.serverAnswers()

        phone.store.add("2 onions, 500g mince")
        #expect(item(phone.store.replica.pending[0].op.addedID)?.name == "onions")
        await phone.store.sync().value

        #expect(phone.transport.calls.prefix(2).map(\.description) == ["POST /api/lists/list/items", "POST /api/lists/list/items"])
        let onions = phone.transport.bodies[0]
        #expect(onions["name"] as? String == "onions")
        #expect(onions["amount"] as? Double == 2)
        #expect(onions["category"] as? String == "Other")
        #expect((onions["id"] as? String)?.isEmpty == false)
        #expect(onions["checked"] == nil)
        #expect(phone.transport.bodies[1]["unit"] as? String == "g")
    }

    @Test func theServersAisleReplacesTheGuessUnlessTheUserMovedTheItem() async {
        // The fixture GET knows nothing of the new items, so it is failed to keep them on screen.
        phone.serverAnswers { call in
            if call.path == "/api/categorize" { return .status(200, #"{"category":"Household"}"#) }
            return call.method == "GET" ? .status(500) : nil
        }
        phone.transport.holding = true

        phone.store.add("candles, matches")
        let candles = phone.store.replica.pending[0].op.addedID
        let matches = phone.store.replica.pending[1].op.addedID
        phone.store.update(matches, .category("Bakery"))
        phone.transport.release()

        await eventually { item(candles)?.category == "Household" }
        #expect(item(matches)?.category == "Bakery")
    }

    @Test func theServersAisleIsIgnoredWhenThatAisleIsNoLongerInTheOrder() async {
        phone.serverAnswers { call in
            switch call.description {
            case "GET /api/settings/categories":
                return .status(200, #"[{"name":"Bakery","order":0},{"name":"Other","order":1}]"#)
            case "GET /api/lists/": return .status(200, Phone.listsJSON)
            case "GET /api/recipes/", "GET /api/units": return .status(200, "[]")
            case "POST /api/categorize": return .status(200, #"{"category":"Household"}"#)
            default: return call.method == "GET" ? .status(500) : nil
            }
        }
        await phone.library.refresh()

        phone.store.add("candles")
        let candles = phone.store.replica.pending[0].op.addedID
        await eventually { phone.transport.allCalls.contains { $0.path == "/api/categorize" } }
        for _ in 0..<20 { await Task.yield() }

        #expect(item(candles)?.category != "Household")
    }

    @Test func aShopCheckIsSentAtOnceAndUndoSendsTheOpposite() async {
        phone.serverAnswers { $0.method == "GET" ? .status(500) : nil }

        phone.store.setChecked("bread", true, undoable: true)
        await phone.store.sync().value
        #expect(phone.undo.banner?.message == "Got bread")
        #expect(phone.transport.bodies.first as? [String: Bool] == ["checked": true])

        phone.undo.undoTapped()
        await phone.store.sync().value

        #expect(item("bread")?.checked == false)
        #expect(phone.transport.bodies.filter { !$0.isEmpty }.compactMap { $0 as? [String: Bool] } == [["checked": true], ["checked": false]])
        #expect(phone.undo.banner == nil)
    }

    @Test func aRemovedItemIsSentOnlyAfterTheBannerSettles() async {
        phone.serverAnswers()

        phone.store.remove(["bread"], saying: "Removed bread")
        await phone.store.sync().value

        #expect(item("bread") == nil)
        #expect(phone.undo.banner?.message == "Removed bread")
        #expect(phone.transport.calls.isEmpty)
        #expect(phone.store.syncStatus == .synced)

        phone.undo.commitNow()
        await phone.store.sync().value

        #expect(phone.transport.calls.first == Call(method: "DELETE", path: "/api/lists/list/items/bread"))
    }

    @Test func undoPutsARemovedItemBackWhereItWasAndSendsNothing() async {
        phone.serverAnswers()

        phone.store.remove(["bread"], saying: "Removed bread")
        phone.undo.undoTapped()
        await phone.store.sync().value

        guard case .ready(let list) = phone.store.phase else { Issue.record("list not ready"); return }
        #expect(list.items.map(\.name) == ["bread", "milk"])
        #expect(phone.transport.calls.isEmpty)
        #expect(phone.storage.replicas[Phone.listID]?.pending.isEmpty == true)
    }

    @Test func removingAMealOffersUndoWithItsTitle() async {
        phone.serverAnswers()

        phone.store.removeMeal("curry", title: "Curry")
        #expect(phone.undo.banner?.message == "Removed Curry and its ingredients")
        phone.undo.commitNow()
        await phone.store.sync().value

        #expect(phone.transport.calls.first == Call(method: "DELETE", path: "/api/lists/list/recipes/curry"))
    }

    @Test func aDragIsSentAsThatAislesNewOrder() async {
        var server = Phone.server
        server.items.append(ListItem(id: "rolls", name: "rolls", amount: nil, unit: nil, category: "Bakery", checked: false, sources: []))
        var replica = ListReplica(id: Phone.listID)
        replica.rebase(onto: server)
        phone.storage.save(replica)
        phone.relaunch()
        phone.serverAnswers { $0.method == "GET" ? .status(500) : nil }

        phone.store.reorder("Bakery", moving: IndexSet(integer: 1), to: 0)
        await phone.store.sync().value

        guard case .ready(let list) = phone.store.phase else { Issue.record("list not ready"); return }
        #expect(list.items.map(\.name) == ["rolls", "milk", "bread"])
        #expect(phone.transport.calls.first == Call(method: "PUT", path: "/api/lists/list/items/reorder"))
        #expect(phone.transport.bodies[0]["category"] as? String == "Bakery")
        #expect(phone.transport.bodies[0]["item_ids"] as? [String] == ["rolls", "bread"])
    }

    @Test func aListDeletedElsewhereIsGone() async {
        phone.serverAnswers { $0.method == "GET" ? .status(404) : nil }

        await phone.store.refresh()

        #expect(phone.store.phase == .gone)
    }

    @Test func aListNeverFetchedIsLoadingThenUnavailableWithNoSignal() async {
        let phone = Phone(fetched: false)
        phone.serverIsUnreachable()
        #expect(phone.store.phase == .loading)

        await phone.store.refresh()
        #expect(phone.store.phase == .unavailable)
        #expect(phone.store.syncStatus == .offline)

        phone.serverAnswers()
        await phone.store.refresh()
        #expect(phone.store.phase == .ready(Phone.server))
    }

    @Test func addingAMealWaitsForTheQueueThenFetchesTheMergedList() async throws {
        phone.serverAnswers()
        phone.store.setChecked("bread", true)

        try await phone.store.addMeal("soup")

        await phone.store.sync().value
        #expect(phone.transport.calls.map(\.description) == [
            "PATCH /api/lists/list/items/bread", "POST /api/lists/list/recipes", "GET /api/lists/list",
        ])
        #expect(phone.transport.bodies[1] as? [String: String] == ["recipe_id": "soup"])
    }

    @Test func aMealPutBackWhileItsRemovalCanStillBeUndoneIsNeverSentEitherWay() async throws {
        phone.serverAnswers()
        phone.store.removeMeal("curry", title: "Curry")
        #expect(phone.store.replica.current?.recipes == [])

        let outcome = try await phone.store.addMeal("curry")
        await phone.store.sync().value

        #expect(outcome == .added)
        #expect(phone.store.replica.current?.recipes == ["curry"])
        #expect(phone.undo.banner == nil)
        #expect(!phone.transport.calls.contains { $0.path.hasSuffix("/recipes") || $0.path.hasSuffix("/recipes/curry") })
    }

    @Test func addingAMealWithNoSignalFails() async {
        phone.serverIsUnreachable()

        await #expect(throws: APIError.unreachable) { try await phone.store.addMeal("soup") }
    }
}

private extension ListOp {
    var addedID: ItemID {
        if case .add(let item) = self { item.id } else { "not an add" }
    }
}
