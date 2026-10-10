import Foundation

nonisolated struct Recipe: Codable, Equatable, Sendable, Identifiable {
    struct Ingredient: Codable, Equatable, Sendable {
        var name: String
        var amount: Double?
        var unit: String?
        var note: String?
    }

    let id: RecipeID
    var title: String
    var steps: [String]
    var ingredients: [Ingredient]
    /// nil when the recipe does not say how many it serves.
    var baseServings: Int?
    /// The server's rating. What the screen shows is `CookStore.rating`.
    var rating: Int?
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
