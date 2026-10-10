import Foundation
import Observation

/// Add a recipe: one field that is a link or a description, or photos, and
/// the one request made from them. App-wide, because that request waits on a
/// model for a minute or more and must outlive the Add tab being on screen.
///
/// Invariant: at most one request is running. `submit()` while working does
/// nothing, so a double tap cannot pay for two recipes.
@Observable final class RecipeIntake {
    enum Phase: Equatable {
        case editing
        case working(RecipeRequest.Kind)
        case finished(RecipeCreation)
    }

    private(set) var text = ""
    private(set) var photos: [RecipePhoto] = []
    private(set) var phase = Phase.editing

    @ObservationIgnored private let library: Library

    init(library: Library) {
        self.library = library
    }

    var isWorking: Bool {
        if case .working = phase { true } else { false }
    }

    var canSubmit: Bool { !isWorking && request != nil }

    var submitLabel: String {
        switch request {
        case .photos(let photos): "Read \(photos.count) photo\(photos.count == 1 ? "" : "s")"
        case .link: "Import recipe"
        case .describe, nil: "Create recipe"
        }
    }

    private var request: RecipeRequest? { RecipeRequest(text: text, photos: photos) }

    // Changing what is asked for puts away the last answer. Ignored while working.

    func edit(_ text: String) {
        guard !isWorking, text != self.text else { return }
        self.text = text
        phase = .editing
    }

    func attach(_ photo: RecipePhoto) {
        guard !isWorking else { return }
        photos.append(photo)
        phase = .editing
    }

    func removePhoto(_ id: UUID) {
        guard !isWorking else { return }
        photos.removeAll { $0.id == id }
        phase = .editing
    }

    /// A saved recipe clears the field for the next one. Anything else keeps
    /// what was typed, to fix or to try again.
    func submit() {
        guard !isWorking, let request else { return }
        phase = .working(request.kind)
        Task {
            let outcome = await library.createRecipe(request)
            if case .saved = outcome { (text, photos) = ("", []) }
            phase = .finished(outcome)
        }
    }
}
