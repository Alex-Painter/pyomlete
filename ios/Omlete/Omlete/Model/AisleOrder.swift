import Foundation

/// The aisles in the order the user walks their shop, and every rule about
/// changing them. Settings edits one of these and hands the result to
/// `AisleStore`; the view holds no rules of its own.
///
/// Invariant: no two aisles have exactly the same name, so a name identifies
/// its aisle. Names that differ only in case can arrive from the server and
/// are kept apart; none can be made here.
nonisolated struct AisleOrder: Equatable, Sendable {
    /// Why a name was not taken.
    enum Refusal: Error, Equatable, Sendable {
        /// Nothing but spaces.
        case empty
        /// Another aisle has this name, whatever its case.
        case taken(String)
    }

    private(set) var names: [String]

    /// Drops a repeated name, keeping its first place. The web can make two
    /// aisles with one name by renaming, and both would group as one anyway.
    init(_ names: [String]) {
        var seen: Set<String> = []
        self.names = names.filter { seen.insert($0).inserted }
    }

    /// The trimmed name goes last, where a new aisle starts.
    func adding(_ name: String) throws(Refusal) -> AisleOrder {
        var order = self
        order.names.append(try accepted(name, replacing: nil))
        return order
    }

    /// The aisle keeps its place. Changing only the case of its own name is
    /// allowed; an aisle that is not here leaves the order as it was.
    func renaming(_ name: String, to newName: String) throws(Refusal) -> AisleOrder {
        guard let place = names.firstIndex(of: name) else { return self }
        var order = self
        order.names[place] = try accepted(newName, replacing: name)
        return order
    }

    /// The name to act on for a row drawn as `name` whose rename to `renamed`
    /// may have just gone through: the new name if the aisle has it now, else
    /// the one the row was drawn with.
    func current(of name: String, renamedTo renamed: String?) -> String {
        guard !names.contains(name), let renamed, names.contains(renamed) else { return name }
        return renamed
    }

    /// A drag, in the shape `onMove` reports it.
    func moving(_ offsets: IndexSet, to destination: Int) -> AisleOrder {
        var order = self
        order.names = names.moving(offsets, to: destination)
        return order
    }

    func deleting(_ name: String) -> AisleOrder {
        var order = self
        order.names.removeAll { $0 == name }
        return order
    }

    /// Puts a deleted aisle back where it was, or last if the order has
    /// shrunk since. An aisle that is already here is left where it is.
    func restoring(_ name: String, at place: Int) -> AisleOrder {
        guard !names.contains(name) else { return self }
        var order = self
        order.names.insert(name, at: min(max(place, 0), names.count))
        return order
    }

    private func accepted(_ name: String, replacing own: String?) throws(Refusal) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw .empty }
        if let other = names.first(where: { $0 != own && $0.caseInsensitiveCompare(name) == .orderedSame }) {
            throw .taken(other)
        }
        return name
    }
}

nonisolated extension Array {
    /// The array after a drag, in the shape `onMove` reports it.
    func moving(_ offsets: IndexSet, to destination: Int) -> [Element] {
        let moved = offsets.map { self[$0] }
        var rest = enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertAt = destination - offsets.count(where: { $0 < destination })
        rest.insert(contentsOf: moved, at: Swift.min(Swift.max(insertAt, 0), rest.count))
        return rest
    }
}
