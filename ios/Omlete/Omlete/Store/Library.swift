import Foundation
import Observation

/// The meals Home offers to cook, and the list they are on.
struct CookShelf: Equatable {
    let listID: ListID
    let listName: String
    /// Never empty: a list with no meals has no shelf.
    let meals: [RecipeSummary]
}

/// App-wide: the Home index, the aisle store, the recipe library and unit
/// cache, and the registry of list stores. Every way of putting a meal on a
/// list ends in `addMeal(_:title:to:)`.
///
/// Invariant: `list(_:)` returns the same `ListStore` for the same id for the
/// life of the process, so Plan, Shop and the Home row read one object.
@Observable final class Library {
    private var index: LibraryIndex
    /// Lists hidden by a delete whose Undo banner is still up.
    private var deleteOffered: Set<ListID> = []
    /// Recipes hidden by a delete whose Undo banner is still up.
    private var recipeDeleteOffered: Set<RecipeID> = []
    /// The last attempt to load the lists failed. Home shows it only when it has nothing saved.
    private(set) var loadFailure: APIError?
    private(set) var hasLoaded: Bool
    /// The recipes have been loaded once, now or by an earlier launch: an empty library is known to be empty.
    private(set) var recipesLoaded: Bool
    /// The aisle order and the saving of it. Plan, Shop and both aisle pickers read `aisles.order`.
    let aisles: AisleStore

    @ObservationIgnored private let deps: StoreDependencies
    @ObservationIgnored private var stores: [ListID: ListStore] = [:]
    @ObservationIgnored private var refreshing: Task<Void, Never>?

    init(deps: StoreDependencies) {
        self.deps = deps
        let saved = deps.disk.loadIndex()
        index = saved ?? LibraryIndex()
        hasLoaded = saved != nil
        recipesLoaded = saved != nil
        aisles = AisleStore(
            deps.disk.loadAisles() ?? AisleRecord(), api: deps.api, undo: deps.undo, save: { [disk = deps.disk] in disk.save($0) })
        for var replica in deps.disk.loadAll() {
            replica.releaseAll()
            deps.disk.save(replica)
            stores[replica.id] = makeStore(replica)
        }
    }

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

    /// Home's "Cook from <list>" section: the meals on the list last opened,
    /// else on the first row. Derived from `rows`, so a list being deleted or
    /// a meal removed but unsent is already accounted for.
    var cookShelf: CookShelf? {
        guard let list = currentList else { return nil }
        let meals = list.meals.compactMap { meal($0.id) }
        return meals.isEmpty ? nil : CookShelf(listID: list.id, listName: list.name, meals: meals)
    }

    /// The list last opened, else the first row: where Home cooks from and
    /// where "Add to list" adds.
    var currentList: ListSummary? {
        let rows = rows
        return rows.first(where: { $0.id == index.currentList }) ?? rows.first
    }

    /// The recipe library, newest first, minus recipes being deleted.
    var recipes: [RecipeSummary] {
        index.recipes.filter { !recipeDeleteOffered.contains($0.id) && !index.deletingRecipes.contains($0.id) }
    }

    /// The only writer of the current list. Called when a list is opened or added to.
    func markCurrent(_ id: ListID) {
        guard index.currentList != id else { return }
        index.currentList = id
        save()
    }

    /// A meal's title and picture: from the recipe cache, else the title the lists endpoint gave.
    func meal(_ id: RecipeID) -> RecipeSummary? {
        if let recipe = index.recipes.first(where: { $0.id == id }) { return recipe }
        let title = index.summaries.lazy.flatMap(\.meals).first(where: { $0.id == id })?.title
        return title.map { RecipeSummary(id: id, title: $0, imageURL: nil) }
    }

    func list(_ id: ListID) -> ListStore {
        if let store = stores[id] { return store }
        let store = makeStore(ListReplica(id: id))
        stores[id] = store
        return store
    }

    /// Loads the lists, recipes and units, and asks for the aisles without waiting
    /// for them. A call made while one is running joins it.
    func refresh() async {
        if let refreshing { return await refreshing.value }
        let task = Task { await load() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    /// Loads the recipes alone, for a screen that shows nothing else of what
    /// `refresh()` loads. Joins a full refresh if one is running.
    func refreshRecipes() async {
        if let refreshing { return await refreshing.value }
        guard case .success(let recipes) = await result({ () async throws(APIError) in try await deps.api.recipes() })
        else { return }
        take(recipes)
        save()
    }

    private func take(_ recipes: [RecipeSummary]) {
        index.recipes = recipes
        recipesLoaded = true
        index.deletingRecipes.formIntersection(recipes.map(\.id))
    }

    private func load() async {
        async let lists = result { () async throws(APIError) in try await deps.api.lists() }
        // Not waited for: the aisles queue behind a save of their own, which may
        // be slow, and the lists are not kept from Home or the disk by that.
        aisles.startLoad()
        async let recipes = result { () async throws(APIError) in try await deps.api.recipes() }
        async let units = result { () async throws(APIError) in try await deps.api.units() }
        async let weekday = result { () async throws(APIError) in try await deps.api.weekStartWeekday() }

        switch await lists {
        case .success(let summaries):
            index.summaries = summaries
            index.deletingLists.formIntersection(summaries.map(\.id))
            (hasLoaded, loadFailure) = (true, nil)
        case .failure(let failure):
            loadFailure = failure
        }
        if case .success(let recipes) = await recipes { take(recipes) }
        if case .success(let units) = await units { index.units = units }
        if case .success(let weekday) = await weekday { index.weekStartWeekday = weekday }
        save()
    }

    /// Home's Plan a week: opens the list for the week `Week.toPlan` picks,
    /// or makes it. Waits for a load first when the phone does not yet know
    /// the lists or the shop day, so it never makes a second copy of a week or
    /// picks the week by a weekday it was never told. A shop day the server
    /// cannot be asked for is Saturday, as on the web.
    func planWeek(today: PlanDate) async throws(APIError) -> ListID {
        if !hasLoaded || index.weekStartWeekday == nil { await refresh() }
        // Not knowing the lists is not the same as having none.
        guard hasLoaded else { throw loadFailure ?? .unreachable }
        let week = Week.toPlan(
            today: today, weekday: index.weekStartWeekday ?? Week.defaultStartWeekday, lists: rows)
        if let existing = week.list { return existing }
        return try await startList(weekStart: week.start).id
    }

    private func startList(weekStart: PlanDate? = nil) async throws(APIError) -> ListSummary {
        let created = try await deps.api.createList(weekStart: weekStart)
        index.summaries.insert(created, at: 0)
        save()
        return created
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

    /// The list a meal should go on. `.new`, and `.current` with no lists yet, start one, which needs signal.
    func resolve(_ target: ListTarget) async throws(APIError) -> ListRef {
        let existing: ListSummary? = switch target {
        case .current: currentList
        case .list(let id): rows.first { $0.id == id }
        case .new: nil
        }
        if let existing { return ListRef(id: existing.id, name: existing.name) }
        if case .list = target { throw .rejected(404) }
        // Not knowing the lists is not the same as having none.
        if target == .current, !hasLoaded { throw .unreachable }
        let created = try await startList()
        return ListRef(id: created.id, name: created.name)
    }

    /// Puts a recipe on a list and says so in the banner, with Undo. Never
    /// throws: a recipe already there, or no signal, is a banner too. The list
    /// it went on becomes the current one.
    func addMeal(_ recipe: RecipeID, title: String, to target: ListTarget) async {
        do {
            let list = try await resolve(target)
            let store = self.list(list.id)
            switch try await store.addMeal(recipe) {
            case .added:
                markCurrent(list.id)
                deps.undo.offer("Added \(title) to \(list.name)", undo: { store.takeBackMeal(recipe) })
            case .alreadyOnList:
                deps.undo.offer("\(title) is already on \(list.name)")
            }
        } catch {
            deps.undo.offer(
                error == .unreachable ? "Couldn't reach Omlete. \(title) wasn't added." : "Couldn't add \(title). Try again.")
        }
    }

    /// A recipe just made joins the library at once, first, without waiting for a refresh.
    func shelve(_ recipe: Recipe) {
        index.recipes.removeAll { $0.id == recipe.id }
        index.recipes.insert(recipe.summary, at: 0)
        save()
    }

    /// A recipe as an edit just saved it: its tile, and its name wherever a
    /// list shows it as a meal, change at once and not at the next refresh.
    func recipeEdited(_ recipe: Recipe) {
        if let place = index.recipes.firstIndex(where: { $0.id == recipe.id }) {
            index.recipes[place].title = recipe.title
            index.recipes[place].ingredientCount = recipe.ingredients.count
            index.recipes[place].ingredientNames = recipe.ingredients.map(\.name)
        }
        for list in index.summaries.indices {
            index.summaries[list].meals = index.summaries[list].meals.map {
                $0.id == recipe.id ? ListSummary.Meal(id: recipe.id, title: recipe.title) : $0
            }
        }
        save()
    }

    /// Hides the recipe at once and offers Undo. The DELETE goes out when the
    /// banner settles; if it cannot, the id is saved and `syncAll` retries.
    func deleteRecipe(_ id: RecipeID, title: String) {
        recipeDeleteOffered.insert(id)
        deps.undo.offer("Deleted \(title)", undo: { [weak self] in
            self?.recipeDeleteOffered.remove(id)
        }, commit: { [weak self] in
            guard let self else { return }
            index.deletingRecipes.insert(id)
            recipeDeleteOffered.remove(id)
            save()
            sendRecipeDelete(id)
        })
    }

    /// Flushes everything unsent. Called when the app comes to the front and
    /// when the network returns.
    func syncAll() {
        for store in stores.values where !store.replica.pending.isEmpty { store.sync() }
        for id in index.deletingLists { sendDelete(id) }
        for id in index.deletingRecipes { sendRecipeDelete(id) }
        aisles.sync()
    }

    private func sendRecipeDelete(_ id: RecipeID) {
        Task { await confirmRecipeDelete(id) }
    }

    private func confirmRecipeDelete(_ id: RecipeID) async {
        do {
            try await deps.api.deleteRecipe(id)
        } catch where error.isRetryable {
            return
        } catch {
            // Already gone, which is what was asked for.
        }
        index.recipes.removeAll { $0.id == id }
        index.deletingRecipes.remove(id)
        save()
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
        ListStore(replica: replica, deps: deps, aisleOrder: { [weak self] in self?.aisles.order.names ?? [] })
    }

    /// A saved index is what says the lists were loaded once, so nothing is written until they have been.
    private func save() {
        guard hasLoaded else { return }
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
