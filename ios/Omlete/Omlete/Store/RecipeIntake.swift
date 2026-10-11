import Foundation
import Observation

struct IntakeDependencies {
    let api: APIClient
    /// Recipes belong to `Library`; a saved one is handed to it.
    let library: Library
    /// Where a job the server is still doing is remembered.
    var defaults: UserDefaults = .standard
    var pause: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}

/// Add a recipe: one field that is a link or a description, or photos, and
/// the one job the server does from them. App-wide, because the job takes a
/// model a minute or more and must outlive the Add tab being on screen.
///
/// The server owns the work. The phone keeps the job's id on disk and asks
/// after it, so leaving the app, or the app being killed, loses nothing:
/// `resume()` picks the job up again.
///
/// Invariant: at most one job is outstanding, and at most one task is asking
/// after it. `submit()` while working does nothing, so a double tap cannot
/// pay for two recipes.
@Observable final class RecipeIntake {
    enum Phase: Equatable {
        case editing
        /// The request is on its way to the server, which has not taken it yet.
        case starting(RecipeRequest.Kind)
        /// The server has the job and the phone is asking after it.
        case working(RecipeJob, Contact)
        case finished(RecipeCreation)
    }

    /// Whether the server has been answering about a job.
    enum Contact: Equatable {
        case inTouch
        /// Several checks in a row went unanswered. The job is no worse for it.
        case waitingForConnection
    }

    /// One unanswered check is a blip; from the second the screen says so.
    static let missesBeforeSayingSo = 2
    private static let jobKey = "add.job"

    /// How long to leave it before asking again: often while the server
    /// answers, then backing off while it does not.
    static func wait(afterMisses misses: Int) -> Duration {
        misses == 0 ? .milliseconds(1500) : .seconds(min(1 << min(misses, 4), 15))
    }

    /// What is saved while a job is outstanding. The text comes back with it,
    /// so a failure after a relaunch still has something to fix and resend.
    private struct Outstanding: Codable {
        let job: RecipeJob
        let text: String
    }

    private(set) var text = ""
    private(set) var photos: [RecipePhoto] = []
    /// Photos picked and still being read off the photo library.
    private(set) var photosArriving = 0
    private(set) var phase = Phase.editing

    @ObservationIgnored private let deps: IntakeDependencies
    @ObservationIgnored private var polling: Task<Void, Never>?
    /// Checks unanswered in a row.
    @ObservationIgnored private var misses = 0

    init(deps: IntakeDependencies) {
        self.deps = deps
        let saved = deps.defaults.data(forKey: Self.jobKey)
        guard let outstanding = saved.flatMap({ try? JSONDecoder().decode(Outstanding.self, from: $0) }) else { return }
        text = outstanding.text
        phase = .working(outstanding.job, .inTouch)
        follow(outstanding.job)
    }

    var isWorking: Bool {
        switch phase {
        case .starting, .working: true
        case .editing, .finished: false
        }
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

    /// Starts a job. A saved recipe clears the field for the next one.
    /// Anything else keeps what was typed, to fix or to try again.
    func submit() {
        guard canSubmit, let request else { return }
        phase = .starting(request.kind)
        Task {
            switch await deps.api.startRecipe(request) {
            case .started(let job):
                deps.defaults.set(try? JSONEncoder().encode(Outstanding(job: job, text: text)), forKey: Self.jobKey)
                phase = .working(job, .inTouch)
                follow(job)
            case .failed(let failure):
                phase = .finished(.failed(failure))
            }
        }
    }

    /// Asks after an outstanding job now, not when the current wait ends. For
    /// when the app comes to the front or the network returns.
    func resume() {
        guard case .working(let job, _) = phase else { return }
        follow(job)
    }

    /// Replaces whatever task was asking, so there is never more than one.
    private func follow(_ job: RecipeJob) {
        polling?.cancel()
        polling = Task { [weak self, api = deps.api, pause = deps.pause] in
            while self != nil, !Task.isCancelled {
                let check = await api.checkRecipe(job)
                // A task replaced while its check was out must not act on the answer.
                guard !Task.isCancelled, let wait = self?.take(check, of: job) else { return }
                guard (try? await pause(wait)) != nil else { return }
            }
        }
    }

    /// Returns how long to wait before asking again, or nil when the job has ended.
    private func take(_ check: RecipeJobCheck, of job: RecipeJob) -> Duration? {
        switch check {
        case .finished(let outcome):
            deps.defaults.removeObject(forKey: Self.jobKey)
            (polling, misses) = (nil, 0)
            if case .saved(let recipe) = outcome {
                deps.library.shelve(recipe)
                (text, photos) = ("", [])
            }
            phase = .finished(outcome)
            return nil
        case .working:
            misses = 0
        case .unanswered:
            misses += 1
        }
        phase = .working(job, misses < Self.missesBeforeSayingSo ? .inTouch : .waitingForConnection)
        return Self.wait(afterMisses: misses)
    }
}
