import SwiftUI

@main
struct OmleteApp: App {
    @State private var library: Library
    @State private var kitchen: Kitchen
    @State private var navigation = AppNavigation()
    @State private var undo: UndoCenter

    init() {
        let undo = UndoCenter()
        let connectivity = Connectivity()
        let api = APIClient(baseURL: APIEnvironment.baseURL, transport: URLSessionTransport())
        let library = Library(deps: StoreDependencies(
            api: api, disk: ReplicaDisk(), undo: undo, connectivity: connectivity))
        let kitchen = Kitchen(deps: KitchenDependencies(api: api, disk: CookDisk()))
        connectivity.onRegain = { [weak library, weak kitchen] in
            library?.syncAll()
            kitchen?.resume()
        }
        connectivity.start()
        _library = State(initialValue: library)
        _kitchen = State(initialValue: kitchen)
        _undo = State(initialValue: undo)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(kitchen)
                .environment(navigation)
                .environment(undo)
        }
    }
}
