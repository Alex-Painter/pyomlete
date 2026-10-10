import Foundation

/// What both Plan and Shop draw. One function, so the aisle order cannot
/// differ between the two modes.
nonisolated struct ListLayout: Equatable, Sendable {
    struct Aisle: Identifiable, Equatable, Sendable {
        let name: String
        let items: [ListItem]
        var id: String { name }

        /// The aisle's ids after a drag, in the shape `onMove` reports it.
        func ids(moving offsets: IndexSet, to destination: Int) -> [ItemID] {
            let ids = items.map(\.id)
            let moved = offsets.map { ids[$0] }
            var rest = ids.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
            let insertAt = destination - offsets.count(where: { $0 < destination })
            rest.insert(contentsOf: moved, at: min(max(insertAt, 0), rest.count))
            return rest
        }
    }

    static let fallbackAisle = "Other"

    /// Unchecked items by aisle, in the user's aisle order. Aisles the order
    /// does not know come last, in the order they first appear.
    let aisles: [Aisle]
    /// Checked items, in list order.
    let got: [ListItem]

    var remaining: Int { aisles.reduce(0) { $0 + $1.items.count } }

    init(_ list: ListDetail, aisleOrder: [String]) {
        var names: [String] = []
        var groups: [String: [ListItem]] = [:]
        for item in list.items where !item.checked {
            let name = item.category.isEmpty ? Self.fallbackAisle : item.category
            if groups[name] == nil { names.append(name) }
            groups[name, default: []].append(item)
        }
        let rank = Dictionary(aisleOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let sorted = names.enumerated().sorted { a, b in
            let (ra, rb) = (rank[a.element] ?? 999, rank[b.element] ?? 999)
            return ra == rb ? a.offset < b.offset : ra < rb
        }
        aisles = sorted.map { Aisle(name: $0.element, items: groups[$0.element] ?? []) }
        got = list.items.filter(\.checked)
    }
}
