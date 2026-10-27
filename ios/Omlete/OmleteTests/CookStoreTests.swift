import Foundation
import Testing
@testable import Omlete

@MainActor struct CookStoreTests {
    private typealias Call = ScriptedTransport.Call
    private let stove = Stove()
    private let rate = Call(method: "PATCH", path: "/api/recipes/curry/rating")

    private var store: CookStore { stove.store }

    /// Opens Cook and walks to the given 1-based step.
    private func cook(toStep number: Int) async {
        await store.open()
        store.start()
        for _ in 1..<number { store.next() }
    }

    private func startTimer(_ position: Int = 0, sourceLocation: SourceLocation = #_sourceLocation) {
        guard case .step(let page) = stove.session?.page, page.timers.indices.contains(position) else {
            Issue.record("no such timer on this page", sourceLocation: sourceLocation)
            return
        }
        store.startTimer(page.timers[position])
    }

    private func finish() async {
        await cook(toStep: 4)
        store.next()
        #expect(stove.session?.stage == .finished)
        await eventually { stove.storage.records[Stove.recipeID]?.mealToSend == nil }
    }

    /// Every meal PUT in order: the key from its path, and its body.
    private var mealsSent: [(key: String, body: [String: Any])] {
        zip(stove.transport.calls, stove.transport.bodies).compactMap { call, body in
            guard call.method == "PUT", call.path.hasPrefix("/api/meals/") else { return nil }
            return (String(call.path.dropFirst("/api/meals/".count)), body)
        }
    }

    private var ratingsSent: [Int] {
        zip(stove.transport.calls, stove.transport.bodies).compactMap { call, body in
            call == rate ? body["rating"] as? Int : nil
        }
    }

    @Test func openingFetchesTheRecipeAndShowsTheOverview() async {
        #expect(store.phase == .loading)

        await store.open()

        guard case .overview(let needs) = stove.session?.page else { Issue.record("not on the overview"); return }
        #expect(stove.session?.recipe.title == "Curry")
        #expect(needs.map(\.name) == ["onions", "rice", "coconut milk"])
        #expect(needs.map(\.quantity) == ["2", "200g", "1 tin"])
        #expect(needs.first?.note == "finely chopped")
    }

    @Test func aRecipeWithOnlyATitleStillOpens() async {
        stove.serverAnswers { $0.method == "GET" ? .status(200, #"{"_id":"curry","title":"Toast"}"#) : nil }

        await store.open()
        store.start()

        #expect(stove.session?.recipe.title == "Toast")
        #expect(stove.session?.stage == .overview)
        #expect(stove.session?.servings.title == "Amount")
    }

    @Test func servingsScaleEveryAmount() async {
        await store.open()

        store.more()
        store.more()

        guard case .overview(let needs) = stove.session?.page else { Issue.record("not on the overview"); return }
        #expect(stove.session?.servings.label == "6")
        #expect(needs.map(\.quantity) == ["3", "300g", "1.5 tin"])
    }

    @Test func aTimerRingsOnceWhenTheClockPassesItWhileAnotherStepShows() async {
        await cook(toStep: 2)
        startTimer()
        store.next()
        store.next()

        stove.clock.advance(by: 719)
        #expect(stove.chimes == 0)
        #expect(stove.session?.timers.first?.chipText(at: stove.clock.now) == "0:01")

        stove.clock.advance(by: 1)
        await eventually { stove.chimes == 1 }
        #expect(stove.session?.stage == .step(3))
        #expect(stove.session?.timers.first?.chipText(at: stove.clock.now) == "Step 2: done")

        stove.clock.advance(by: 600)
        store.resume()
        #expect(stove.chimes == 1)
    }

    @Test func afterARelaunchARungTimerShowsDoneAndDoesNotRingAgain() async {
        await cook(toStep: 2)
        startTimer()
        stove.clock.advance(by: 720)
        await eventually { stove.chimes == 1 }

        stove.relaunch()
        stove.kitchen.resume()

        #expect(stove.session?.stage == .step(1))
        #expect(stove.session?.timers.first?.chipText(at: stove.clock.now) == "Step 2: done")
        #expect(stove.chimes == 1)
    }

    @Test func aTimerThatEndedWhileTheAppWasGoneRingsOnceAtLaunch() async {
        await cook(toStep: 2)
        startTimer()

        stove.kill()
        stove.clock.advance(by: 900)
        #expect(stove.chimes == 0)
        stove.relaunch()

        #expect(stove.chimes == 1)
        stove.kitchen.resume()
        #expect(stove.chimes == 1)
    }

    @Test func twoTimersPassingAtOnceChimeOnce() async {
        await cook(toStep: 1)
        startTimer()
        store.next()
        startTimer()
        #expect(stove.session?.timers.count == 2)

        stove.clock.advance(by: 3600)

        await eventually { stove.chimes == 1 }
        #expect(stove.session?.timers.allSatisfy(\.rung) == true)
        #expect(stove.session?.nextRing == nil)
    }

    @Test func aDismissedTimerNeverRings() async throws {
        await cook(toStep: 1)
        startTimer()
        let timer = try #require(stove.session?.timers.first)

        store.dismissTimer(timer.id)
        stove.clock.advance(by: 3600)
        store.resume()

        #expect(stove.session?.timers.isEmpty == true)
        #expect(stove.chimes == 0)
    }

    @Test func closingAndReopeningCookFindsTheSameStepServingsAndTimers() async {
        await store.open()
        store.more()
        store.start()
        store.next()
        startTimer()

        stove.clock.advance(by: 60)
        await stove.kitchen.cook(Stove.recipeID).open()

        #expect(stove.session?.stage == .step(1))
        #expect(stove.session?.servings.label == "5")
        #expect(stove.session?.timers.count == 1)
    }

    @Test func aRecipeSeenBeforeOpensWithNoSignal() async {
        await cook(toStep: 3)
        stove.serverIsUnreachable()
        stove.relaunch()

        #expect(stove.session?.stage == .step(2))
        await store.open()

        #expect(stove.session?.stage == .step(2))
    }

    @Test func warmingPutsARecipeOnThePhoneBeforeItIsOpened() async {
        await stove.kitchen.warm([Stove.recipeID])
        await stove.kitchen.warm([Stove.recipeID])
        #expect(stove.transport.calls == [Call(method: "GET", path: "/api/recipes/curry")])

        stove.serverIsUnreachable()
        await store.open()

        #expect(stove.session?.stage == .overview)
    }

    @Test func aFailedWarmIsSilentAndOpeningTriesAgain() async {
        stove.serverIsUnreachable()
        await stove.kitchen.warm([Stove.recipeID])
        #expect(store.phase == .loading)

        await store.open()
        #expect(store.phase == .unavailable)

        stove.serverAnswers()
        await store.open()
        #expect(stove.session != nil)
    }

    @Test func aDeletedRecipeNeverCookedHereIsGone() async {
        stove.serverAnswers { $0.method == "GET" ? .status(404) : nil }

        await store.open()

        #expect(store.phase == .gone)
    }

    @Test func aRecipeDeletedMidCookStaysCookable() async {
        await cook(toStep: 2)
        stove.serverAnswers { $0.method == "GET" ? .status(404) : nil }

        await store.open()

        #expect(stove.session?.stage == .step(1))
    }

    @Test func aRefetchMidCookDoesNotMoveTheStep() async {
        await cook(toStep: 4)
        stove.serverAnswers { call in
            call.method == "GET" ? .status(200, #"{"_id":"curry","title":"Shorter","instructions":["Serve."],"rating":5}"#) : nil
        }

        await store.open()

        #expect(stove.session?.stage == .step(3))
        #expect(stove.session?.recipe.title == "Curry")
        #expect(store.rating.stars == 5)
    }

    @Test func aRatingIsSentAndThanked() async {
        await finish()
        #expect(store.rating == RatingView(stars: nil, status: .unrated))

        store.rate(4)
        #expect(store.rating.stars == 4)

        await eventually { store.rating.status == .sent }
        #expect(ratingsSent == [4])
        #expect(stove.storage.records[Stove.recipeID]?.unsentRating == nil)
        #expect(stove.session?.recipe.rating == 4)
    }

    @Test func aRatingWithNoSignalShowsAtOnceSurvivesARelaunchAndIsSentOnceOnResume() async {
        await finish()
        stove.serverIsUnreachable()

        store.rate(4)
        #expect(store.rating.stars == 4)
        await eventually { store.rating == RatingView(stars: 4, status: .savedHere) }

        stove.relaunch()
        #expect(store.rating == RatingView(stars: 4, status: .savedHere))
        let before = stove.transport.calls.count

        stove.serverAnswers()
        stove.kitchen.resume()
        await eventually { store.rating == RatingView(stars: 4, status: .sent) }
        stove.kitchen.resume()
        await eventually { stove.storage.records[Stove.recipeID]?.unsentRating == nil }

        #expect(stove.transport.calls[before...].filter { $0.method == "PATCH" } == [rate])
        #expect(ratingsSent.last == 4)
    }

    @Test func aSecondTapWhileTheFirstIsInFlightEndsWithTheSecondSentLast() async {
        await finish()
        stove.transport.holding = true

        store.rate(4)
        await eventually { stove.transport.calls.contains(rate) }
        store.rate(5)
        store.rate(2)
        #expect(store.rating.stars == 2)
        stove.transport.release()

        await eventually { store.rating == RatingView(stars: 2, status: .sent) }
        await eventually { stove.storage.records[Stove.recipeID]?.mealToSend == nil }
        #expect(ratingsSent == [4, 2])
        #expect(mealsSent.compactMap { $0.body["rating"] as? Int } == [4, 2])
        // One rating and one meal.
        #expect(stove.transport.peakInFlight == 2)
        #expect(stove.session?.recipe.rating == 2)
    }

    @Test func aRatingForADeletedRecipeIsDroppedAndTheStarsFallBack() async {
        stove.serverAnswers { call in
            switch call.method {
            case "GET": .status(200, #"{"_id":"curry","title":"Curry","instructions":["Serve."],"rating":3}"#)
            case "PATCH": .status(404)
            default: nil
            }
        }
        await store.open()
        store.start()
        store.next()

        store.rate(5)
        #expect(store.rating.stars == 5)

        await eventually { store.rating == RatingView(stars: 3, status: .unrated) }
        #expect(stove.storage.records[Stove.recipeID]?.unsentRating == nil)

        stove.kitchen.resume()
        #expect(ratingsSent == [5])
    }

    @Test func finishingLogsTheMealOnceUnderAKeyMadeForThisCook() async throws {
        await finish()
        store.back()
        store.next()
        stove.kitchen.resume()
        await settle()

        let meals = mealsSent
        #expect(meals.count == 1)
        let key = try #require(meals.first?.key)
        #expect(UUID(uuidString: key)?.uuidString.lowercased() == key)
        #expect(meals.first?.body as? [String: String] == ["recipe_id": "curry"])
    }

    @Test func aRatingAfterFinishingRatesTheSameMeal() async {
        await finish()

        store.rate(4)
        await eventually { mealsSent.count == 2 && store.rating.status == .sent }

        #expect(mealsSent[1].key == mealsSent[0].key)
        #expect(mealsSent[1].body["rating"] as? Int == 4)
        #expect(ratingsSent == [4])
    }

    @Test func aRelaunchAfterFinishingKeepsTheMealsKey() async {
        await finish()
        stove.relaunch()
        stove.kitchen.resume()
        await settle()
        #expect(mealsSent.count == 1)

        store.rate(5)
        await eventually { mealsSent.count == 2 }
        #expect(mealsSent[1].key == mealsSent[0].key)
    }

    @Test func aMealFinishedWithNoSignalIsSentOnceOnResumeWithItsRating() async {
        await cook(toStep: 4)
        stove.serverIsUnreachable()
        store.next()
        store.rate(4)
        await eventually { store.rating.status == .savedHere }
        let key = mealsSent.first?.key
        #expect(mealsSent.allSatisfy { $0.key == key })

        stove.relaunch()
        let before = mealsSent.count
        stove.serverAnswers()
        stove.kitchen.resume()
        await eventually { stove.storage.records[Stove.recipeID]?.mealToSend == nil }
        stove.kitchen.resume()
        await settle()

        #expect(mealsSent.count == before + 1)
        #expect(mealsSent.last?.key == key)
        #expect(mealsSent.last?.body["rating"] as? Int == 4)
    }

    @Test func cookingItAgainIsANewMeal() async {
        await finish()
        await finish()

        #expect(mealsSent.count == 2)
        #expect(mealsSent[0].key != mealsSent[1].key)
    }

    @Test func aRatingBeforeTheEndLogsNoMeal() async {
        await cook(toStep: 2)
        store.rate(3)
        await eventually { store.rating.status == .sent }

        #expect(mealsSent.isEmpty)
    }

    @Test func aMealForADeletedRecipeIsDroppedNotRetried() async {
        stove.serverAnswers { $0.method == "PUT" ? .status(404) : nil }
        await finish()
        stove.kitchen.resume()
        await settle()

        #expect(mealsSent.count == 1)
    }

    @Test func aCookUntouchedForAMonthIsKeptWhileItsMealIsUnsent() async {
        await cook(toStep: 4)
        stove.serverIsUnreachable()
        store.next()
        stove.clock.advance(by: Kitchen.keepsCooksFor + 1)
        stove.relaunch()

        #expect(stove.storage.records[Stove.recipeID]?.mealToSend != nil)
    }

    /// Lets any request a step started go out and be answered.
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test func aCookUntouchedForAMonthIsForgottenUnlessARatingIsUnsent() async {
        await finish()
        stove.clock.advance(by: Kitchen.keepsCooksFor + 1)
        stove.relaunch()
        #expect(stove.storage.records.isEmpty)
        #expect(store.phase == .loading)

        await finish()
        stove.serverIsUnreachable()
        store.rate(4)
        await eventually { store.rating.status == .savedHere }
        stove.clock.advance(by: Kitchen.keepsCooksFor + 1)
        stove.relaunch()

        #expect(store.rating == RatingView(stars: 4, status: .savedHere))
    }
}
