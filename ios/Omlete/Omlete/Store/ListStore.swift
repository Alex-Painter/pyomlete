import Foundation
import Observation

enum ListPhase: Equatable {
    case loading
    case ready(ListDetail)
    /// Never fetched, and the fetch failed. Only a list not yet on this phone can be here.
    case unavailable
    case gone
}

enum SyncStatus: Equatable {
    case synced
    case syncing(Int)
    case offline

    var pillText: String? {
        switch self {
        case .synced: nil
        case .syncing: "Syncing"
        case .offline: "Offline, saved here"
        }
    }
}

struct StoreDependencies {
    let api: APIClient
    let disk: any ReplicaStorage
    let undo: UndoCenter
    let connectivity: Connectivity
    var newID: () -> String = { UUID().uuidString.lowercased() }
    /// First wait before retrying a failed send; it doubles up to a minute. nil never retries on a timer.
    var retryDelay: Duration? = .seconds(2)
}

/// One list on this phone, shared by Plan, Shop and its Home row. Handed out
/// only by `Library.list(_:)`, so there is one instance per list and nothing
/// to invalidate.
///
/// The only writer of its replica. Every mutator is synchronous: change the
/// replica, save it, kick the sync. A view never awaits a list change.
///
/// Invariant: at most one request for this list is in flight. The single sync
/// task sends due ops in order and fetches only after the queue has drained,
/// so a GET can never miss an op that is still on the wire.
@Observable final class ListStore {
    let id: ListID
    private(set) var replica: ListReplica
    private(set) var isGone = false
    private var fetchFailed = false
    private var serverUnreachable = false
    /// Recipes on their way onto the list: asked for, and not yet answered and fetched.
    private(set) var mealsBeingAdded: Set<RecipeID> = []

    @ObservationIgnored private let deps: StoreDependencies
    @ObservationIgnored private let aisleOrder: () -> [String]
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var kicked = false
    @ObservationIgnored private var wantsRefresh = false
    @ObservationIgnored private var failedSends = 0
    @ObservationIgnored private var mealRequests: [MealRequest] = []

    private struct MealRequest {
        let recipe: RecipeID
        let done: CheckedContinuation<Result<MealAdd, APIError>, Never>
    }

    init(replica: ListReplica, deps: StoreDependencies, aisleOrder: @escaping () -> [String]) {
        self.id = replica.id
        self.replica = replica
        self.deps = deps
        self.aisleOrder = aisleOrder
    }

    var phase: ListPhase {
        if isGone { return .gone }
        if let list = replica.current { return .ready(list) }
        return fetchFailed ? .unavailable : .loading
    }

    var syncStatus: SyncStatus {
        if !deps.connectivity.isOnline || serverUnreachable { return .offline }
        return replica.unsentCount > 0 ? .syncing(replica.unsentCount) : .synced
    }

    /// Parses the text and adds each item under a locally guessed aisle. The
    /// server's answer replaces the guess later, unless the user moved the item first.
    func add(_ text: String) {
        for parsed in parseItems(text) {
            let guess = guessCategory(parsed.name, categories: aisleOrder(), existing: replica.current?.items ?? [])
            let item = ListItem(
                id: ItemID(deps.newID()), name: parsed.name, amount: parsed.amount, unit: parsed.unit,
                category: guess, checked: false, sources: [ItemSource(recipeID: nil, amount: parsed.amount)])
            apply(.add(item))
            Task { [weak self, api = deps.api] in
                guard let category = try? await api.categorize(parsed.name), category != guess else { return }
                self?.recategorize(item.id, from: guess, to: category)
            }
        }
    }

    func update(_ item: ItemID, _ patch: ItemPatch) {
        guard !patch.isEmpty else { return }
        apply(.patch(item, patch))
    }

    /// `undoable` (Shop) offers Undo, which queues the opposite change. The
    /// check itself is sent at once, because someone else may be shopping the same list.
    func setChecked(_ item: ItemID, _ checked: Bool, undoable: Bool = false) {
        guard let name = replica.current?.items.first(where: { $0.id == item })?.name else { return }
        apply(.patch(item, .checked(checked)))
        guard undoable else { return }
        deps.undo.offer(checked ? "Got \(name)" : "\(name) back on the list", undo: { [weak self] in
            self?.apply(.patch(item, .checked(!checked)))
        })
    }

    /// Hides the items now and sends the deletes only once Undo has had its chance.
    func remove(_ items: [ItemID], saying message: String) {
        hold(items.map(ListOp.delete), saying: message)
    }

    func removeMeal(_ recipe: RecipeID, title: String) {
        hold([.removeRecipe(recipe)], saying: "Removed \(title) and its ingredients")
    }

    func reorder(_ category: String, moving offsets: IndexSet, to destination: Int) {
        guard let list = replica.current,
              let aisle = ListLayout(list, aisleOrder: []).aisles.first(where: { $0.name == category })
        else { return }
        let ids = aisle.ids(moving: offsets, to: destination)
        guard ids != aisle.items.map(\.id) else { return }
        apply(.reorder(category: category, itemIDs: ids))
    }

    func rename(_ name: String) {
        let name = name.trimmed
        guard !name.isEmpty, name != replica.current?.name else { return }
        apply(.rename(name))
    }

    /// Puts a meal on an evening of a week list, taking off whatever was
    /// there. Works offline: the meal shows on its day at once and its
    /// ingredients arrive with the refetch once the server has it.
    func plan(_ recipe: RecipeID, on date: PlanDate) {
        if undoHeldRemoval(of: recipe), let days = replica.current?.days {
            // The meal comes back on the days it was taken off, and the server never
            // heard it left them. Planning it says where it goes now, so clear them.
            for day in days where day.plan == .meal(recipe) && day.date != date {
                apply(.setDay(day.date, .open))
            }
        }
        apply(.setDay(date, .meal(recipe)))
    }

    /// Takes the meal off its evening at once, with Undo. It stays on the list
    /// as an any-day meal, so Undo only has to put the day back.
    func clearDay(_ date: PlanDate, title: String) {
        guard let recipe = day(date)?.plan.meal else { return }
        apply(.setDay(date, .open))
        deps.undo.offer("Took \(title) off \(date.dayLong)", undo: { [weak self] in
            self?.apply(.setDay(date, .meal(recipe)))
        })
    }

    /// Out for the evening, or back in. An evening with a meal keeps it.
    func setOut(_ date: PlanDate, _ out: Bool) {
        guard let day = day(date), day.plan.meal == nil else { return }
        apply(.setDay(date, out ? .out : .open))
    }

    private func day(_ date: PlanDate) -> PlanDay? {
        replica.current?.days.first { $0.date == date }
    }

    /// Putting a meal back while its removal is still behind the Undo banner is
    /// that Undo: the server still has the meal, and the removal, sent later,
    /// would take it off again.
    private func undoHeldRemoval(of recipe: RecipeID) -> Bool {
        guard replica.pending.contains(where: { $0.held && $0.op == .removeRecipe(recipe) }) else { return false }
        deps.undo.undoTapped()
        return true
    }

    /// Puts a recipe on the list. The server merges its ingredients into the
    /// list, which cannot be predicted here, so this needs signal: it runs
    /// inside the sync task after the queue has drained, then refetches.
    @discardableResult
    func addMeal(_ recipe: RecipeID) async throws(APIError) -> MealAdd {
        if undoHeldRemoval(of: recipe) { return .added }
        mealsBeingAdded.insert(recipe)
        let result = await withCheckedContinuation { done in
            mealRequests.append(MealRequest(recipe: recipe, done: done))
            sync(refresh: true)
        }
        mealsBeingAdded.remove(recipe)
        return try result.get()
    }

    /// Undo of `addMeal`: queued like any other change, with no banner of its own.
    func takeBackMeal(_ recipe: RecipeID) {
        apply(.removeRecipe(recipe))
    }

    /// Pulls the server's copy. Safe to call at any time; joins a running sync.
    func refresh() async {
        await sync(refresh: true).value
    }

    /// Kicks the sync task, or tells the running one to go round again.
    @discardableResult
    func sync(refresh: Bool = false) -> Task<Void, Never> {
        if refresh { wantsRefresh = true }
        kicked = true
        if let syncTask { return syncTask }
        retryTask?.cancel()
        let task = Task { await run() }
        syncTask = task
        return task
    }

    private func run() async {
        defer { syncTask = nil }
        while kicked {
            kicked = false
            if let failure = await drain() {
                failMealRequests(with: failure)
                return
            }
            let answered = await sendMealRequests()
            if wantsRefresh { await fetch() }
            // After the fetch, so whoever asked finds the meal already on the list.
            for answer in answered { answer() }
        }
    }

    private func drain() async -> APIError? {
        while let next = replica.beginSend() {
            do {
                try await deps.api.send(next.op, to: id)
                replica.finishSend(.accepted)
                // Others may be editing this list; pick up their changes once ours are in.
                wantsRefresh = true
            } catch where error.isRetryable {
                replica.abortSend()
                serverUnreachable = error == .unreachable
                scheduleRetry()
                return error
            } catch {
                replica.finishSend(.rejected)
                wantsRefresh = true
            }
            serverUnreachable = false
            failedSends = 0
            persist()
        }
        return nil
    }

    private func fetch() async {
        do {
            let server = try await deps.api.list(id)
            replica.rebase(onto: server)
            (isGone, fetchFailed, serverUnreachable, wantsRefresh) = (false, false, false, false)
            persist()
        } catch where error.isNotFound {
            (isGone, wantsRefresh) = (true, false)
        } catch {
            // `wantsRefresh` stays set, so the next kick tries again.
            fetchFailed = true
            serverUnreachable = error == .unreachable
        }
    }

    private func sendMealRequests() async -> [() -> Void] {
        var answered: [() -> Void] = []
        while !mealRequests.isEmpty {
            let request = mealRequests.removeFirst()
            let result: Result<MealAdd, APIError>
            do {
                result = .success(try await deps.api.addRecipe(request.recipe, to: id))
            } catch {
                result = .failure(error)
            }
            answered.append { request.done.resume(returning: result) }
        }
        return answered
    }

    private func failMealRequests(with failure: APIError) {
        for request in mealRequests { request.done.resume(returning: .failure(failure)) }
        mealRequests = []
    }

    private func scheduleRetry() {
        guard let base = deps.retryDelay else { return }
        let delay = min(base * (1 << min(failedSends, 5)), .seconds(60))
        failedSends += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { self?.sync() }
        }
    }

    @discardableResult
    private func apply(_ op: ListOp, held: Bool = false) -> OpID {
        let opID = replica.enqueue(op, id: OpID(deps.newID()), held: held)
        persist()
        if !held { sync() }
        return opID
    }

    private func hold(_ ops: [ListOp], saying message: String) {
        guard !ops.isEmpty else { return }
        let held = Set(ops.map { apply($0, held: true) })
        deps.undo.offer(message, undo: { [weak self] in
            guard let self else { return }
            replica.cancel(held)
            persist()
        }, commit: { [weak self] in
            guard let self else { return }
            replica.release(held)
            persist()
            sync()
        })
    }

    private func recategorize(_ item: ItemID, from guess: String, to category: String) {
        // The server remembers an ingredient's aisle by name, and that aisle may since have been renamed or deleted.
        let aisles = aisleOrder()
        guard aisles.isEmpty || aisles.contains(category) else { return }
        guard replica.current?.items.first(where: { $0.id == item })?.category == guess else { return }
        apply(.patch(item, .category(category)))
    }

    private func persist() {
        deps.disk.save(replica)
    }
}
