import Testing
@testable import Omlete

struct HomeContentTests {
    private let week = ListSummary(id: "week", name: "Week", itemCount: 2, checkedCount: 0, meals: [])
    private let idea = Suggestion(id: "a", title: "Bean Chilli", section: .moreIdeas, stage: .fresh)

    private func content(
        lists: [ListSummary] = [], loaded: Bool = true, failure: APIError? = nil, picks: [Suggestion] = [],
        feedAnswered: Bool = true
    ) -> HomeContent {
        HomeContent(lists: lists, listsLoaded: loaded, loadFailure: failure, picks: picks, feedAnswered: feedAnswered)
    }

    @Test func listsAndPicksAreSectionsInThatOrder() {
        #expect(content(lists: [week], picks: [idea]) == .sections(lists: [week], picks: [idea]))
        #expect(content(lists: [week]) == .sections(lists: [week], picks: []))
    }

    @Test func untilTheListsLoadThereIsASpinnerOrTheFailureAndNeverPicks() {
        #expect(content(loaded: false, picks: [idea]) == .loading)
        #expect(content(loaded: false, failure: .unreachable, picks: [idea]) == .unavailable(.unreachable))
    }

    @Test func withNoListsTheInvitationHasTheScreenUnlessThereArePicksToKeepInView() {
        #expect(content() == .noLists)
        #expect(content(picks: [idea]) == .sections(lists: [], picks: [idea]))
    }

    @Test func withNoListsTheInvitationWaitsForTheFeedSoItDoesNotRearrange() {
        #expect(content(feedAnswered: false) == .loading)
        #expect(content(lists: [week], feedAnswered: false) == .sections(lists: [week], picks: []))
    }
}
