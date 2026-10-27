import Foundation

nonisolated struct Recipe: Codable, Equatable, Sendable, Identifiable {
    struct Ingredient: Codable, Equatable, Sendable {
        var name: String
        var amount: Double?
        var unit: String?
        var note: String?
        /// The heading the source page put it under, such as "For the sauce".
        var group: String?
        var category: String?
        /// Off for something always in the cupboard: it stays out of shopping lists.
        var isOnList = true
    }

    /// A run of ingredients under one heading, in the order the source had them.
    struct IngredientGroup: Equatable, Identifiable {
        struct Line: Equatable, Identifiable {
            /// Index in `Recipe.ingredients`, which is how the server addresses an ingredient.
            let id: Int
            let ingredient: Ingredient
        }

        let heading: String?
        /// Never empty.
        let lines: [Line]

        var id: Int { lines[0].id }
    }

    let id: RecipeID
    var title: String
    var steps: [String]
    var ingredients: [Ingredient]
    /// nil when the recipe does not say how many it serves.
    var baseServings: Int?
    /// The server's rating. What the screen shows is `CookStore.rating`.
    var rating: Int?
    var imageURL: URL?
    var totalMinutes: Int?
    var source: RecipeSource?
    var createdAt: Date?

    var ingredientGroups: [IngredientGroup] {
        var groups: [IngredientGroup] = []
        for (index, ingredient) in ingredients.enumerated() {
            let line = IngredientGroup.Line(id: index, ingredient: ingredient)
            if let last = groups.last, last.heading == ingredient.group {
                groups[groups.count - 1] = IngredientGroup(heading: last.heading, lines: last.lines + [line])
            } else {
                groups.append(IngredientGroup(heading: ingredient.group, lines: [line]))
            }
        }
        return groups
    }

    var summary: RecipeSummary {
        RecipeSummary(
            id: id, title: title, imageURL: imageURL, totalMinutes: totalMinutes, rating: rating,
            sourceName: source?.name, ingredientCount: ingredients.count,
            ingredientNames: ingredients.map(\.name), createdAt: createdAt)
    }
}

nonisolated extension Recipe.Ingredient {
    /// Written by hand so a cook saved before `isOnList` existed still opens.
    /// In an extension, which keeps the memberwise initialiser.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        amount = try container.decodeIfPresent(Double.self, forKey: .amount)
        unit = try container.decodeIfPresent(String.self, forKey: .unit)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        isOnList = try container.decodeIfPresent(Bool.self, forKey: .isOnList) ?? true
    }
}

nonisolated func formatMinutes(_ minutes: Int) -> String {
    let (hours, rest) = (minutes / 60, minutes % 60)
    if hours == 0 { return "\(minutes) min" }
    return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
}

/// The servings control. With a known yield it counts servings; without one it
/// is a multiplier, so the view never branches on "has a yield".
nonisolated struct Servings: Codable, Equatable, Sendable {
    /// Servings when `base` is known, else a multiplier. Never below `step`.
    private(set) var value: Double
    let base: Int?

    init(base: Int?) {
        self.base = base
        value = Double(base ?? 1)
    }

    var step: Double { base == nil ? 0.5 : 1 }
    var factor: Double { base.map { value / Double($0) } ?? value }
    var label: String { base == nil ? "×\(formatAmount(value))" : formatAmount(value) }
    var title: String { base == nil ? "Amount" : "Servings" }
    var canDecrease: Bool { value > step }

    mutating func more() {
        value += step
    }

    mutating func fewer() {
        value = max(step, value - step)
    }
}

/// A cooking time found in a step's text.
nonisolated struct DetectedTimer: Equatable, Sendable, Identifiable {
    /// The words as written.
    let label: String
    let seconds: Int
    /// Position among the step's matches, so two "5 mins" in one step stay distinct.
    let id: Int
}

/// A started timer. An end date, not a countdown: it survives the app being
/// suspended or killed, and needs nothing to keep it correct.
nonisolated struct CookTimer: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let label: String
    let stepIndex: Int
    let endsAt: Date
    /// The chime for this timer has played. Saved, so a relaunch does not ring twice.
    var rung = false

    func isDone(at now: Date) -> Bool { endsAt <= now }

    func chipText(at now: Date) -> String {
        isDone(at: now) ? "Step \(stepIndex + 1): done" : formatClock(Int(endsAt.timeIntervalSince(now).rounded(.up)))
    }
}
