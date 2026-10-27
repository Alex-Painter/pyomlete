import Foundation
import Observation

/// What Chef knows, shown in Settings: what they told it, then what it
/// noticed. Owned by `Chef`, so a chat that changes it can refresh it.
///
/// Forget applies at once with Undo, as on the web: the row goes and the
/// server is told straight away, and Undo tells it again the other way.
@Observable final class ChefMemory {
    enum Status: Equatable {
        case loading
        /// Nothing has loaded yet and the last try failed.
        case failed
        case loaded
    }

    private(set) var status = Status.loading
    /// As the server last gave them, less those forgotten here since.
    private(set) var preferences: [Preference] = []

    @ObservationIgnored private let deps: ChefDependencies
    /// Forgets the server has not answered yet. A load answered meanwhile may still list them.
    @ObservationIgnored private var forgetting: [PreferenceID: Task<Bool, Never>] = [:]

    init(deps: ChefDependencies) {
        self.deps = deps
    }

    var told: [Preference] { preferences.filter { $0.source == .told } }
    var noticed: [Preference] { preferences.filter { $0.source == .inferred } }

    /// A failed load keeps the rows already shown.
    func load() async {
        if status == .failed { status = .loading }
        do throws(APIError) {
            let answer = try await deps.api.preferences()
            preferences = answer.filter { forgetting[$0.id] == nil }
            status = .loaded
        } catch {
            if status != .loaded { status = .failed }
        }
    }

    func forget(_ preference: Preference) {
        guard let place = preferences.firstIndex(of: preference) else { return }
        preferences.remove(at: place)
        let sent = Task { [api = deps.api] in
            (try? await api.setForgotten(preference.id, true)) != nil
        }
        forgetting[preference.id] = sent
        Task {
            let forgot = await sent.value
            forgetting[preference.id] = nil
            if !forgot {
                putBack(preference, at: place)
                deps.undo.inform("Couldn't forget \(preference.subject). Try again.")
            }
        }
        deps.undo.offer("Forgot \(preference.subject)", undo: { [weak self] in
            self?.remember(preference, at: place, after: sent)
        })
    }

    /// Undo: back at once in its place, and the server told once the forget has been answered.
    private func remember(_ preference: Preference, at place: Int, after forget: Task<Bool, Never>) {
        putBack(preference, at: place)
        Task {
            // A forget that failed has already put it back, and left nothing to undo.
            guard await forget.value else { return }
            do throws(APIError) {
                try await deps.api.setForgotten(preference.id, false)
            } catch {
                preferences.removeAll { $0.id == preference.id }
                deps.undo.inform("Couldn't bring back \(preference.subject). Try again.")
                return
            }
            await load()
        }
    }

    private func putBack(_ preference: Preference, at place: Int) {
        guard !preferences.contains(where: { $0.id == preference.id }) else { return }
        preferences.insert(preference, at: min(place, preferences.count))
    }
}
