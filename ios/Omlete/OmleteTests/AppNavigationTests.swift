import Testing
@testable import Omlete

@MainActor struct AppNavigationTests {
    @Test func aSecondTapBeforeAScreenShowsDoesNotPushItTwice() {
        let navigation = AppNavigation()

        navigation.push(.settings, on: .home)
        navigation.push(.settings, on: .home)

        #expect(navigation[.home] == [.settings])
    }

    @Test func aListLeftOpenUnderAnotherTabIsStillTheOpenList() {
        let navigation = AppNavigation()
        navigation.push(.plan("week"), on: .home)

        navigation.tab = .recipes
        navigation.push(.recipe("curry"), on: .recipes)

        #expect(navigation.openList == "week")
    }
}
