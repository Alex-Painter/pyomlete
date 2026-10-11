import Foundation
import Testing
@testable import Omlete

struct AisleDraftsTests {
    private let order = AisleOrder(["Bakery", "Dairy", "Frozen"])
    private var drafts = AisleDrafts()

    @Test mutating func aRowShowsItsAisleUntilSomethingIsTypedOverIt() {
        #expect(drafts.text(for: "Dairy") == "Dairy")

        drafts.type("Milk", over: "Dairy")

        #expect(drafts.text(for: "Dairy") == "Milk")
        #expect(drafts.text(for: "Bakery") == "Bakery")
    }

    @Test mutating func whatIsTypedIsNoRenameUntilItIsOffered() {
        drafts.type("Milk", over: "Dairy")

        let renamed = drafts.rename("Bakery", in: order, beingDeleted: nil)
        #expect(renamed == nil)
        #expect(drafts.text(for: "Dairy") == "Milk")
    }

    @Test mutating func anOfferedRenameIsTheOrderToSave() {
        drafts.type(" Milk ", over: "Dairy")

        let renamed = drafts.rename("Dairy", in: order, beingDeleted: nil)
        #expect(renamed == AisleOrder(["Bakery", "Milk", "Frozen"]))
        #expect(drafts.text(for: "Dairy") == "Dairy")
        #expect(drafts.refusal == nil)
    }

    @Test mutating func typingAnAislesOwnNameBackIsNothingToSave() {
        drafts.type("Milk", over: "Dairy")
        drafts.type("Dairy", over: "Dairy")
        let renamed = drafts.rename("Dairy", in: order, beingDeleted: nil)
        #expect(renamed == nil)

        drafts.type("Dairy ", over: "Dairy")
        let renamed2 = drafts.rename("Dairy", in: order, beingDeleted: nil)
        #expect(renamed2 == nil)
        #expect(drafts.text(for: "Dairy") == "Dairy")
    }

    @Test mutating func aRefusedRenameKeepsWhatWasTypedAndSaysWhyAtItsRow() {
        drafts.type("frozen", over: "Dairy")

        let renamed = drafts.rename("Dairy", in: order, beingDeleted: nil)
        #expect(renamed == nil)

        #expect(drafts.text(for: "Dairy") == "frozen")
        #expect(drafts.refusal(at: "Dairy") == "There's already an aisle called Frozen.")
        #expect(drafts.refusal(at: "Frozen") == nil)
        #expect(drafts.refusal(at: nil) == nil)
    }

    @Test mutating func aRefusedRenamePutRightIsTaken() {
        drafts.type("frozen", over: "Dairy")
        _ = drafts.rename("Dairy", in: order, beingDeleted: nil)

        drafts.type("frozen veg", over: "Dairy")

        let renamed = drafts.rename("Dairy", in: order, beingDeleted: nil)
        #expect(renamed == AisleOrder(["Bakery", "frozen veg", "Frozen"]))
        #expect(drafts.refusal == nil)
    }

    @Test mutating func anEmptiedNameGoesBackToTheOldOneWithNoWords() {
        drafts.type("   ", over: "Dairy")

        let renamed = drafts.rename("Dairy", in: order, beingDeleted: nil)
        #expect(renamed == nil)

        #expect(drafts.text(for: "Dairy") == "Dairy")
        #expect(drafts.refusal == nil)
    }

    @Test mutating func theNameOfAnAisleBeingDeletedIsRefusedForARenameAndForANewAisle() {
        let shown = order.deleting("Frozen")
        drafts.type("frozen", over: "Dairy")
        let renamed = drafts.rename("Dairy", in: shown, beingDeleted: "Frozen")
        #expect(renamed == nil)
        #expect(drafts.refusal(at: "Dairy") == "Frozen is being deleted. Tap Undo to keep it.")
        #expect(drafts.text(for: "Dairy") == "frozen")

        drafts.newName = "Frozen"
        let added = drafts.add(to: shown, beingDeleted: "Frozen")
        #expect(added == nil)
        #expect(drafts.refusal(at: nil) == "Frozen is being deleted. Tap Undo to keep it.")
        #expect(drafts.newName == "Frozen")
    }

    @Test mutating func aNewAisleIsTheOrderToSaveAndItsFieldIsEmptied() {
        drafts.newName = " Drinks "

        let added = drafts.add(to: order, beingDeleted: nil)
        #expect(added == AisleOrder(["Bakery", "Dairy", "Frozen", "Drinks"]))
        #expect(drafts.newName.isEmpty)
    }

    @Test mutating func aNewAisleThatIsRefusedStaysInItsFieldWithTheReason() {
        drafts.newName = "bakery"

        let added = drafts.add(to: order, beingDeleted: nil)
        #expect(added == nil)

        #expect(drafts.newName == "bakery")
        #expect(drafts.refusal(at: nil) == "There's already an aisle called Bakery.")
    }

    @Test mutating func aRefusalLastsUntilTheNextChange() {
        drafts.newName = "bakery"
        _ = drafts.add(to: order, beingDeleted: nil)
        drafts.moved()
        #expect(drafts.refusal == nil)

        _ = drafts.add(to: order, beingDeleted: nil)
        _ = drafts.deleting("Dairy", from: order)
        #expect(drafts.refusal == nil)

        _ = drafts.add(to: order, beingDeleted: nil)
        drafts.newName = "Drinks"
        _ = drafts.add(to: order, beingDeleted: nil)
        #expect(drafts.refusal == nil)
    }

    @Test mutating func aNewAisleWhoseSaveWasRefusedGoesBackToItsField() throws {
        drafts.newName = "Drinks"
        let sentOrNil = drafts.add(to: order, beingDeleted: nil)
        let sent = try #require(sentOrNil)

        drafts.saveRefused(sent, now: order)

        #expect(drafts.newName == "Drinks")
    }

    @Test mutating func aNameTypedSinceIsNotReplacedByOneWhoseSaveWasRefused() throws {
        drafts.newName = "Drinks"
        let sentOrNil = drafts.add(to: order, beingDeleted: nil)
        let sent = try #require(sentOrNil)
        drafts.newName = "Sna"

        drafts.saveRefused(sent, now: order)

        #expect(drafts.newName == "Sna")
    }

    @Test mutating func aRenameWhoseSaveWasRefusedShowsAgainInItsRow() throws {
        drafts.type("Milk", over: "Dairy")
        let sentOrNil = drafts.rename("Dairy", in: order, beingDeleted: nil)
        let sent = try #require(sentOrNil)

        drafts.saveRefused(sent, now: order)

        #expect(drafts.text(for: "Dairy") == "Milk")
    }

    @Test mutating func aRefusedSaveThatDidNotCarryTheLastNameTypedGivesNothingBack() throws {
        drafts.newName = "Drinks"
        let addedOrNil = drafts.add(to: order, beingDeleted: nil)
        let added = try #require(addedOrNil)

        drafts.saveRefused(order.moving(IndexSet(integer: 2), to: 0), now: added)

        #expect(drafts.newName.isEmpty)
    }

    @Test mutating func leavingTheScreenOffersEveryRenameTyped() {
        drafts.type("Bread", over: "Bakery")
        drafts.type("bread", over: "Dairy")
        drafts.type("Ice", over: "Frozen")

        let renamed = drafts.renameAll(in: order, beingDeleted: nil)
        #expect(renamed == AisleOrder(["Bread", "Dairy", "Ice"]))
        #expect(drafts.text(for: "Dairy") == "bread")
        #expect(drafts.refusal(at: "Dairy") == nil)
    }

    @Test mutating func leavingTheScreenWithNothingTypedSavesNothing() {
        let renamed = drafts.renameAll(in: order, beingDeleted: nil)
        #expect(renamed == nil)
    }

    @Test mutating func deleteActsOnTheNewNameWhenTheRowsRenameHasJustGoneThrough() throws {
        drafts.type("Milk", over: "Dairy")
        let renamedOrNil = drafts.rename("Dairy", in: order, beingDeleted: nil)
        let renamed = try #require(renamedOrNil)

        let deleted = drafts.deleting("Dairy", from: renamed)
        #expect(deleted == "Milk")
        let deleted2 = drafts.deleting("Bakery", from: renamed)
        #expect(deleted2 == "Bakery")
    }

    @Test mutating func deleteDropsWhatWasTypedOverItsAisle() {
        drafts.type("frozen", over: "Dairy")
        _ = drafts.rename("Dairy", in: order, beingDeleted: nil)

        let deleted = drafts.deleting("Dairy", from: order)
        #expect(deleted == "Dairy")

        #expect(drafts.text(for: "Dairy") == "Dairy")
        #expect(drafts.refusal == nil)
    }
}
