import Foundation
import Testing
@testable import Omlete

struct AisleOrderTests {
    private typealias Refusal = AisleOrder.Refusal
    private let order = AisleOrder(["Bakery", "Dairy", "Frozen"])

    @Test func aNewAisleIsTrimmedAndGoesLast() throws {
        #expect(try order.adding("  World foods \n").names == ["Bakery", "Dairy", "Frozen", "World foods"])
    }

    @Test func anEmptyNameIsNotAdded() {
        #expect(throws: Refusal.empty) { try order.adding("   ") }
    }

    @Test func aNameAnotherAisleHasIsNotAddedWhateverItsCase() {
        #expect(throws: Refusal.taken("Dairy")) { try order.adding(" dairy") }
    }

    @Test func aRenamedAisleKeepsItsPlace() throws {
        #expect(try order.renaming("Dairy", to: " Milk & eggs ").names == ["Bakery", "Milk & eggs", "Frozen"])
    }

    @Test func anAisleIsNotRenamedToNothing() {
        #expect(throws: Refusal.empty) { try order.renaming("Dairy", to: " ") }
    }

    @Test func anAisleIsNotRenamedToAnothersName() {
        #expect(throws: Refusal.taken("Frozen")) { try order.renaming("Dairy", to: "FROZEN") }
    }

    @Test func anAisleMayChangeTheCaseOfItsOwnName() throws {
        #expect(try order.renaming("Dairy", to: "DAIRY").names == ["Bakery", "DAIRY", "Frozen"])
    }

    @Test func renamingAnAisleThatIsNotThereChangesNothing() throws {
        #expect(try order.renaming("Drinks", to: "Pop") == order)
    }

    @Test func aDragMovesAnAisle() {
        #expect(order.moving(IndexSet(integer: 0), to: 3).names == ["Dairy", "Frozen", "Bakery"])
        #expect(order.moving(IndexSet(integer: 2), to: 0).names == ["Frozen", "Bakery", "Dairy"])
        #expect(order.moving(IndexSet(integer: 1), to: 1) == order)
    }

    @Test func aDeletedAisleLeavesTheOthersInOrder() {
        #expect(order.deleting("Dairy").names == ["Bakery", "Frozen"])
    }

    @Test func aDeletedAisleGoesBackWhereItWas() {
        #expect(order.deleting("Dairy").restoring("Dairy", at: 1) == order)
    }

    @Test func anAisleRestoredToAShorterOrderGoesLast() {
        #expect(AisleOrder(["Bakery"]).restoring("Frozen", at: 2).names == ["Bakery", "Frozen"])
    }

    @Test func restoringAnAisleThatIsThereChangesNothing() {
        #expect(order.restoring("Bakery", at: 2) == order)
    }

    @Test func aRepeatedNameIsOneAisleInItsFirstPlace() {
        #expect(AisleOrder(["Bakery", "Dairy", "Bakery", "bakery"]).names == ["Bakery", "Dairy", "bakery"])
    }
}

@MainActor struct AisleSavingTests {
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

    private var aisles: AisleOrder { AisleOrder(phone.library.aisleOrder) }

    @Test func aSaveSendsTheWholeOrderNumberedByPlace() async throws {
        await loaded()

        phone.library.setAisles(aisles.moving(IndexSet(integer: 2), to: 0))

        #expect(phone.library.aisleOrder == ["Frozen", "Bakery", "Dairy"])
        await eventually { phone.storage.index?.aisleOrder == ["Frozen", "Bakery", "Dairy"] }
        let body = try #require(zip(phone.transport.calls, phone.transport.bodies).first { $0.0 == Self.put }?.1)
        let sent = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        #expect(String(decoding: sent, as: UTF8.self)
            == #"{"categories":[{"name":"Frozen","order":0},{"name":"Bakery","order":1},{"name":"Dairy","order":2}]}"#)
    }

    @Test func aSaveThatFailsPutsTheOrderBackAndSaysSo() async throws {
        await loaded { $0 == Self.put ? .unreachable : nil }

        phone.library.setAisles(try aisles.adding("Drinks"))
        #expect(phone.library.aisleOrder == ["Bakery", "Dairy", "Frozen", "Drinks"])

        await eventually { phone.undo.banner != nil }
        #expect(phone.library.aisleOrder == ["Bakery", "Dairy", "Frozen"])
        #expect(phone.undo.banner?.message == "Couldn't reach Omlete. Your aisles are as the server has them.")
        #expect(phone.undo.banner?.canUndo == false)
        #expect(phone.storage.index?.aisleOrder == ["Bakery", "Dairy", "Frozen"])
    }

    @Test func aSaveTheServerRefusesPutsTheOrderBackToo() async throws {
        await loaded { $0 == Self.put ? .status(500) : nil }

        phone.library.setAisles(try aisles.renaming("Dairy", to: "Milk"))

        await eventually { phone.undo.banner != nil }
        #expect(phone.library.aisleOrder == ["Bakery", "Dairy", "Frozen"])
        #expect(phone.undo.banner?.message == "Couldn't save your aisles. They're as the server has them.")
    }

    @Test func twoQuickChangesArriveOneAtATimeInOrder() async throws {
        await loaded()
        phone.transport.holding = true

        phone.library.setAisles(try aisles.adding("Drinks"))
        await eventually { saves.count == 1 }
        phone.library.setAisles(aisles.moving(IndexSet(integer: 3), to: 0))
        for _ in 0..<20 { await Task.yield() }
        #expect(saves == [["Bakery", "Dairy", "Frozen", "Drinks"]])

        phone.transport.release()

        await eventually { saves.count == 2 }
        #expect(saves.last == ["Drinks", "Bakery", "Dairy", "Frozen"])
        await eventually { phone.storage.index?.aisleOrder == ["Drinks", "Bakery", "Dairy", "Frozen"] }
        #expect(phone.library.aisleOrder == ["Drinks", "Bakery", "Dairy", "Frozen"])
    }

    @Test func changesMadeBeforeASaveGoesOutAreOneSave() async throws {
        await loaded()

        phone.library.setAisles(try aisles.adding("Drinks"))
        phone.library.setAisles(aisles.moving(IndexSet(integer: 3), to: 0))

        await eventually { phone.storage.index?.aisleOrder == ["Drinks", "Bakery", "Dairy", "Frozen"] }
        #expect(saves == [["Drinks", "Bakery", "Dairy", "Frozen"]])
    }

    @Test func aChangeUndoneDuringASaveEndsWithTheServerHoldingTheLastOne() async throws {
        await loaded()
        phone.transport.holding = true

        phone.library.setAisles(aisles.deleting("Frozen"))
        await eventually { saves.count == 1 }
        phone.library.setAisles(aisles.restoring("Frozen", at: 2))
        phone.transport.release()

        await eventually { saves.count == 2 }
        #expect(saves.last == ["Bakery", "Dairy", "Frozen"])
    }

    @Test func aDeletedAisleIsHiddenAndUndoBringsItBackWithNothingSent() async {
        await loaded()

        phone.library.deleteAisle("Dairy")
        #expect(phone.library.aisleOrder == ["Bakery", "Frozen"])
        #expect(phone.undo.banner?.message == "Deleted Dairy")

        phone.undo.undoTapped()
        for _ in 0..<20 { await Task.yield() }

        #expect(phone.library.aisleOrder == ["Bakery", "Dairy", "Frozen"])
        #expect(saves.isEmpty)
    }

    @Test func aSettledDeleteIsSent() async {
        await loaded()

        phone.library.deleteAisle("Dairy")
        for _ in 0..<20 { await Task.yield() }
        #expect(saves.isEmpty)
        phone.undo.commitNow()

        await eventually { phone.storage.index?.aisleOrder == ["Bakery", "Frozen"] }
        #expect(saves == [["Bakery", "Frozen"]])
    }

    @Test func aDeleteMadeDuringASaveStillWaitsForItsBanner() async throws {
        await loaded()
        phone.transport.holding = true
        phone.library.setAisles(try aisles.adding("Drinks"))
        await eventually { saves.count == 1 }

        phone.library.deleteAisle("Dairy")
        phone.transport.release()
        await eventually { phone.storage.index?.aisleOrder == ["Bakery", "Dairy", "Frozen", "Drinks"] }
        for _ in 0..<20 { await Task.yield() }
        #expect(saves.count == 1)

        phone.undo.commitNow()

        await eventually { saves.count == 2 }
        #expect(saves.last == ["Bakery", "Frozen", "Drinks"])
    }

    @Test func aSecondDeleteSendsTheFirstAndIsHeldItself() async {
        await loaded()

        phone.library.deleteAisle("Dairy")
        phone.library.deleteAisle("Frozen")
        #expect(phone.library.aisleOrder == ["Bakery"])
        await eventually { saves.count == 1 }
        #expect(saves == [["Bakery", "Frozen"]])

        phone.undo.undoTapped()

        #expect(phone.library.aisleOrder == ["Bakery", "Frozen"])
        for _ in 0..<20 { await Task.yield() }
        #expect(saves.count == 1)
    }

    @Test func aChangeMadeWhileADeleteCanStillBeUndoneNeverSendsTheDelete() async throws {
        await loaded()

        phone.library.deleteAisle("Dairy")
        phone.library.setAisles(try aisles.adding("Drinks"))
        await eventually { saves.count == 1 }
        #expect(saves.last == ["Bakery", "Dairy", "Frozen", "Drinks"])
        #expect(phone.library.aisleOrder == ["Bakery", "Frozen", "Drinks"])

        phone.undo.undoTapped()

        #expect(phone.library.aisleOrder == ["Bakery", "Dairy", "Frozen", "Drinks"])
        for _ in 0..<20 { await Task.yield() }
        #expect(saves.count == 1)
    }

    @Test func aChangeMadeWhileADeleteIsHeldIsFollowedByTheDeleteOnceItSettles() async throws {
        await loaded()

        phone.library.deleteAisle("Dairy")
        phone.library.setAisles(try aisles.adding("Drinks"))
        await eventually { saves.count == 1 }
        phone.undo.commitNow()

        await eventually { saves.count == 2 }
        #expect(saves.last == ["Bakery", "Frozen", "Drinks"])
    }

    @Test func aSaveThatFailsWhileADeleteIsHeldLeavesTheDeleteAndItsUndoAlone() async throws {
        await loaded { $0 == Self.put ? .unreachable : nil }

        phone.library.deleteAisle("Dairy")
        phone.library.setAisles(try aisles.adding("Drinks"))
        await eventually { phone.library.aisleOrder == ["Bakery", "Frozen"] }
        #expect(phone.undo.banner?.message == "Deleted Dairy")

        phone.undo.undoTapped()
        #expect(phone.library.aisleOrder == ["Bakery", "Dairy", "Frozen"])
        #expect(phone.undo.banner?.message == "Couldn't reach Omlete. Your aisles are as the server has them.")
    }

    @Test func aSaveThatFailsDoesNotTakeANewerChangeWithIt() async throws {
        var puts = 0
        await loaded { call in
            guard call == Self.put else { return nil }
            puts += 1
            return puts == 1 ? .unreachable : nil
        }
        phone.transport.holding = true
        phone.library.setAisles(try aisles.adding("Drinks"))
        await eventually { phone.transport.calls.contains(Self.put) }
        phone.library.setAisles(try aisles.adding("Snacks"))
        phone.transport.release()

        await eventually { puts == 2 }
        await eventually { phone.library.aisleOrder == ["Bakery", "Dairy", "Frozen", "Drinks", "Snacks"] }
        #expect(phone.undo.banner == nil)
    }

    @Test func aDeleteThatCannotBeSavedBringsTheAisleBackAndSaysSo() async {
        await loaded { $0 == Self.put ? .unreachable : nil }

        phone.library.deleteAisle("Dairy")
        phone.undo.commitNow()

        await eventually { phone.undo.banner != nil }
        #expect(phone.library.aisleOrder == ["Bakery", "Dairy", "Frozen"])
        #expect(phone.undo.banner?.message == "Couldn't reach Omlete. Your aisles are as the server has them.")
    }

    @Test func aChangeNotYetSavedIsTheServersOrderAgainAfterARelaunch() async throws {
        await loaded()
        phone.transport.holding = true
        phone.library.setAisles(try aisles.adding("Drinks"))

        phone.relaunch()

        #expect(phone.library.aisleOrder == ["Bakery", "Dairy", "Frozen"])
        phone.transport.release()
    }

    @Test func aislesAreNotChangedUntilTheServerHasAnsweredThisLaunch() async throws {
        await loaded()
        phone.serverIsUnreachable()
        phone.relaunch()
        await phone.library.refresh()
        #expect(phone.library.aisleOrder == ["Bakery", "Dairy", "Frozen"])
        #expect(!phone.library.aislesLoaded)

        phone.library.setAisles(try aisles.adding("Drinks"))
        phone.library.deleteAisle("Dairy")

        #expect(phone.library.aisleOrder == ["Bakery", "Dairy", "Frozen"])
        #expect(phone.undo.banner == nil)
    }

    @Test func aLoadThatCrossedASaveDoesNotBringTheOldOrderBack() async throws {
        await loaded()
        phone.transport.holding = true
        async let refresh: Void = phone.library.refresh()
        await eventually { phone.transport.calls.count(where: { $0.path == "/api/settings/categories" }) == 2 }

        phone.library.setAisles(try aisles.adding("Drinks"))
        await eventually { saves.count == 1 }
        phone.transport.release()
        await refresh

        await eventually { phone.storage.index?.aisleOrder == ["Bakery", "Dairy", "Frozen", "Drinks"] }
        #expect(phone.library.aisleOrder == ["Bakery", "Dairy", "Frozen", "Drinks"])
    }

    @Test func anotherDevicesOrderShowsOnTheNextLoad() async {
        await loaded()

        await loaded { $0.description == "GET /api/settings/categories" ? .status(200, #"[{"name":"Fish","order":0}]"#) : nil }

        #expect(phone.library.aisleOrder == ["Fish"])
    }

    @Test func listsRegroupAsSoonAsTheOrderChanges() async {
        await loaded()

        phone.library.setAisles(aisles.deleting("Bakery"))

        #expect(ListLayout(Phone.server, aisleOrder: phone.library.aisleOrder).aisles.map(\.name) == ["Dairy", "Bakery"])
    }
}
