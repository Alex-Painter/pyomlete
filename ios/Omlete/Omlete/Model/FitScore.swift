import Foundation

/// How well a meal fits one evening of the week, with the reason in a few words.
///
/// A port of the web's `client/src/lib/fitScore.ts`, rule for rule: a plain sum
/// of signals, so every suggestion can say why it is there. Variety rules (the
/// same recipe, base, main or cuisine too close together, or a long cook on a
/// quick night) are clashes: a clashing meal is never hidden, it sinks below
/// every clean one and says why. Boosts (rated well and not had lately, uses
/// what is on the list) order the rest.
///
/// Pure, so it runs offline and within a frame. `docs/fixtures/fit-score-cases.json`
/// pins the order for the web and for this port, and `docs/DESIGN.md` explains the rules.
nonisolated enum FitScore {
    /// Every weight in one place. Penalties are positive numbers taken off.
    enum Weight {
        static let sameRecipe = 60.0
        static let sameBase = 40.0
        static let quickNight = 35.0
        static let sameMain = 30.0
        static let sameCuisine = 25.0
        /// Per star above or below 3.
        static let ratingStar = 5.0
        /// Per week since last planned, up to `recencyWeeksCap`.
        static let recencyWeek = 1.5
        static let recencyWeeksCap = 8.0
        /// A meal never planned: unknown, so a little less than a long gap.
        static let neverPlanned = 4.0
        /// Per perishable ingredient already on the list, up to `sharedCap`.
        static let sharedIngredient = 6.0
        static let sharedCap = 18.0
        static let quickFit = 5.0
    }

    /// Same cuisine family within this many days is a clash.
    static let cuisineDays = 2
    /// Same recipe within this many days is a clash.
    static let repeatDays = 14
    /// Rated at least this and not had for this many days earns its own reason.
    static let wellRated = 4
    static let longGapDays = 21

    /// Things that go off. Pantry staples are on every list, so they say nothing.
    static let perishable: Set<String> = ["Fresh Produce", "Meat & Fish", "Dairy & Eggs", "Bakery"]

    static let cuisineLabels: [String: String] = [
        "british": "British", "french": "French", "italian": "Italian", "spanish": "Spanish",
        "greek": "Greek", "middle_eastern": "Middle Eastern", "north_african": "North African",
        "indian": "Indian", "chinese": "Chinese", "japanese": "Japanese", "korean": "Korean",
        "south_east_asian": "South-east Asian", "mexican": "Mexican", "latin_american": "Latin American",
        "american": "American", "other": "Other",
    ]

    struct Fit: Equatable, Sendable {
        var score: Double
        /// The strongest clash, else the strongest reason to pick it; nil when nothing stands out.
        var reason: String?
        var clash: Bool
    }

    /// A meal planned near the evening being ranked, from this week or from history.
    struct Neighbour: Sendable {
        let date: PlanDate
        let recipe: RecipeSummary
        let inWeek: Bool
        /// Whole days from the evening being ranked, either way.
        let gap: Int
    }

    /// Everything about one evening that does not depend on the meal, built once per day.
    struct Context: Sendable {
        let day: PlanDay
        /// Nearby meals by recipe, base, main and cuisine, each already inside its rule's window.
        var sameRecipe: [RecipeID: [Neighbour]] = [:]
        var sameBase: [String: [Neighbour]] = [:]
        var sameMain: [String: [Neighbour]] = [:]
        var sameCuisine: [String: [Neighbour]] = [:]
        /// Perishable ingredients already on the list, by folded name, with the meals they came from.
        var onList: [String: (name: String, recipes: Set<RecipeID>)] = [:]

        /// - Parameters:
        ///   - days: the week's days; empty for a plain list.
        ///   - recipes: the whole library, with `lastPlannedOn` already covering this week.
        init(day: PlanDay, days: [PlanDay], recipes: [RecipeSummary], items: [ListItem], varietyDays: Int) {
            self.day = day
            let byID = Dictionary(recipes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let week = Set(days.map(\.date))
            var near: [Neighbour] = []
            for other in days where other.date != day.date {
                guard let id = other.plan.meal, let recipe = byID[id] else { continue }
                near.append(Neighbour(date: other.date, recipe: recipe, inWeek: true, gap: abs(other.date.days(to: day.date))))
            }
            // Earlier weeks reach across the shop day: pasta last Friday counts on Saturday.
            // Inside this week, the week's own days are the truth.
            let reach = max(varietyDays, FitScore.repeatDays)
            let from = day.date.adding(days: -reach)
            let to = day.date.adding(days: reach)
            for recipe in recipes {
                guard let last = recipe.lastPlannedOn, last >= from, last <= to, !week.contains(last) else { continue }
                let gap = abs(last.days(to: day.date))
                if gap >= 1 { near.append(Neighbour(date: last, recipe: recipe, inWeek: false, gap: gap)) }
            }

            for neighbour in near {
                if neighbour.gap <= FitScore.repeatDays { sameRecipe[neighbour.recipe.id, default: []].append(neighbour) }
                guard let tags = neighbour.recipe.tags else { continue }
                if tags.base != "none", neighbour.gap <= varietyDays { sameBase[tags.base, default: []].append(neighbour) }
                if tags.main != "veggie", neighbour.gap == 1 { sameMain[tags.main, default: []].append(neighbour) }
                if tags.cuisine != "other", neighbour.gap <= FitScore.cuisineDays {
                    sameCuisine[tags.cuisine, default: []].append(neighbour)
                }
            }

            for item in items where FitScore.perishable.contains(item.category) {
                let key = FitScore.fold(item.name)
                var entry = onList[key] ?? (name: item.name, recipes: [])
                for source in item.sources {
                    if let recipe = source.recipeID { entry.recipes.insert(recipe) }
                }
                onList[key] = entry
            }
        }
    }

    private struct Signal {
        let weight: Double
        let reason: String
    }

    static func fold(_ text: String) -> String {
        text.folding(options: .diacriticInsensitive, locale: nil).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capitalised(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The closest nearby meal other than this one, for a rule's reason.
    private static func closestOther(_ found: [Neighbour]?, _ id: RecipeID) -> Neighbour? {
        var best: Neighbour?
        for neighbour in found ?? [] where neighbour.recipe.id != id {
            if best == nil || neighbour.gap < best!.gap { best = neighbour }
        }
        return best
    }

    private static func clashes(_ recipe: RecipeSummary, _ context: Context) -> [Signal] {
        var out: [Signal] = []
        if let repeats = context.sameRecipe[recipe.id], var repeated = repeats.first {
            for neighbour in repeats.dropFirst() where neighbour.gap < repeated.gap { repeated = neighbour }
            let reason = repeated.inWeek ? "On \(repeated.date.dayLong) already" : "Had on \(repeated.date.shortLabel)"
            out.append(Signal(weight: Weight.sameRecipe, reason: reason))
        }
        if let tags = recipe.tags {
            if tags.base != "none", let base = closestOther(context.sameBase[tags.base], recipe.id) {
                out.append(Signal(weight: Weight.sameBase, reason: "\(capitalised(tags.base)) on \(base.date.dayLong)"))
            }
            if let main = closestOther(context.sameMain[tags.main], recipe.id) {
                out.append(Signal(weight: Weight.sameMain, reason: "\(capitalised(tags.main)) on \(main.date.dayLong)"))
            }
            if let cuisine = closestOther(context.sameCuisine[tags.cuisine], recipe.id) {
                let label = cuisineLabels[tags.cuisine] ?? capitalised(tags.cuisine)
                out.append(Signal(weight: Weight.sameCuisine, reason: "\(label) on \(cuisine.date.dayLong)"))
            }
        }
        if context.day.quick, let minutes = recipe.totalMinutes, minutes > MealLibraryQuery.quickMinutes {
            out.append(Signal(weight: Weight.quickNight, reason: "\(minutes) min on a quick night"))
        }
        return out
    }

    private static func listNames(_ names: [String]) -> String {
        switch names.count {
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: "\(names[0]), \(names[1]) and more"
        }
    }

    /// The perishable ingredients this meal shares with what other meals put on the list.
    static func sharedWithList(_ recipe: RecipeSummary, _ context: Context) -> [String] {
        var shared: [String] = []
        var seen: Set<String> = []
        for key in recipe.ingredientNames.map(fold) {
            guard let entry = context.onList[key], !seen.contains(key) else { continue }
            // An item only this meal put on the list isn't shared.
            if !entry.recipes.isEmpty, entry.recipes.allSatisfy({ $0 == recipe.id }) { continue }
            seen.insert(key)
            shared.append(entry.name.lowercased())
        }
        return shared
    }

    private static func boosts(_ recipe: RecipeSummary, _ context: Context) -> [Signal] {
        var out: [Signal] = []
        let rating = recipe.rating.map { Double($0 - 3) * Weight.ratingStar } ?? 0
        let last = recipe.lastPlannedOn
        let gap = last.map { $0.days(to: context.day.date) }
        let recency: Double = switch gap {
        case nil: Weight.neverPlanned
        case let gap? where gap > 0: min(Double(gap) / 7, Weight.recencyWeeksCap) * Weight.recencyWeek
        default: 0
        }
        let wellRatedGap = (recipe.rating ?? 0) >= wellRated && (gap.map { $0 >= longGapDays } ?? true)
        let reason: String = if !wellRatedGap {
            ""
        } else if let last {
            "Not had since \(last.monthLong), rated \(recipe.rating!)"
        } else {
            "Rated \(recipe.rating!), not planned yet"
        }
        out.append(Signal(weight: rating + recency, reason: reason))

        let shared = sharedWithList(recipe, context)
        if !shared.isEmpty {
            out.append(Signal(
                weight: min(Double(shared.count) * Weight.sharedIngredient, Weight.sharedCap),
                reason: "Uses the \(listNames(shared)) already on the list"))
        }

        if context.day.quick, let minutes = recipe.totalMinutes, minutes <= MealLibraryQuery.quickMinutes {
            out.append(Signal(weight: Weight.quickFit, reason: "\(minutes) min, quick enough"))
        }
        return out
    }

    static func fit(_ recipe: RecipeSummary, _ context: Context) -> Fit {
        let bad = clashes(recipe, context)
        let good = boosts(recipe, context)
        let score = good.reduce(0) { $0 + $1.weight } - bad.reduce(0) { $0 + $1.weight }
        if var worst = bad.first {
            for signal in bad.dropFirst() where signal.weight > worst.weight { worst = signal }
            return Fit(score: score, reason: worst.reason, clash: true)
        }
        var best: Signal?
        for signal in good where !signal.reason.isEmpty {
            if best == nil || signal.weight > best!.weight { best = signal }
        }
        return Fit(score: score, reason: best?.reason, clash: false)
    }

    struct Ranked: Sendable {
        let recipe: RecipeSummary
        let fit: Fit
    }

    /// The library in order for this evening: clean meals first, then clashes, each by score.
    static func rank(_ recipes: [RecipeSummary], for context: Context) -> [Ranked] {
        recipes
            .enumerated()
            .map { (offset: $0.offset, ranked: Ranked(recipe: $0.element, fit: fit($0.element, context))) }
            .sorted { a, b in
                if a.ranked.fit.clash != b.ranked.fit.clash { return !a.ranked.fit.clash }
                if a.ranked.fit.score != b.ranked.fit.score { return a.ranked.fit.score > b.ranked.fit.score }
                switch a.ranked.recipe.title.compare(b.ranked.recipe.title, options: [.caseInsensitive, .diacriticInsensitive]) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return a.offset < b.offset
                }
            }
            .map(\.ranked)
    }
}
