import Foundation
import Testing
@testable import Omlete

/// The rules of the web's `ChefPicks` on Home, which is the spec.
struct ChefPicksTests {
    private func card(_ id: SuggestionID, _ stage: Suggestion.Stage = .fresh) -> Suggestion {
        Suggestion(id: id, title: "Idea \(id.rawValue)", section: .moreIdeas, stage: stage)
    }

    @Test func onlyCardsNobodyHasActedOnArePicksInFeedOrder() {
        let picks = ChefPicks(cards: [
            card("saving", .saving), card("b"), card("saved", .saved("r")), card("a"), card("failed", .failed),
        ])

        #expect(picks.shown.map(\.id) == ["b", "a"])
        #expect(picks.fresh == picks.shown)
    }

    /// Counted after the rest: a card that cannot be a pick must not take one of the three places.
    @Test func theNewestThreeAreShownAndClearCoversTheRest() {
        let picks = ChefPicks(cards: [card("1", .failed), card("2"), card("3"), card("4", .saving), card("5"), card("6"), card("7")])

        #expect(picks.shown.map(\.id) == ["2", "3", "5"])
        #expect(picks.fresh.map(\.id) == ["2", "3", "5", "6", "7"])
    }

    @Test func aCardWhoseSaveCouldNotBeSentIsStillAPick() {
        #expect(ChefPicks(cards: [card("a", .unsent), card("b")]).shown.map(\.id) == ["a", "b"])
    }

    @Test func aFeedWithNothingFreshHasNoPicks() {
        #expect(ChefPicks(cards: []).shown.isEmpty)
        #expect(ChefPicks(cards: [card("a", .saved("r")), card("b", .failed)]).shown.isEmpty)
    }
}
