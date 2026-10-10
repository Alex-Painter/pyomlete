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
        let done: CheckedContinuation<APIError?, Never>
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

    /// The seam for the meal picker. The server merges the recipe's ingredients
    /// into the list, which cannot be predicted here, so this needs signal: it
    /// runs inside the sync task after the queue has drained, then refetches.
    func addMeal(_ recipe: RecipeID) async throws(APIError) {
        let failure = await withCheckedContinuation { done in
            mealRequests.append(MealRequest(recipe: recipe, done: done))
            sync(refresh: true)
        }
        if let failure { throw failure }
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
            await sendMealRequests()
            if wantsRefresh { await fetch() }
        }
    }

    /// Sends due ops in order. Returns the error that stopped it, if one did.
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

    private func sendMealRequests() async {
        while !mealRequests.isEmpty {
            let request = mealRequests.removeFirst()
            do {
                try await deps.api.addRecipe(request.recipe, to: id)
                request.done.resume(returning: nil)
            } catch {
                request.done.resume(returning: error)
            }
        }
    }

    private func failMealRequests(with failure: APIError) {
        for request in mealRequests { request.done.resume(returning: failure) }
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
        guard replica.current?.items.first(where: { $0.id == item })?.category == guess else { return }
        apply(.patch(item, .category(category)))
    }

    private func persist() {
        deps.disk.save(replica)
    }
}
