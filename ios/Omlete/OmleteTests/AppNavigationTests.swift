import Testing
@testable import Omlete

@MainActor struct AppNavigationTests {
    @Test func aListLeftOpenUnderAnotherTabIsStillTheOpenList() {
        let navigation = AppNavigation()
        navigation.push(.plan("week"), on: .home)

        navigation.tab = .recipes
        navigation.push(.recipe("curry"), on: .recipes)

        #expect(navigation.openList == "week")
    }
}
