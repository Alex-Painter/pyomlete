import Foundation
import Observation

/// App-wide: the Home index, the aisle order, the recipe and unit caches, and
/// the registry of list stores.
///
/// Invariant: `list(_:)` returns the same `ListStore` for the same id for the
/// life of the process, so Plan, Shop and the Home row read one object.
@Observable final class Library {
    private var index: LibraryIndex
    /// Lists hidden by a delete whose Undo banner is still up.
    private var deleteOffered: Set<ListID> = []
    /// The last attempt to load the lists failed. Home shows it only when it has nothing saved.
    private(set) var loadFailure: APIError?
    private(set) var hasLoaded: Bool

    @ObservationIgnored private let deps: StoreDependencies
    @ObservationIgnored private var stores: [ListID: ListStore] = [:]
    @ObservationIgnored private var refreshing: Task<Void, Never>?

    init(deps: StoreDependencies) {
        self.deps = deps
        let saved = deps.disk.loadIndex()
        index = saved ?? LibraryIndex()
        hasLoaded = saved != nil
        for var replica in deps.disk.loadAll() {
            // A kill mid-banner commits what the banner was holding.
            replica.releaseAll()
            deps.disk.save(replica)
            stores[replica.id] = makeStore(replica)
        }
    }

    var aisleOrder: [String] { index.aisleOrder }
    var units: [String] { index.units }

    /// Home rows: the saved summaries minus lists being deleted, with the name
    /// and counts taken from the list's own replica once it has one, so a row
    /// shows unsent changes too.
    var rows: [ListSummary] {
        index.summaries
            .filter { !deleteOffered.contains($0.id) && !index.deletingLists.contains($0.id) }
            .map { summary in
                guard let replica = stores[summary.id]?.replica else { return summary }
                var row = summary
                if let list = replica.current {
                    row.name = list.name
                    row.itemCount = list.items.count
                    row.checkedCount = list.items.count(where: \.checked)
                    row.meals = list.recipes.compactMap { id in
                        meal(id).map { ListSummary.Meal(id: id, title: $0.title) }
                    }
                } else if let name = replica.pendingName {
                    row.name = name
                }
                return row
            }
    }

    /// A meal's title and picture: from the recipe cache, else the title the lists endpoint gave.
    func meal(_ id: RecipeID) -> RecipeSummary? {
        if let recipe = index.recipes.first(where: { $0.id == id }) { return recipe }
        let title = index.summaries.lazy.flatMap(\.meals).first(where: { $0.id == id })?.title
        return title.map { RecipeSummary(id: id, title: $0, imageURL: nil) }
    }

    /// The one way to get a list's store.
    func list(_ id: ListID) -> ListStore {
        if let store = stores[id] { return store }
        let store = makeStore(ListReplica(id: id))
        stores[id] = store
        return store
    }

    /// Loads the lists, aisles, recipes and units. A call made while one is running joins it.
    func refresh() async {
        if let refreshing { return await refreshing.value }
        let task = Task { await load() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func load() async {
        async let lists = result { () async throws(APIError) in try await deps.api.lists() }
        async let aisles = result { () async throws(APIError) in try await deps.api.aisleOrder() }
        async let recipes = result { () async throws(APIError) in try await deps.api.recipes() }
        async let units = result { () async throws(APIError) in try await deps.api.units() }

        switch await lists {
        case .success(let summaries):
            index.summaries = summaries
            index.deletingLists.formIntersection(summaries.map(\.id))
            (hasLoaded, loadFailure) = (true, nil)
        case .failure(let failure):
            loadFailure = failure
        }
        if case .success(let aisles) = await aisles { index.aisleOrder = aisles }
        if case .success(let recipes) = await recipes { index.recipes = recipes }
        if case .success(let units) = await units { index.units = units }
        // A saved index is what says the lists were loaded once, so a first load that failed must not write one.
        if hasLoaded { save() }
    }

    func newList() async throws(APIError) -> ListID {
        let created = try await deps.api.createList()
        index.summaries.insert(created, at: 0)
        save()
        return created.id
    }

    func duplicate(_ id: ListID) async throws(APIError) -> ListID {
        var copy = try await deps.api.duplicateList(id)
        if let source = rows.first(where: { $0.id == id }) {
            // The server copies the items unchecked, and the meals with them.
            copy.itemCount = source.itemCount
            copy.meals = source.meals
        }
        index.summaries.insert(copy, at: 0)
        save()
        return copy.id
    }

    /// Hides the list at once and offers Undo. The DELETE goes out when the
    /// banner settles; if it cannot, the id is saved and `syncAll` retries.
    func delete(_ id: ListID) {
        guard let name = rows.first(where: { $0.id == id })?.name else { return }
        deleteOffered.insert(id)
        deps.undo.offer("Deleted \(name)", undo: { [weak self] in
            self?.deleteOffered.remove(id)
        }, commit: { [weak self] in
            guard let self else { return }
            index.deletingLists.insert(id)
            deleteOffered.remove(id)
            save()
            sendDelete(id)
        })
    }

    /// Flushes everything unsent. Called when the app comes to the front and
    /// when the network returns.
    func syncAll() {
        for store in stores.values where !store.replica.pending.isEmpty { store.sync() }
        for id in index.deletingLists { sendDelete(id) }
    }

    private func sendDelete(_ id: ListID) {
        Task { await confirmDelete(id) }
    }

    private func confirmDelete(_ id: ListID) async {
        do {
            try await deps.api.deleteList(id)
        } catch where error.isRetryable {
            return
        } catch {
            // Already gone, which is what was asked for.
        }
        index.summaries.removeAll { $0.id == id }
        index.deletingLists.remove(id)
        stores[id] = nil
        deps.disk.discard(id)
        save()
    }

    private func makeStore(_ replica: ListReplica) -> ListStore {
        ListStore(replica: replica, deps: deps, aisleOrder: { [weak self] in self?.index.aisleOrder ?? [] })
    }

    private func save() {
        deps.disk.save(index)
    }

    private func result<Value: Sendable>(_ call: () async throws(APIError) -> Value) async -> Result<Value, APIError> {
        do {
            return .success(try await call())
        } catch {
            return .failure(error)
        }
    }
}
