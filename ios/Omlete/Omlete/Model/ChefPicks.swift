import Foundation

/// Home's taste of Discover: the ideas nobody has acted on yet. A card that
/// is saving, saved or failed has been answered already, and is Discover's to
/// show. Where they sit on Home is `HomeContent`'s to decide.
nonisolated struct ChefPicks: Sendable {
    static let mostShown = 3

    /// Every fresh card, in feed order. Clear covers all of them, not only
    /// the ones shown, or it would uncover the next three.
    let fresh: [Suggestion]

    var shown: [Suggestion] { Array(fresh.prefix(Self.mostShown)) }

    init(cards: [Suggestion]) {
        fresh = cards.filter { $0.stage == .fresh }
    }
}
