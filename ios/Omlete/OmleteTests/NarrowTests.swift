import Foundation
import Testing
@testable import Omlete

/// The runs in `docs/fixtures/narrow-cases.json`, which the web's
/// `narrow.test.ts` plays too: both must end every run the same way.
struct NarrowFixture: Decodable, Sendable {
    struct Meal: Decodable, Sendable {
        let id: String
        let tags: String?
        let minutes: Int?
        let score: Double
        let clash: Bool
    }

    struct Run: Decodable, Sendable, CustomTestStringConvertible {
        struct Expect: Decodable, Sendable {
            let question: String?
            let labels: [String]?
            let finalists: [String]?
            let preset: Bool?
        }

        let name: String
        let quick: Bool
        let only: [String]?
        let `do`: [String]
        let expect: Expect

        var testDescription: String { name }
    }

    let library: [Meal]
    let runs: [Run]

    static let shared: NarrowFixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "../../../docs/fixtures/narrow-cases.json")
        return try! JSONDecoder().decode(NarrowFixture.self, from: Data(contentsOf: url))
    }()

    /// In the order the fixture says a ranked library has: clean first, then by score, then id.
    static func ranked(_ meals: [Meal]) -> [FitScore.Ranked] {
        meals
            .sorted { a, b in
                if a.clash != b.clash { return !a.clash }
                if a.score != b.score { return a.score > b.score }
                return a.id < b.id
            }
            .map { meal in
                FitScore.Ranked(
                    recipe: RecipeSummary(
                        id: RecipeID(meal.id), title: meal.id, totalMinutes: meal.minutes, tags: FitScoreCase.tags(meal.tags)),
                    fit: FitScore.Fit(score: meal.score, reason: nil, clash: meal.clash))
            }
    }
}

struct NarrowTests {
    private func play(_ run: NarrowFixture.Run, _ ranked: [FitScore.Ranked]) throws -> Narrow.State {
        var state = Narrow.start(ranked, quickNight: run.quick)
        for step in run.do {
            let view = Narrow.next(state, ranked)
            if step == "back" {
                state = Narrow.back(state)
            } else {
                guard case .question(let question, let answers, _, _) = view else {
                    Issue.record("no question for \(step)")
                    return state
                }
                if step == "skip" {
                    state = Narrow.dontMind(state, question)
                } else if step == "biggest" {
                    state = Narrow.answer(state, question, answers[0].values)
                } else {
                    state = Narrow.answer(state, question, [String(step.dropFirst("answer:".count))])
                }
            }
            state = Narrow.settle(state, ranked)
        }
        return state
    }

    @Test(arguments: NarrowFixture.shared.runs)
    func sharedRun(_ run: NarrowFixture.Run) throws {
        let fixture = NarrowFixture.shared
        let meals = run.only.map { only in fixture.library.filter { only.contains($0.id) } } ?? fixture.library
        let ranked = NarrowFixture.ranked(meals)
        let state = try play(run, ranked)
        let view = Narrow.next(state, ranked)
        if let expected = run.expect.question {
            guard case .question(let question, let answers, _, _) = view else {
                Issue.record("expected a question, got finalists")
                return
            }
            #expect(question.rawValue == expected)
            #expect(answers.map(\.label) == run.expect.labels)
        }
        if let expected = run.expect.finalists {
            guard case .finalists(let finalists) = view else {
                Issue.record("expected finalists, got a question")
                return
            }
            #expect(finalists.map(\.recipe.id.rawValue) == expected)
        }
        if let preset = run.expect.preset {
            #expect(state.steps.contains(where: \.preset) == preset)
        }
    }

    @Test func theFixtureHasEveryRun() {
        #expect(NarrowFixture.shared.runs.count == 10)
    }

    private let ranked = NarrowFixture.ranked(NarrowFixture.shared.library)

    @Test func neverAsksMoreThanFourQuestionsWhateverIsAnswered() {
        guard case .question(let question, let answers, _, _) = Narrow.next(Narrow.start(ranked, quickNight: false), ranked) else {
            Issue.record("expected a question")
            return
        }
        for first in answers {
            var state = Narrow.answer(Narrow.start(ranked, quickNight: false), question, first.values)
            var asked = 1
            while case .question(let next, let answers, _, _) = Narrow.next(state, ranked) {
                asked += 1
                state = Narrow.answer(state, next, answers[0].values)
            }
            #expect(asked <= 4)
        }
        guard case .question = Narrow.next(Narrow.start(ranked, quickNight: true), ranked) else {
            Issue.record("a quick night should still ask")
            return
        }
    }

    @Test func answersAreSizedByAShareThatAddsUpToTheWhole() {
        guard case .question(_, let answers, let peek, let left) = Narrow.next(Narrow.start(ranked, quickNight: false), ranked) else {
            Issue.record("expected a question")
            return
        }
        #expect(abs(answers.reduce(0) { $0 + $1.share } - 1) < 0.001)
        #expect(answers.count <= 4)
        #expect(left == ranked.count)
        #expect(peek.map(\.recipe.id) == ranked.prefix(3).map(\.recipe.id))
    }

    @Test func aClashIsASliverNeverTheBiggestAnswer() {
        let state = Narrow.State(steps: [Narrow.Step(question: .main, values: ["veggie"])])
        guard case .question(_, let answers, _, _) = Narrow.next(state, ranked) else {
            Issue.record("expected a question")
            return
        }
        let pasta = answers.first { $0.label == "Pasta" }
        #expect((pasta?.share ?? 1) < 0.1)
    }

    @Test func aQuickNightsAnswerIsLabelledQuickNight() {
        let state = Narrow.start(ranked, quickNight: true)
        #expect(Narrow.answeredLabels(state).map(\.label) == ["Quick night"])
    }
}
