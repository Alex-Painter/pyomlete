import Foundation
import Observation

enum AppTab: Hashable {
    case home, discover, add, recipes
}

enum Route: Hashable {
    case plan(ListID)
    case recipe(RecipeID)
}

/// The one full-screen mode on top of the tabs, if any. A single optional
/// value, so shopping and cooking at once cannot be written down.
enum Immersive: Hashable, Identifiable {
    case shop(ListID)
    case cook(RecipeID)

    var id: Self { self }
}

/// Where the user is: a tab, that tab's own stack, and perhaps a mode over
/// everything. Modes are entered and left only through these methods.
///
/// `immersive` is keyed on an id, not on data, so no sync result, refresh or
/// deletion can present or dismiss Shop or Cook. A list or recipe deleted
/// elsewhere shows as gone inside the mode.
///
/// A mode covers the tabs and leaves every stack alone, so leaving it returns
/// to wherever it was entered from.
@Observable final class AppNavigation {
    var tab = AppTab.home
    private var paths: [AppTab: [Route]] = [:]
    private(set) var immersive: Immersive?

    subscript(tab: AppTab) -> [Route] {
        get { paths[tab] ?? [] }
        set { paths[tab] = newValue }
    }

    /// Names its tab because a push can follow a request, and by then another tab may be showing.
    func push(_ route: Route, on tab: AppTab) {
        self[tab].append(route)
    }

    var shopping: ListID? {
        if case .shop(let id) = immersive { id } else { nil }
    }

    /// The list on screen, or under Cook, if any.
    var openList: ListID? {
        if let shopping { return shopping }
        // Whichever tab is showing: a Plan left open under another tab still wants refreshing.
        return paths.values.lazy.compactMap { path -> ListID? in
            if case .plan(let id) = path.last { id } else { nil }
        }.first
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
