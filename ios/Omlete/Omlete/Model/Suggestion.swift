import Foundation

/// Discover's shelves, in the order they are shown. A card whose section the
/// app does not know goes under "More ideas".
nonisolated enum DiscoverSection: CaseIterable, Sendable {
    case thisWeek, under30, somethingNew, moreIdeas

    var title: String {
        switch self {
        case .thisWeek: "For this week"
        case .under30: "Under 30 minutes"
        case .somethingNew: "Something new"
        case .moreIdeas: "More ideas"
        }
    }

    init(named name: String?) {
        self = Self.allCases.first { $0.title == name } ?? .moreIdeas
    }
}

/// A Discover card: an idea, not yet a recipe. Saving one makes the recipe in
/// the background, which is what `stage` follows.
nonisolated struct Suggestion: Identifiable, Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case fresh
        case saving
        case saved(RecipeID)
        case failed
    }

    let id: SuggestionID
    var title: String
    var reason: String?
    var imageURL: URL?
    var source: RecipeSource?
    var totalMinutes: Int?
    var section: DiscoverSection
    var stage: Stage
}

nonisolated struct Shelf: Equatable, Identifiable, Sendable {
    let section: DiscoverSection
    /// Never empty: a section with no cards has no shelf.
    let cards: [Suggestion]

    var id: DiscoverSection { section }

    static func shelves(of cards: [Suggestion]) -> [Shelf] {
        DiscoverSection.allCases.compactMap { section in
            let cards = cards.filter { $0.section == section }
            return cards.isEmpty ? nil : Shelf(section: section, cards: cards)
        }
    }
}

/// What the Discover screen shows below its toolbar.
nonisolated enum DiscoverFeed: Equatable, Sendable {
    case loading
    /// Never loaded, and the load failed.
    case unavailable(APIError)
    case empty
    case shelves([Shelf])
}

/// How the next batch of ideas is steered. Ratings and lists always count too.
nonisolated struct TuneSettings: Codable, Equatable, Sendable {
    enum Diet: String, Codable, CaseIterable, Sendable {
        case any, vegetarian, vegan, pescatarian, meaty

        var title: String { rawValue.capitalized }
    }

    enum Effort: String, Codable, CaseIterable, Sendable {
        case any, quick, moderate, involved

        var title: String {
            switch self {
            case .any: "Any"
            case .quick: "Quick & easy"
            case .moderate: "Moderate"
            case .involved: "Involved"
            }
        }
    }

    var diet = Diet.any
    var effort = Effort.any
    var notes = ""
}
