import Foundation

/// Narrow it down: a few one-tap questions that end on three finalists.
///
/// A port of the web's `client/src/lib/narrow.ts`. For the evenings when
/// nothing in the top three appeals and you don't know what you want. Each
/// question is the one that best splits the meals still in play, so it rarely
/// takes more than two or three taps, and each answer is sized by how many
/// good meals sit behind it, so the likely answer is the big one. A pure state
/// machine over the evening's ranked library: the screen keeps the state,
/// `next` says what to show. `docs/fixtures/narrow-cases.json` pins the rules
/// for the web and this port.
nonisolated enum Narrow {
    enum Question: String, CaseIterable, Sendable {
        case time, mood, base, main

        var prompt: String {
            switch self {
            case .time: "How much time?"
            case .mood: "What sort of mood?"
            case .base: "What in the middle?"
            case .main: "What's the main?"
            }
        }
    }

    private static let labels: [String: String] = [
        "time:quick": "Quick", "time:normal": "Up to an hour", "time:slow": "Happy to take it slow",
        "mood:comforting": "Comforting", "mood:fresh": "Light and fresh", "mood:different": "Something different",
        "base:rice": "Rice", "base:pasta": "Pasta", "base:potatoes": "Potatoes", "base:bread": "Bread",
        "base:noodles": "Noodles", "base:none": "None of those",
        "main:chicken": "Chicken", "main:beef": "Beef", "main:pork": "Pork", "main:lamb": "Lamb",
        "main:fish": "Fish", "main:veggie": "Veggie", "main:beans": "Beans and lentils",
    ]

    /// At most this many answers on screen; the smallest fold into Something else.
    static let maxAnswers = 4
    /// Stop once this many good meals or fewer are left.
    static let finalistCount = 3
    /// A clashing meal still counts, a little, so its group never vanishes.
    static let clashWeight = 0.15

    /// One step taken: an answer (one value, or several for Something else), or Don't mind (nil).
    struct Step: Equatable, Sendable {
        let question: Question
        let values: [String]?
        var preset = false
    }

    struct State: Equatable, Sendable {
        var steps: [Step] = []
    }

    struct Answer: Equatable, Sendable {
        let values: [String]
        let label: String
        /// Meals behind this answer.
        let count: Int
        /// This answer's share of the good meals' weight, 0 to 1, for its size.
        let share: Double
    }

    enum View: Sendable {
        /// `peek` is the best meals still in play, and `left` how many there are.
        case question(Question, answers: [Answer], peek: [FitScore.Ranked], left: Int)
        case finalists([FitScore.Ranked])
    }

    static func label(_ question: Question, _ value: String) -> String {
        labels["\(question.rawValue):\(value)"] ?? value
    }

    private static func minutesGroup(_ minutes: Int?) -> String? {
        guard let minutes else { return nil }
        if minutes <= MealLibraryQuery.quickMinutes { return "quick" }
        return minutes <= 60 ? "normal" : "slow"
    }

    /// The meal's answer to a question, or nil when it can't say (no tags, no time).
    static func value(of ranked: FitScore.Ranked, _ question: Question) -> String? {
        switch question {
        case .time: minutesGroup(ranked.recipe.totalMinutes)
        case .mood: ranked.recipe.tags?.mood
        case .base: ranked.recipe.tags?.base
        case .main: ranked.recipe.tags?.main
        }
    }

    private static func weight(_ ranked: FitScore.Ranked) -> Double {
        ranked.fit.clash ? clashWeight : 1 + max(0, ranked.fit.score) / 20
    }

    /// A meal that can't answer a question (no tags, no time) leaves the run once it's answered.
    private static func passes(_ ranked: FitScore.Ranked, _ steps: [Step]) -> Bool {
        steps.allSatisfy { step in
            guard let values = step.values else { return true }
            guard let value = value(of: ranked, step.question) else { return false }
            return values.contains(value)
        }
    }

    private static func pool(_ ranked: [FitScore.Ranked], _ steps: [Step]) -> [FitScore.Ranked] {
        ranked.filter { passes($0, steps) }
    }

    /// The answers a question would offer over these meals, biggest first.
    static func answers(for meals: [FitScore.Ranked], _ question: Question) -> [Answer] {
        var groups: [String: (count: Int, weight: Double)] = [:]
        var total = 0.0
        for meal in meals {
            guard let value = value(of: meal, question) else { continue }
            groups[value, default: (0, 0)].count += 1
            groups[value, default: (0, 0)].weight += weight(meal)
            total += weight(meal)
        }
        let sorted = groups.sorted { a, b in
            a.value.weight != b.value.weight ? a.value.weight > b.value.weight : a.key < b.key
        }
        let kept = sorted.count > maxAnswers ? Array(sorted.prefix(maxAnswers - 1)) : sorted
        var answers = kept.map { value, group in
            Answer(values: [value], label: label(question, value), count: group.count, share: total > 0 ? group.weight / total : 0)
        }
        if sorted.count > maxAnswers {
            let rest = sorted.dropFirst(maxAnswers - 1)
            let restWeight = rest.reduce(0) { $0 + $1.value.weight }
            answers.append(Answer(
                values: rest.map(\.key), label: "Something else", count: rest.reduce(0) { $0 + $1.value.count },
                share: total > 0 ? restWeight / total : 0))
        }
        return answers
    }

    /// How evenly a question splits the meals, by weight: the higher, the more one tap tells us.
    private static func entropy(_ answers: [Answer]) -> Double {
        answers.reduce(0) { h, answer in answer.share > 0 ? h - answer.share * log2(answer.share) : h }
    }

    /// Three finalists, meals with no clash first, in ranked order.
    private static func finalists(_ meals: [FitScore.Ranked]) -> [FitScore.Ranked] {
        Array((meals.filter { !$0.fit.clash } + meals.filter(\.fit.clash)).prefix(finalistCount))
    }

    /// Where a run starts. On a quick night the time question is already
    /// answered and shown as a chip, unless no quick meal exists.
    static func start(_ ranked: [FitScore.Ranked], quickNight: Bool) -> State {
        if quickNight, ranked.contains(where: { value(of: $0, .time) == "quick" }) {
            return State(steps: [Step(question: .time, values: ["quick"], preset: true)])
        }
        return State()
    }

    /// The state with any answer that leaves no meal taken back, latest first, so a run never shows nothing.
    static func settle(_ state: State, _ ranked: [FitScore.Ranked]) -> State {
        var steps = state.steps
        while !steps.isEmpty, pool(ranked, steps).isEmpty { steps.removeLast() }
        return State(steps: steps)
    }

    static func next(_ state: State, _ ranked: [FitScore.Ranked]) -> View {
        let steps = settle(state, ranked).steps
        let meals = pool(ranked, steps)
        let good = meals.filter { !$0.fit.clash }.count
        let asked = Set(steps.map(\.question))
        if good > finalistCount {
            var best: (question: Question, answers: [Answer], h: Double)?
            for question in Question.allCases where !asked.contains(question) {
                let answers = answers(for: meals, question)
                guard answers.count >= 2 else { continue }
                let h = entropy(answers)
                if best == nil || h > best!.h { best = (question, answers, h) }
            }
            if let best {
                return .question(best.question, answers: best.answers, peek: finalists(meals), left: meals.count)
            }
        }
        return .finalists(finalists(meals))
    }

    static func answer(_ state: State, _ question: Question, _ values: [String]) -> State {
        State(steps: state.steps + [Step(question: question, values: values)])
    }

    static func dontMind(_ state: State, _ question: Question) -> State {
        State(steps: state.steps + [Step(question: question, values: nil)])
    }

    static func back(_ state: State) -> State {
        State(steps: Array(state.steps.dropLast()))
    }

    /// Labels for the answers so far, for the chips above the question. A
    /// quick night's own answer reads Quick night.
    static func answeredLabels(_ state: State) -> [(step: Step, label: String)] {
        state.steps.compactMap { step in
            guard let values = step.values else { return nil }
            if step.preset { return (step, "Quick night") }
            return (step, values.count == 1 ? label(step.question, values[0]) : "Something else")
        }
    }
}
