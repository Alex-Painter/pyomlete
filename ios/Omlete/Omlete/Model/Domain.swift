import Foundation

/// A string id that cannot be mixed up with an id of another kind.
nonisolated struct Identifier<Scope>: Hashable, Sendable, Identifiable, Codable, ExpressibleByStringLiteral {
    let rawValue: String

    init(_ rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { self.rawValue = value }

    var id: Self { self }

    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated enum ListScope {}
nonisolated enum ItemScope {}
nonisolated enum RecipeScope {}
nonisolated enum OpScope {}

/// Minted by the server (a Mongo ObjectId).
typealias ListID = Identifier<ListScope>
/// Minted on the phone (a UUID), which is what makes a retried add idempotent.
typealias ItemID = Identifier<ItemScope>
typealias RecipeID = Identifier<RecipeScope>
typealias OpID = Identifier<OpScope>

nonisolated struct ItemSource: Codable, Equatable, Sendable {
    var recipeID: RecipeID?
    var amount: Double?
}

nonisolated struct ListItem: Identifiable, Codable, Equatable, Sendable {
    let id: ItemID
    var name: String
    var amount: Double?
    var unit: String?
    var category: String
    var checked: Bool
    var sources: [ItemSource]
}

nonisolated struct ListDetail: Codable, Equatable, Sendable {
    let id: ListID
    var name: String
    var recipes: [RecipeID]
    var items: [ListItem]
}

nonisolated struct ListSummary: Identifiable, Codable, Equatable, Sendable {
    struct Meal: Codable, Equatable, Sendable {
        let id: RecipeID
        let title: String
    }

    let id: ListID
    var name: String
    var itemCount: Int
    var checkedCount: Int
    var meals: [Meal]
}

nonisolated struct RecipeSummary: Identifiable, Codable, Equatable, Sendable {
    let id: RecipeID
    var title: String
    var imageURL: URL?
}
