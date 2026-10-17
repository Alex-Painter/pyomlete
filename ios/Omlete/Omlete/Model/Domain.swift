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
nonisolated enum SuggestionScope {}
nonisolated enum RecipeJobScope {}

/// Minted by the server (a Mongo ObjectId).
typealias ListID = Identifier<ListScope>
/// Minted on the phone (a UUID), which is what makes a retried add idempotent.
typealias ItemID = Identifier<ItemScope>
typealias RecipeID = Identifier<RecipeScope>
typealias OpID = Identifier<OpScope>
typealias SuggestionID = Identifier<SuggestionScope>
typealias RecipeJobID = Identifier<RecipeJobScope>

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
    var totalMinutes: Int?
    var rating: Int?
    /// Set only for a recipe imported from a link, which is what "From the web" means.
    var sourceName: String?
    /// nil in a library saved before the picker needed it, and for a meal known only by its title.
    var ingredientCount: Int?
}

/// Where a recipe or an idea came from. A source always has a name to show;
/// only some have a page to open.
nonisolated struct RecipeSource: Codable, Equatable, Sendable {
    let name: String
    let url: URL?
}

nonisolated struct ListRef: Equatable, Sendable {
    let id: ListID
    let name: String
}

/// Where "Add to list" should put a meal. `.current` is the list last opened,
/// else the first, else a new one; `Library` works that out, never a view.
nonisolated enum ListTarget: Equatable, Sendable {
    case current
    case list(ListID)
    case new
}

nonisolated enum MealAdd: Equatable, Sendable {
    case added
    case alreadyOnList
}
