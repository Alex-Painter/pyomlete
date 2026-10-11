import SwiftUI

@main
struct OmleteApp: App {
    @State private var library: Library
    @State private var kitchen: Kitchen
    @State private var chef: Chef
    @State private var intake: RecipeIntake
    @State private var navigation = AppNavigation()
    @State private var undo: UndoCenter

    init() {
        let undo = UndoCenter()
        let connectivity = Connectivity()
        let api = APIClient(baseURL: APIEnvironment.baseURL, transport: URLSessionTransport())
        let library = Library(deps: StoreDependencies(
            api: api, disk: ReplicaDisk(), undo: undo, connectivity: connectivity))
        let kitchen = Kitchen(deps: KitchenDependencies(
            api: api, disk: CookDisk(), recipeSaved: { [weak library] in library?.adopt($0) }))
        let intake = RecipeIntake(deps: IntakeDependencies(api: api, library: library))
        connectivity.onRegain = { [weak library, weak kitchen, weak intake] in
            library?.syncAll()
            kitchen?.resume()
            intake?.resume()
        }
        connectivity.start()
        _library = State(initialValue: library)
        _kitchen = State(initialValue: kitchen)
        _chef = State(initialValue: Chef(deps: ChefDependencies(api: api, undo: undo, library: library)))
        _intake = State(initialValue: intake)
        _undo = State(initialValue: undo)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(kitchen)
                .environment(chef)
                .environment(intake)
                .environment(navigation)
                .environment(undo)
        }
    }
}
