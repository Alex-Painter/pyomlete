import Foundation
import Observation

struct ChefDependencies {
    let api: APIClient
    let undo: UndoCenter
    /// Lists belong to `Library`; Chef reaches them only through its intents.
    let library: Library
    /// Where the Tune settings are remembered.
    var defaults: UserDefaults = .standard
    var now: () -> Date = { .now }
    var pause: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}

/// App-wide owner of Discover's suggestions, beside `Library` and `Kitchen`,
/// and the only writer of them. Chef is the name the app gives to whatever
/// fills the feed.
///
/// Every intent returns at once or awaits only its own short request. The
/// slow work (a model finding ideas, a card becoming a recipe) runs in tasks
/// Chef owns, so leaving Discover cannot cancel it.
///
/// Invariant: while any card is saving and the server can be reached, exactly
/// one task is polling the feed. It stops when none is saving, which always
/// comes: the server answers a save it lost as failed, and a card the server
/// still calls saving `giveUpAfter` after the phone first saw it so is shown
/// as failed. That takes hearing from the server after the time is up: a
/// fetch that fails decides nothing about a card. Polling still ends when the
/// server cannot be reached: after `restAfterUnanswered` failed fetches in a
/// row with a save past its time, it rests, with the card left saving and
/// nothing said, until the next `load()`. A clock put back fails no card: the
/// card's time starts again from the earlier reading.
@Observable final class Chef {
    static let pollEvery: Duration = .seconds(3)
    /// How long after the phone first saw a card saving it stops believing so.
    /// Longer than the server's own bound, so the server's answer comes first
    /// and this only ends a save for a server that never says.
    static let giveUpAfter = RecipeIntake.serverGivesUpAfter + 2 * 60
    /// How many fetches in a row may fail, with a save past its time, before polling rests.
    static let restAfterUnanswered = 3
    private static let tuneKey = "discover.tune"

    /// The feed as the server last gave it, newest first.
    private var cards: [Suggestion] = []
    /// Cards taken off screen by "Not for me" or a Clear, until the server has been told.
    private var hidden: Set<SuggestionID> = []
    private var loadFailure: APIError?
    private var hasLoaded = false
    private(set) var isFindingIdeas = false
    private(set) var tune: TuneSettings

    @ObservationIgnored private let deps: ChefDependencies
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var polling: Task<Void, Never>?
    /// Cards whose save request is on the wire: a feed fetched meanwhile may not know yet.
    @ObservationIgnored private var posting: Set<SuggestionID> = []
    /// Feed fetches begun so far, which numbers them in the order they were asked for.
    @ObservationIgnored private var fetchesBegun = 0
    /// Cards whose save request has been answered, each with the number of the
    /// first fetch asked for afterwards. An earlier one may not know of the
    /// save, so it does not decide the card.
    @ObservationIgnored private var decidedFrom: [SuggestionID: Int] = [:]
    /// The list a card's latest save was sent to, kept while the card is
    /// saving or failed so that Try again sends it there again.
    @ObservationIgnored private var sentTo: [SuggestionID: ListID] = [:]
    /// Fetches that have failed in a row while a save was past its time.
    @ObservationIgnored private var unanswered = 0
    /// A save the phone is waiting on, from when it first saw the card saving.
    private struct Save {
        var seen: Date
        /// The list the card was sent to, which is refreshed when the recipe lands.
        var list: ListID?
        /// The server still says saving and the phone no longer believes it, so the card shows as failed.
        var givenUp = false
    }

    /// Every card the server has yet to answer for, each with its own clock.
    @ObservationIgnored private var saves: [SuggestionID: Save] = [:]

    init(deps: ChefDependencies) {
        self.deps = deps
        let saved = deps.defaults.data(forKey: Self.tuneKey)
        tune = saved.flatMap { try? JSONDecoder().decode(TuneSettings.self, from: $0) } ?? TuneSettings()
    }

    var feed: DiscoverFeed {
        let visible = visible
        if !visible.isEmpty { return .shelves(Shelf.shelves(of: visible)) }
        if hasLoaded { return .empty }
        return loadFailure.map { .unavailable($0) } ?? .loading
    }

    /// The cards on screen, in feed order: what `feed` shelves and the meal picker picks from.
    var visible: [Suggestion] {
        cards.filter { !hidden.contains($0.id) }
    }

    /// Fetches the feed. A call made while one is running joins it.
    func load() async {
        if let loading { return await loading.value }
        let task = Task {
            await fetch()
            // Cleared here, not by the caller: a waiter that resumes first must not join a fetch that is over.
            loading = nil
        }
        loading = task
        await task.value
    }

    /// Asks for a new batch of cards, which takes a model a while. `tuned`
    /// replaces the remembered settings first. Ignored while one is running.
    func findIdeas(tuned: TuneSettings? = nil) {
        if let tuned {
            tune = tuned
            deps.defaults.set(try? JSONEncoder().encode(tuned), forKey: Self.tuneKey)
        }
        guard !isFindingIdeas else { return }
        isFindingIdeas = true
        Task {
            do {
                try await deps.api.findIdeas(tune)
            } catch {
                deps.undo.offer("Couldn't get new ideas right now. Try again in a bit.")
            }
            // Either way: a request that timed out here may still have finished on the server.
            await reload()
            isFindingIdeas = false
        }
    }

    /// Turns a card into a recipe. The card says "saving" at once; the recipe
    /// is made on the server and the poll picks it up. This is also Try again,
    /// which sends a card that failed on its way to a list to that list again.
    func save(_ id: SuggestionID) {
        Task { await send(id, onto: sentTo[id]) }
    }

    /// A saved card's recipe goes on the list now. Any other card is saved
    /// first, and the server puts it on the list when the recipe exists.
    func addToList(_ id: SuggestionID, to target: ListTarget) async {
        guard let card = cards.first(where: { $0.id == id }) else { return }
        switch card.stage {
        case .saved(let recipe):
            await deps.library.addMeal(recipe, title: card.title, to: target)
        case .saving:
            return
        case .fresh, .failed:
            // Saving from this moment, so a second tap while the list is found is the `.saving` case above.
            setStage(of: id, to: .saving)
            guard let list = try? await deps.library.resolve(target), await send(id, onto: list.id) else {
                if cards.first(where: { $0.id == id })?.stage == .saving, !posting.contains(id) {
                    setStage(of: id, to: .failed)
                }
                deps.undo.offer("Couldn't add \(card.title). Try again.")
                return
            }
            deps.library.markCurrent(list.id)
            // The save can fail before `send` returns, and then the banner has already said so.
            if cards.first(where: { $0.id == id })?.stage == .failed { return }
            deps.undo.offer("Saving \(card.title). It goes on \(list.name) when it's ready.")
        }
    }

    /// "Not for me": hides the card at once and, unless undone, tells the
    /// server, which suggests less like it. Not offered while the card is
    /// saving, because the finished save would bring it back.
    func dismiss(_ id: SuggestionID) {
        guard let card = cards.first(where: { $0.id == id }), card.stage != .saving else { return }
        hide([id], saying: "Hid \(card.title). You'll see less like it.") { [api = deps.api] in
            try await api.dismissSuggestion(id)
        }
    }

    /// What Home shows of the feed, and what its Clear covers.
    /// The feed has loaded, or tried and failed: there is nothing more to wait for.
    var hasAnswered: Bool { hasLoaded || loadFailure != nil }

    var picks: ChefPicks {
        ChefPicks(cards: visible)
    }

    /// Tidies every card off the feed except those still saving. Not a taste
    /// signal: the server learns nothing from it.
    func clearAll() {
        clear(visible.filter { $0.stage != .saving })
    }

    /// Home's Clear: only the ideas nobody has acted on. A saved or failed
    /// card is not on Home, so clearing it from there would remove something
    /// the user never saw go.
    func clearPicks() {
        clear(picks.fresh)
    }

    private func clear(_ cards: [Suggestion]) {
        let ids = cards.map(\.id)
        guard !ids.isEmpty else { return }
        hide(ids, saying: "Cleared \(ids.count) suggestion\(ids.count == 1 ? "" : "s")") { [api = deps.api] in
            try await api.clearSuggestions(ids)
        }
    }

    /// If the server cannot be told, the cards stay hidden until the next
    /// launch rather than reappearing under the user's thumb.
    private func hide(_ ids: [SuggestionID], saying message: String, tell: @escaping () async throws -> Void) {
        hidden.formUnion(ids)
        deps.undo.offer(message, undo: { [weak self] in
            self?.hidden.subtract(ids)
        }, commit: { [weak self] in
            Task {
                guard (try? await tell()) != nil else { return }
                // A feed asked for before the server was told still lists these cards, so they
                // stay hidden until one asked for afterwards has been adopted.
                await self?.reload()
                self?.forget(ids)
            }
        })
    }

    private func forget(_ ids: [SuggestionID]) {
        cards.removeAll { ids.contains($0.id) }
        hidden.subtract(ids)
    }

    /// Returns whether the server took the request.
    private func send(_ id: SuggestionID, onto list: ListID?) async -> Bool {
        guard !posting.contains(id) else { return false }
        posting.insert(id)
        saves[id] = Save(seen: deps.now(), list: list)
        sentTo[id] = list
        setStage(of: id, to: .saving)
        do {
            try await deps.api.saveSuggestion(id, onto: list)
        } catch {
            posting.remove(id)
            saves[id] = nil
            setStage(of: id, to: .failed)
            return false
        }
        posting.remove(id)
        decidedFrom[id] = fetchesBegun + 1
        await reload()
        return true
    }

    /// A fetch that began before the request just made may not show its effect, so wait it out and fetch again.
    private func reload() async {
        await loading?.value
        await load()
    }

    private func fetch() async {
        fetchesBegun += 1
        let number = fetchesBegun
        do {
            let fresh = try await deps.api.suggestions()
            adopt(fresh, fetch: number, at: timeNow())
            (hasLoaded, loadFailure, unanswered) = (true, nil, 0)
        } catch {
            loadFailure = error
            let now = timeNow()
            if saves.values.contains(where: { !$0.givenUp && isOverdue($0, at: now) }) { unanswered += 1 }
        }
        poll()
    }

    /// The clock's reading. A save first seen later than this was seen before
    /// the clock was put back, and is counted from the new reading, so its
    /// time still comes and comes no sooner.
    private func timeNow() -> Date {
        let now = deps.now()
        for (id, save) in saves where save.seen > now { saves[id]?.seen = now }
        return now
    }

    private func isOverdue(_ save: Save, at now: Date) -> Bool {
        now.timeIntervalSince(save.seen) >= Self.giveUpAfter
    }

    private func adopt(_ fresh: [Suggestion], fetch: Int, at now: Date) {
        var waiting: [SuggestionID: Save] = [:]
        var failed: [SuggestionID] = []
        var landed: [Save] = []
        var lists: [SuggestionID: ListID] = [:]
        cards = fresh.map { card in
            var card = card
            if posting.contains(card.id) || fetch < decidedFrom[card.id] ?? 0 { card.stage = .saving }
            let save = saves[card.id]
            switch card.stage {
            case .saving:
                // With no save of the phone's own, this is the first it has seen of one made elsewhere.
                var save = save ?? Save(seen: now)
                if !save.givenUp, isOverdue(save, at: now) {
                    // The backstop for a server that never says how a save ended. The save
                    // is kept, so a recipe that does land later is still taken as landed.
                    save.givenUp = true
                    failed.append(card.id)
                }
                waiting[card.id] = save
                if save.givenUp { card.stage = .failed }
                lists[card.id] = sentTo[card.id]
            case .failed:
                // A save given up on has already been said.
                if let save, !save.givenUp { failed.append(card.id) }
                lists[card.id] = sentTo[card.id]
            case .saved:
                if let save { landed.append(save) }
            case .fresh:
                break
            }
            return card
        }
        sayNotComing(failed)
        saves = waiting
        sentTo = lists
        decidedFrom = decidedFrom.filter { fetch < $0.value }
        guard !landed.isEmpty else { return }
        // A recipe exists that the library has not seen, perhaps on a list too.
        for list in landed.compactMap(\.list) { deps.library.list(list).sync(refresh: true) }
        Task { await deps.library.refresh() }
    }

    private var isWorthPolling: Bool {
        cards.contains(where: { $0.stage == .saving }) && unanswered < Self.restAfterUnanswered
    }

    private func poll() {
        guard polling == nil, isWorthPolling else { return }
        polling = Task { [weak self, pause = deps.pause] in
            while (try? await pause(Self.pollEvery)) != nil, let self {
                await load()
                if !isWorthPolling { break }
            }
            self?.polling = nil
        }
    }

    /// Every way a save ends in failure after the server took it comes
    /// through here. A meal promised to a list is not coming, and its row has
    /// left the picker in Plan, so only the banner can say so.
    private func sayNotComing(_ failed: [SuggestionID]) {
        let titles = cards.filter { failed.contains($0.id) && saves[$0.id]?.list != nil }.map(\.title)
        guard let first = titles.first else { return }
        deps.undo.inform(
            titles.count == 1
                ? "Couldn't save \(first), so it isn't on your list."
                : "Couldn't save \(titles.count) meals, so they aren't on your list.")
    }

    private func setStage(of id: SuggestionID, to stage: Suggestion.Stage) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].stage = stage
    }
}
