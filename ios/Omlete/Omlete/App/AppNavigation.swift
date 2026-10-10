import Foundation
import Observation

enum Route: Hashable {
    case plan(ListID)
}

/// The one full-screen mode on top of the stack, if any. A single optional
/// value, so shopping and cooking at once cannot be written down.
enum Immersive: Hashable, Identifiable {
    case shop(ListID)
    case cook(RecipeID)

    var id: Self { self }
}

/// Where the user is. Modes are entered and left only through these methods.
///
/// `immersive` is keyed on an id, not on data, so no sync result, refresh or
/// deletion can present or dismiss Shop or Cook. A list or recipe deleted
/// elsewhere shows as gone inside the mode.
///
/// A mode covers the stack and leaves `path` alone, so leaving it returns to
/// wherever it was entered from.
@Observable final class AppNavigation {
    var path: [Route] = []
    private(set) var immersive: Immersive?

    var shopping: ListID? {
        if case .shop(let id) = immersive { id } else { nil }
    }

    /// The list on screen, or under Cook, if any.
    var openList: ListID? {
        if let shopping { return shopping }
        if case .plan(let id) = path.last { return id }
        return nil
    }

    func startShopping(_ id: ListID) {
        enter(.shop(id))
    }

    func startCooking(_ id: RecipeID) {
        enter(.cook(id))
    }

    func leaveImmersive() {
        immersive = nil
    }

    /// Ignored while a mode is up: a mode is never replaced, only left.
    private func enter(_ mode: Immersive) {
        guard immersive == nil else { return }
        immersive = mode
    }
}
