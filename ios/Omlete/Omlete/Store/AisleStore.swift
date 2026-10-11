import Foundation
import Observation

/// An aisle hidden by a delete whose Undo banner is still up, and where it sat.
private struct HeldAisle {
    let name: String
    let place: Int
}

/// The aisle order on this phone and the saving of it. `Library` owns the one
/// instance. It writes `saved` and `owed` to disk itself, whenever either changes.
///
/// Invariant: at most one request for the aisles is out at a time, and an
/// order that is owed goes before a load. So a load's answer is never older
/// than a save, two saves cannot arrive out of order, and a load asked for
/// during a save is answered after it.
///
/// Invariant: an order that is owed is always sent, even one equal to
/// `saved`. A save that timed out may have been stored all the same, then or
/// later, so `saved` is only the last answer and not what the server holds now.
@Observable final class AisleStore {
    /// The server has answered for the aisles this launch. Until then they are
    /// not changed: a save replaces the whole order, and one made from an old
    /// copy would undo whatever another device did since.
    private(set) var isLoaded = false
    /// The order the server last answered with, to a load or to a save.
    private(set) var saved: AisleOrder
    /// The whole order as the user has made it and the server has not answered
    /// for, an aisle being deleted included until its banner settles. Kept on
    /// disk until the server answers for it, so an order the app was killed or
    /// cut off before sending goes out later. It replaces whatever the server
    /// holds by then: the last order sent wins.
    private(set) var owed: AisleOrder?
    /// The order of a save the server refused, until the next change. Settings
    /// gives the name typed for it back to its field.
    private(set) var refused: AisleOrder?
    /// At most one, because there is one banner. Hidden from `order` and in
    /// nothing that is sent, so Undo only has to forget it.
    private var held: HeldAisle?

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let undo: UndoCenter
    @ObservationIgnored private let save: (AisleRecord) -> Void
    /// The turn of requests now running, which a test waits for.
    @ObservationIgnored private(set) var working: Task<Void, Never>?
    /// A load has been asked for and not yet answered.
    @ObservationIgnored private var loadWanted = false

    init(_ record: AisleRecord, api: APIClient, undo: UndoCenter, save: @escaping (AisleRecord) -> Void) {
        saved = AisleOrder(record.saved)
        owed = record.owed.map { AisleOrder($0) }
        self.api = api
        self.undo = undo
        self.save = save
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
    /// made while a load is out joins it. An order still owed when the answer
    /// comes stays the one shown.
    func load() async {
        await startLoad().value
    }

    /// `load()` for a caller with nothing to wait for.
    @discardableResult func startLoad() -> Task<Void, Never> {
        loadWanted = true
        return work()
    }

    private func owe(_ order: AisleOrder) {
        owed = order
        refused = nil
        persist()
        work()
    }

    private func persist() {
        save(AisleRecord(saved: saved.names, owed: owed?.names))
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

    /// One request at a time until nothing is left to try. A save carries the
    /// whole order as it stands when it goes out, so a change made during one
    /// is picked up by the next turn of the loop, and a save that is refused
    /// takes with it only the order it carried.
    ///
    /// An order the server could not be reached for is tried once and stays
    /// owed: the next call here tries it again, and nothing waits or repeats
    /// in between. A load that is wanted still runs after it, so aisles that
    /// cannot be saved can still be loaded and changed.
    private func settle() async {
        defer { working = nil }
        var unsent: AisleOrder?
        while true {
            if let order = owed, order != unsent {
                if await !send(order) { unsent = order }
            } else if loadWanted {
                let answer = try? await api.aisleOrder()
                loadWanted = false
                if let answer { serverAnswered(answer) }
            } else {
                return
            }
        }
    }

    private func serverAnswered(_ order: AisleOrder) {
        saved = order
        isLoaded = true
        persist()
    }

    /// False when the server could not be reached and the order is still the one owed.
    private func send(_ order: AisleOrder) async -> Bool {
        do {
            // The order as stored, which is the one to show: the server drops a name that repeats another.
            let stored = try await api.saveAisleOrder(order)
            if owed == order { owed = nil }
            serverAnswered(stored)
        } catch {
            // Changed again while that was on its way: the newer order has not been tried.
            if owed != order { return true }
            if error.isRetryable { return false }
            owed = nil
            refused = order
            persist()
            undo.inform("Couldn't save your aisles. They're as the server has them.")
            // Makes that true, whatever another device has done since.
            loadWanted = true
        }
        return true
    }
}
