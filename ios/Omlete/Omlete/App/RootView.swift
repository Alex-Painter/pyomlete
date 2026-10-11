import SwiftUI

struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(Kitchen.self) private var kitchen
    @Environment(Chef.self) private var chef
    @Environment(RecipeIntake.self) private var intake
    @Environment(AppNavigation.self) private var navigation
    @Environment(UndoCenter.self) private var undo
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.tab) {
            Tab(value: AppTab.home) {
                stack(.home) { HomeScreen() }
            } label: {
                tabLabel("Home", systemImage: "house", identifier: "tab.home")
            }
            Tab(value: AppTab.discover) {
                stack(.discover) { DiscoverScreen() }
            } label: {
                tabLabel("Discover", systemImage: "safari", identifier: "tab.discover")
            }
            Tab(value: AppTab.add) {
                stack(.add) { AddScreen() }
            } label: {
                tabLabel("Add", systemImage: "plus", identifier: "tab.add")
            }
            Tab(value: AppTab.recipes) {
                stack(.recipes) { RecipeLibraryScreen() }
            } label: {
                tabLabel("Recipes", systemImage: "book", identifier: "tab.recipes")
            }
        }
        // Read-only: only `leaveImmersive()` ends a mode.
        .fullScreenCover(item: Binding(get: { navigation.immersive }, set: { _ in })) { mode in
            switch mode {
            case .shop(let id): ShopScreen(listID: id)
            case .cook(let id): CookScreen(recipeID: id)
            }
        }
        // A job restored at launch is followed from here: `onChange` below does not fire for the first scene phase.
        .task { intake.resume() }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                undo.appCameToFront()
                library.syncAll()
                kitchen.resume()
                intake.resume()
                if let open = navigation.openList { library.list(open).sync(refresh: true) }
                Task { await library.refresh() }
                Task { await chef.load() }
            } else {
                undo.appLeftFront()
            }
        }
    }

    private func tabLabel(_ title: String, systemImage: String, identifier: String) -> some View {
        Label(title, systemImage: systemImage)
            .accessibilityIdentifier(identifier)
    }

    /// One stack per tab, each with its own path, and the one place a route becomes a screen.
    private func stack(_ tab: AppTab, @ViewBuilder root: () -> some View) -> some View {
        NavigationStack(path: Binding(get: { navigation[tab] }, set: { navigation[tab] = $0 })) {
            root()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .plan(let id): PlanScreen(listID: id)
                    case .recipe(let id): RecipeScreen(recipeID: id)
                    case .settings: SettingsScreen()
                    }
                }
        }
    }
}
