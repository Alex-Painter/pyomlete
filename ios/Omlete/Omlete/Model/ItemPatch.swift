import Foundation

/// One field of a partial update. `.keep` is "key absent"; `.set(nil)` on an
/// optional field is "explicit null". There is no third spelling.
nonisolated enum Change<Value: Codable & Equatable & Sendable>: Equatable, Sendable {
    case keep
    case set(Value)
}

/// A partial update to an item. Its Codable is both the PATCH body and the
/// on-disk queue format, and is the only place that knows `.keep` means "no
/// key" and `.set(nil)` means JSON null.
nonisolated struct ItemPatch: Equatable, Sendable, Codable {
    var name: Change<String> = .keep
    var amount: Change<Double?> = .keep
    var unit: Change<String?> = .keep
    var category: Change<String> = .keep
    var checked: Change<Bool> = .keep

    init() {}

    static func checked(_ value: Bool) -> ItemPatch {
        var patch = ItemPatch()
        patch.checked = .set(value)
        return patch
    }

    static func category(_ value: String) -> ItemPatch {
        var patch = ItemPatch()
        patch.category = .set(value)
        return patch
    }

    var isEmpty: Bool { self == ItemPatch() }

    /// Right-biased: a later `.set` wins and `.keep` never erases.
    func merging(_ later: ItemPatch) -> ItemPatch {
        var merged = self
        if later.name != .keep { merged.name = later.name }
        if later.amount != .keep { merged.amount = later.amount }
        if later.unit != .keep { merged.unit = later.unit }
        if later.category != .keep { merged.category = later.category }
        if later.checked != .keep { merged.checked = later.checked }
        return merged
    }

    func applied(to item: ListItem) -> ListItem {
        var item = item
        if case .set(let name) = name { item.name = name }
        if case .set(let amount) = amount { item.amount = amount }
        if case .set(let unit) = unit { item.unit = unit }
        if case .set(let category) = category { item.category = category }
        if case .set(let checked) = checked { item.checked = checked }
        return item
    }

    private enum CodingKeys: String, CodingKey {
        case name, amount, unit, category, checked
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.change(.name)
        amount = try container.change(.amount)
        unit = try container.change(.unit)
        category = try container.change(.category)
        checked = try container.change(.checked)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(amount, forKey: .amount)
        try container.encode(unit, forKey: .unit)
        try container.encode(category, forKey: .category)
        try container.encode(checked, forKey: .checked)
    }
}

nonisolated private extension KeyedDecodingContainer {
    func change<Value>(_ key: Key) throws -> Change<Value> {
        contains(key) ? .set(try decode(Value.self, forKey: key)) : .keep
    }
}

nonisolated private extension KeyedEncodingContainer {
    mutating func encode<Value>(_ change: Change<Value>, forKey key: Key) throws {
        if case .set(let value) = change { try encode(value, forKey: key) }
    }

    mutating func encode<Wrapped>(_ change: Change<Wrapped?>, forKey key: Key) throws {
        switch change {
        case .keep: break
        case .set(nil): try encodeNil(forKey: key)
        case .set(let value?): try encode(value, forKey: key)
        }
    }
}

/// What the item sheet edits. `patch(from:)` turns it into the smallest patch
/// that takes the item to the draft, so an untouched field is never sent.
nonisolated struct ItemDraft: Equatable, Sendable {
    var name: String
    var amount: Double?
    var unit: String?
    var category: String

    init(_ item: ListItem) {
        name = item.name
        amount = item.amount
        unit = item.unit.flatMap { $0.isEmpty ? nil : $0 }
        category = item.category
    }

    func patch(from item: ListItem) -> ItemPatch {
        var patch = ItemPatch()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != item.name { patch.name = .set(trimmed) }
        if amount != item.amount { patch.amount = .set(amount) }
        let unit = unit.flatMap { $0.isEmpty ? nil : $0 }
        if unit != ItemDraft(item).unit { patch.unit = .set(unit) }
        if category != item.category { patch.category = .set(category) }
        return patch
    }
}
