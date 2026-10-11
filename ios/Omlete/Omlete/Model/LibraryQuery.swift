import Foundation

/// The recipe library's search, sort and filter as one value, so the screen
/// holds a single piece of state and the rules are tested without it.
nonisolated struct LibraryQuery: Equatable, Sendable {
    enum Sort: String, CaseIterable, Sendable {
        case newest, topRated, quickest, alphabetical

        var title: String {
            switch self {
            case .newest: "Newest"
            case .topRated: "Top rated"
            case .quickest: "Quickest"
            case .alphabetical: "A–Z"
            }
        }
    }

    enum Filter: String, CaseIterable, Sendable {
        case favourites, quick, fromTheWeb

        var title: String {
            switch self {
            case .favourites: "4★ and up"
            case .quick: "Under 30 min"
            case .fromTheWeb: "From the web"
            }
        }

        func admits(_ recipe: RecipeSummary) -> Bool {
            switch self {
            case .favourites: (recipe.rating ?? 0) >= 4
            case .quick: recipe.totalMinutes.map { $0 <= 30 } ?? false
            case .fromTheWeb: recipe.sourceName != nil
            }
        }
    }

    var search = ""
    var sort = Sort.newest
    var filter: Filter?

    /// `recipes` arrive newest first, which is what `.newest` keeps. Every
    /// other sort keeps that order among equals.
    func apply(to recipes: [RecipeSummary]) -> [RecipeSummary] {
        let needle = search.trimmed.lowercased()
        let shown = recipes.filter { recipe in
            (needle.isEmpty || recipe.title.lowercased().contains(needle)) && (filter?.admits(recipe) ?? true)
        }
        let ordered: (RecipeSummary, RecipeSummary) -> ComparisonResult = switch sort {
        case .newest: { _, _ in .orderedSame }
        case .topRated: { compare($1.rating ?? 0, $0.rating ?? 0) }
        case .quickest: { compare($0.totalMinutes ?? .max, $1.totalMinutes ?? .max) }
        case .alphabetical: { $0.title.localizedCaseInsensitiveCompare($1.title) }
        }
        return shown.enumerated().sorted { first, second in
            switch ordered(first.element, second.element) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: first.offset < second.offset
            }
        }.map(\.element)
    }
}

nonisolated private func compare(_ first: Int, _ second: Int) -> ComparisonResult {
    first < second ? .orderedAscending : first > second ? .orderedDescending : .orderedSame
}
