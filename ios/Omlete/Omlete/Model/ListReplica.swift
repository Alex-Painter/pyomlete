import Foundation

/// Every change to a list. There is no un-queued mutation path: reorder and
/// rename are ops too, because the screen is derived from the op log.
nonisolated enum ListOp: Codable, Equatable, Sendable {
    case add(ListItem)
    case patch(ItemID, ItemPatch)
    case delete(ItemID)
    case removeRecipe(RecipeID)
    case reorder(category: String, itemIDs: [ItemID])
    case rename(String)

    /// Pure reducer that mirrors what the server does with the same request.
    /// Applying an op whose target is missing, or applying one twice, changes nothing.
    func applied(to list: ListDetail) -> ListDetail {
        var list = list
        switch self {
        case .add(let item):
            if !list.items.contains(where: { $0.id == item.id }) { list.items.append(item) }

        case .patch(let id, let patch):
            list.items = list.items.map { $0.id == id ? patch.applied(to: $0) : $0 }

        case .delete(let id):
            list.items.removeAll { $0.id == id }

        case .removeRecipe(let recipe):
            list.recipes.removeAll { $0 == recipe }
            list.items = list.items.compactMap { item in
                guard item.sources.contains(where: { $0.recipeID == recipe }) else { return item }
                var item = item
                item.sources.removeAll { $0.recipeID == recipe }
                guard !item.sources.isEmpty else { return nil }
                item.amount = Self.total(item.sources)
                return item
            }

        case .reorder(let category, let itemIDs):
            let byID = Dictionary(list.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let ordered = itemIDs.compactMap { byID[$0] }.filter { $0.category == category }
            let moving = Set(ordered.map(\.id))
            let slots = list.items.indices.filter { moving.contains(list.items[$0].id) }
            for (slot, item) in zip(slots, ordered) { list.items[slot] = item }

        case .rename(let name):
            list.name = name
        }
        return list
    }

    private static func total(_ sources: [ItemSource]) -> Double? {
        let amounts = sources.compactMap(\.amount)
        guard !amounts.isEmpty else { return nil }
        return (amounts.reduce(0, +) * 100).rounded() / 100
    }
}

nonisolated struct PendingOp: Codable, Equatable, Sendable, Identifiable {
    let id: OpID
    var op: ListOp
    /// Held by an Undo banner: applied on screen, not yet sendable. Released
    /// when the banner settles. Not a timestamp, so the core has no clock.
    var held: Bool
}

nonisolated enum SendOutcome: Sendable {
    /// 2xx: the op becomes part of `base`.
    case accepted
    /// 4xx: retrying cannot fix it, so the op is dropped and `base` is untouched.
    case rejected
}

/// One list's last server copy plus its unsent changes. The single source of
/// truth for a list on this phone and the unit of persistence, so the snapshot
/// and the queue cannot disagree after a kill.
///
/// Invariant: what the user sees is `base ⊕ pending`, always derived, never stored.
/// - Undo of a held delete is `cancel`: the row was never removed from `base`,
///   so it returns to its old slot.
/// - A refresh is `rebase`: unsent ops stay on top by construction.
/// - An acknowledged op moves from `pending` into `base`, so nothing flickers
///   back between the 2xx and the next GET.
nonisolated struct ListReplica: Codable, Equatable, Sendable {
    let id: ListID
    /// nil until the first fetch succeeds.
    private(set) var base: ListDetail?
    private(set) var pending: [PendingOp] = []
    /// The op on the wire. Folding never touches it, so a change made
    /// mid-request cannot be dropped along with the ack.
    private(set) var sending: OpID?

    private enum CodingKeys: String, CodingKey {
        case id, base, pending
    }

    init(id: ListID) {
        self.id = id
    }

    var current: ListDetail? {
        guard let base else { return nil }
        return pending.reduce(base) { list, pending in pending.op.applied(to: list) }
    }

    /// Ops waiting on the network. Held ones are waiting on the user instead.
    var unsentCount: Int { pending.count(where: { !$0.held }) }

    /// The name a queued rename will give the list, for a list never fetched.
    var pendingName: String? {
        for pending in pending.reversed() {
            if case .rename(let name) = pending.op { return name }
        }
        return nil
    }

    /// Appends the op, or folds it into an earlier unsent one and returns that
    /// op's id. A fold happens only where it cannot change `current`: never into
    /// the op on the wire, never into a held op, and never across an op the new
    /// one does not commute with.
    @discardableResult
    mutating func enqueue(_ op: ListOp, id: OpID, held: Bool = false) -> OpID {
        if !held, let index = foldIndex(for: op) {
            pending[index].op = Self.fold(op, into: pending[index].op)
            return pending[index].id
        }
        pending.append(PendingOp(id: id, op: op, held: held))
        return id
    }

    /// Undo. Ids that were already sent are ignored; returns the ids removed.
    @discardableResult
    mutating func cancel(_ ids: Set<OpID>) -> Set<OpID> {
        let removed = Set(pending.filter { ids.contains($0.id) && $0.id != sending }.map(\.id))
        pending.removeAll { removed.contains($0.id) }
        return removed
    }

    /// The banner settled without Undo.
    mutating func release(_ ids: Set<OpID>) {
        for index in pending.indices where ids.contains(pending[index].id) {
            pending[index].held = false
        }
    }

    /// Called on load from disk: a kill mid-banner commits what was held.
    mutating func releaseAll() {
        for index in pending.indices { pending[index].held = false }
    }

    /// Marks the first op that is not held as on the wire and returns it.
    mutating func beginSend() -> PendingOp? {
        precondition(sending == nil, "one send at a time")
        guard let next = pending.first(where: { !$0.held }) else { return nil }
        sending = next.id
        return next
    }

    /// Network failure or a retryable status: the op stays first in line.
    mutating func abortSend() {
        sending = nil
    }

    mutating func finishSend(_ outcome: SendOutcome) {
        guard let index = pending.firstIndex(where: { $0.id == sending }) else { return }
        let sent = pending.remove(at: index)
        sending = nil
        if outcome == .accepted, let base { self.base = sent.op.applied(to: base) }
    }

    /// Server truth arrived. Legal only with nothing on the wire: a GET that
    /// raced a send could miss it, and the acked op would vanish from screen.
    mutating func rebase(onto server: ListDetail) {
        precondition(sending == nil, "no rebase while a send is outstanding")
        base = server
    }

    private func foldIndex(for op: ListOp) -> Int? {
        for index in pending.indices.reversed() {
            let earlier = pending[index]
            let frozen = earlier.held || earlier.id == sending
            switch (op, earlier.op) {
            case (.patch(let id, _), .patch(let other, _)) where id == other:
                return frozen ? nil : index
            // POST items ignores `checked`, so a check folded into an unsent add would be lost.
            case (.patch(let id, let patch), .add(let item)) where id == item.id:
                return frozen || patch.checked != .keep ? nil : index
            case (.patch(let id, _), .delete(let other)) where id == other:
                return nil
            case (.patch, .reorder), (.patch, .removeRecipe):
                return nil
            case (.patch, _):
                continue

            case (.reorder(let category, _), .reorder(let other, _)) where category == other:
                return frozen ? nil : index
            case (.reorder, .reorder), (.reorder, .rename):
                continue
            case (.reorder, .patch(_, let patch)) where patch.category == .keep:
                continue
            case (.reorder, _):
                return nil

            case (.rename, .rename):
                return frozen ? nil : index
            case (.rename, _):
                continue

            case (.add, _), (.delete, _), (.removeRecipe, _):
                return nil
            }
        }
        return nil
    }

    private static func fold(_ later: ListOp, into earlier: ListOp) -> ListOp {
        switch (earlier, later) {
        case (.patch(let id, let first), .patch(_, let second)): .patch(id, first.merging(second))
        case (.add(let item), .patch(_, let patch)): .add(patch.applied(to: item))
        default: later
        }
    }
}
