import Foundation

/// What Home shows below the cook shelf, decided in one place: the view
/// switches on it and holds no rules of its own.
nonisolated enum HomeContent: Equatable, Sendable {
    /// Nothing to show yet. Covers the screen.
    case loading
    /// The lists never loaded, and the last try failed. Covers the screen.
    case unavailable(APIError)
    /// Loaded, with no lists and no picks: the invitation has the screen to itself.
    case noLists
    /// The Lists section, then Chef's picks if there are any. With picks and
    /// no lists the invitation is a row in Lists, so it does not cover them.
    case sections(lists: [ListSummary], picks: [Suggestion])

    static let noListsTitle = "No weeks planned yet"
    static let noListsInvitation = "Plan one, pick a dinner for each day, and the shopping list builds itself."

    /// `feedAnswered` is whether the suggestions have loaded or failed to.
    /// Until then a Home with no lists waits, so the full-screen invitation
    /// does not show and then rearrange itself around picks that arrive.
    init(lists: [ListSummary], listsLoaded: Bool, loadFailure: APIError?, picks: [Suggestion], feedAnswered: Bool) {
        if !lists.isEmpty {
            // Picks never sit under lists that are only the saved copy of a load still to come.
            self = .sections(lists: lists, picks: listsLoaded ? picks : [])
        } else if !listsLoaded {
            self = loadFailure.map { .unavailable($0) } ?? .loading
        } else if !picks.isEmpty {
            self = .sections(lists: [], picks: picks)
        } else {
            self = feedAnswered ? .noLists : .loading
        }
    }
}
