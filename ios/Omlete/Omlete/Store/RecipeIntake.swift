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
    /// Photos picked and still being read off the photo library.
    private(set) var photosArriving = 0
    private(set) var phase = Phase.editing

    @ObservationIgnored private let library: Library

    init(library: Library) {
        self.library = library
    }

    var isWorking: Bool {
        if case .working = phase { true } else { false }
    }

    /// Not while photos are arriving: sending now would read the recipe from some of its pages.
    var canSubmit: Bool { !isWorking && photosArriving == 0 && request != nil }

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

    /// `count` photos were picked. Each is settled by one `attach(_:)`.
    func expectPhotos(_ count: Int) {
        guard !isWorking else { return }
        photosArriving += count
        phase = .editing
    }

    /// One picked photo, read and encoded, or nil if it could not be.
    func attach(_ photo: RecipePhoto?) {
        guard photosArriving > 0 else { return }
        photosArriving -= 1
        if let photo { photos.append(photo) }
    }

    func removePhoto(_ id: UUID) {
        guard !isWorking else { return }
        photos.removeAll { $0.id == id }
        phase = .editing
    }

    /// A saved recipe clears the field for the next one. Anything else keeps
    /// what was typed, to fix or to try again.
    func submit() {
        guard canSubmit, let request else { return }
        phase = .working(request.kind)
        Task {
            let outcome = await library.createRecipe(request)
            if case .saved = outcome { (text, photos) = ("", []) }
            phase = .finished(outcome)
        }
    }
}
