import Foundation

/// Which cards a Clear takes off the feed. Both screens' choices are made
/// here, so neither can drift from what its screen shows.
nonisolated enum ClearScope: Sendable {
    /// Discover's Clear all: every card but one still saving, which the
    /// finished save would bring back.
    case everything
    /// Home's Clear: only the ideas nobody has acted on. A saved or failed
    /// card is not on Home, so clearing it from there would remove something
    /// the user never saw go.
    case picks

    func cards(of visible: [Suggestion]) -> [Suggestion] {
        switch self {
        case .everything: visible.filter { $0.stage != .saving }
        case .picks: ChefPicks(cards: visible).fresh
        }
    }

    /// Whether the server is to leave a card that is no longer new to it: one
    /// saved or failed somewhere else since the phone read the feed.
    var onlyNewOnServer: Bool {
        switch self {
        case .everything: false
        case .picks: true
        }
    }
}
