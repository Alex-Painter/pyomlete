import SwiftUI

@main
struct OmleteApp: App {
    @State private var library: Library
    @State private var navigation = AppNavigation()
    @State private var undo: UndoCenter

    init() {
        let undo = UndoCenter()
        let connectivity = Connectivity()
        let library = Library(deps: StoreDependencies(
            api: APIClient(baseURL: APIEnvironment.baseURL, transport: URLSessionTransport()),
            disk: ReplicaDisk(), undo: undo, connectivity: connectivity))
        connectivity.onRegain = { [weak library] in library?.syncAll() }
        connectivity.start()
        _library = State(initialValue: library)
        _undo = State(initialValue: undo)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(navigation)
                .environment(undo)
        }
    }
}
