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
nonisolated enum WeekPlanScope {}
nonisolated enum ChefActionScope {}
nonisolated enum PreferenceScope {}

/// Minted by the server (a Mongo ObjectId).
typealias ListID = Identifier<ListScope>
/// Minted on the phone (a UUID), which is what makes a retried add idempotent.
typealias ItemID = Identifier<ItemScope>
typealias RecipeID = Identifier<RecipeScope>
typealias OpID = Identifier<OpScope>
typealias SuggestionID = Identifier<SuggestionScope>
typealias RecipeJobID = Identifier<RecipeJobScope>
typealias WeekPlanID = Identifier<WeekPlanScope>
/// One change Chef made, which `POST /chef/actions/{id}/undo` puts back.
typealias ChefActionID = Identifier<ChefActionScope>
typealias PreferenceID = Identifier<PreferenceScope>

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
    /// nil for a plain list. A week list has its seven days, in order.
    var weekStart: PlanDate? = nil
    var days: [PlanDay] = []
    /// The meals on the list that have been cooked, a subset of `recipes`. Nothing moves because of it.
    var cooked: Set<RecipeID> = []

    var isWeek: Bool { weekStart != nil && !days.isEmpty }
}

nonisolated struct ListSummary: Identifiable, Codable, Equatable, Sendable {
    struct Meal: Codable, Equatable, Sendable {
        let id: RecipeID
        let title: String
        var cooked = false
    }

    let id: ListID
    var name: String
    var itemCount: Int
    var checkedCount: Int
    var meals: [Meal]
    var weekStart: PlanDate? = nil
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
    /// The latest day it was planned for on any week list, as the server last worked it out.
    var lastPlannedOn: PlanDate? = nil
    var ingredientNames: [String] = []
    var cuisine: String? = nil
    var createdAt: Date? = nil
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

/// Written by hand so a list or library saved by an older build, before weeks or the Cooked tick, still loads.
nonisolated extension ListDetail {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ListID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        recipes = try container.decode([RecipeID].self, forKey: .recipes)
        items = try container.decode([ListItem].self, forKey: .items)
        weekStart = try container.decodeIfPresent(PlanDate.self, forKey: .weekStart)
        days = try container.decodeIfPresent([PlanDay].self, forKey: .days) ?? []
        cooked = try container.decodeIfPresent(Set<RecipeID>.self, forKey: .cooked) ?? []
    }
}

/// An index saved before the Cooked tick has meals with no `cooked`.
nonisolated extension ListSummary.Meal {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(RecipeID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        cooked = try container.decodeIfPresent(Bool.self, forKey: .cooked) ?? false
    }
}

nonisolated extension RecipeSummary {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(RecipeID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        imageURL = try container.decodeIfPresent(URL.self, forKey: .imageURL)
        totalMinutes = try container.decodeIfPresent(Int.self, forKey: .totalMinutes)
        rating = try container.decodeIfPresent(Int.self, forKey: .rating)
        sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName)
        ingredientCount = try container.decodeIfPresent(Int.self, forKey: .ingredientCount)
        lastPlannedOn = try container.decodeIfPresent(PlanDate.self, forKey: .lastPlannedOn)
        ingredientNames = try container.decodeIfPresent([String].self, forKey: .ingredientNames) ?? []
        cuisine = try container.decodeIfPresent(String.self, forKey: .cuisine)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}
