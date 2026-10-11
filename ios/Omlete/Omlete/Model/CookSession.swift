import Foundation

/// One cook of one recipe: where you are, how much you are making, what is timing.
///
/// Invariants, held by `private(set)` plus the mutators (there is no other way in):
/// - `.step(i)` always has `0 <= i < recipe.steps.count`.
/// - `.finished` is reachable only through the last step, so never for a recipe with no steps.
/// - `init(from:)` re-establishes both (a saved step past the end clamps), so a
///   stale file cannot produce an illegal session.
///
/// The session carries the recipe it is cooking from. That is what lets Cook
/// open with no signal, and what stops a refetch moving the step under your thumb.
nonisolated struct CookSession: Codable, Equatable, Sendable {
    enum Stage: Codable, Equatable, Sendable {
        case overview
        case step(Int)
        case finished
    }

    private(set) var recipe: Recipe
    private(set) var stage: Stage = .overview
    private(set) var servings: Servings
    private(set) var timers: [CookTimer] = []
    /// Last time the cook touched it; decides whether reopening resumes.
    private(set) var touchedAt: Date

    static let resumeWindow: TimeInterval = 8 * 3600

    init(recipe: Recipe, now: Date) {
        self.recipe = recipe
        servings = Servings(base: recipe.baseServings)
        touchedAt = now
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recipe = try container.decode(Recipe.self, forKey: .recipe)
        servings = try container.decode(Servings.self, forKey: .servings)
        timers = try container.decode([CookTimer].self, forKey: .timers)
        touchedAt = try container.decode(Date.self, forKey: .touchedAt)
        let lastStep = recipe.steps.count - 1
        stage = switch try container.decode(Stage.self, forKey: .stage) {
        case _ where lastStep < 0: .overview
        case .step(let index): .step(min(max(index, 0), lastStep))
        case let saved: saved
        }
    }

    var canStart: Bool { !recipe.steps.isEmpty }

    // Every move is total: one that does not apply is a no-op, so a double tap
    // or a replayed call cannot break the invariants.

    mutating func start(now: Date) {
        guard stage == .overview, canStart else { return }
        move(to: .step(0), now: now)
    }

    mutating func next(now: Date) {
        guard case .step(let index) = stage else { return }
        move(to: index + 1 < recipe.steps.count ? .step(index + 1) : .finished, now: now)
    }

    mutating func back(now: Date) {
        switch stage {
        case .overview: break
        case .step(let index): move(to: index > 0 ? .step(index - 1) : .overview, now: now)
        case .finished: move(to: .step(recipe.steps.count - 1), now: now)
        }
    }

    mutating func setServings(_ change: (inout Servings) -> Void, now: Date) {
        change(&servings)
        touchedAt = now
    }

    /// Only on a step. `id` is passed in so the function stays pure.
    mutating func startTimer(_ found: DetectedTimer, id: UUID, now: Date) {
        guard case .step(let index) = stage else { return }
        timers.append(CookTimer(
            id: id, label: found.label, stepIndex: index, endsAt: now.addingTimeInterval(TimeInterval(found.seconds))))
        touchedAt = now
    }

    mutating func dismissTimer(_ id: UUID) {
        timers.removeAll { $0.id == id }
    }

    /// Marks every timer that has ended and not yet rung, and returns them.
    /// Idempotent: a second call at the same `now` returns [].
    mutating func ringDue(at now: Date) -> [CookTimer] {
        let due = timers.indices.filter { !timers[$0].rung && timers[$0].isDone(at: now) }
        for index in due { timers[index].rung = true }
        return due.map { timers[$0] }
    }

    /// When the store next has to wake: the earliest `endsAt` not yet rung.
    var nextRing: Date? {
        timers.lazy.filter { !$0.rung }.map(\.endsAt).min()
    }

    /// A fresh server copy. The rating is always taken. Title, steps and
    /// ingredients are taken only on the overview with no timers running:
    /// mid-cook you finish the recipe you started.
    mutating func adopt(_ fresh: Recipe) {
        recipe.rating = fresh.rating
        guard stage == .overview, timers.isEmpty else { return }
        recipe = fresh
        if servings.base != fresh.baseServings { servings = Servings(base: fresh.baseServings) }
    }

    /// Safe mid-cook: the flag is about shopping lists and changes nothing being cooked.
    mutating func setOnList(_ index: Int, _ onList: Bool) {
        guard recipe.ingredients.indices.contains(index) else { return }
        recipe.ingredients[index].isOnList = onList
    }

    /// Called when Cook is opened. Resumes the step, servings and timers, unless
    /// the last cook was finished or went quiet more than `resumeWindow` ago;
    /// then it starts over from the overview and drops ended timers.
    mutating func reopen(at now: Date) {
        if stage == .finished || now.timeIntervalSince(touchedAt) > Self.resumeWindow {
            stage = .overview
            servings = Servings(base: recipe.baseServings)
            timers.removeAll { $0.isDone(at: now) }
        }
        touchedAt = now
    }

    private mutating func move(to stage: Stage, now: Date) {
        self.stage = stage
        touchedAt = now
    }
}

nonisolated extension CookSession {
    /// What the screen shows, derived in one place so the view holds no cooking logic.
    enum Page: Equatable {
        case overview(needs: [IngredientLine])
        case step(StepPage)
        case finished
    }

    struct IngredientLine: Equatable, Identifiable {
        /// Index in `recipe.ingredients`.
        let id: Int
        let name: String
        let note: String?
        let quantity: String
    }

    struct StepPage: Equatable {
        /// 1-based.
        let number: Int
        let count: Int
        let text: String
        let timers: [DetectedTimer]
        let ingredients: [IngredientLine]

        var isLast: Bool { number == count }
        var progress: Double { Double(number) / Double(count) }
    }

    var page: Page {
        switch stage {
        case .overview:
            .overview(needs: recipe.ingredients.indices.map(line))
        case .step(let index):
            .step(StepPage(
                number: index + 1, count: recipe.steps.count,
                text: scaleText(recipe.steps[index], by: servings.factor),
                timers: detectTimers(in: recipe.steps[index]),
                ingredients: ingredients(forStep: recipe.steps[index], in: recipe.ingredients).map(line)))
        case .finished:
            .finished
        }
    }

    private func line(_ index: Int) -> IngredientLine {
        let ingredient = recipe.ingredients[index]
        return IngredientLine(
            id: index, name: ingredient.name, note: ingredient.note,
            quantity: formatQuantity(scaleAmount(ingredient.amount, by: servings.factor), ingredient.unit))
    }
}
