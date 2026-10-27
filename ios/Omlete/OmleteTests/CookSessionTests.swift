import Foundation
import Testing
@testable import Omlete

struct CookSessionTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func session(steps: Int, servings: Int? = 4) -> CookSession {
        CookSession(recipe: .fixture(steps: steps, servings: servings), now: t0)
    }

    private func roundTrip(_ session: CookSession, editing edit: (inout [String: Any]) -> Void = { _ in }) throws -> CookSession {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        edit(&json)
        return try JSONDecoder().decode(CookSession.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func aRecipeWithNoStepsStaysOnTheOverview() {
        var cook = session(steps: 0)

        cook.start(now: t0)
        cook.next(now: t0, mealKey: UUID())

        #expect(!cook.canStart)
        #expect(cook.stage == .overview)
    }

    @Test func nextOnTheLastStepFinishesAndBackReturnsToIt() {
        var cook = session(steps: 2)

        cook.start(now: t0)
        #expect(cook.stage == .step(0))
        cook.next(now: t0, mealKey: UUID())
        cook.next(now: t0, mealKey: UUID())
        #expect(cook.stage == .finished)
        cook.next(now: t0, mealKey: UUID())
        #expect(cook.stage == .finished)

        cook.back(now: t0)
        #expect(cook.stage == .step(1))
        cook.back(now: t0)
        cook.back(now: t0)
        #expect(cook.stage == .overview)
    }

    @Test func aSavedStepPastTheEndClampsOnDecode() throws {
        var cook = session(steps: 4)
        cook.start(now: t0)
        for _ in 0..<3 { cook.next(now: t0, mealKey: UUID()) }
        #expect(cook.stage == .step(3))

        let shorter = try roundTrip(cook) { json in
            var recipe = json["recipe"] as! [String: Any]
            recipe["steps"] = ["Chop.", "Fry."]
            json["recipe"] = recipe
        }

        #expect(shorter.stage == .step(1))
    }

    @Test func aSavedFinishWithNoStepsDecodesToTheOverview() throws {
        var cook = session(steps: 1)
        cook.start(now: t0)
        cook.next(now: t0, mealKey: UUID())
        #expect(cook.stage == .finished)

        let emptied = try roundTrip(cook) { json in
            var recipe = json["recipe"] as! [String: Any]
            recipe["steps"] = [String]()
            json["recipe"] = recipe
        }

        #expect(emptied.stage == .overview)
    }

    @Test func adoptMidCookTakesOnlyTheRating() {
        var cook = session(steps: 3)
        cook.start(now: t0)
        cook.next(now: t0, mealKey: UUID())
        var fresh = Recipe.fixture(steps: 1, servings: 2)
        fresh.title = "Renamed"
        fresh.rating = 5

        cook.adopt(fresh)

        #expect(cook.recipe.rating == 5)
        #expect(cook.recipe.title == "Curry")
        #expect(cook.recipe.steps.count == 3)
        #expect(cook.stage == .step(1))
        #expect(cook.servings.base == 4)
    }

    @Test func adoptOnTheOverviewTakesTheWholeRecipe() {
        var cook = session(steps: 3)
        cook.setServings({ $0.more() }, now: t0)
        let fresh = Recipe.fixture(steps: 1, servings: 2)

        cook.adopt(fresh)

        #expect(cook.recipe == fresh)
        #expect(cook.servings == Servings(base: 2))
    }

    @Test func anyRunOfTapsLeavesALegalSessionThatSurvivesSaving() throws {
        var random = SeededGenerator(seed: 42)
        for steps in 0...4 {
            var cook = session(steps: steps)
            var now = t0
            for _ in 0..<400 {
                now += Double(Int.random(in: 0...90, using: &random))
                switch Int.random(in: 0..<6, using: &random) {
                case 0: cook.start(now: now)
                case 1, 2: cook.next(now: now, mealKey: UUID())
                case 3: cook.back(now: now)
                case 4:
                    cook.startTimer(DetectedTimer(label: "5 mins", seconds: Int.random(in: 1...300, using: &random), id: 0), id: UUID(), now: now)
                default:
                    _ = cook.ringDue(at: now)
                    #expect(cook.ringDue(at: now).isEmpty)
                    #expect(cook.nextRing.map { $0 > now } ?? true)
                }

                switch cook.stage {
                case .overview: break
                case .step(let index): #expect((0..<steps).contains(index))
                case .finished: #expect(steps > 0)
                }
                #expect(cook.timers.allSatisfy { (0..<steps).contains($0.stepIndex) })
                #expect(try roundTrip(cook) == cook)
            }
        }
    }

    @Test func aTimerRingsOnceWhenItsTimeHasPassed() {
        var cook = session(steps: 2)
        cook.start(now: t0)
        cook.startTimer(DetectedTimer(label: "5 mins", seconds: 300, id: 0), id: UUID(), now: t0)
        cook.startTimer(DetectedTimer(label: "20 minutes", seconds: 1200, id: 1), id: UUID(), now: t0)

        #expect(cook.nextRing == t0 + 300)
        #expect(cook.ringDue(at: t0 + 299).isEmpty)
        #expect(cook.ringDue(at: t0 + 300).map(\.label) == ["5 mins"])
        #expect(cook.ringDue(at: t0 + 300).isEmpty)
        #expect(cook.nextRing == t0 + 1200)
        #expect(cook.timers[0].chipText(at: t0 + 300) == "Step 1: done")
        #expect(cook.timers[1].chipText(at: t0 + 300.5) == "15:00")
    }

    @Test func aTimerCannotBeStartedOffAStep() {
        var cook = session(steps: 2)

        cook.startTimer(DetectedTimer(label: "5 mins", seconds: 300, id: 0), id: UUID(), now: t0)

        #expect(cook.timers.isEmpty)
    }

    @Test func reopeningWithinEightHoursResumes() {
        var cook = session(steps: 3)
        cook.start(now: t0)
        cook.next(now: t0, mealKey: UUID())
        cook.setServings({ $0.more() }, now: t0)
        cook.startTimer(DetectedTimer(label: "5 mins", seconds: 300, id: 0), id: UUID(), now: t0)

        cook.reopen(at: t0 + CookSession.resumeWindow)

        #expect(cook.stage == .step(1))
        #expect(cook.servings.label == "5")
        #expect(cook.timers.count == 1)
    }

    @Test func reopeningLaterStartsOverAndKeepsOnlyRunningTimers() {
        var cook = session(steps: 3)
        cook.start(now: t0)
        cook.setServings({ $0.more() }, now: t0)
        cook.startTimer(DetectedTimer(label: "5 mins", seconds: 300, id: 0), id: UUID(), now: t0)
        cook.startTimer(DetectedTimer(label: "12 hours", seconds: 12 * 3600, id: 1), id: UUID(), now: t0)

        cook.reopen(at: t0 + CookSession.resumeWindow + 1)

        #expect(cook.stage == .overview)
        #expect(cook.servings.label == "4")
        #expect(cook.timers.map(\.label) == ["12 hours"])
    }

    @Test func reopeningAFinishedCookStartsOver() {
        var cook = session(steps: 1)
        cook.start(now: t0)
        cook.next(now: t0, mealKey: UUID())

        cook.reopen(at: t0 + 60)

        #expect(cook.stage == .overview)
    }

    @Test func theMealIsMadeAtTheFirstFinishAndKeptUntilTheCookStartsOver() throws {
        let first = UUID()
        var cook = session(steps: 2)
        cook.start(now: t0)
        cook.rateMeal(3)
        cook.next(now: t0, mealKey: first)
        #expect(cook.meal == nil)

        cook.next(now: t0, mealKey: first)
        cook.back(now: t0)
        cook.next(now: t0, mealKey: UUID())
        cook.rateMeal(4)
        #expect(cook.meal == CookSession.Meal(key: first, rating: 4))
        #expect(try roundTrip(cook).meal == cook.meal)

        cook.reopen(at: t0 + 60)
        #expect(cook.meal == nil)
    }

    @Test func aSessionSavedBeforeMealsDecodesWithNone() throws {
        var cook = session(steps: 1)
        cook.start(now: t0)
        cook.next(now: t0, mealKey: UUID())

        let old = try roundTrip(cook) { $0["meal"] = nil }

        #expect(old.stage == .finished)
        #expect(old.meal == nil)
    }

    @Test func aStepPageScalesItsTextAndListsItsTimersAndIngredients() {
        var cook = session(steps: 2)
        cook.setServings({ $0.more(); $0.more(); $0.more(); $0.more() }, now: t0)
        cook.start(now: t0)

        guard case .step(let page) = cook.page else { Issue.record("not on a step"); return }
        #expect(page.number == 1)
        #expect(page.count == 2)
        #expect(!page.isLast)
        #expect(page.text == "Fry the onion with 400g rice for 5 mins.")
        #expect(page.timers.map(\.seconds) == [300])
        #expect(page.ingredients.map(\.name) == ["onions", "rice"])
        #expect(page.ingredients.map(\.quantity) == ["4", "400g"])
    }

    @Test func servingsCountPeopleWhenTheRecipeSaysHowManyItServes() {
        var servings = Servings(base: 4)
        #expect(servings.title == "Servings")
        #expect(servings.label == "4")

        servings.more()
        #expect(servings.label == "5")
        #expect(servings.factor == 1.25)

        for _ in 0..<10 { servings.fewer() }
        #expect(servings.label == "1")
        #expect(!servings.canDecrease)
    }

    @Test func servingsAreAMultiplierWhenItDoesNot() {
        var servings = Servings(base: nil)
        #expect(servings.title == "Amount")
        #expect(servings.label == "×1")

        servings.more()
        #expect(servings.label == "×1.5")
        #expect(servings.factor == 1.5)

        for _ in 0..<10 { servings.fewer() }
        #expect(servings.label == "×0.5")
        #expect(!servings.canDecrease)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
