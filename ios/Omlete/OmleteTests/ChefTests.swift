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
        async let first: Void = chef.load()
        async let second: Void = chef.load()
        _ = await (first, second)

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

        await eventually { phone.ticker.isWaiting }
        #expect(stage("a") == .saving)
        #expect(calls(getFeed) == 3)
    }

    @Test func aSaveTheServerNeverFinishesIsGivenUpOnSoTheCardCanBeDismissed() async {
        server.cards = [card("a", "saving")]
        await chef.load()

        for _ in 0..<Chef.mostPolls {
            await eventually { phone.ticker.isWaiting }
            phone.ticker.tick()
        }
        await eventually { stage("a") == .failed }
        #expect(!phone.ticker.isWaiting)

        await chef.load()
        #expect(stage("a") == .failed)
        chef.dismiss("a")
        #expect(shown.isEmpty)
    }

    @Test func aFeedLoadedWithACardAlreadySavingIsPolledToo() async {
        server.cards = [card("a", "saving")]

        await chef.load()
        await eventually { phone.ticker.isWaiting }

        server.cards = [card("a", "failed")]
        phone.ticker.tick()
        await eventually { stage("a") == .failed }
    }

    @Test func aSaveThatCannotBeSentFailsTheCardAndCanBeTriedAgain() async {
        server.cards = [card("a")]
        await chef.load()
        serverAnswers { $0.method == "POST" ? .unreachable : nil }

        chef.save("a")
        await eventually { stage("a") == .failed }

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

        chef.clearAll()
        #expect(shown == ["b"])
        #expect(phone.undo.banner?.message == "Cleared 3 suggestions")

        phone.undo.undoTapped()
        #expect(shown == ["a", "b", "c", "d"])
        #expect(calls(clear) == 0)

        chef.clearAll()
        phone.undo.commitNow()
        await eventually { calls(clear) == 1 }
        #expect(body(of: clear)?["ids"] as? [String] == ["a", "c", "d"])
    }

    @Test func clearingOneCardSaysOneAndClearingNoneSaysNothing() async {
        server.cards = [card("a")]
        await chef.load()
        chef.clearAll()
        #expect(phone.undo.banner?.message == "Cleared 1 suggestion")
        phone.undo.commitNow()
        await eventually { shown.isEmpty && chef.feed == .empty }

        chef.clearAll()
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

        chef.clearPicks()
        #expect(chef.picks.shown.isEmpty)
        #expect(shown == ["b", "c", "d"])
        #expect(phone.undo.banner?.message == "Cleared 4 suggestions")

        phone.undo.undoTapped()
        #expect(chef.picks.shown.map(\.id) == ["a", "e", "f"])
        #expect(calls(clear) == 0)

        chef.clearPicks()
        phone.undo.commitNow()
        await eventually { calls(clear) == 1 }
        #expect(body(of: clear)?["ids"] as? [String] == ["a", "e", "f", "g"])
    }

    @Test func clearingPicksWhenNoneIsFreshSaysNothing() async {
        server.cards = [card("c", "saved", recipe: "r"), card("d", "failed")]
        await chef.load()

        chef.clearPicks()

        #expect(phone.undo.banner == nil)
        #expect(shown == ["c", "d"])
    }

    @Test func aFeedThatFailsToLoadGivesHomeNoPicks() async {
        phone.serverIsUnreachable()
        await chef.load()

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

        for _ in 0..<Chef.mostPolls {
            await eventually { phone.ticker.isWaiting }
            phone.ticker.tick()
        }

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
        #expect(stage("a") == .failed)
    }
}
