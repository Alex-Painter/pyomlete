import Foundation
import Testing
@testable import Omlete

/// The life of one tap on Add a recipe: a job keyed and saved on the phone,
/// sent until the server has it, asked after until it ends, and picked up
/// again by a phone that was away.
@MainActor struct RecipeIntakeTests {
    private typealias Call = ScriptedTransport.Call
    private let phone = Phone()
    private let server = JobServer()
    private let startLink = Call(method: "PUT", path: "/api/recipe-jobs/job1/link")
    private let askAfter = Call(method: "GET", path: "/api/recipe-jobs/job1")
    private let fetchRecipe = Call(method: "GET", path: "/api/recipes/traybake")
    private let refreshLibrary = Call(method: "GET", path: "/api/recipes/")

    /// A server that keeps jobs by key, as the real one does: a start for a
    /// key it has makes nothing, and a key it was never sent is not found.
    @MainActor final class JobServer {
        enum Start {
            case taken
            /// The job is made and the phone never hears.
            case takenButTheAnswerIsLost
            case neverArrives
            /// The phone has no network, so the start never leaves it.
            case noSignal
            case answers(Int)
        }

        var start = Start.taken
        /// What is said about a job the server has.
        var job = ScriptedTransport.Reply.status(200, RecipeIntakeTests.working)
        var recipe = ScriptedTransport.Reply.status(200, ExploreAPITests.traybakeJSON)
        /// One entry for each job made, so a key twice here is a recipe paid for twice.
        private(set) var made: [String] = []

        func answer(_ call: ScriptedTransport.Call) -> ScriptedTransport.Reply? {
            let path = call.path.split(separator: "/").map(String.init)
            guard path.starts(with: ["api", "recipe-jobs"]), path.count > 2 else { return nil }
            let key = path[2]
            switch (call.method, start) {
            case ("GET", _): return made.contains(key) ? job : .status(404, #"{"detail":"Recipe job not found"}"#)
            case (_, .neverArrives): return .lost
            case (_, .noSignal): return .unreachable
            case (_, .answers(let status)): return .status(status)
            case (_, .taken), (_, .takenButTheAnswerIsLost):
                let isNew = !made.contains(key)
                if isNew { made.append(key) }
                if case .takenButTheAnswerIsLost = start { return .lost }
                return .status(isNew ? 202 : 200, RecipeIntakeTests.working)
            }
        }
    }

    nonisolated static let working = ExploreAPITests.jobJSON("working")
    static let saved = ExploreAPITests.jobJSON("saved", recipe: "traybake")
    static let alreadySaved = ExploreAPITests.jobJSON("already_imported", recipe: "traybake")

    static func failed(_ failure: String) -> String {
        ExploreAPITests.jobJSON("failed", failure: failure)
    }

    private var intake: RecipeIntake { phone.intake }

    private var job: RecipeJob { RecipeJob(key: "job1", kind: .link, startedAt: phone.now) }

    init() {
        phone.serverAnswers { [server] call in
            if let answer = server.answer(call) { return answer }
            switch (call.method, call.path) {
            case ("GET", "/api/recipes/traybake"): return server.recipe
            case ("GET", "/api/lists/"): return .status(200, Phone.listsJSON)
            case ("GET", "/api/recipes/"), ("GET", "/api/units"), ("GET", "/api/settings/categories"): return .status(200, "[]")
            default: return nil
            }
        }
    }

    private func calls(_ call: Call) -> Int {
        phone.transport.calls.count(where: { $0 == call })
    }

    /// Submits a link and waits until the start has been taken and the job looked at once.
    private func startALinkJob() async {
        intake.edit("https://example.com/traybake")
        intake.submit()
        await eventually { phone.pulse.isWaiting }
    }

    /// Lets the wait between tries end, and waits for the next try to be answered.
    private func nextTry() async {
        let before = phone.transport.calls.count
        phone.pulse.tick()
        await eventually { phone.transport.calls.count > before && (phone.pulse.isWaiting || !intake.isWorking) }
    }

    @Test func theButtonNamesWhatSubmittingWillDo() {
        #expect(intake.submitLabel == "Create recipe")
        #expect(!intake.canSubmit)

        intake.edit("leek and potato soup")
        #expect(intake.submitLabel == "Create recipe")
        #expect(intake.canSubmit)

        intake.edit("https://example.com/soup")
        #expect(intake.submitLabel == "Import recipe")
        #expect(!intake.makesChanges)

        intake.edit("https://example.com/soup but use quorn mince")
        #expect(intake.submitLabel == "Import with changes")
        #expect(intake.makesChanges)

        let photo = RecipePhoto(id: UUID(), jpeg: Data())
        intake.expectPhotos(2)
        intake.attach(photo)
        #expect(intake.submitLabel == "Read 1 photo")
        intake.attach(RecipePhoto(id: UUID(), jpeg: Data()))
        #expect(intake.submitLabel == "Read 2 photos")

        intake.removePhoto(photo.id)
        #expect(intake.photos.count == 1)
    }

    @Test func aTapIsOnThePhoneUnderItsKeyBeforeAnythingIsAnswered() async {
        phone.transport.holding = true
        intake.edit("https://example.com/traybake")

        intake.submit()
        #expect(intake.phase == .working(job, .inTouch))

        // Killed before the start was even sent: the next launch has the job
        // all the same, and making the app sends nothing.
        phone.relaunch(comingToFront: false)
        #expect(intake.phase == .working(job, .inTouch))
        #expect(intake.text == "https://example.com/traybake")
        #expect(!intake.canSubmit)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(phone.transport.calls.isEmpty)
    }

    @Test func oneTapStartsOneJobHoweverOftenItIsTapped() async {
        phone.transport.holding = true
        intake.edit("https://example.com/traybake")

        intake.submit()
        #expect(!intake.canSubmit)
        intake.submit()
        intake.edit("something else")
        phone.transport.release()
        await eventually { phone.pulse.isWaiting }

        #expect(intake.phase == .working(job, .inTouch))
        intake.submit()
        intake.edit("something else")
        #expect(intake.text == "https://example.com/traybake")
        #expect(phone.transport.calls == [startLink, askAfter])
        #expect(phone.transport.bodies[0] as? [String: String] == ["url": "https://example.com/traybake"])
        #expect(server.made == ["job1"])
    }

    @Test func aJobIsAskedAfterUntilItIsSavedAndTheRecipeJoinsTheLibraryFirst() async {
        await phone.library.refresh()
        await startALinkJob()
        await nextTry()
        #expect(intake.phase == .working(job, .inTouch))

        server.job = .status(200, Self.saved)
        await nextTry()

        guard case .finished(.saved(let recipe)) = intake.phase else { Issue.record("not saved"); return }
        #expect(recipe.title == "Traybake")
        #expect(intake.text.isEmpty)
        #expect(calls(startLink) == 1)
        #expect(Array(phone.transport.calls.suffix(4)) == [askAfter, askAfter, askAfter, fetchRecipe])
        #expect(phone.library.recipes.first == RecipeSummary(
            id: "traybake", title: "Traybake", totalMinutes: 45, rating: 5, sourceName: "example.com", ingredientCount: 4))
        #expect(phone.pulse.asked == [.milliseconds(1500), .milliseconds(1500)])

        phone.serverIsUnreachable()
        phone.relaunch()
        #expect(intake.phase == .editing)
        #expect(phone.library.recipes.first?.title == "Traybake")
    }

    @Test func aLinkAlreadySavedKeepsWhatWasTypedAndEditingPutsTheAnswerAway() async {
        server.job = .status(200, Self.alreadySaved)
        intake.edit("https://example.com/traybake")

        intake.submit()
        await eventually { !intake.isWorking }

        #expect(intake.phase == .finished(.alreadySaved("traybake")))
        #expect(intake.text == "https://example.com/traybake")

        intake.edit("https://example.com/traybake-2")
        #expect(intake.phase == .editing)
    }

    @Test func aJobThatFailsKeepsTheInputForAnotherTryWhichIsANewJobUnderANewKey() async {
        await phone.library.refresh()
        let before = phone.library.recipes
        server.job = .status(200, Self.failed("site_did_not_respond"))
        intake.edit("https://example.com/down")

        intake.submit()
        await eventually { !intake.isWorking }

        #expect(intake.phase == .finished(.failed(.siteDidNotRespond)))
        #expect(intake.text == "https://example.com/down")
        #expect(phone.library.recipes == before)
        #expect(intake.canSubmit)

        intake.submit()
        await eventually { server.made == ["job1", "job2"] }
    }

    @Test func nothingIsSentWhilePickedPhotosAreStillArriving() {
        intake.expectPhotos(3)
        intake.attach(RecipePhoto(id: UUID(), jpeg: Data("page 1".utf8)))
        #expect(!intake.canSubmit)

        intake.submit()
        #expect(phone.transport.calls.isEmpty)

        intake.attach(nil)
        intake.attach(RecipePhoto(id: UUID(), jpeg: Data("page 3".utf8)))
        #expect(intake.canSubmit)
        #expect(intake.submitLabel == "Read 2 photos")
    }

    @Test func aTapWithNoSignalSaysSoAtOnceAndKeepsWhatWasTyped() async {
        server.start = .noSignal
        intake.edit("https://example.com/traybake")
        intake.submit()

        await eventually { !intake.isWorking }

        #expect(intake.phase == .finished(.failed(.unreachable)))
        #expect(intake.text == "https://example.com/traybake")
        #expect(intake.canSubmit)
        #expect(phone.transport.calls == [startLink])
        #expect(server.made.isEmpty)
    }

    @Test func losingSignalAfterAStartMayHaveArrivedKeepsWaitingForThatJob() async {
        server.start = .neverArrives
        await startALinkJob()

        server.start = .noSignal
        await nextTry()

        #expect(intake.isWorking)
        #expect(intake.phase == .working(job, .lost(.noConnection)))
    }

    /// Its answer was thrown away with the task that sent it, so the phone cannot say it never left.
    @Test func aFirstStartReplacedWhileStillOutIsNotLaterWrittenOffAsNeverSent() async {
        phone.transport.holding = true
        intake.edit("https://example.com/traybake")
        intake.submit()
        await eventually { phone.transport.calls == [startLink] }

        intake.resume()
        server.start = .noSignal
        phone.transport.release()
        await eventually { phone.pulse.isWaiting }
        await nextTry()

        #expect(intake.phase == .working(job, .inTouch))
        #expect(phone.transport.calls.count(where: { $0 == startLink }) == 2)
    }

    @Test func aTapWithNoSignalStillSaysSoAtOnceWhenTheAppWasJustRelaunchedIdle() async {
        intake.resume()
        server.start = .noSignal
        intake.edit("https://example.com/traybake")
        intake.submit()

        await eventually { !intake.isWorking }
        #expect(intake.phase == .finished(.failed(.unreachable)))
    }

    @Test func aStartThatIsNotAnsweredIsSentAgainUnderTheSameKeyUntilItIs() async {
        server.start = .neverArrives
        await startALinkJob()
        #expect(intake.phase == .working(job, .inTouch))

        await nextTry()
        #expect(intake.phase == .working(job, .lost(.noConnection)))
        #expect(phone.transport.calls == [startLink, startLink])
        #expect(!intake.canSubmit)

        server.start = .taken
        await nextTry()

        #expect(intake.phase == .working(job, .inTouch))
        #expect(phone.transport.calls == [startLink, startLink, startLink, askAfter])
        #expect(phone.pulse.asked == [.seconds(2), .seconds(4), .milliseconds(1500)])
        #expect(server.made == ["job1"])
    }

    @Test func aStartWhoseAnswerWasLostIsSentAgainAndTheServerStillHasOneJob() async {
        server.start = .takenButTheAnswerIsLost
        await startALinkJob()

        server.start = .taken
        server.job = .status(200, Self.alreadySaved)
        await nextTry()

        #expect(intake.phase == .finished(.alreadySaved("traybake")))
        #expect(phone.transport.calls == [startLink, startLink, askAfter])
        #expect(server.made == ["job1"])
    }

    @Test(arguments: [(429, RecipeCreation.Failure.busy), (413, .other), (422, .other)])
    func aStartTheServerRefusesIsTheOnlyStartThatFails(status: Int, failure: RecipeCreation.Failure) async {
        server.start = .answers(status)
        intake.edit("leek and potato soup")

        intake.submit()
        await eventually { !intake.isWorking }

        #expect(intake.phase == .finished(.failed(failure)))
        #expect(intake.text == "leek and potato soup")
        #expect(intake.canSubmit)
        #expect(phone.transport.calls == [Call(method: "PUT", path: "/api/recipe-jobs/job1/describe")])

        phone.relaunch()
        #expect(intake.phase == .editing)
    }

    @Test func aServerFaultOnTheStartIsNotARefusalAndSaysTheServerIsInTrouble() async {
        server.start = .answers(503)
        await startALinkJob()
        await nextTry()

        #expect(intake.phase == .working(job, .lost(.serverTrouble)))
        #expect(phone.transport.calls == [startLink, startLink])
    }

    @Test func pastTheStartWindowTheStartIsNoLongerSentAndAServerThatNeverGotItEndsTheJob() async {
        server.start = .neverArrives
        await startALinkJob()

        phone.now += RecipeIntake.startWindow + 1
        await nextTry()
        // That send was already due. From here the job is only asked after.
        server.start = .taken
        await nextTry()

        #expect(intake.phase == .finished(.failed(.unreachable)))
        #expect(intake.text == "https://example.com/traybake")
        #expect(phone.transport.calls == [startLink, startLink, askAfter])
        #expect(server.made.isEmpty)
    }

    @Test func triesThatCannotReachTheServerKeepTheJobAndBackOffAndSaySoWhenItGoesOn() async {
        await startALinkJob()
        server.job = .unreachable

        await nextTry()
        #expect(intake.phase == .working(job, .inTouch))
        await nextTry()
        #expect(intake.phase == .working(job, .lost(.noConnection)))
        await nextTry()
        await nextTry()
        #expect(phone.pulse.asked == [.milliseconds(1500), .seconds(2), .seconds(4), .seconds(8), .seconds(15)])

        server.job = .status(200, Self.working)
        await nextTry()
        #expect(intake.phase == .working(job, .inTouch))
        #expect(phone.pulse.asked.last == .milliseconds(1500))

        server.job = .status(200, Self.alreadySaved)
        await nextTry()
        #expect(intake.phase == .finished(.alreadySaved("traybake")))
        #expect(calls(startLink) == 1)
    }

    @Test(arguments: [
        ScriptedTransport.Reply.status(500), .status(503), .status(422), .status(200, "[]"),
        .status(200, ExploreAPITests.jobJSON("simmering")), .status(200, ExploreAPITests.jobJSON("saved")),
    ])
    func anAnswerThatCannotBeReadDoesNotEndTheJobAndSaysTheServerIsInTrouble(answer: ScriptedTransport.Reply) async {
        await startALinkJob()
        server.job = answer

        await nextTry()
        await nextTry()
        #expect(intake.phase == .working(job, .lost(.serverTrouble)))

        server.job = .status(200, Self.failed("no_recipe_on_page"))
        await nextTry()
        #expect(intake.phase == .finished(.failed(.noRecipeOnPage)))
        #expect(server.made == ["job1"])
    }

    @Test func aSavedJobWhoseRecipeCannotBeFetchedYetIsAskedAgainUntilItCan() async {
        await startALinkJob()
        server.job = .status(200, Self.saved)
        server.recipe = .status(500)

        await nextTry()
        await nextTry()
        #expect(intake.phase == .working(job, .lost(.serverTrouble)))

        server.recipe = .status(200, ExploreAPITests.traybakeJSON)
        await nextTry()
        guard case .finished(.saved(let recipe)) = intake.phase else { Issue.record("not saved"); return }
        #expect(recipe.id == "traybake")
    }

    @Test func aSavedJobWhoseRecipeHasSinceBeenDeletedEndsQuietlyOnAnEmptyForm() async {
        await startALinkJob()
        server.job = .status(200, Self.saved)
        server.recipe = .status(404)

        await nextTry()

        #expect(intake.phase == .editing)
        #expect(intake.text.isEmpty)
        #expect(!intake.canSubmit)
        await eventually { calls(refreshLibrary) == 1 }

        phone.relaunch()
        #expect(intake.phase == .editing)
        #expect(calls(askAfter) == 2)
    }

    @Test(arguments: [ScriptedTransport.Reply.unreachable, .status(500), .status(200, RecipeIntakeTests.working)])
    func aJobNothingEndsIsOverForThePhoneOnceNoJobCouldStillBeRunning(answer: ScriptedTransport.Reply) async {
        await startALinkJob()
        server.job = answer
        await nextTry()

        phone.now += RecipeIntake.giveUpAfter - 1
        await nextTry()
        #expect(intake.isWorking)

        phone.now += 2
        let asked = calls(askAfter)
        phone.pulse.tick()
        await eventually { !intake.isWorking }

        #expect(intake.phase == .finished(.failed(.noAnswerInTime)))
        #expect(intake.text == "https://example.com/traybake")
        #expect(intake.canSubmit)
        #expect(calls(askAfter) == asked)
        // The recipe may have been saved by a server that could not say so.
        await eventually { calls(refreshLibrary) == 1 }

        phone.relaunch()
        #expect(intake.phase == .editing)
    }

    @Test func aPhoneOpenedLongAfterItsJobWasStartedEndsItWithoutAsking() async {
        await startALinkJob()

        phone.now += RecipeIntake.giveUpAfter + 1
        phone.relaunch()
        await eventually { !intake.isWorking }

        #expect(intake.phase == .finished(.failed(.noAnswerInTime)))
        #expect(intake.text == "https://example.com/traybake")
        #expect(phone.transport.calls.filter { $0.path.hasPrefix("/api/recipe-jobs/") } == [startLink, askAfter])
    }

    @Test func theLongestAJobIsKeptIsTheStartWindowPlusTheServersOwnLimit() {
        #expect(RecipeIntake.startWindow == 120)
        #expect(RecipeIntake.giveUpAfter == 480)
    }

    @Test func theWaitBetweenTriesIsShortWhileAnsweredAndGrowsToACapWhileNot() {
        #expect((0...6).map(RecipeIntake.wait(afterMisses:)) == [
            .milliseconds(1500), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(15), .seconds(15),
        ])
    }

    @Test func aPhoneKilledBeforeItsStartArrivedSendsItAgainUnderTheSameKeyAndFollowsTheOneJob() async {
        server.start = .neverArrives
        await startALinkJob()

        server.start = .taken
        phone.relaunch()
        await eventually { calls(askAfter) == 1 && phone.pulse.isWaiting }
        #expect(intake.phase == .working(job, .inTouch))
        #expect(server.made.isEmpty)

        server.job = .status(200, Self.failed("link_blocked"))
        await nextTry()

        #expect(intake.phase == .finished(.failed(.linkBlocked)))
        #expect(phone.transport.calls == [startLink, askAfter, startLink, askAfter])
        #expect(phone.transport.bodies[2] as? [String: String] == ["url": "https://example.com/traybake"])
        #expect(server.made == ["job1"])
    }

    @Test func aPhoneKilledAfterItsStartArrivedAndBeforeTheAnswerFollowsTheJobAndSendsNothingMore() async {
        server.start = .takenButTheAnswerIsLost
        await startALinkJob()

        phone.relaunch()
        await eventually { calls(askAfter) == 1 && phone.pulse.isWaiting }
        server.job = .status(200, Self.saved)
        await nextTry()

        guard case .finished(.saved(let recipe)) = intake.phase else { Issue.record("not saved"); return }
        #expect(recipe.id == "traybake")
        #expect(phone.transport.calls == [startLink, askAfter, askAfter, fetchRecipe])
        #expect(server.made == ["job1"])
    }

    @Test func aLinkWithWordsAroundItIsImportedWithThemAsItsChanges() async {
        intake.edit("https://example.com/traybake\nbut use quorn mince")
        intake.submit()
        await eventually { phone.pulse.isWaiting }

        #expect(phone.transport.calls.first == startLink)
        #expect(phone.transport.bodies.first as? [String: String] == [
            "url": "https://example.com/traybake", "changes": "but use quorn mince",
        ])
    }

    /// The previous build wrote this, and this build must still pick it up.
    @Test func aJobSavedByThePreviousBuildIsPickedUpAndStartedAgainAsItWas() async {
        let saved = #"{"job":{"key":"job1","kind":"link","startedAt":800000000},"text":"https:\/\/example.com\/traybake","server":"http:\/\/phone.test"}"#
        phone.defaults.set(Data(saved.utf8), forKey: "add.job")

        phone.relaunch()
        #expect(intake.phase == .working(job, .inTouch))
        #expect(intake.text == "https://example.com/traybake")
        await eventually { phone.pulse.isWaiting }
        await nextTry()

        // The server never had it, so the start is sent again under the same key.
        #expect(Array(phone.transport.calls.prefix(2)) == [askAfter, startLink])
        #expect(phone.transport.bodies.dropFirst().first as? [String: String] == ["url": "https://example.com/traybake"])
        #expect(server.made == ["job1"])
    }

    @Test func aPhoneRelaunchedWithAJobOutstandingShowsItWorkingAndReachesItsOutcomeWithoutStartingAgain() async {
        await startALinkJob()

        phone.relaunch()
        #expect(intake.phase == .working(job, .inTouch))
        #expect(intake.text == "https://example.com/traybake")
        #expect(!intake.canSubmit)
        intake.submit()
        await eventually { calls(askAfter) == 2 && phone.pulse.isWaiting }

        server.job = .status(200, Self.saved)
        await nextTry()

        guard case .finished(.saved(let recipe)) = intake.phase else { Issue.record("not saved"); return }
        #expect(recipe.id == "traybake")
        #expect(intake.text.isEmpty)
        #expect(phone.library.recipes.map(\.title) == ["Traybake"])
        // The intake that was killed asked once, and this one twice.
        #expect(phone.transport.calls == [startLink, askAfter, askAfter, askAfter, fetchRecipe])

        phone.relaunch()
        #expect(intake.phase == .editing)
    }

    @Test func aPhoneRelaunchedWithNoSignalWaitsAndTheJobIsStillThereWhenItReturns() async {
        await startALinkJob()

        server.job = .unreachable
        phone.relaunch()
        await eventually { calls(askAfter) == 2 && phone.pulse.isWaiting }
        await nextTry()
        #expect(intake.phase == .working(job, .lost(.noConnection)))

        server.job = .status(200, Self.failed("no_recipe_on_page"))
        await nextTry()

        #expect(intake.phase == .finished(.failed(.noRecipeOnPage)))
        #expect(intake.text == "https://example.com/traybake")
        #expect(calls(startLink) == 1)
    }

    @Test func aJobSentToAnotherServerIsLeftAloneAndIsStillThereForItsOwn() async {
        await startALinkJob()
        let sent = phone.transport.calls

        phone.relaunch(against: "http://another.test")
        #expect(intake.phase == .editing)
        #expect(intake.text.isEmpty)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(phone.transport.calls == sent)

        phone.relaunch()
        #expect(intake.phase == .working(job, .inTouch))
    }

    @Test func comingBackToTheAppAsksAtOnceStartsCountingMissesAgainAndOnlyOneTaskGoesOnAsking() async {
        await startALinkJob()
        server.job = .unreachable
        await nextTry()
        await nextTry()
        await nextTry()
        #expect(intake.phase == .working(job, .lost(.noConnection)))

        let looks = calls(askAfter)
        intake.resume()
        #expect(intake.phase == .working(job, .inTouch))
        await eventually { calls(askAfter) == looks + 1 && phone.pulse.isWaiting }
        // One miss since coming back, not four.
        #expect(intake.phase == .working(job, .inTouch))
        #expect(phone.pulse.asked.last == .seconds(2))

        // The wait that `resume()` cut short ends here too, and its task must not ask again.
        server.job = .status(200, Self.working)
        await nextTry()
        #expect(calls(askAfter) == looks + 2)
        #expect(calls(startLink) == 1)
    }

    @Test func comingBackWithNothingOutstandingAsksNothing() async {
        intake.resume()
        intake.edit("leek and potato soup")
        intake.resume()

        try? await Task.sleep(for: .milliseconds(20))
        #expect(phone.transport.calls.isEmpty)
    }

    @Test func photosAreSentInsteadOfTheTextAndClearedOnceSaved() async {
        server.job = .status(200, Self.saved)
        intake.edit("ignored")
        intake.expectPhotos(1)
        intake.attach(RecipePhoto(id: UUID(), jpeg: Data("page".utf8)))

        intake.submit()
        #expect(intake.phase == .working(RecipeJob(key: "job1", kind: .photos, startedAt: phone.now), .inTouch))
        await eventually { !intake.isWorking }

        #expect(phone.transport.calls == [Call(method: "PUT", path: "/api/recipe-jobs/job1/photos"), askAfter, fetchRecipe])
        #expect(intake.photos.isEmpty)
    }

    @Test func photosWhoseStartWasNotAnsweredAreSentAgainWhileTheAppStillHoldsThem() async {
        server.start = .neverArrives
        intake.expectPhotos(1)
        intake.attach(RecipePhoto(id: UUID(), jpeg: Data("page".utf8)))
        intake.submit()
        await eventually { phone.pulse.isWaiting }

        server.start = .taken
        intake.resume()
        await eventually { calls(askAfter) == 1 && phone.pulse.isWaiting }
        await nextTry()

        let sendPhotos = Call(method: "PUT", path: "/api/recipe-jobs/job1/photos")
        #expect(phone.transport.calls == [sendPhotos, askAfter, sendPhotos, askAfter])
        let resent = String(decoding: phone.transport.requests[2].httpBody ?? Data(), as: UTF8.self)
        #expect(resent.contains("Content-Type: image/jpeg\r\n\r\npage\r\n"))
    }

    @Test func photosThatNeverArrivedBeforeTheAppWasKilledCannotBeSentAgainAndTheScreenSaysSo() async {
        server.start = .neverArrives
        intake.expectPhotos(1)
        intake.attach(RecipePhoto(id: UUID(), jpeg: Data("page".utf8)))
        intake.submit()
        await eventually { phone.pulse.isWaiting }

        server.start = .taken
        phone.relaunch()
        await eventually { !intake.isWorking }

        #expect(intake.phase == .finished(.failed(.photosNotSent)))
        #expect(RecipeCreation.Failure.photosNotSent.message == "Your photos didn't reach Omlete before the app closed. Choose them again.")
        #expect(phone.transport.calls == [Call(method: "PUT", path: "/api/recipe-jobs/job1/photos"), askAfter])
        #expect(server.made.isEmpty)
    }

    @Test func photosThatDidArriveBeforeTheAppWasKilledAreFollowedToTheirRecipe() async {
        server.start = .takenButTheAnswerIsLost
        intake.expectPhotos(1)
        intake.attach(RecipePhoto(id: UUID(), jpeg: Data("page".utf8)))
        intake.submit()
        await eventually { phone.pulse.isWaiting }

        server.job = .status(200, Self.saved)
        phone.relaunch()
        await eventually { !intake.isWorking }

        guard case .finished(.saved(let recipe)) = intake.phase else { Issue.record("not saved"); return }
        #expect(recipe.id == "traybake")
        #expect(server.made == ["job1"])
    }
}
