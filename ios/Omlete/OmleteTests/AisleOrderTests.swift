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

    @Test func aRowActsOnItsNewNameOnlyIfTheRenameWentThrough() {
        let renamed = AisleOrder(["Bakery", "Deli", "Drinks"])
        #expect(renamed.current(of: "Dairy", renamedTo: "Deli") == "Deli")

        let refused = AisleOrder(["Bakery", "Frozen", "Drinks"])
        #expect(refused.current(of: "Frozen", renamedTo: "Drinks") == "Frozen")
        #expect(refused.current(of: "Frozen", renamedTo: nil) == "Frozen")
        #expect(refused.current(of: "Frozen", renamedTo: "Nowhere") == "Frozen")
    }

    @Test func aRepeatedNameIsOneAisleInItsFirstPlace() {
        #expect(AisleOrder(["Bakery", "Dairy", "Bakery", "bakery"]).names == ["Bakery", "Dairy", "bakery"])
    }
}
