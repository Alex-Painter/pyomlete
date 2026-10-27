import Foundation
import Observation

/// What Chef knows, shown in Settings: what they told it, then what it
/// noticed. Owned by `Chef`, so a chat that changes it can refresh it.
///
/// Forget applies at once with Undo, as on the web: the row goes and the
/// server is told straight away, and Undo tells it again the other way.
///
/// Invariant: a row Forget or Undo has changed shows as changed whatever a
/// load answers while the server has yet to answer the change, and a load
/// asked for before a change was answered decides nothing.
@Observable final class ChefMemory {
    enum Status: Equatable {
        case loading
        /// Nothing has loaded yet and the last try failed.
        case failed
        case loaded
    }

    private enum Change {
        case forgotten
        /// Undo, with the row's place to put it back in.
        case remembered(Preference, at: Int)
    }

    private(set) var status = Status.loading
    /// As the server last gave them.
    private var answered: [Preference] = []
    /// Changes the server has not answered yet, shown over `answered`.
    private var unanswered: [PreferenceID: Change] = [:]

    @ObservationIgnored private let deps: ChefDependencies
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// Changes answered so far. A load that saw this move while it was out is stale.
    @ObservationIgnored private var changesAnswered = 0

    init(deps: ChefDependencies) {
        self.deps = deps
    }

    var preferences: [Preference] {
        var shown = answered
        for (id, change) in unanswered {
            switch change {
            case .forgotten:
                shown.removeAll { $0.id == id }
            case .remembered(let preference, let place):
                if !shown.contains(where: { $0.id == id }) { shown.insert(preference, at: min(place, shown.count)) }
            }
        }
        return shown
    }

    var told: [Preference] { preferences.filter { $0.source == .told } }
    var noticed: [Preference] { preferences.filter { $0.source == .inferred } }

    /// A call made while a load is out joins it. A failed load keeps the rows already shown.
    func load() async {
        if let loading { return await loading.value }
        let task = Task {
            if status == .failed { status = .loading }
            let asked = changesAnswered
            do throws(APIError) {
                let answer = try await deps.api.preferences()
                if asked == changesAnswered { answered = answer }
                status = .loaded
            } catch {
                if status != .loaded { status = .failed }
            }
            loading = nil
        }
        loading = task
        await task.value
    }

    func forget(_ preference: Preference) {
        guard let place = preferences.firstIndex(of: preference) else { return }
        unanswered[preference.id] = .forgotten
        let sent = Task { () -> Bool in
            let forgot = (try? await deps.api.setForgotten(preference.id, true)) != nil
            changesAnswered += 1
            if forgot { answered.removeAll { $0.id == preference.id } }
            if case .forgotten = unanswered[preference.id] { unanswered[preference.id] = nil }
            if !forgot { deps.undo.inform("Couldn't forget \(preference.subject). Try again.") }
            return forgot
        }
        deps.undo.offer("Forgot \(preference.subject)", undo: { [weak self] in
            self?.remember(preference, at: place, after: sent)
        })
    }

    /// Undo: back at once in its place, and the server told once the forget has been answered.
    private func remember(_ preference: Preference, at place: Int, after forget: Task<Bool, Never>) {
        unanswered[preference.id] = .remembered(preference, at: place)
        Task {
            // A forget that failed left it remembered, with nothing to send.
            let remembered = await forget.value
                ? (try? await deps.api.setForgotten(preference.id, false)) != nil : true
            changesAnswered += 1
            unanswered[preference.id] = nil
            if remembered {
                if !answered.contains(where: { $0.id == preference.id }) {
                    answered.insert(preference, at: min(place, answered.count))
                }
            } else {
                answered.removeAll { $0.id == preference.id }
                deps.undo.inform("Couldn't bring back \(preference.subject). Try again.")
            }
        }
    }
}
