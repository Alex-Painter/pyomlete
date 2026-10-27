import Foundation

/// Search, filters and sort for the meal library on Plan, as one value so the
/// rules are tested without a screen. The default sort puts the meals you
/// haven't had for longest first: variety without having to remember what you ate.
nonisolated struct MealLibraryQuery: Equatable, Sendable {
    enum Sort: String, CaseIterable, Sendable {
        case notLately, favourites, quickest, newest, aToZ

        var title: String {
            switch self {
            case .notLately: "Not had lately"
            case .favourites: "Your favourites"
            case .quickest: "Quickest"
            case .newest: "Newest"
            case .aToZ: "A to Z"
            }
        }
    }

    enum Filter: String, CaseIterable, Sendable {
        case quick, notLately, favourites

        var title: String {
            switch self {
            case .quick: "Quick"
            case .notLately: "Not had lately"
            case .favourites: "Favourites"
            }
        }

        func admits(_ recipe: RecipeSummary, today: PlanDate) -> Bool {
            switch self {
            case .quick: recipe.totalMinutes.map { $0 <= MealLibraryQuery.quickMinutes } ?? false
            case .notLately: recipe.lastPlannedOn.map { $0 < today.adding(days: -MealLibraryQuery.notLatelyDays) } ?? true
            case .favourites: (recipe.rating ?? 0) >= MealLibraryQuery.favouriteRating
            }
        }
    }

    static let quickMinutes = 30
    static let notLatelyDays = 21
    static let favouriteRating = 4

    var text = ""
    var sort = Sort.notLately
    var filters: Set<Filter> = []

    mutating func toggle(_ filter: Filter) {
        if filters.remove(filter) == nil { filters.insert(filter) }
    }

    /// Every word must be found in the title, the cuisine or an ingredient,
    /// whatever its case or accents, so "creme" finds "Crème fraîche".
    func results(_ recipes: [RecipeSummary], today: PlanDate) -> [RecipeSummary] {
        let words = Self.fold(text).split(whereSeparator: \.isWhitespace)
        return recipes
            .filter { recipe in
                let haystack = Self.fold(([recipe.title, recipe.cuisine ?? ""] + recipe.ingredientNames).joined(separator: "\n"))
                return words.allSatisfy { haystack.contains($0) } && filters.allSatisfy { $0.admits(recipe, today: today) }
            }
            .enumerated()
            .sorted { first, second in
                switch order(first.element, second.element) ?? byTitle(first.element, second.element) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: first.offset < second.offset
                }
            }
            .map(\.element)
    }

    /// The sort's own order, or nil where it cannot tell the two apart. A
    /// missing value goes last in every sort except Not had lately, where
    /// never planned is the point and comes first.
    private func order(_ a: RecipeSummary, _ b: RecipeSummary) -> ComparisonResult? {
        let result: ComparisonResult = switch sort {
        case .notLately: compare(a.lastPlannedOn, b.lastPlannedOn, missing: .orderedAscending)
        case .favourites: compare(b.rating, a.rating, missing: .orderedAscending)
        case .quickest: compare(a.totalMinutes, b.totalMinutes, missing: .orderedDescending)
        case .newest: compare(b.createdAt, a.createdAt, missing: .orderedAscending)
        case .aToZ: .orderedSame
        }
        return result == .orderedSame ? nil : result
    }

    /// `missing` is where a value that is nil goes when it is `a`'s.
    private func compare<Value: Comparable>(_ a: Value?, _ b: Value?, missing: ComparisonResult) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): .orderedSame
        case (nil, _): missing
        case (_, nil): missing == .orderedAscending ? .orderedDescending : .orderedAscending
        case (let a?, let b?): a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        }
    }

    private func byTitle(_ a: RecipeSummary, _ b: RecipeSummary) -> ComparisonResult {
        a.title.compare(b.title, options: [.caseInsensitive, .diacriticInsensitive])
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Lays this week's days over each recipe's `lastPlannedOn`, so a meal just
    /// put on Tuesday counts as had at once, before the server has heard of it.
    static func withWeekHistory(_ recipes: [RecipeSummary], days: [PlanDay]) -> [RecipeSummary] {
        var latest: [RecipeID: PlanDate] = [:]
        for day in days {
            guard let recipe = day.plan.meal else { continue }
            latest[recipe] = max(latest[recipe] ?? day.date, day.date)
        }
        guard !latest.isEmpty else { return recipes }
        return recipes.map { recipe in
            guard let week = latest[recipe.id], (recipe.lastPlannedOn ?? week) <= week else { return recipe }
            var recipe = recipe
            recipe.lastPlannedOn = week
            return recipe
        }
    }

    /// One line of context for a library row, in place of the ingredient count.
    static func contextLine(_ recipe: RecipeSummary, today: PlanDate) -> String {
        guard let last = recipe.lastPlannedOn else { return "Never planned" }
        let ago = last.days(to: today)
        switch ago {
        case ..<0: return "Planned for \(last.shortLabel)"
        case 0: return "Planned for today"
        case 1: return "Last had yesterday"
        case 2..<7: return "Last had \(ago) days ago"
        case 7..<14: return "Last had a week ago"
        case 14..<63: return "Last had \(ago / 7) weeks ago"
        case 63..<365: return "Last had \(ago / 30) months ago"
        default: return "Last had over a year ago"
        }
    }
}
