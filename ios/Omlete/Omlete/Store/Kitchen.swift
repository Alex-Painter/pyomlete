import Foundation
import Observation

struct KitchenDependencies {
    let api: APIClient
    let disk: any CookStorage
    var now: () -> Date = { .now }
    var sleepUntil: (Date) async throws -> Void = { try await Task.sleep(for: .seconds($0.timeIntervalSinceNow)) }
    /// Sound and haptic for a finished timer.
    var chime: () -> Void = { TimerChime.play() }
}

/// App-wide owner of cooking, beside `Library`. Library owns lists; Kitchen
/// owns recipes in full and the cooks made from them. Neither writes the
/// other's state.
///
/// Invariant: `cook(_:)` returns the same `CookStore` for the same id for the
/// life of the process, so closing and reopening Cook finds the same step,
/// servings and timers, and a timer rings whether or not Cook is on screen.
@Observable final class Kitchen {
    /// A cook untouched for this long, with nothing unsent, is forgotten at launch.
    static let keepsCooksFor: TimeInterval = 30 * 24 * 3600

    @ObservationIgnored private let deps: KitchenDependencies
    @ObservationIgnored private var stores: [RecipeID: CookStore] = [:]

    /// Loads every saved cook, so a timer started before a kill rings, or shows as done, after it.
    init(deps: KitchenDependencies) {
        self.deps = deps
        let now = deps.now()
        for record in deps.disk.loadAll() {
            if record.unsentRating == nil, now.timeIntervalSince(record.session.touchedAt) > Self.keepsCooksFor {
                deps.disk.discard(record.id)
            } else {
                stores[record.id] = CookStore(id: record.id, record: record, deps: deps)
            }
        }
    }

    func cook(_ id: RecipeID) -> CookStore {
        if let store = stores[id] { return store }
        let store = CookStore(id: id, record: nil, deps: deps)
        stores[id] = store
        return store
    }

    /// Fetches the recipes not yet on this phone, so the first tap on a Home
    /// card works with no signal. Failures are silent; Cook's own `open` retries.
    func warm(_ ids: [RecipeID]) async {
        for id in ids { await cook(id).warm() }
    }

    /// The app came to the front, or the network returned: ring what ended
    /// while away and send unsent ratings.
    func resume() {
        for store in stores.values { store.resume() }
    }
}
