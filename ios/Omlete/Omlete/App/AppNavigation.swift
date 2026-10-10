import Foundation
import Observation

enum Route: Hashable {
    case plan(ListID)
}

/// Where the user is. Modes are entered and left only through these methods.
///
/// `shopping` is keyed on a list id, not on list data, so no sync result,
/// refresh or deletion can present or dismiss Shop. A list deleted elsewhere
/// shows as gone inside Shop.
@Observable final class AppNavigation {
    var path: [Route] = []
    private(set) var shopping: ListID?

    /// The list on screen, if any.
    var openList: ListID? {
        if let shopping { return shopping }
        if case .plan(let id) = path.last { return id }
        return nil
    }

    func startShopping(_ id: ListID) {
        shopping = id
    }

    func leaveShopping() {
        shopping = nil
    }
}
