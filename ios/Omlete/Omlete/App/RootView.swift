import SwiftUI

struct RootView: View {
    @Environment(Library.self) private var library
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
        // Read-only: only `leaveShopping()` ends Shop.
        .fullScreenCover(item: Binding(get: { navigation.shopping }, set: { _ in })) { id in
            ShopScreen(listID: id)
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                library.syncAll()
                if let open = navigation.openList { library.list(open).sync(refresh: true) }
            } else {
                // Leaving the app settles the banner, as closing the page does on the web.
                undo.commitNow()
            }
        }
    }
}
