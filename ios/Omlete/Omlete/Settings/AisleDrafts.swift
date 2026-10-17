import Foundation

/// What is typed in Settings and is not an aisle's name yet: a new aisle's
/// name, and text typed over an aisle's own. Kept by the screen and not by a
/// row, so a row scrolled off screen neither loses nor saves what it holds,
/// and a name that is refused stays in its field to be put right.
///
/// The rules about names are `AisleOrder`'s. This words a refusal and decides
/// what the fields show.
nonisolated struct AisleDrafts: Equatable, Sendable {
    /// Why the last name typed was not taken, and the row that says so: an aisle's, or nil for the new aisle's.
    struct Refusal: Equatable, Sendable {
        let aisle: String?
        let message: String
    }

    /// The last name handed over to be saved, and the field it was typed in.
    private enum Sent: Equatable, Sendable {
        case added(String)
        case renamed(from: String, to: String)
    }

    var newName = ""
    /// Until the next change.
    private(set) var refusal: Refusal?
    /// Text typed over an aisle's name and not taken as its name, by that aisle.
    private var typed: [String: String] = [:]
    private var sent: Sent?
    /// A name the server refused to save, by the aisle whose field has it
    /// back. Leaving the screen does not offer it again.
    private var refusedByServer: [String: String] = [:]

    func text(for aisle: String) -> String {
        typed[aisle] ?? aisle
    }

    mutating func type(_ text: String, over aisle: String) {
        typed[aisle] = text == aisle ? nil : text
    }

    func refusal(at aisle: String?) -> String? {
        refusal?.aisle == aisle ? refusal?.message : nil
    }

    /// The order with the new aisle in it, to be saved, or nil with the name
    /// left in its field and the reason in `refusal`. `beingDeleted` is the
    /// aisle behind the Undo banner, whose name is still taken.
    mutating func add(to order: AisleOrder, beingDeleted: String?) -> AisleOrder? {
        guard case .taken(let name, let added) = take(newName, beingDeleted, at: nil, { name throws(AisleOrder.Refusal) in try order.adding(name) })
        else { return nil }
        sent = .added(name)
        newName = ""
        return added
    }

    /// The order with `aisle` under the name typed over it, to be saved, or
    /// nil when there is nothing to save: nothing was typed, the name was
    /// emptied, or it was refused and stays in the field with the reason in
    /// `refusal`. An emptied name is put back to the old one and not refused:
    /// there is nothing in the field to put right, and no aisle has no name.
    mutating func rename(_ aisle: String, in order: AisleOrder, beingDeleted: String?) -> AisleOrder? {
        guard let text = typed[aisle] else { return nil }
        switch take(text, beingDeleted, at: aisle, { name throws(AisleOrder.Refusal) in try order.renaming(aisle, to: name) }) {
        case .taken(let name, let renamed):
            typed[aisle] = nil
            guard renamed != order else { return nil }
            sent = .renamed(from: aisle, to: name)
            return renamed
        case .empty:
            typed[aisle] = nil
            return nil
        case .refused:
            return nil
        }
    }

    /// Every rename typed and not yet offered, as one order. For leaving the
    /// screen, which takes no focus from a field. A name the server has just
    /// refused is not among them: sending it again would be refused again,
    /// to a banner on whatever screen came next.
    mutating func renameAll(in order: AisleOrder, beingDeleted: String?) -> AisleOrder? {
        var latest = order
        for aisle in order.names where typed[aisle] != nil && typed[aisle] != refusedByServer[aisle] {
            latest = rename(aisle, in: latest, beingDeleted: beingDeleted) ?? latest
        }
        return latest == order ? nil : latest
    }

    /// The name to delete for the row drawn as `aisle`. Tapping Delete can
    /// take the keyboard from the row's field first, which renames the aisle
    /// under the row; anything else typed there goes with the aisle.
    mutating func deleting(_ aisle: String, from order: AisleOrder) -> String {
        refusal = nil
        typed[aisle] = nil
        guard case .renamed(from: aisle, to: let renamed) = sent else { return aisle }
        return order.current(of: aisle, renamedTo: renamed)
    }

    /// A drag is a change, and a refusal lasts until the next one.
    mutating func moved() {
        refusal = nil
    }

    /// The order is now `order`, by whatever hand. What was typed over an
    /// aisle that is no longer in it goes, so a later aisle of the same name
    /// does not open showing it.
    mutating func orderChanged(to order: AisleOrder) {
        typed = typed.filter { order.names.contains($0.key) }
        refusedByServer = refusedByServer.filter { order.names.contains($0.key) }
        if let aisle = refusal?.aisle, !order.names.contains(aisle) { refusal = nil }
    }

    /// The server refused to save `refused`, and the order is `order` again.
    /// The name typed for that save goes back to its field, unless something
    /// else has been typed there since.
    mutating func saveRefused(_ refused: AisleOrder, now order: AisleOrder) {
        defer { sent = nil }
        switch sent {
        case .added(let name):
            if refused.names.contains(name), !order.names.contains(name), newName.isEmpty { newName = name }
        case .renamed(let aisle, let name):
            if refused.names.contains(name), !order.names.contains(name), order.names.contains(aisle), typed[aisle] == nil {
                typed[aisle] = name
                refusedByServer[aisle] = name
            }
        case nil:
            break
        }
    }

    private enum Take {
        /// The trimmed name, and the order with it in.
        case taken(String, AisleOrder)
        /// Nothing but spaces, which needs no words.
        case empty
        /// Worded in `refusal`.
        case refused
    }

    /// Tries `text` as a name, leaving `refusal` saying why it was not taken, or nil.
    private mutating func take(
        _ text: String, _ beingDeleted: String?, at row: String?, _ change: (String) throws(AisleOrder.Refusal) -> AisleOrder
    ) -> Take {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        refusal = nil
        if let beingDeleted, beingDeleted.caseInsensitiveCompare(name) == .orderedSame {
            refusal = Refusal(aisle: row, message: "\(beingDeleted) is being deleted. Tap Undo to keep it.")
            return .refused
        }
        do {
            return .taken(name, try change(name))
        } catch .taken(let other) {
            refusal = Refusal(aisle: row, message: "There's already an aisle called \(other).")
            return .refused
        } catch {
            return .empty
        }
    }
}
