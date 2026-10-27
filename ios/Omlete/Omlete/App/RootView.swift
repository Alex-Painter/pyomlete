import SwiftUI

struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(Kitchen.self) private var kitchen
    @Environment(Chef.self) private var chef
    @Environment(RecipeIntake.self) private var intake
    @Environment(AppNavigation.self) private var navigation
    @Environment(UndoCenter.self) private var undo
    @Environment(ChefChat.self) private var chefChat
    @Environment(\.scenePhase) private var scenePhase

    /// What the tab bar holds: the three tabs, and Chef, which opens its sheet
    /// over the screen on show and is never the selected tab.
    private enum TabBarItem: Hashable {
        case tab(AppTab)
        case chef
    }

    /// The tab bar's own selection. Chef is selected only for the moment it takes to open the sheet and go back.
    @State private var selection = TabBarItem.tab(.home)

    var body: some View {
        TabView(selection: $selection) {
            Tab(value: TabBarItem.tab(.home)) {
                stack(.home) { HomeScreen() }
            } label: {
                tabLabel("Home", systemImage: "house", identifier: "tab.home")
            }
            Tab(value: TabBarItem.tab(.discover)) {
                stack(.discover) { DiscoverScreen() }
            } label: {
                tabLabel("Discover", systemImage: "safari", identifier: "tab.discover")
            }
            Tab(value: TabBarItem.chef) {
                Color.clear
            } label: {
                tabLabel("Chef", systemImage: "bubble.left.and.text.bubble.right", identifier: "tab.chef")
            }
            Tab(value: TabBarItem.tab(.recipes)) {
                stack(.recipes) { RecipeLibraryScreen() }
            } label: {
                tabLabel("Recipes", systemImage: "book", identifier: "tab.recipes")
            }
        }
        .onChange(of: selection) {
            switch selection {
            case .tab(let tab):
                navigation.tab = tab
            case .chef:
                chefChat.toggle()
                // On the next turn: put back in the same update, the stack left
                // and returned to loses its safe area, and screens pushed on it
                // lay out under the navigation bar.
                Task { selection = .tab(navigation.tab) }
            }
        }
        .onChange(of: navigation.tab, initial: true) { selection = .tab(navigation.tab) }
        .chefSheet()
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
                Task { await chef.week.load() }
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
                    case .addRecipe: AddScreen()
                    }
                }
        }
    }
}
