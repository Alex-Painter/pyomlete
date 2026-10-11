import Foundation

/// Home's taste of Discover: the ideas nobody has acted on yet. A card that
/// is saving, saved or failed has been answered already, and is Discover's to
/// show. Built in one place so Home holds no rules.
nonisolated struct ChefPicks: Equatable, Sendable {
    static let mostShown = 3

    /// Every fresh card, in feed order. Clear covers all of them, not only
    /// the ones shown, or it would uncover the next three.
    let fresh: [Suggestion]

    var shown: [Suggestion] { Array(fresh.prefix(Self.mostShown)) }

    init(cards: [Suggestion]) {
        fresh = cards.filter { $0.stage == .fresh }
    }
}
