import Foundation
import Observation

enum CookPhase: Equatable {
    case loading
    case cooking(CookSession)
    /// Never fetched, and the fetch failed. Only a recipe not yet on this phone can be here.
    case unavailable
    /// Deleted, and never cooked on this phone. A recipe you are cooking stays cookable.
    case gone
}

/// What the recipe page shows. Unlike `CookPhase` it follows the server: a
/// recipe deleted there is gone here even if it was once cooked on this phone.
enum RecipePage: Equatable {
    case loading
    case ready(Recipe)
    case unavailable
    case gone
}

/// The rating as shown: the unsent tap if there is one, else the server's.
struct RatingView: Equatable {
    enum Status: Equatable {
        case unrated
        case sent
        case savedHere

        var message: String {
            switch self {
            case .unrated: "One tap. It shapes what Discover suggests."
            case .sent: "Thanks. Discover will suggest more like this, or less."
            case .savedHere: "Saved. It will send when you're back online."
            }
        }
    }

    let stars: Int?
    let status: Status
}

/// One recipe on this phone, cooked or only looked at. Handed out only by
/// `Kitchen.cook(_:)`, so there is one instance per recipe, it outlives the
/// Cook screen, and Cook and the recipe page show the same rating.
///
/// Cook reads `phase`, whose recipe stays as it was when the cook began. The
/// recipe page reads `page`, which prefers this launch's copy from the server.
///
/// The only writer of its record. Every intent is synchronous: change the
/// record, save it, re-arm the one sleeping task. A view never awaits a tap.
///
/// Nothing here ticks. A timer is an end date; the task sleeps until the next
/// one is due and rings it, and what a chip reads is derived from the clock.
///
/// Invariant: at most one rating request for this recipe is in flight, and the
/// last one sent carries the latest tap.
@Observable final class CookStore {
    let id: RecipeID
    private var record: CookRecord?
    private var fetchFailure: APIError?
    /// The server's copy as last fetched this launch. Kept apart from the
    /// record because `CookSession.adopt` rightly refuses a new copy mid-cook.
    private var latest: Recipe?
    private var deletedOnServer = false
    private var delivery: RatingDelivery

    @ObservationIgnored private let deps: KitchenDependencies
    @ObservationIgnored private var sleeper: Task<Void, Never>?
    @ObservationIgnored private var isSendingRating = false
    @ObservationIgnored private var onListSends: Task<Void, Never>?
    /// How many edits have been saved, so a fetch can tell it was asked for before one.
    @ObservationIgnored private var saves = 0

    private enum RatingDelivery {
        case untried
        /// The last attempt could not reach the server, or was never made before a relaunch.
        case waiting
        case confirmed
    }

    init(id: RecipeID, record: CookRecord?, deps: KitchenDependencies) {
        self.id = id
        self.record = record
        self.deps = deps
        delivery = record?.unsentRating == nil ? .untried : .waiting
        arm()
    }

    var phase: CookPhase {
        if let record { return .cooking(record.session) }
        guard let fetchFailure else { return .loading }
        return fetchFailure.isNotFound ? .gone : .unavailable
    }

    /// The server has answered for this recipe this launch, so `page` is not only the copy saved on the phone.
    var hasServerCopy: Bool { latest != nil }

    var page: RecipePage {
        if deletedOnServer { return .gone }
        if let recipe = latest ?? record?.session.recipe { return .ready(recipe) }
        return fetchFailure == nil ? .loading : .unavailable
    }

    var rating: RatingView {
        let unsent = record?.unsentRating
        let status: RatingView.Status = switch delivery {
        case .confirmed: .sent
        case .waiting where unsent != nil: .savedHere
        case .waiting, .untried: .unrated
        }
        return RatingView(stars: unsent ?? record?.session.recipe.rating, status: status)
    }

    /// Called when Cook appears. Resumes or restarts per `CookSession.reopen`,
    /// then fetches: a fresh copy is adopted per `CookSession.adopt`, and a
    /// failure shows only when nothing is saved.
    func open() async {
        let now = deps.now()
        mutate { $0.session.reopen(at: now) }
        if delivery == .confirmed { delivery = .untried }
        await load()
    }

    /// Called when the recipe page appears. Fetches without touching the cook:
    /// looking at a recipe never moves its step or restarts it.
    func load() async {
        fetchFailure = nil
        await fetch(reportingFailure: true)
    }

    /// Whether an ingredient goes on shopping lists. Shows at once and flips
    /// back if the server cannot be told. Sent one at a time, in tap order.
    func setOnList(_ index: Int, _ onList: Bool) {
        guard flip(index, to: onList) else { return }
        onListSends = Task { [earlier = onListSends, api = deps.api, id] in
            await earlier?.value
            do {
                try await api.setOnList(id, ingredient: index, onList)
            } catch {
                flip(index, to: !onList)
            }
        }
    }

    /// Sends an edit and takes the server's answer as the recipe: the page
    /// shows it at once, a cook adopts it per `CookSession.adopt`, so one
    /// under way keeps the recipe it started with, and the library is told.
    /// Needs signal. An edit is never queued, so a failure is the caller's to show.
    func save(_ edit: RecipeEdit) async throws(APIError) {
        // An on-list change still on its way names its ingredient by position, which this save may move.
        await onListSends?.value
        // Only now is the on-list flag settled: a change that failed has flipped back.
        let edit = (latest ?? record?.session.recipe).map(edit.carryingUntouched) ?? edit
        let saved = try await deps.api.updateRecipe(id, edit)
        saves += 1
        take(saved)
        deps.recipeSaved(saved)
    }

    @discardableResult
    private func flip(_ index: Int, to onList: Bool) -> Bool {
        guard let shown = latest ?? record?.session.recipe, shown.ingredients.indices.contains(index),
              shown.ingredients[index].isOnList != onList
        else { return false }
        // Only the flag, on each copy: adopting a whole recipe here would take its rating too.
        if latest?.ingredients.indices.contains(index) == true { latest?.ingredients[index].isOnList = onList }
        // A cook under way may hold the recipe as it was before an edit, where this position is another ingredient.
        if record?.session.recipe.ingredients.map(\.name) == shown.ingredients.map(\.name) {
            mutate { $0.session.setOnList(index, onList) }
        }
        return true
    }

    /// Fetches a recipe not yet on this phone, without opening it.
    func warm() async {
        guard record == nil else { return }
        await fetch(reportingFailure: false)
    }

    /// Rings what ended while the app was away and sends an unsent rating.
    func resume() {
        arm()
        sendRating()
    }

    func start() { move { $0.start(now: $1) } }
    func next() { move { $0.next(now: $1) } }
    func back() { move { $0.back(now: $1) } }
    func more() { move { $0.setServings({ $0.more() }, now: $1) } }
    func fewer() { move { $0.setServings({ $0.fewer() }, now: $1) } }

    func startTimer(_ found: DetectedTimer) {
        move { $0.startTimer(found, id: UUID(), now: $1) }
    }

    func dismissTimer(_ id: UUID) {
        mutate { $0.session.dismissTimer(id) }
    }

    /// Optimistic and durable: shows at once, is saved, and is sent. If it
    /// cannot be sent now it waits for `resume()`. Never an error to dismiss.
    func rate(_ stars: Int) {
        guard record != nil else { return }
        mutate { $0.unsentRating = stars }
        if delivery == .confirmed { delivery = .untried }
        sendRating()
    }

    private func sendRating() {
        guard !isSendingRating, let stars = record?.unsentRating else { return }
        isSendingRating = true
        Task {
            let failure = await deliver(stars)
            isSendingRating = false
            settleRating(stars, failure: failure)
        }
    }

    private func deliver(_ stars: Int) async -> APIError? {
        do {
            try await deps.api.rate(id, stars: stars)
            return nil
        } catch {
            return error
        }
    }

    private func settleRating(_ sent: Int, failure: APIError?) {
        if let failure {
            if failure.isRetryable {
                delivery = .waiting
            } else {
                // The recipe is gone or the rating is refused: the stars fall back to the server's.
                mutate { $0.unsentRating = nil }
                delivery = .untried
            }
        } else if record?.unsentRating == sent {
            mutate {
                $0.unsentRating = nil
                var rated = $0.session.recipe
                rated.rating = sent
                $0.session.adopt(rated)
            }
            delivery = .confirmed
        } else {
            // Tapped again while that one was on the wire.
            sendRating()
        }
    }

    private func fetch(reportingFailure: Bool) async {
        do {
            let asked = saves
            let fresh = try await deps.api.recipe(id)
            // Asked for before an edit was saved: it is the recipe as it was, and would put it back.
            guard asked == saves else { return }
            take(fresh)
        } catch {
            if error.isNotFound { deletedOnServer = true }
            if record == nil, reportingFailure { fetchFailure = error }
        }
    }

    /// The server's copy, fetched or just saved: the page's at once, the cook's when `adopt` allows.
    private func take(_ fresh: Recipe) {
        (latest, deletedOnServer) = (fresh, false)
        if record == nil {
            let created = CookRecord(session: CookSession(recipe: fresh, now: deps.now()))
            record = created
            deps.disk.save(created)
        } else {
            mutate { $0.session.adopt(fresh) }
        }
    }

    private func move(_ change: (inout CookSession, Date) -> Void) {
        let now = deps.now()
        mutate { change(&$0.session, now) }
    }

    /// The one place a record changes: apply, save, arm. Scheduling a local
    /// notification per timer would replace the pending set here.
    private func mutate(_ change: (inout CookRecord) -> Void) {
        guard var changed = record else { return }
        change(&changed)
        guard changed != record else { return }
        record = changed
        deps.disk.save(changed)
        arm()
    }

    /// Rings what is due, once for however many, and sleeps until the next timer ends.
    private func arm() {
        sleeper?.cancel()
        sleeper = nil
        guard var rung = record else { return }
        if !rung.session.ringDue(at: deps.now()).isEmpty {
            record = rung
            deps.disk.save(rung)
            deps.chime()
        }
        guard let wake = rung.session.nextRing else { return }
        sleeper = Task { [weak self, sleepUntil = deps.sleepUntil] in
            do { try await sleepUntil(wake) } catch { return }
            if !Task.isCancelled { self?.arm() }
        }
    }
}
