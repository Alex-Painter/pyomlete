import Foundation
import Testing
@testable import Omlete

struct ListReplicaTests {
    private static func item(_ id: ItemID, category: String = "Bakery", checked: Bool = false) -> ListItem {
        ListItem(id: id, name: id.rawValue, amount: nil, unit: nil, category: category, checked: checked, sources: [])
    }

    private static let server = ListDetail(
        id: "list", name: "Week", recipes: [],
        items: [item("bread"), item("milk", category: "Dairy"), item("rolls")])

    /// A replica that has fetched `server` and has nothing unsent.
    private static func fetched() -> ListReplica {
        var replica = ListReplica(id: "list")
        replica.rebase(onto: server)
        return replica
    }

    private func names(_ replica: ListReplica) -> [String] {
        replica.current?.items.map(\.name) ?? []
    }

    @Test func aHeldDeleteHidesTheItemAndCancelRestoresItInPlace() {
        var replica = Self.fetched()

        let op = replica.enqueue(.delete("milk"), id: "op1", held: true)
        #expect(names(replica) == ["bread", "rolls"])
        #expect(replica.beginSend() == nil)
        #expect(replica.unsentCount == 0)

        #expect(replica.cancel([op]) == [op])
        #expect(names(replica) == ["bread", "milk", "rolls"])
        #expect(replica.pending.isEmpty)
    }

    @Test func releasingAHeldDeleteMakesItSendable() {
        var replica = Self.fetched()
        replica.enqueue(.delete("milk"), id: "op1", held: true)

        replica.release(["op1"])

        #expect(replica.unsentCount == 1)
        #expect(replica.beginSend()?.op == .delete("milk"))
    }

    @Test func cancellingAnOpThatWasAlreadySentDoesNothing() {
        var replica = Self.fetched()
        replica.enqueue(.delete("milk"), id: "op1")
        _ = replica.beginSend()
        replica.finishSend(.accepted)

        #expect(replica.cancel(["op1"]).isEmpty)
        #expect(names(replica) == ["bread", "rolls"])
    }

    @Test func rebaseKeepsUnsentOpsVisible() {
        var replica = Self.fetched()
        replica.enqueue(.add(Self.item("jam")), id: "op1")
        replica.enqueue(.patch("bread", .checked(true)), id: "op2")

        var fresh = Self.server
        fresh.items.append(Self.item("eggs"))
        fresh.name = "Renamed elsewhere"
        replica.rebase(onto: fresh)

        #expect(names(replica) == ["bread", "milk", "rolls", "eggs", "jam"])
        #expect(replica.current?.items.first?.checked == true)
        #expect(replica.current?.name == "Renamed elsewhere")
        #expect(replica.pending.count == 2)
    }

    @Test func anAcceptedSendLeavesTheScreenUnchanged() {
        var replica = Self.fetched()
        replica.enqueue(.add(Self.item("jam")), id: "op1")
        replica.enqueue(.delete("milk"), id: "op2")
        let before = replica.current

        _ = replica.beginSend()
        replica.finishSend(.accepted)

        #expect(replica.current == before)
        #expect(replica.base?.items.map(\.name) == ["bread", "milk", "rolls", "jam"])
        #expect(replica.pending.map(\.id) == ["op2"])
    }

    @Test func aRejectedSendDropsTheOpAndLeavesTheServerCopyAlone() {
        var replica = Self.fetched()
        replica.enqueue(.patch("bread", .checked(true)), id: "op1")

        _ = replica.beginSend()
        replica.finishSend(.rejected)

        #expect(replica.pending.isEmpty)
        #expect(replica.current == Self.server)
    }

    @Test func anAbortedSendStaysFirstInLine() {
        var replica = Self.fetched()
        replica.enqueue(.delete("milk"), id: "op1")
        replica.enqueue(.delete("bread"), id: "op2")

        _ = replica.beginSend()
        replica.abortSend()

        #expect(replica.beginSend()?.id == "op1")
    }

    @Test func aPatchMadeWhileItsTargetIsOnTheWireIsNotFoldedAndSurvivesTheAck() {
        var replica = Self.fetched()
        replica.enqueue(.patch("bread", .checked(true)), id: "op1")
        _ = replica.beginSend()

        let second = replica.enqueue(.patch("bread", .checked(false)), id: "op2")
        replica.finishSend(.accepted)

        #expect(second == "op2")
        #expect(replica.pending.map(\.id) == ["op2"])
        #expect(replica.base?.items.first?.checked == true)
        #expect(replica.current?.items.first?.checked == false)
    }

    @Test func tenTogglesFoldToOneOp() {
        var replica = Self.fetched()

        for toggle in 1...10 {
            replica.enqueue(.patch("bread", .checked(toggle.isMultiple(of: 2) == false)), id: OpID("op\(toggle)"))
        }

        #expect(replica.pending.count == 1)
        #expect(replica.pending.first?.op == .patch("bread", .checked(false)))
        #expect(replica.current?.items.first?.checked == false)
    }

    @Test func anEditFoldsIntoAnUnsentAdd() {
        var replica = Self.fetched()
        replica.enqueue(.add(Self.item("jam", category: "Other")), id: "op1")

        let folded = replica.enqueue(.patch("jam", .category("Pantry")), id: "op2")

        #expect(folded == "op1")
        #expect(replica.pending.count == 1)
        #expect(replica.current?.items.last?.category == "Pantry")
    }

    // POST items ignores `checked`, so the check has to travel as its own PATCH.
    @Test func addThenCheckOfflineIsTwoOpsAndEndsChecked() {
        var replica = Self.fetched()
        replica.enqueue(.add(Self.item("jam")), id: "op1")
        replica.enqueue(.patch("jam", .checked(true)), id: "op2")

        #expect(replica.pending.map(\.op) == [.add(Self.item("jam")), .patch("jam", .checked(true))])

        while replica.beginSend() != nil { replica.finishSend(.accepted) }

        #expect(replica.pending.isEmpty)
        #expect(replica.current?.items.last == Self.item("jam", checked: true))
    }

    @Test func aPatchDoesNotFoldAcrossAnOpItDoesNotCommuteWith() {
        var replica = Self.fetched()
        replica.enqueue(.patch("bread", .category("Dairy")), id: "op1")
        replica.enqueue(.reorder(category: "Dairy", itemIDs: ["bread", "milk"]), id: "op2")

        replica.enqueue(.patch("bread", .category("Bakery")), id: "op3")

        #expect(replica.pending.map(\.id) == ["op1", "op2", "op3"])
    }

    @Test func aLaterReorderOrRenameReplacesTheUnsentOne() {
        var replica = Self.fetched()
        replica.enqueue(.reorder(category: "Bakery", itemIDs: ["rolls", "bread"]), id: "op1")
        replica.enqueue(.rename("Weekend"), id: "op2")
        replica.enqueue(.reorder(category: "Bakery", itemIDs: ["bread", "rolls"]), id: "op3")
        replica.enqueue(.rename("Week 2"), id: "op4")

        #expect(replica.pending.map(\.id) == ["op1", "op2"])
        #expect(replica.current?.name == "Week 2")
        #expect(names(replica) == ["bread", "milk", "rolls"])
    }

    @Test(arguments: [
        [ListOp.add(item("jam")), .patch("jam", .checked(true)), .delete("milk")],
        [.patch("bread", .category("Dairy")), .reorder(category: "Dairy", itemIDs: ["bread", "milk"]), .patch("bread", .checked(true))],
        [.rename("A"), .delete("rolls"), .rename("B"), .add(item("rolls"))],
        [.reorder(category: "Bakery", itemIDs: ["rolls", "bread"]), .add(item("bun")), .reorder(category: "Bakery", itemIDs: ["bun", "bread", "rolls"])],
        [.patch("milk", .checked(true)), .patch("bread", .checked(true)), .patch("milk", .checked(false)), .patch("milk", .category("Other"))],
    ])
    func currentEqualsApplyingTheOpsOneByOne(ops: [ListOp]) {
        var replica = Self.fetched()
        for (index, op) in ops.enumerated() { replica.enqueue(op, id: OpID("op\(index)")) }

        let sequential = ops.reduce(Self.server) { list, op in op.applied(to: list) }

        #expect(replica.current == sequential)
    }

    @Test(arguments: [
        ListOp.add(item("jam")),
        .patch("bread", .checked(true)),
        .delete("milk"),
        .removeRecipe("curry"),
        .reorder(category: "Bakery", itemIDs: ["rolls", "bread"]),
        .rename("Weekend"),
        .delete("not on the list"),
        .patch("not on the list", .checked(true)),
    ])
    func replayingAnAppliedOpIsANoOp(op: ListOp) {
        var list = Self.server
        list.recipes = ["curry", "soup"]
        list.items[0].sources = [ItemSource(recipeID: "curry", amount: 1), ItemSource(recipeID: "soup", amount: 2)]

        let once = op.applied(to: list)

        #expect(op.applied(to: once) == once)
    }

    @Test func removingARecipeDropsItsShareAndItemsNothingElseAskedFor() {
        var list = Self.server
        list.recipes = ["curry", "soup"]
        list.items[0].amount = 3.5
        list.items[0].sources = [ItemSource(recipeID: "curry", amount: 1.25), ItemSource(recipeID: "soup", amount: 2.25)]
        list.items[1].sources = [ItemSource(recipeID: "curry", amount: 1)]
        list.items[2].sources = [ItemSource(recipeID: nil, amount: nil)]

        let after = ListOp.removeRecipe("curry").applied(to: list)

        #expect(after.recipes == ["soup"])
        #expect(after.items.map(\.name) == ["bread", "rolls"])
        #expect(after.items[0].amount == 2.25)
    }

    @Test func reorderPermutesOnlyTheSlotsThatAisleOccupies() {
        let after = ListOp.reorder(category: "Bakery", itemIDs: ["rolls", "milk", "bread", "gone"]).applied(to: Self.server)

        #expect(after.items.map(\.name) == ["rolls", "milk", "bread"])
    }

    @Test func releaseAllAfterDecodeMakesHeldOpsDue() throws {
        var replica = Self.fetched()
        replica.enqueue(.delete("milk"), id: "op1", held: true)
        replica.enqueue(.patch("bread", .checked(true)), id: "op2")
        _ = replica.beginSend()

        var restored = try JSONDecoder().decode(ListReplica.self, from: JSONEncoder().encode(replica))

        #expect(restored.sending == nil)
        #expect(restored.current == replica.current)
        #expect(restored.pending.map(\.held) == [true, false])

        restored.releaseAll()

        #expect(restored.unsentCount == 2)
        #expect(restored.beginSend()?.id == "op1")
    }

    @Test func aRenameQueuedBeforeTheFirstFetchIsKnownByName() {
        var replica = ListReplica(id: "list")
        replica.enqueue(.rename("Weekend"), id: "op1")

        #expect(replica.current == nil)
        #expect(replica.pendingName == "Weekend")
    }
}
