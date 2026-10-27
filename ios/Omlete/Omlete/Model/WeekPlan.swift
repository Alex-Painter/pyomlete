import Foundation

/// A week of dinners Chef proposes: five, on different evenings, each with a
/// line of why. Nothing changes until Make the list. Only a plan still
/// waiting for that tap reaches the app.
nonisolated struct WeekPlan: Identifiable, Equatable, Sendable {
    let id: WeekPlanID
    let weekOf: PlanDate
    let note: String
    /// In day order.
    let meals: [WeekMeal]
}

nonisolated struct WeekMeal: Identifiable, Equatable, Sendable {
    let day: PlanDate
    let title: String
    let reason: String
    /// One of their recipes, or nil for a new idea, which becomes a recipe
    /// once the list is made and lands on its evening when it has.
    let recipe: RecipeID?
    let imageURL: URL?

    var id: PlanDate { day }
    var isNew: Bool { recipe == nil }
}

/// The list Make the list filled or made, and the change to undo.
nonisolated struct MadeWeek: Equatable, Sendable {
    let list: ListID
    let name: String
    let undo: ChefActionID
}
