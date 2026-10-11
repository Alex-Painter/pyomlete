import Foundation
import Testing
@testable import Omlete

@MainActor struct AisleStoreTests {
    private typealias Call = ScriptedTransport.Call
    private static let put = Call(method: "PUT", path: "/api/settings/categories")
    private let phone = Phone()

    /// A phone that has loaded Bakery, Dairy, Frozen, with the server answering as `override` says.
    private func loaded(_ override: @escaping (Call) -> ScriptedTransport.Reply? = { _ in nil }) async {
        phone.serverAnswers { call in
            if let reply = override(call) { return reply }
            switch call.description {
            case "GET /api/lists/": return .status(200, Phone.listsJSON)
            case "GET /api/settings/categories":
                return .status(200, #"[{"name":"Dairy","order":1},{"name":"Frozen","order":2},{"name":"Bakery","order":0}]"#)
            case "GET /api/recipes/", "GET /api/units": return .status(200, "[]")
            default: return nil
            }
        }
        await phone.library.refresh()
    }

    /// The aisle names of each save, in the order the server received them.
    private var saves: [[String]] {
        zip(phone.transport.calls, phone.transport.bodies).filter { $0.0 == Self.put }.map { _, body in
            (body["categories"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        }
    }

    private var store: AisleStore { phone.library.aisles }
    private var aisles: AisleOrder { store.order }
    private var shown: [String] { aisles.names }
    private var disk: LibraryIndex? { phone.storage.index }

    private var aisleCalls: [String] {
        phone.transport.calls.filter { $0.path == "/api/settings/categories" }.map(\.method)
    }

    @Test func aSaveSendsTheWholeOrderNumberedByPlace() async throws {
        await loaded()

        store.set(aisles.moving(IndexSet(integer: 2), to: 0))

        #expect(shown == ["Frozen", "Bakery", "Dairy"])
        await eventually { disk?.aisleOrder == ["Frozen", "Bakery", "Dairy"] }
        let body = try #require(zip(phone.transport.calls, phone.transport.bodies).first { $0.0 == Self.put }?.1)
        let sent = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        #expect(String(decoding: sent, as: UTF8.self)
            == #"{"categories":[{"name":"Frozen","order":0},{"name":"Bakery","order":1},{"name":"Dairy","order":2}]}"#)
    }

    @Test func aSaveThatCannotReachTheServerStaysOwedAndIsSentWhenItCan() async throws {
        var reachable = false
        await loaded { $0 == Self.put && !reachable ? .unreachable : nil }

        store.set(try aisles.adding("Drinks"))
        await eventually { saves.count == 1 }
        for _ in 0..<20 { await Task.yield() }

        #expect(shown == ["Bakery", "Dairy", "Frozen", "Drinks"])
        #expect(phone.undo.banner == nil)
        #expect(disk?.aisleOrder == ["Bakery", "Dairy", "Frozen"])
        #expect(disk?.unsentAisles == ["Bakery", "Dairy", "Frozen", "Drinks"])

        reachable = true
        phone.library.syncAll()

        await eventually { disk?.aisleOrder == ["Bakery", "Dairy", "Frozen", "Drinks"] }
        #expect(disk?.unsentAisles == nil)
        #expect(saves.count == 2)
    }

    @Test func aSaveTheServerCannotMakeStaysOwedToo() async throws {
        await loaded { $0 == Self.put ? .status(500) : nil }

        store.set(try aisles.renaming("Dairy", to: "Milk"))
        await eventually { saves.count == 1 }
        for _ in 0..<20 { await Task.yield() }

        #expect(shown == ["Bakery", "Milk", "Frozen"])
        #expect(phone.undo.banner == nil)
    }

    @Test func aSaveTheServerRefusesPutsTheOrderBackAndSaysSo() async throws {
        await loaded { $0 == Self.put ? .status(422) : nil }

        let renamed = try aisles.renaming("Dairy", to: "Milk")
        store.set(renamed)
        #expect(shown == ["Bakery", "Milk", "Frozen"])

        await eventually { phone.undo.banner != nil }
        #expect(shown == ["Bakery", "Dairy", "Frozen"])
        #expect(phone.undo.banner?.message == "Couldn't save your aisles. They're as the server has them.")
        #expect(phone.undo.banner?.canUndo == false)
        #expect(store.refused == renamed)
        #expect(disk?.aisleOrder == ["Bakery", "Dairy", "Frozen"])
        #expect(disk?.unsentAisles == nil)
    }

    @Test func aRefusedSaveIsForgottenAtTheNextChange() async throws {
        var refusing = true
        await loaded { $0 == Self.put && refusing ? .status(422) : nil }
        store.set(try aisles.adding("Drinks"))
        await eventually { store.refused != nil }
        refusing = false

        store.set(try aisles.adding("Snacks"))

        #expect(store.refused == nil)
        await eventually { disk?.aisleOrder == ["Bakery", "Dairy", "Frozen", "Snacks"] }
    }

    @Test func twoQuickChangesArriveOneAtATimeInOrder() async throws {
        await loaded()
        phone.transport.holding = true

        store.set(try aisles.adding("Drinks"))
        await eventually { saves.count == 1 }
        store.set(aisles.moving(IndexSet(integer: 3), to: 0))
        for _ in 0..<20 { await Task.yield() }
        #expect(saves == [["Bakery", "Dairy", "Frozen", "Drinks"]])

        phone.transport.release()

        await eventually { saves.count == 2 }
        #expect(saves.last == ["Drinks", "Bakery", "Dairy", "Frozen"])
        await eventually { disk?.aisleOrder == ["Drinks", "Bakery", "Dairy", "Frozen"] }
        #expect(shown == ["Drinks", "Bakery", "Dairy", "Frozen"])
    }

    @Test func changesMadeBeforeASaveGoesOutAreOneSave() async throws {
        await loaded()

        store.set(try aisles.adding("Drinks"))
        store.set(aisles.moving(IndexSet(integer: 3), to: 0))

        await eventually { disk?.aisleOrder == ["Drinks", "Bakery", "Dairy", "Frozen"] }
        #expect(saves == [["Drinks", "Bakery", "Dairy", "Frozen"]])
    }

    @Test func aChangeUndoneDuringASaveEndsWithTheServerHoldingTheLastOne() async throws {
        await loaded()
        phone.transport.holding = true

        store.set(aisles.deleting("Frozen"))
        await eventually { saves.count == 1 }
        store.set(aisles.restoring("Frozen", at: 2))
        phone.transport.release()

        await eventually { saves.count == 2 }
        #expect(saves.last == ["Bakery", "Dairy", "Frozen"])
    }

    @Test func aDeletedAisleIsHiddenAndUndoBringsItBackWithNothingSent() async {
        await loaded()

        store.delete("Dairy")
        #expect(shown == ["Bakery", "Frozen"])
        #expect(phone.undo.banner?.message == "Deleted Dairy")

        phone.undo.undoTapped()
        for _ in 0..<20 { await Task.yield() }

        #expect(shown == ["Bakery", "Dairy", "Frozen"])
        #expect(saves.isEmpty)
    }

    @Test func aSettledDeleteIsSent() async {
        await loaded()

        store.delete("Dairy")
        for _ in 0..<20 { await Task.yield() }
        #expect(saves.isEmpty)
        phone.undo.commitNow()

        await eventually { disk?.aisleOrder == ["Bakery", "Frozen"] }
        #expect(saves == [["Bakery", "Frozen"]])
    }

    @Test func aDeleteMadeDuringASaveStillWaitsForItsBanner() async throws {
        await loaded()
        phone.transport.holding = true
        store.set(try aisles.adding("Drinks"))
        await eventually { saves.count == 1 }

        store.delete("Dairy")
        phone.transport.release()
        await eventually { disk?.aisleOrder == ["Bakery", "Dairy", "Frozen", "Drinks"] }
        for _ in 0..<20 { await Task.yield() }
        #expect(saves.count == 1)

        phone.undo.commitNow()

        await eventually { saves.count == 2 }
        #expect(saves.last == ["Bakery", "Frozen", "Drinks"])
    }

    @Test func aSecondDeleteSendsTheFirstAndIsHeldItself() async {
        await loaded()

        store.delete("Dairy")
        store.delete("Frozen")
        #expect(shown == ["Bakery"])
        await eventually { saves.count == 1 }
        #expect(saves == [["Bakery", "Frozen"]])

        phone.undo.undoTapped()

        #expect(shown == ["Bakery", "Frozen"])
        for _ in 0..<20 { await Task.yield() }
        #expect(saves.count == 1)
    }

    @Test func aChangeMadeWhileADeleteCanStillBeUndoneNeverSendsTheDelete() async throws {
        await loaded()

        store.delete("Dairy")
        store.set(try aisles.adding("Drinks"))
        await eventually { saves.count == 1 }
        #expect(saves.last == ["Bakery", "Dairy", "Frozen", "Drinks"])
        #expect(shown == ["Bakery", "Frozen", "Drinks"])

        phone.undo.undoTapped()

        #expect(shown == ["Bakery", "Dairy", "Frozen", "Drinks"])
        for _ in 0..<20 { await Task.yield() }
        #expect(saves.count == 1)
    }

    @Test func theNameOfAnAisleBeingDeletedIsStillTakenUntilItsBannerSettles() async {
        await loaded()
        #expect(store.beingDeleted == nil)

        store.delete("Dairy")
        #expect(store.beingDeleted == "Dairy")

        phone.undo.commitNow()
        #expect(store.beingDeleted == nil)
    }

    @Test func aChangeMadeWhileTheServerIsAskedAfterARefusalIsStillSent() async throws {
        var puts = 0
        await loaded { call in
            guard call == Self.put else { return nil }
            puts += 1
            return puts == 1 ? .status(422) : nil
        }
        store.set(try aisles.adding("Drinks"))
        await eventually { puts == 1 }
        phone.transport.holding = true
        await eventually { phone.transport.calls.last?.description == "GET /api/settings/categories" && puts == 1 }

        store.set(try aisles.adding("Snacks"))
        phone.transport.release()

        await eventually { puts == 2 }
        #expect(saves.last == ["Bakery", "Dairy", "Frozen", "Snacks"])
    }

    @Test func aChangeMadeWhileADeleteIsHeldIsFollowedByTheDeleteOnceItSettles() async throws {
        await loaded()

        store.delete("Dairy")
        store.set(try aisles.adding("Drinks"))
        await eventually { saves.count == 1 }
        phone.undo.commitNow()

        await eventually { saves.count == 2 }
        #expect(saves.last == ["Bakery", "Frozen", "Drinks"])
    }

    @Test func aSaveRefusedWhileADeleteIsHeldLeavesTheDeleteAndItsUndoAlone() async throws {
        await loaded { $0 == Self.put ? .status(422) : nil }

        store.delete("Dairy")
        store.set(try aisles.adding("Drinks"))
        await eventually { shown == ["Bakery", "Frozen"] }
        #expect(phone.undo.banner?.message == "Deleted Dairy")

        phone.undo.undoTapped()
        #expect(shown == ["Bakery", "Dairy", "Frozen"])
        #expect(phone.undo.banner?.message == "Couldn't save your aisles. They're as the server has them.")
    }

    @Test func aSaveThatFailsDoesNotTakeANewerChangeWithIt() async throws {
        var puts = 0
        await loaded { call in
            guard call == Self.put else { return nil }
            puts += 1
            return puts == 1 ? .unreachable : nil
        }
        phone.transport.holding = true
        store.set(try aisles.adding("Drinks"))
        await eventually { phone.transport.calls.contains(Self.put) }
        store.set(try aisles.adding("Snacks"))
        phone.transport.release()

        await eventually { puts == 2 }
        await eventually { shown == ["Bakery", "Dairy", "Frozen", "Drinks", "Snacks"] }
        #expect(phone.undo.banner == nil)
    }

    @Test func aDeleteTheServerRefusesBringsTheAisleBackAndSaysSo() async {
        await loaded { $0 == Self.put ? .status(422) : nil }

        store.delete("Dairy")
        phone.undo.commitNow()

        await eventually { phone.undo.banner != nil }
        #expect(shown == ["Bakery", "Dairy", "Frozen"])
        #expect(phone.undo.banner?.message == "Couldn't save your aisles. They're as the server has them.")
    }

    @Test func aDeleteSettledAsTheAppLeavesIsSentWhenItComesBack() async {
        var reachable = true
        await loaded { $0 == Self.put && !reachable ? .unreachable : nil }
        store.delete("Dairy")
        reachable = false

        phone.undo.appLeftFront()
        await eventually { saves.count == 1 }
        for _ in 0..<20 { await Task.yield() }
        #expect(disk?.unsentAisles == ["Bakery", "Frozen"])

        reachable = true
        phone.undo.appCameToFront()
        phone.library.syncAll()

        await eventually { disk?.aisleOrder == ["Bakery", "Frozen"] }
        #expect(disk?.unsentAisles == nil)
        #expect(phone.undo.banner == nil)
    }

    @Test func anOrderNotYetSavedSurvivesAKillAndIsSentAtTheNextLaunch() async throws {
        await loaded()
        phone.transport.holding = true
        store.set(try aisles.adding("Drinks"))
        await eventually { saves.count == 1 }

        phone.serverIsUnreachable()
        phone.relaunch()
        phone.transport.release()
        await phone.library.refresh()

        #expect(shown == ["Bakery", "Dairy", "Frozen", "Drinks"])
        #expect(!store.isLoaded)
        #expect(disk?.unsentAisles == ["Bakery", "Dairy", "Frozen", "Drinks"])

        // Another device has changed the order meanwhile. The order owed replaces it: the last one sent wins.
        var held = #"[{"name":"Fish","order":0}]"#
        await loaded { call in
            if call == Self.put { held = #"[{"name":"Bakery","order":0},{"name":"Drinks","order":1}]"# }
            return call.description == "GET /api/settings/categories" ? .status(200, held) : nil
        }

        #expect(saves.last == ["Bakery", "Dairy", "Frozen", "Drinks"])
        #expect(aisleCalls.suffix(2) == ["PUT", "GET"])
        #expect(shown == ["Bakery", "Drinks"])
        #expect(store.isLoaded)
        #expect(disk?.unsentAisles == nil)
    }

    @Test func aDeleteStillBehindItsBannerIsForgottenByAKill() async {
        await loaded()
        store.delete("Dairy")

        phone.relaunch()

        #expect(shown == ["Bakery", "Dairy", "Frozen"])
        #expect(disk?.unsentAisles == nil)
    }

    @Test func aislesAreNotChangedUntilTheServerHasAnsweredThisLaunch() async throws {
        await loaded()
        phone.serverIsUnreachable()
        phone.relaunch()
        await phone.library.refresh()
        #expect(shown == ["Bakery", "Dairy", "Frozen"])
        #expect(!store.isLoaded)

        store.set(try aisles.adding("Drinks"))
        store.delete("Dairy")

        #expect(shown == ["Bakery", "Dairy", "Frozen"])
        #expect(phone.undo.banner == nil)
    }

    @Test func aSaveMadeDuringALoadGoesOutAfterItAndIsNotUndoneByItsAnswer() async throws {
        await loaded()
        phone.transport.holding = true
        async let refresh: Void = phone.library.refresh()
        await eventually { aisleCalls == ["GET", "GET"] }

        store.set(try aisles.adding("Drinks"))
        for _ in 0..<20 { await Task.yield() }
        #expect(saves.isEmpty)
        phone.transport.release()
        await refresh

        await eventually { disk?.aisleOrder == ["Bakery", "Dairy", "Frozen", "Drinks"] }
        #expect(aisleCalls == ["GET", "GET", "PUT"])
        #expect(shown == ["Bakery", "Dairy", "Frozen", "Drinks"])
    }

    @Test func aLoadAskedForDuringASaveRunsAfterItAndIsNotLost() async throws {
        var held = #"[{"name":"Bakery","order":0},{"name":"Dairy","order":1},{"name":"Frozen","order":2}]"#
        await loaded { call in
            // Another device adds Fish as this phone's save lands.
            if call == Self.put { held = #"[{"name":"Fish","order":0},{"name":"Drinks","order":1}]"# }
            return call.description == "GET /api/settings/categories" ? .status(200, held) : nil
        }
        phone.transport.holding = true
        store.set(try aisles.adding("Drinks"))
        await eventually { saves.count == 1 }

        async let load: Void = store.load()
        for _ in 0..<20 { await Task.yield() }
        #expect(aisleCalls == ["GET", "PUT"])
        phone.transport.release()
        await load

        #expect(aisleCalls == ["GET", "PUT", "GET"])
        #expect(shown == ["Fish", "Drinks"])
        #expect(disk?.aisleOrder == ["Fish", "Drinks"])
    }

    @Test func aLoadAskedForWhileOneIsOutJoinsIt() async {
        await loaded()
        phone.transport.holding = true

        async let first: Void = store.load()
        await eventually { aisleCalls == ["GET", "GET"] }
        async let second: Void = store.load()
        for _ in 0..<20 { await Task.yield() }
        phone.transport.release()
        _ = await (first, second)

        #expect(aisleCalls == ["GET", "GET"])
    }

    @Test func aLoadAfterASaveThatCouldNotBeSentSendsItFirst() async throws {
        var reachable = false
        await loaded { $0 == Self.put && !reachable ? .unreachable : nil }
        store.set(try aisles.adding("Drinks"))
        await eventually { saves.count == 1 }
        for _ in 0..<20 { await Task.yield() }
        reachable = true

        await store.load()

        #expect(aisleCalls == ["GET", "PUT", "PUT", "GET"])
        #expect(disk?.unsentAisles == nil)
    }

    @Test func aLoadThatCannotGetThroughLeavesAnOwedOrderOwed() async throws {
        await loaded()
        phone.serverIsUnreachable()
        store.set(try aisles.adding("Drinks"))

        await store.load()

        #expect(shown == ["Bakery", "Dairy", "Frozen", "Drinks"])
        #expect(disk?.unsentAisles == ["Bakery", "Dairy", "Frozen", "Drinks"])
        #expect(aisleCalls == ["GET", "PUT"])
    }

    @Test func anotherDevicesOrderShowsOnTheNextLoad() async {
        await loaded()

        await loaded { $0.description == "GET /api/settings/categories" ? .status(200, #"[{"name":"Fish","order":0}]"#) : nil }

        #expect(shown == ["Fish"])
    }

    @Test func listsRegroupAsSoonAsTheOrderChanges() async {
        await loaded()

        store.set(aisles.deleting("Bakery"))

        #expect(ListLayout(Phone.server, aisleOrder: shown).aisles.map(\.name) == ["Dairy", "Bakery"])
    }
}
