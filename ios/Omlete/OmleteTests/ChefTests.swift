import Foundation
import Testing
@testable import Omlete

@MainActor struct ChefTests {
    private typealias Call = ScriptedTransport.Call

    /// The server's feed, which a test changes to play the recipe being made in the background.
    @MainActor private final class Feed {
        var cards: [String] = []
        var json: String { "[\(cards.joined(separator: ","))]" }
    }

    private let phone = Phone()
    private let server = Feed()
    private let getFeed = Call(method: "GET", path: "/api/suggestions/")

    private var chef: Chef { phone.chef }

    init() {
        serverAnswers()
    }

    private func card(_ id: String, _ status: String = "new", section: String? = nil, recipe: String? = nil) -> String {
        let section = section.map { "\"\($0)\"" } ?? "null"
        let recipe = recipe.map { "\"\($0)\"" } ?? "null"
        return #"{"id":"\#(id)","title":"Card \#(id)","status":"\#(status)","section":\#(section),"recipe_id":\#(recipe)}"#
    }

    private func serverAnswers(_ override: @escaping (Call) -> ScriptedTransport.Reply? = { _ in nil }) {
        phone.serverAnswers { [server] call in
            if let reply = override(call) { return reply }
            switch call.description {
            case "GET /api/suggestions/": return .status(200, server.json)
            case "GET /api/lists/": return .status(200, Phone.listsJSON)
            case "GET /api/recipes/", "GET /api/units", "GET /api/settings/categories": return .status(200, "[]")
            default: return nil
            }
        }
    }

    private var shelves: [Shelf] {
        if case .shelves(let shelves) = chef.feed { shelves } else { [] }
    }

    private var shown: [SuggestionID] { shelves.flatMap(\.cards).map(\.id) }

    private func stage(_ id: SuggestionID) -> Suggestion.Stage? {
        shelves.flatMap(\.cards).first { $0.id == id }?.stage
    }

    private func calls(_ call: Call) -> Int {
        phone.transport.calls.count(where: { $0 == call })
    }

    /// Puts the phone's clock forward and lets the poll that was waiting look again.
    private func pollAfter(_ seconds: TimeInterval) async {
        await eventually { phone.ticker.isWaiting }
        phone.now += seconds
        phone.ticker.tick()
    }

    /// The server is out of reach from now until a card's time is up and for the polls after that.
    private func theServerStaysAwayUntilPollingRests() async {
        phone.serverIsUnreachable()
        await pollAfter(Chef.giveUpAfter)
        for _ in 1..<Chef.restAfterUnanswered { await pollAfter(0) }
        // Joins the last poll's fetch if it is still on its way, so the poll has decided by the time this returns.
        await chef.load()
        await eventually { !phone.ticker.isWaiting }
    }

    private func body(of call: Call) -> [String: Any]? {
        Array(zip(phone.transport.calls, phone.transport.bodies)).last { $0.0 == call }?.1
    }

    @Test func theFeedIsLoadingThenShelvedBySection() async {
        server.cards = [card("a"), card("b", section: "Something new"), card("c", section: "For this week")]
        #expect(chef.feed == .loading)

        await chef.load()

        #expect(shelves.map(\.section) == [.thisWeek, .somethingNew, .moreIdeas])
        #expect(shown == ["c", "b", "a"])
    }

    @Test func theCardsOnScreenAreTheFeedInServerOrderWithoutThoseHiddenForUndo() async {
        server.cards = [card("a"), card("b", "saving", section: "For this week"), card("c", "failed")]
        await chef.load()
        #expect(chef.visible.map(\.id) == ["a", "b", "c"])
        #expect(chef.visible.map(\.stage) == [.fresh, .saving, .failed])

        chef.dismiss("a")
        #expect(chef.visible.map(\.id) == ["b", "c"])

        phone.undo.undoTapped()
        #expect(chef.visible.map(\.id) == ["a", "b", "c"])
    }

    @Test func anEmptyFeedAndAFeedThatNeverLoadedAreToldApart() async {
        await chef.load()
        #expect(chef.feed == .empty)

        phone.relaunch()
        phone.serverIsUnreachable()
        await phone.chef.load()
        #expect(phone.chef.feed == .unavailable(.unreachable))
    }

    @Test func aFailedReloadKeepsTheCardsAlreadyShown() async {
        server.cards = [card("a")]
        await chef.load()

        phone.serverIsUnreachable()
        await chef.load()

        #expect(shown == ["a"])
    }

    @Test func aLoadMadeDuringAnotherJoinsIt() async {
        // Held, so the first is still on its way when the second is made. Both
        // are made on the main actor, so the second runs before anything the release resumes.
        phone.transport.holding = true
        let first = Task { await chef.load() }
        await eventually { calls(getFeed) == 1 }
        let second = Task { await chef.load() }
        phone.transport.release()
        _ = await first.value
        _ = await second.value

        #expect(calls(getFeed) == 1)
    }

    @Test func savingShowsAtOnceAndTheFeedIsPolledUntilTheRecipeExists() async {
        server.cards = [card("a")]
        await chef.load()
        phone.transport.holding = true

        chef.save("a")
        await eventually { stage("a") == .saving }

        server.cards = [card("a", "saving")]
        phone.transport.release()
        await eventually { phone.ticker.isWaiting }
        #expect(stage("a") == .saving)
        #expect(body(of: Call(method: "POST", path: "/api/suggestions/a/save"))?["list_id"] == nil)

        phone.ticker.tick()
        await eventually { phone.ticker.isWaiting }
        #expect(stage("a") == .saving)

        server.cards = [card("a", "saved", recipe: "r1")]
        phone.ticker.tick()
        await eventually { stage("a") == .saved("r1") }

        let fetches = calls(getFeed)
        await eventually { calls(Call(method: "GET", path: "/api/recipes/")) == 1 }
        phone.ticker.tick()
        #expect(!phone.ticker.isWaiting)
        #expect(calls(getFeed) == fetches)
    }

    @Test func aSaveAnsweredWhileAnOlderFeedIsOnItsWayStillEndsUpSaving() async {
        server.cards = [card("a")]
        await chef.load()
        let stale = server.json
        var feedsAsked = 0
        serverAnswers { [getFeed] call in
            guard call == getFeed else { return nil }
            feedsAsked += 1
            return feedsAsked == 1 ? .status(200, stale) : nil
        }
        phone.transport.holding = true
        Task { await chef.load() }
        await eventually { feedsAsked == 0 && calls(getFeed) == 2 }

        chef.save("a")
        server.cards = [card("a", "saving")]
        phone.transport.release()

        await eventually { calls(getFeed) == 3 && phone.ticker.isWaiting }
        #expect(stage("a") == .saving)
    }

    /// The feed asked for before the save was answered shows the card as it
    /// was, fresh or failed. Adopted after the answer, it must not decide the card.
    @Test(arguments: ["new", "failed"])
    func aFeedAskedForBeforeASaveWasAnsweredDoesNotCostTheCardItsList(before: String) async {
        server.cards = [card("a", before)]
        await chef.load()
        await phone.library.refresh()
        let stale = server.json
        let save = Call(method: "POST", path: "/api/suggestions/a/save")
        let getList = Call(method: "GET", path: "/api/lists/list")
        var feedsAsked = 0
        serverAnswers { [server, getFeed] call in
            if call == save { server.cards = [self.card("a", "saving")] }
            guard call == getFeed else { return nil }
            feedsAsked += 1
            return feedsAsked == 1 ? .status(200, stale) : nil
        }
        phone.transport.holding = true
        Task { await chef.load() }
        await eventually { calls(getFeed) == 2 }
        let adding = Task { await chef.addToList("a", to: .list("list")) }
        await eventually { calls(save) == 1 }

        phone.transport.release(only: save)
        await eventually { phone.transport.answered.contains(save) }
        phone.transport.release(only: getFeed)
        await eventually { feedsAsked == 1 && phone.transport.answered.count(where: { $0 == getFeed }) == 2 }
        let saidOfTheOlderFeed = phone.undo.banner?.message
        phone.transport.release()
        await adding.value

        #expect(calls(getFeed) == 3)
        #expect(stage("a") == .saving)
        #expect(saidOfTheOlderFeed == nil)
        #expect(phone.undo.banner?.message == "Saving Card a. It goes on Week when it's ready.")
        await eventually { phone.ticker.isWaiting }
        let fetchesBefore = calls(getList)

        server.cards = [card("a", "saved", recipe: "soup")]
        phone.ticker.tick()

        await eventually { calls(getList) == fetchesBefore + 1 }
        #expect(stage("a") == .saved("soup"))
    }

    @Test func aSaveTheServerNeverFinishesIsGivenUpOnSoTheCardCanBeDismissed() async {
        server.cards = [card("a", "saving")]
        await chef.load()

        await pollAfter(Chef.giveUpAfter - 1)
        await eventually { phone.ticker.isWaiting }
        #expect(stage("a") == .saving)

        await pollAfter(1)
        await eventually { stage("a") == .failed }
        #expect(!phone.ticker.isWaiting)

        await chef.load()
        #expect(stage("a") == .failed)
        chef.dismiss("a")
        #expect(shown.isEmpty)
    }

    /// A fetch that fails has heard nothing, so it decides nothing about a card.
    @Test func aServerThatCannotBeReachedIsNotTakenForAFailedSaveAndPollingRests() async {
        server.cards = [card("a")]
        await chef.load()
        await phone.library.refresh()
        serverAnswers { [server] call in
            if call.path == "/api/suggestions/a/save" { server.cards = [self.card("a", "saving")] }
            return nil
        }
        await chef.addToList("a", to: .list("list"))
        phone.undo.commitNow()
        phone.serverIsUnreachable()

        for _ in 0...Chef.restAfterUnanswered { await pollAfter(1) }
        await eventually { phone.ticker.isWaiting }

        await theServerStaysAwayUntilPollingRests()

        #expect(!phone.ticker.isWaiting)
        #expect(stage("a") == .saving)
        #expect(phone.undo.banner == nil)
    }

    @Test func theLoadAfterPollingRestedHearsThatTheSaveLanded() async {
        server.cards = [card("a")]
        await chef.load()
        await phone.library.refresh()
        serverAnswers { [server] call in
            if call.path == "/api/suggestions/a/save" { server.cards = [self.card("a", "saving")] }
            return nil
        }
        await chef.addToList("a", to: .list("list"))
        phone.undo.commitNow()
        await theServerStaysAwayUntilPollingRests()
        let getList = Call(method: "GET", path: "/api/lists/list")
        let lists = calls(getList)

        serverAnswers()
        server.cards = [card("a", "saved", recipe: "soup")]
        await chef.load()

        #expect(stage("a") == .saved("soup"))
        #expect(phone.undo.banner == nil)
        await eventually { calls(getList) == lists + 1 }
    }

    @Test func theLoadAfterPollingRestedGivesUpOnASaveTheServerStillCallsSaving() async {
        server.cards = [card("a", "saving")]
        await chef.load()
        await theServerStaysAwayUntilPollingRests()
        #expect(stage("a") == .saving)

        serverAnswers()
        await chef.load()

        #expect(stage("a") == .failed)
        #expect(!phone.ticker.isWaiting)
    }

    @Test func aClockPutBackFailsNoCardAndTheCardIsStillGivenUpOnInTime() async {
        server.cards = [card("a", "saving")]
        await chef.load()

        await pollAfter(-Chef.giveUpAfter)
        await eventually { phone.ticker.isWaiting }
        #expect(stage("a") == .saving)

        await pollAfter(Chef.giveUpAfter - 1)
        await eventually { phone.ticker.isWaiting }
        #expect(stage("a") == .saving)

        await pollAfter(1)
        await eventually { stage("a") == .failed }
        #expect(!phone.ticker.isWaiting)
    }

    /// Each card has its own clock: one saved late is not failed with one saved long before.
    @Test func aCardSavedWhileAnotherIsNearlyGivenUpOnKeepsItsOwnTime() async {
        server.cards = [card("a", "saving"), card("b")]
        await chef.load()
        serverAnswers { [server] call in
            if call.path == "/api/suggestions/b/save" { server.cards = [self.card("a", "saving"), self.card("b", "saving")] }
            return nil
        }
        await pollAfter(Chef.giveUpAfter - 10)
        await eventually { phone.ticker.isWaiting }
        chef.save("b")
        await eventually { stage("b") == .saving }

        await pollAfter(10)
        await eventually { stage("a") == .failed }
        #expect(stage("b") == .saving)

        await pollAfter(Chef.giveUpAfter - 11)
        await eventually { phone.ticker.isWaiting }
        #expect(stage("b") == .saving)

        await pollAfter(1)
        await eventually { stage("b") == .failed }
        #expect(!phone.ticker.isWaiting)
    }

    @Test func aCardGivenUpOnThatTheServerThenFinishesIsASaveThatLanded() async {
        server.cards = [card("a")]
        await chef.load()
        await phone.library.refresh()
        serverAnswers { [server] call in
            if call.path == "/api/suggestions/a/save" { server.cards = [self.card("a", "saving")] }
            return nil
        }
        await chef.addToList("a", to: .list("list"))
        await pollAfter(Chef.giveUpAfter)
        await eventually { stage("a") == .failed }
        let getList = Call(method: "GET", path: "/api/lists/list")
        let getRecipes = Call(method: "GET", path: "/api/recipes/")
        let (lists, recipes) = (calls(getList), calls(getRecipes))

        server.cards = [card("a", "saved", recipe: "soup")]
        await chef.load()

        #expect(stage("a") == .saved("soup"))
        await eventually { calls(getList) == lists + 1 && calls(getRecipes) == recipes + 1 }

        server.cards = [card("a", "saving")]
        await chef.load()
        #expect(stage("a") == .saving)
    }

    @Test func aCardGivenUpOnThatTheServerThenFailsIsNotSaidTwice() async {
        server.cards = [card("a")]
        await chef.load()
        await phone.library.refresh()
        serverAnswers { [server] call in
            if call.path == "/api/suggestions/a/save" { server.cards = [self.card("a", "saving")] }
            return nil
        }
        await chef.addToList("a", to: .list("list"))
        await pollAfter(Chef.giveUpAfter)
        await eventually { stage("a") == .failed }
        phone.undo.commitNow()
        #expect(phone.undo.banner == nil)

        server.cards = [card("a", "failed")]
        await chef.load()

        #expect(stage("a") == .failed)
        #expect(phone.undo.banner == nil)
    }

    @Test func tryAgainOnACardGivenUpOnSavesItAgainWithATimeOfItsOwn() async {
        server.cards = [card("a", "saving")]
        await chef.load()
        await pollAfter(Chef.giveUpAfter)
        await eventually { stage("a") == .failed }
        let save = Call(method: "POST", path: "/api/suggestions/a/save")

        chef.save("a")
        await eventually { calls(save) == 1 && phone.ticker.isWaiting }
        #expect(stage("a") == .saving)

        await pollAfter(Chef.giveUpAfter - 1)
        await eventually { phone.ticker.isWaiting }
        #expect(stage("a") == .saving)

        server.cards = [card("a", "saved", recipe: "soup")]
        await pollAfter(1)
        await eventually { stage("a") == .saved("soup") }
    }

    @Test func tryAgainOnACardThatFailedOnItsWayToAListSendsItToThatListAgain() async {
        server.cards = [card("a")]
        await chef.load()
        await phone.library.refresh()
        let save = Call(method: "POST", path: "/api/suggestions/a/save")
        let getList = Call(method: "GET", path: "/api/lists/list")
        serverAnswers { [server] call in
            if call == save { server.cards = [self.card("a", "saving")] }
            return nil
        }
        await chef.addToList("a", to: .list("list"))
        await eventually { phone.ticker.isWaiting }
        server.cards = [card("a", "failed")]
        phone.ticker.tick()
        await eventually { stage("a") == .failed }

        chef.save("a")
        await eventually { calls(save) == 2 && phone.ticker.isWaiting }

        #expect(body(of: save) as? [String: String] == ["list_id": "list"])
        let fetchesBefore = calls(getList)
        server.cards = [card("a", "saved", recipe: "soup")]
        phone.ticker.tick()
        await eventually { calls(getList) == fetchesBefore + 1 }
    }

    @Test func tryAgainOnACardThatWasOnlySavedSendsNoList() async {
        server.cards = [card("a", "failed")]
        await chef.load()
        let save = Call(method: "POST", path: "/api/suggestions/a/save")

        chef.save("a")
        await eventually { calls(save) == 1 }

        #expect(body(of: save)?["list_id"] == nil)
    }

    @Test func aFeedLoadedWithACardAlreadySavingIsPolledToo() async {
        server.cards = [card("a", "saving")]

        await chef.load()
        await eventually { phone.ticker.isWaiting }

        server.cards = [card("a", "failed")]
        phone.ticker.tick()
        await eventually { stage("a") == .failed }
    }

    @Test func aSaveTheServerRefusesIsFailedNotUnsent() async {
        server.cards = [card("a")]
        await chef.load()
        serverAnswers { $0.method == "POST" ? .status(404, "{}") : nil }

        chef.save("a")

        await eventually { stage("a") == .failed }
    }

    @Test func aSaveThatCannotBeSentIsMarkedUnsentAndCanBeTriedAgain() async {
        server.cards = [card("a")]
        await chef.load()
        serverAnswers { $0.method == "POST" ? .unreachable : nil }

        chef.save("a")
        await eventually { stage("a") == .unsent }

        serverAnswers()
        server.cards = [card("a", "saving")]
        chef.save("a")
        await eventually { phone.ticker.isWaiting }
        #expect(stage("a") == .saving)
    }

    @Test func notForMeHidesAtOnceAndUndoBringsItBackWithNothingSent() async {
        server.cards = [card("a"), card("b")]
        await chef.load()
        let before = phone.transport.calls.count

        chef.dismiss("a")
        #expect(shown == ["b"])
        #expect(phone.undo.banner?.message == "Hid Card a. You'll see less like it.")

        phone.undo.undoTapped()

        #expect(shown == ["a", "b"])
        #expect(phone.transport.calls.count == before)
    }

    @Test func aSettledNotForMeIsSentAsATasteSignal() async {
        server.cards = [card("a"), card("b")]
        await chef.load()
        let dismissal = Call(method: "PATCH", path: "/api/suggestions/a")

        chef.dismiss("a")
        phone.undo.commitNow()

        await eventually { calls(dismissal) == 1 }
        #expect(body(of: dismissal) as? [String: String] == ["status": "dismissed"])
        server.cards = [card("b")]
        await chef.load()
        #expect(shown == ["b"])
    }

    @Test func aNotForMeThatCannotBeSentStaysHidden() async {
        server.cards = [card("a"), card("b")]
        await chef.load()
        serverAnswers { $0.method == "PATCH" ? .unreachable : nil }

        chef.dismiss("a")
        phone.undo.commitNow()
        await eventually { calls(Call(method: "PATCH", path: "/api/suggestions/a")) == 1 }
        await chef.load()

        #expect(shown == ["b"])
    }

    @Test func aSavingCardCannotBeDismissedBecauseTheSaveWouldBringItBack() async {
        server.cards = [card("a", "saving")]
        await chef.load()

        chef.dismiss("a")

        #expect(shown == ["a"])
        #expect(phone.undo.banner == nil)
    }

    @Test func clearAllTidiesEveryCardButThoseStillSaving() async {
        server.cards = [card("a"), card("b", "saving"), card("c", "saved", recipe: "r"), card("d", "failed")]
        await chef.load()
        let clear = Call(method: "POST", path: "/api/suggestions/clear")

        chef.clear(.everything)
        #expect(shown == ["b"])
        #expect(phone.undo.banner?.message == "Cleared 3 suggestions")

        phone.undo.undoTapped()
        #expect(shown == ["a", "b", "c", "d"])
        #expect(calls(clear) == 0)

        chef.clear(.everything)
        phone.undo.commitNow()
        await eventually { calls(clear) == 1 }
        #expect(body(of: clear)?["ids"] as? [String] == ["a", "c", "d"])
        // The request the web sends, which takes a named card whatever its answer.
        #expect(body(of: clear)?["only_new"] == nil)
    }

    @Test func clearingOneCardSaysOneAndClearingNoneSaysNothing() async {
        server.cards = [card("a")]
        await chef.load()
        chef.clear(.everything)
        #expect(phone.undo.banner?.message == "Cleared 1 suggestion")
        phone.undo.commitNow()
        await eventually { shown.isEmpty && chef.feed == .empty }

        chef.clear(.everything)
        #expect(phone.undo.banner == nil)
    }

    @Test func clearingHomesPicksTidiesEveryFreshCardAndLeavesTheRest() async {
        server.cards = [
            card("a"), card("b", "saving"), card("c", "saved", recipe: "r"), card("d", "failed"),
            card("e"), card("f"), card("g"),
        ]
        await chef.load()
        let clear = Call(method: "POST", path: "/api/suggestions/clear")
        #expect(chef.picks.shown.map(\.id) == ["a", "e", "f"])

        chef.clear(.picks)
        #expect(chef.picks.shown.isEmpty)
        #expect(shown == ["b", "c", "d"])
        #expect(phone.undo.banner?.message == "Cleared 4 suggestions")

        phone.undo.undoTapped()
        #expect(chef.picks.shown.map(\.id) == ["a", "e", "f"])
        #expect(calls(clear) == 0)

        chef.clear(.picks)
        phone.undo.commitNow()
        await eventually { calls(clear) == 1 }
        #expect(body(of: clear)?["ids"] as? [String] == ["a", "e", "f", "g"])
        #expect(body(of: clear)?["only_new"] as? Bool == true)
    }

    @Test func aPickSavedElsewhereSinceThePhoneReadItIsBackOnDiscoverOnceTheServerHasKeptIt() async {
        server.cards = [card("a"), card("b")]
        await chef.load()
        serverAnswers { [server, card] call in
            if call.path == "/api/suggestions/clear" { server.cards = [card("b", "saved", nil, "r")] }
            return nil
        }

        chef.clear(.picks)
        #expect(shown.isEmpty)
        phone.undo.commitNow()

        await eventually { shown == ["b"] }
        #expect(stage("b") == .saved("r"))
        #expect(chef.picks.shown.isEmpty)
    }

    /// Gone while the feed cannot be read, and not hidden for ever: the next feed read decides.
    @Test func clearedCardsStayGoneWhenTheFeedCannotBeReadAfterwards() async {
        server.cards = [card("a"), card("b", "saving")]
        await chef.load()
        serverAnswers { [getFeed] in $0 == getFeed ? .unreachable : nil }

        chef.clear(.picks)
        phone.undo.commitNow()
        await eventually { calls(Call(method: "POST", path: "/api/suggestions/clear")) == 1 }
        await eventually { calls(getFeed) >= 2 }
        await chef.load()
        #expect(shown == ["b"])

        serverAnswers()
        for _ in 0..<50 where shown != ["a", "b"] {
            await chef.load()
            await Task.yield()
        }
        #expect(shown == ["a", "b"])
    }

    @Test func aScreenThatOnlyShowsTheFeedAsksOnceAndAgainOnlyAfterAFailure() async {
        phone.serverIsUnreachable()
        await chef.loadIfNeeded()
        #expect(calls(getFeed) == 1)

        serverAnswers()
        server.cards = [card("a")]
        await chef.loadIfNeeded()
        #expect(calls(getFeed) == 2)
        #expect(shown == ["a"])

        await chef.loadIfNeeded()
        #expect(calls(getFeed) == 2)
    }

    @Test func clearingPicksWhenNoneIsFreshSaysNothing() async {
        server.cards = [card("c", "saved", recipe: "r"), card("d", "failed")]
        await chef.load()

        chef.clear(.picks)

        #expect(phone.undo.banner == nil)
        #expect(shown == ["c", "d"])
    }

    @Test func aRefreshThatFailsKeepsThePicksHomeAlreadyHad() async {
        server.cards = [card("a")]
        await chef.load()
        #expect(chef.hasAnswered)

        phone.serverIsUnreachable()
        await chef.load()

        #expect(chef.picks.shown.map(\.id) == ["a"])
    }

    @Test func aFeedThatNeverLoadedHasAnsweredOnceItHasFailed() async {
        #expect(!chef.hasAnswered)
        phone.serverIsUnreachable()
        await chef.load()

        #expect(chef.hasAnswered)
        #expect(chef.picks.shown.isEmpty)
    }

    @Test func aFeedAskedForBeforeAClearWasSentDoesNotBringTheCardsBack() async {
        server.cards = [card("a"), card("b")]
        await chef.load()
        let stale = server.json
        chef.clear(.picks)
        var feedsAsked = 0
        serverAnswers { [server, getFeed] call in
            if call.path == "/api/suggestions/clear" { server.cards = [] }
            guard call == getFeed else { return nil }
            feedsAsked += 1
            return feedsAsked == 1 ? .status(200, stale) : nil
        }
        phone.transport.holding = true
        Task { await chef.load() }
        await eventually { calls(getFeed) == 2 }

        phone.undo.commitNow()
        await eventually { calls(Call(method: "POST", path: "/api/suggestions/clear")) == 1 }
        phone.transport.release()

        await eventually { calls(getFeed) == 3 }
        await eventually { chef.feed == .empty }
        #expect(chef.picks.shown.isEmpty)
    }

    @Test func findingIdeasAsksOnceShowsItIsWorkingAndThenLoadsTheNewCards() async {
        await chef.load()
        let refresh = Call(method: "POST", path: "/api/suggestions/refresh")
        phone.transport.holding = true

        chef.findIdeas()
        chef.findIdeas()
        #expect(chef.isFindingIdeas)
        await eventually { calls(refresh) == 1 }

        server.cards = [card("new")]
        phone.transport.release()
        await eventually { !chef.isFindingIdeas }

        #expect(calls(refresh) == 1)
        #expect(shown == ["new"])
        #expect(body(of: refresh) as? [String: String] == ["diet": "any", "ease": "any", "notes": ""])
    }

    @Test func tunedSettingsSteerThisBatchAndAreRememberedAcrossARelaunch() async {
        let tuned = TuneSettings(diet: .vegetarian, effort: .involved, notes: "more fish")
        let refresh = Call(method: "POST", path: "/api/suggestions/refresh")

        chef.findIdeas(tuned: tuned)
        await eventually { !chef.isFindingIdeas }
        #expect(body(of: refresh) as? [String: String] == ["diet": "vegetarian", "ease": "involved", "notes": "more fish"])

        phone.relaunch()
        #expect(phone.chef.tune == tuned)
    }

    @Test func ideasThatCannotBeFetchedSaySoAndLeaveTheFeedAlone() async {
        server.cards = [card("a")]
        await chef.load()
        serverAnswers { $0.method == "POST" ? .status(500) : nil }

        chef.findIdeas()
        await eventually { !chef.isFindingIdeas }

        #expect(phone.undo.banner?.message == "Couldn't get new ideas right now. Try again in a bit.")
        #expect(phone.undo.banner?.canUndo == false)
        #expect(shown == ["a"])
    }

    @Test func aSavedCardGoesOnTheListAsItsRecipe() async {
        server.cards = [card("a", "saved", recipe: "soup")]
        await chef.load()
        await phone.library.refresh()
        let add = Call(method: "POST", path: "/api/lists/list/recipes")

        await chef.addToList("a", to: .current)

        #expect(body(of: add) as? [String: String] == ["recipe_id": "soup"])
        #expect(phone.undo.banner?.message == "Added Card a to Week")
    }

    @Test func anUnsavedCardIsSavedOntoTheListAndTheListIsFetchedWhenTheRecipeLands() async {
        server.cards = [card("a")]
        await chef.load()
        await phone.library.refresh()
        let save = Call(method: "POST", path: "/api/suggestions/a/save")
        let getList = Call(method: "GET", path: "/api/lists/list")
        serverAnswers { [server] call in
            if call == save { server.cards = [self.card("a", "saving")] }
            return nil
        }

        await chef.addToList("a", to: .list("list"))

        #expect(body(of: save) as? [String: String] == ["list_id": "list"])
        #expect(phone.undo.banner?.message == "Saving Card a. It goes on Week when it's ready.")
        #expect(phone.undo.banner?.canUndo == false)
        #expect(stage("a") == .saving)
        await eventually { phone.ticker.isWaiting }
        let fetchesBefore = calls(getList)

        server.cards = [card("a", "saved", recipe: "soup")]
        phone.ticker.tick()

        await eventually { calls(getList) == fetchesBefore + 1 }
        #expect(stage("a") == .saved("soup"))
    }

    /// The picker in Plan drops a failed card, so there the banner is all that says the meal is not coming.
    @Test func aCardSentToAListWhoseRecipeCouldNotBeMadeSaysSo() async {
        server.cards = [card("a"), card("b")]
        await chef.load()
        await phone.library.refresh()
        serverAnswers { [server] call in
            if call.path == "/api/suggestions/a/save" { server.cards = [self.card("a", "saving"), self.card("b", "saving")] }
            return nil
        }
        await chef.addToList("a", to: .list("list"))
        await eventually { phone.ticker.isWaiting }

        server.cards = [card("a", "failed"), card("b", "failed")]
        phone.ticker.tick()

        await eventually { stage("a") == .failed }
        #expect(phone.undo.banner?.message == "Couldn't save Card a, so it isn't on your list.")
    }

    @Test func aCardSentToAListThatIsGivenUpOnSaysSoToo() async {
        server.cards = [card("a")]
        await chef.load()
        await phone.library.refresh()
        serverAnswers { [server] call in
            if call.path == "/api/suggestions/a/save" { server.cards = [self.card("a", "saving")] }
            return nil
        }
        await chef.addToList("a", to: .list("list"))

        await pollAfter(Chef.giveUpAfter)

        await eventually { stage("a") == .failed }
        #expect(phone.undo.banner?.message == "Couldn't save Card a, so it isn't on your list.")
    }

    @Test func severalCardsFailingTogetherAreSaidInOneBanner() async {
        server.cards = [card("a"), card("b")]
        await chef.load()
        await phone.library.refresh()
        serverAnswers { [server] call in
            if call.path == "/api/suggestions/a/save" { server.cards = [self.card("a", "saving"), self.card("b")] }
            if call.path == "/api/suggestions/b/save" { server.cards = [self.card("a", "saving"), self.card("b", "saving")] }
            return nil
        }
        await chef.addToList("a", to: .list("list"))
        await chef.addToList("b", to: .list("list"))
        await eventually { phone.ticker.isWaiting }

        server.cards = [card("a", "failed"), card("b", "failed")]
        phone.ticker.tick()

        await eventually { stage("b") == .failed }
        #expect(phone.undo.banner?.message == "Couldn't save 2 meals, so they aren't on your list.")
    }

    @Test func aSaveThatHasFailedByTheTimeItIsAnsweredIsNotPromised() async {
        server.cards = [card("a")]
        await chef.load()
        await phone.library.refresh()
        serverAnswers { [server] call in
            if call.path == "/api/suggestions/a/save" { server.cards = [self.card("a", "failed")] }
            return nil
        }

        await chef.addToList("a", to: .list("list"))

        #expect(phone.undo.banner?.message == "Couldn't save Card a, so it isn't on your list.")
    }

    @Test func aFailedSaveNeverCostsAnUndoThatIsStillOnOffer() async {
        server.cards = [card("a")]
        await chef.load()
        await phone.library.refresh()
        serverAnswers { [server] call in
            if call.path == "/api/suggestions/a/save" { server.cards = [self.card("a", "saving")] }
            return nil
        }
        await chef.addToList("a", to: .list("list"))
        await eventually { phone.ticker.isWaiting }
        phone.store.removeMeal("curry", title: "Curry")

        server.cards = [card("a", "failed")]
        phone.ticker.tick()
        await eventually { stage("a") == .failed }
        #expect(phone.undo.banner?.message == "Removed Curry and its ingredients")
        #expect(phone.undo.banner?.canUndo == true)

        phone.undo.undoTapped()
        #expect(phone.store.replica.current?.recipes == ["curry"])
        #expect(phone.undo.banner?.message == "Couldn't save Card a, so it isn't on your list.")
    }

    /// A save with no list behind it fails on its card, which is on screen.
    @Test func aPlainSaveThatFailsLeavesTheBannerAlone() async {
        server.cards = [card("a")]
        await chef.load()
        serverAnswers { [server] call in
            if call.path == "/api/suggestions/a/save" { server.cards = [self.card("a", "saving")] }
            return nil
        }
        chef.save("a")
        await eventually { phone.ticker.isWaiting }

        server.cards = [card("a", "failed")]
        phone.ticker.tick()

        await eventually { stage("a") == .failed }
        #expect(phone.undo.banner == nil)
    }

    @Test func aCardThatCannotBeSavedOntoAListSaysSo() async {
        server.cards = [card("a")]
        await chef.load()
        await phone.library.refresh()
        serverAnswers { $0.method == "POST" ? .unreachable : nil }

        await chef.addToList("a", to: .current)

        #expect(phone.undo.banner?.message == "Couldn't add Card a. Try again.")
        #expect(stage("a") == .unsent)
    }

    private var picks: [SuggestionID] {
        MealMenu(recipes: [], cards: chef.visible, onList: [], search: "").picks.map(\.id)
    }

    /// The web's picker keeps a card whose request could not be sent, so it is tapped again there.
    @Test func aPickWhoseSaveCouldNotBeSentIsStillAPickAndASecondTapSendsIt() async {
        server.cards = [card("a")]
        await chef.load()
        await phone.library.refresh()
        serverAnswers { $0.method == "POST" ? .unreachable : nil }

        await chef.addToList("a", to: .list("list"))
        #expect(picks == ["a"])

        serverAnswers { [server] call in
            if call.path == "/api/suggestions/a/save" { server.cards = [self.card("a", "saving")] }
            return nil
        }
        await chef.addToList("a", to: .list("list"))
        #expect(phone.undo.banner?.message == "Saving Card a. It goes on Week when it's ready.")
        #expect(picks == ["a"])
    }

    /// The picker has no way to send a save again, so a card the server could not make a recipe of leaves it.
    @Test func aPickTheServerCouldNotSaveLeavesThePicker() async {
        server.cards = [card("a")]
        await chef.load()
        await phone.library.refresh()
        serverAnswers { [server] call in
            if call.path == "/api/suggestions/a/save" { server.cards = [self.card("a", "failed")] }
            return nil
        }

        await chef.addToList("a", to: .list("list"))

        #expect(picks == [])
    }

    @Test func addingACardWhoseSaveIsAlreadyOnTheWireNeverSaysItFailed() async {
        server.cards = [card("a")]
        await chef.load()
        await phone.library.refresh()
        let newList = Call(method: "POST", path: "/api/lists/")
        let save = Call(method: "POST", path: "/api/suggestions/a/save")
        serverAnswers { $0 == newList ? .status(200, #"{"id":"new","name":"10th October","created_at":null}"#) : nil }
        phone.transport.holding = true
        let adding = Task { await chef.addToList("a", to: .new) }
        await eventually { phone.transport.calls.contains(newList) }
        chef.save("a")
        await eventually { phone.transport.calls.contains(save) }

        phone.transport.release(only: newList)
        await adding.value

        #expect(phone.undo.banner?.message == "Already saving Card a.")
        #expect(stage("a") == .saving)
        phone.transport.release()
    }
}
