import SwiftUI

struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(Kitchen.self) private var kitchen
    @Environment(AppNavigation.self) private var navigation
    @Environment(UndoCenter.self) private var undo
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var navigation = navigation
        NavigationStack(path: $navigation.path) {
            HomeScreen()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .plan(let id): PlanScreen(listID: id)
                    }
                }
        }
        // Read-only: only `leaveImmersive()` ends a mode.
        .fullScreenCover(item: Binding(get: { navigation.immersive }, set: { _ in })) { mode in
            switch mode {
            case .shop(let id): ShopScreen(listID: id)
            case .cook(let id): CookScreen(recipeID: id)
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                library.syncAll()
                kitchen.resume()
                if let open = navigation.openList { library.list(open).sync(refresh: true) }
                Task { await library.refresh() }
            } else {
                // Leaving the app settles the banner, as closing the page does on the web.
                undo.commitNow()
            }
        }
    }
}
