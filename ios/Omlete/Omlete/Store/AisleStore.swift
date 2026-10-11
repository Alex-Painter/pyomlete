import Foundation
import Observation

/// An aisle hidden by a delete whose Undo banner is still up, and where it sat.
private struct HeldAisle {
    let name: String
    let place: Int
}

/// The aisle order on this phone and the saving of it. `Library` owns the one
/// instance and writes `saved` and `owed` to disk when `onChange` says so.
///
/// Invariant: at most one request for the aisles is out at a time, and an
/// order that is owed goes before a load. So a load's answer is never older
/// than a save, two saves cannot arrive out of order, and a load asked for
/// during a save is answered after it.
@Observable final class AisleStore {
    /// The server has answered for the aisles this launch. Until then they are
    /// not changed: a save replaces the whole order, and one made from an old
    /// copy would undo whatever another device did since.
    private(set) var isLoaded = false
    /// The order the server holds, as far as this phone knows.
    private(set) var saved: AisleOrder
    /// The whole order as the user has made it and the server lacks, an aisle
    /// being deleted included until its banner settles. Kept on disk until
    /// the server answers for it, so an order the app was killed or cut off
    /// before sending goes out later. It replaces whatever the server holds
    /// by then: the last order sent wins.
    private(set) var owed: AisleOrder?
    /// The order of a save the server refused, until the next change. Settings
    /// gives the name typed for it back to its field.
    private(set) var refused: AisleOrder?
    /// At most one, because there is one banner. Hidden from `order` and in
    /// nothing that is sent, so Undo only has to forget it.
    private var held: HeldAisle?

    /// Called whenever `saved` or `owed` changes.
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let undo: UndoCenter
    @ObservationIgnored private var working: Task<Void, Never>?
    /// A load has been asked for and not yet answered.
    @ObservationIgnored private var loadWanted = false

    init(saved: AisleOrder, owed: AisleOrder?, api: APIClient, undo: UndoCenter) {
        self.saved = saved
        self.owed = owed
        self.api = api
        self.undo = undo
    }

    /// The order as the user last left it, sent or not.
    var order: AisleOrder {
        guard let held else { return all }
        return all.deleting(held.name)
    }

    /// `order` with an aisle being deleted still in it.
    private var all: AisleOrder { owed ?? saved }

    /// The aisle hidden behind the Undo banner, if any. Its name is still
    /// taken: giving it to another aisle would lose that aisle when the delete settles.
    var beingDeleted: String? { held?.name }

    /// Shows the order at once and saves it. With no signal it stays owed and
    /// is sent by `sync()`; if the server refuses it, the order goes back to
    /// the server's and the banner says so. An aisle whose delete can still be
    /// undone is sent where it was, so this never sends that delete early.
    func set(_ order: AisleOrder) {
        guard isLoaded, order != self.order else { return }
        owe(held.map { order.restoring($0.name, at: $0.place) } ?? order)
    }

    /// Hides the aisle at once and offers Undo. Nothing about it is sent
    /// until the banner settles, so an Undo sends nothing, whatever else was
    /// changed meanwhile.
    func delete(_ name: String) {
        guard isLoaded, order.names.contains(name) else { return }
        undo.offer("Deleted \(name)", undo: { [weak self] in
            guard let self, held?.name == name else { return }
            held = nil
        }, commit: { [weak self] in
            guard let self, held?.name == name else { return }
            held = nil
            owe(all.deleting(name))
        })
        // Read after the offer, which settles an earlier delete and so changes the order.
        guard let place = all.names.firstIndex(of: name) else { return }
        held = HeldAisle(name: name, place: place)
    }

    /// Sends an order still owed. Called when the app comes to the front and
    /// when the network returns.
    func sync() {
        if owed != nil { work() }
    }

    /// Asks the server for the order, after sending any that is owed. A call
    /// made while a load is out joins it.
    func load() async {
        loadWanted = true
        await work().value
    }

    private func owe(_ order: AisleOrder) {
        owed = order
        refused = nil
        onChange()
        work()
    }

    @discardableResult private func work() -> Task<Void, Never> {
        if let working { return working }
        let task = Task { [weak self] in
            await self?.settle()
            return
        }
        working = task
        return task
    }

    /// One request at a time until nothing is owed and no load is wanted. A
    /// save carries the whole order as it stands when it goes out, so a
    /// change made during one is picked up by the next turn, and a save that
    /// is refused takes with it only the order it carried.
    private func settle() async {
        defer { working = nil }
        while true {
            if let order = owed {
                guard await send(order) else { return }
            } else if loadWanted {
                if let answer = try? await api.aisleOrder() {
                    saved = answer
                    isLoaded = true
                    onChange()
                }
                loadWanted = false
            } else {
                return
            }
        }
    }

    /// False when the server could not be reached, which ends the turn with the order still owed.
    private func send(_ order: AisleOrder) async -> Bool {
        if order != saved {
            do {
                try await api.saveAisleOrder(order)
            } catch {
                // Changed again while that was on its way: the newer order has not been tried.
                if owed != order { return true }
                if error.isRetryable {
                    // A load would fare no better, and its caller is waiting.
                    loadWanted = false
                    return false
                }
                owed = nil
                refused = order
                onChange()
                undo.inform("Couldn't save your aisles. They're as the server has them.")
                // Makes that true, whatever another device has done since.
                loadWanted = true
                return true
            }
            saved = order
            // The server now holds this order, which is as good as its answer to a load.
            isLoaded = true
        }
        if owed == order { owed = nil }
        onChange()
        return true
    }
}
