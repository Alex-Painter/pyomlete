import Foundation

/// What ranking a week's library brings: the order for the evening, and what shares the list.
nonisolated struct DayRanking: Sendable {
    let ranked: [FitScore.Ranked]
    let context: FitScore.Context
    let rank: [RecipeID: Int]
    let usesList: Set<RecipeID>

    init(library: [RecipeSummary], day: PlanDay, days: [PlanDay], items: [ListItem], varietyDays: Int) {
        let context = FitScore.Context(day: day, days: days, recipes: library, items: items, varietyDays: varietyDays)
        let ranked = FitScore.rank(library, for: context)
        self.context = context
        self.ranked = ranked
        rank = Dictionary(ranked.enumerated().map { ($0.element.recipe.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        usesList = Set(library.filter { !FitScore.sharedWithList($0, context).isEmpty }.map(\.id))
    }

    func fit(_ id: RecipeID) -> FitScore.Fit? {
        rank[id].map { ranked[$0].fit }
    }
}

/// Search, filters and sort for the meal library on Plan, as one value so the
/// rules are tested without a screen. A plain list's default sort puts the
/// meals you haven't had for longest first; a week's is Best for this day,
/// the fit score's order for the evening.
nonisolated struct MealLibraryQuery: Equatable, Sendable {
    enum Sort: String, CaseIterable, Sendable {
        /// Needs an evening to rank for, so only a week's library offers it.
        case best
        case notLately, favourites, quickest, newest, aToZ

        var title: String {
            switch self {
            case .best: "Best for this day"
            case .notLately: "Not had lately"
            case .favourites: "Your favourites"
            case .quickest: "Quickest"
            case .newest: "Newest"
            case .aToZ: "A to Z"
            }
        }
    }

    /// A chip for each base, main and cuisine, in that order.
    enum TagGroup: String, CaseIterable, Sendable {
        case base, main, cuisine

        func value(of tags: RecipeTags) -> String {
            switch self {
            case .base: tags.base
            case .main: tags.main
            case .cuisine: tags.cuisine
            }
        }
    }

    enum Filter: Hashable, Sendable {
        case quick, notLately, favourites
        /// Shown on a week, where there is a list to share ingredients with.
        case usesList
        case tag(TagGroup, String)

        static let fixed: [Filter] = [.quick, .notLately, .favourites]

        /// For the chip's accessibility identifier.
        var id: String {
            switch self {
            case .quick: "quick"
            case .notLately: "notLately"
            case .favourites: "favourites"
            case .usesList: "usesList"
            case .tag(let group, let value): "\(group.rawValue).\(value)"
            }
        }

        var title: String {
            switch self {
            case .quick: "Quick"
            case .notLately: "Not had lately"
            case .favourites: "Favourites"
            case .usesList: "Uses the list"
            case .tag(_, let value): Self.tagLabels[value] ?? value.prefix(1).uppercased() + value.dropFirst()
            }
        }

        private static let tagLabels = [
            "south_east_asian": "South-east Asian", "middle_eastern": "Middle Eastern",
            "north_african": "North African", "latin_american": "Latin American",
            "veggie": "Veggie", "beans": "Beans and lentils",
        ]

        /// Tag chips are judged a group at a time, in `results`.
        func admits(_ recipe: RecipeSummary, today: PlanDate, day: DayRanking?) -> Bool {
            switch self {
            case .quick: recipe.totalMinutes.map { $0 <= MealLibraryQuery.quickMinutes } ?? false
            case .notLately: recipe.lastPlannedOn.map { $0 < today.adding(days: -MealLibraryQuery.notLatelyDays) } ?? true
            case .favourites: (recipe.rating ?? 0) >= MealLibraryQuery.favouriteRating
            case .usesList: day.map { $0.usesList.contains(recipe.id) } ?? true
            case .tag: true
            }
        }

        /// A chip for each base, main and cuisine the library actually has, so
        /// a library of curries never offers Pasta. Bases, then mains, then cuisines.
        static func tags(in recipes: [RecipeSummary]) -> [Filter] {
            TagGroup.allCases.flatMap { group in
                Set(recipes.compactMap { $0.tags.map(group.value) })
                    .subtracting(["none", "other"])
                    .sorted()
                    .map { Filter.tag(group, $0) }
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
    /// whatever its case or accents, so "creme" finds "Crème fraîche". Tag
    /// chips in one group widen (pasta or rice), and groups narrow (pasta and fish).
    func results(_ recipes: [RecipeSummary], today: PlanDate, day: DayRanking? = nil) -> [RecipeSummary] {
        let words = Self.fold(text).split(whereSeparator: \.isWhitespace)
        var wanted: [TagGroup: Set<String>] = [:]
        for case .tag(let group, let value) in filters { wanted[group, default: []].insert(value) }
        return recipes
            .filter { recipe in
                let haystack = Self.fold(([recipe.title, recipe.cuisine ?? ""] + recipe.ingredientNames).joined(separator: "\n"))
                return words.allSatisfy { haystack.contains($0) }
                    && filters.allSatisfy { $0.admits(recipe, today: today, day: day) }
                    && wanted.allSatisfy { group, values in recipe.tags.map { values.contains(group.value(of: $0)) } ?? false }
            }
            .enumerated()
            .sorted { first, second in
                switch order(first.element, second.element, day: day) ?? byTitle(first.element, second.element) {
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
    private func order(_ a: RecipeSummary, _ b: RecipeSummary, day: DayRanking?) -> ComparisonResult? {
        let result: ComparisonResult = switch sort {
        case .best: day.map { compare($0.rank[a.id] ?? .max, $0.rank[b.id] ?? .max, missing: .orderedDescending) } ?? .orderedSame
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
