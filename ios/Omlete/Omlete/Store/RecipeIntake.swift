import Foundation
import Observation

struct IntakeDependencies {
    let api: APIClient
    /// Recipes belong to `Library`; a saved one is handed to it.
    let library: Library
    /// Where the outstanding job is remembered.
    var defaults: UserDefaults = .standard
    var pause: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var now: () -> Date = { Date() }
    /// A UUID, which is what the server takes as a job's key.
    var newKey: () -> RecipeJobID = { RecipeJobID(UUID().uuidString.lowercased()) }
}

/// Add a recipe: one field that is a link or a description, or photos, and
/// the one job the server does from them. App-wide, because the job takes a
/// model a minute or more and must outlive the Add tab being on screen.
///
/// The server owns the work and the phone owns the job's key. A tap mints the
/// key and writes the job to disk before anything is sent, so there is no
/// moment when a job exists that the phone could not find again. From then
/// until it ends the job is in one state, working, and `resume()` picks it up
/// the same way whether its start was answered, lost, or never left: ask for
/// the job by key, and send the start again if the server has never heard of
/// it. The start names the key, so sending it twice makes one job.
///
/// Only a clear answer ends a job: the server saying how it ended, the server
/// refusing to start it, or `giveUpAfter` passing with neither.
///
/// Invariant: at most one job is outstanding, and at most one task is asking
/// after it. `submit()` while working does nothing, so a double tap cannot
/// pay for two recipes.
@Observable final class RecipeIntake {
    enum Phase: Equatable {
        case editing
        /// The job is on disk and the phone is sending it or asking after it.
        case working(RecipeJob, Contact)
        case finished(RecipeCreation)
    }

    /// Whether the server has been answering about a job.
    enum Contact: Equatable {
        case inTouch
        /// Several tries in a row went unanswered. The job is no worse for it.
        case lost(Silence)
    }

    /// One unanswered try is a blip; from the second the screen says so.
    static let missesBeforeSayingSo = 2
    /// How long after the tap the start is still sent. A job the server has
    /// not got by then was never started, and no later send can start one.
    static let startWindow: TimeInterval = 2 * 60
    /// The longest the server lets a job stay working: `RECIPE_JOB_STALE_AFTER` in `server/main.py`.
    static let serverGivesUpAfter: TimeInterval = 6 * 60
    /// The job is over for the phone this long after the tap, whatever the
    /// server says or does not say. Every job the phone started has ended on
    /// the server by then, so the Add screen cannot stay locked past it.
    static let giveUpAfter = startWindow + serverGivesUpAfter
    private static let jobKey = "add.job"

    /// How long to leave it before trying again: often while the server
    /// answers, then backing off while it does not.
    static func wait(afterMisses misses: Int) -> Duration {
        misses == 0 ? .milliseconds(1500) : .seconds(min(1 << min(misses, 4), 15))
    }

    /// What is on disk while a job is outstanding. The text comes back with
    /// it, so a failure after a relaunch still has something to fix and
    /// resend. Photos are not kept: they are too large for `UserDefaults`.
    private struct Outstanding: Codable {
        let job: RecipeJob
        let text: String
        /// The server the job was sent to. A build pointed at another leaves it alone.
        let server: URL
    }

    private enum Move {
        case send
        case ask
    }

    private enum Reply {
        case start(RecipeStart)
        case check(RecipeJobCheck)
    }

    private(set) var text = ""
    private(set) var photos: [RecipePhoto] = []
    /// Photos picked and still being read off the photo library.
    private(set) var photosArriving = 0
    private(set) var phase = Phase.editing

    @ObservationIgnored private let deps: IntakeDependencies
    @ObservationIgnored private var polling: Task<Void, Never>?
    /// Tries unanswered in a row.
    @ObservationIgnored private var misses = 0
    /// A start for the outstanding job may have reached the server. False only
    /// from a tap until its first send is answered, goes unanswered or is
    /// replaced by `resume()`: a job restored at launch may have been sent by
    /// the app that was killed.
    @ObservationIgnored private var startMayHaveArrived = false

    /// Restores an outstanding job and sends nothing: `resume()` does that,
    /// when the scene becomes active.
    init(deps: IntakeDependencies) {
        self.deps = deps
        let saved = deps.defaults.data(forKey: Self.jobKey)
        guard let outstanding = saved.flatMap({ try? JSONDecoder().decode(Outstanding.self, from: $0) }),
            outstanding.server.absoluteString == deps.api.baseURL.absoluteString
        else { return }
        text = outstanding.text
        phase = .working(outstanding.job, .inTouch)
        startMayHaveArrived = true
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

    /// Starts a job. A saved recipe clears the field for the next one.
    /// Anything else keeps what was typed, to fix or to try again.
    func submit() {
        guard canSubmit, let request else { return }
        let job = RecipeJob(key: deps.newKey(), kind: request.kind, startedAt: deps.now())
        let outstanding = Outstanding(job: job, text: text, server: deps.api.baseURL)
        deps.defaults.set(try? JSONEncoder().encode(outstanding), forKey: Self.jobKey)
        phase = .working(job, .inTouch)
        startMayHaveArrived = false
        follow(job, first: .send)
    }

    /// Asks after an outstanding job now, not when the current wait ends. For
    /// a launch, the app coming to the front and the network returning, each
    /// of which is a reason to think the server can be reached again.
    func resume() {
        guard case .working(let job, _) = phase else { return }
        misses = 0
        // The task this replaces may have a start out whose answer it will now never take.
        startMayHaveArrived = true
        phase = .working(job, .inTouch)
        follow(job, first: .ask)
    }

    /// Replaces whatever task was following the job, so there is never more than one.
    private func follow(_ job: RecipeJob, first: Move) {
        polling?.cancel()
        // What a start would send. nil for photos after a relaunch, which are gone.
        let request = request.flatMap { $0.kind == job.kind ? $0 : nil }
        polling = Task { [weak self, api = deps.api, pause = deps.pause] in
            var move = first
            while !Task.isCancelled, self?.isStillWaiting(for: job) == true {
                let reply: Reply
                if move == .send, let request {
                    reply = .start(await api.startRecipe(request, as: job))
                } else {
                    reply = .check(await api.checkRecipe(job))
                }
                // A task replaced while its request was out must not act on the answer.
                guard !Task.isCancelled, let next = self?.take(reply, of: job, canSend: request != nil) else { return }
                move = next.move
                if let wait = next.wait {
                    guard (try? await pause(wait)) != nil else { return }
                }
            }
        }
    }

    /// False once the job is older than any job can be, which ends it. The
    /// library is refreshed because the recipe may have been saved all the
    /// same, by a server that could not say so.
    private func isStillWaiting(for job: RecipeJob) -> Bool {
        // Either side of now, so a clock put back does not keep the job for ever.
        guard abs(deps.now().timeIntervalSince(job.startedAt)) > Self.giveUpAfter else { return true }
        end(.failed(.noAnswerInTime))
        Task { await deps.library.refresh() }
        return false
    }

    /// Returns what to do next and how long to wait first, or nil when the job has ended.
    private func take(_ reply: Reply, of job: RecipeJob, canSend: Bool) -> (move: Move, wait: Duration?)? {
        let canStillStart = abs(deps.now().timeIntervalSince(job.startedAt)) <= Self.startWindow
        switch reply {
        case .start(.taken):
            startMayHaveArrived = true
            inTouch(about: job)
            return (.ask, nil)
        case .start(.refused(let failure)):
            end(.failed(failure))
            return nil
        case .start(.notSent) where !startMayHaveArrived:
            // Nothing has left the phone for this job, so there is nothing to wait for: say so at once.
            end(.failed(.unreachable))
            return nil
        case .start(.notSent):
            return missed(.noConnection, about: job, next: canStillStart ? .send : .ask)
        case .start(.unanswered(let silence)):
            // It may have arrived, so past the window the job is asked after, not written off.
            startMayHaveArrived = true
            return missed(silence, about: job, next: canStillStart ? .send : .ask)
        case .check(.working):
            inTouch(about: job)
            return (.ask, Self.wait(afterMisses: 0))
        case .check(.finished(let outcome)):
            end(outcome)
            return nil
        case .check(.recipeGone):
            // Deleted somewhere else since it was saved. Nothing failed and there is nothing to show.
            forget()
            (text, photos) = ("", [])
            phase = .editing
            Task { await deps.library.refresh() }
            return nil
        case .check(.unknown):
            guard canStillStart else {
                end(.failed(.unreachable))
                return nil
            }
            guard canSend else {
                end(.failed(.photosNotSent))
                return nil
            }
            // After a wait: a start still on its way from before would be taken for missing.
            inTouch(about: job)
            return (.send, Self.wait(afterMisses: 0))
        case .check(.unanswered(let silence)):
            return missed(silence, about: job, next: .ask)
        }
    }

    private func inTouch(about job: RecipeJob) {
        misses = 0
        phase = .working(job, .inTouch)
    }

    private func missed(_ silence: Silence, about job: RecipeJob, next: Move) -> (move: Move, wait: Duration?) {
        misses += 1
        phase = .working(job, misses < Self.missesBeforeSayingSo ? .inTouch : .lost(silence))
        return (next, Self.wait(afterMisses: misses))
    }

    private func end(_ outcome: RecipeCreation) {
        forget()
        if case .saved(let recipe) = outcome {
            deps.library.shelve(recipe)
            (text, photos) = ("", [])
        }
        phase = .finished(outcome)
    }

    private func forget() {
        deps.defaults.removeObject(forKey: Self.jobKey)
        (polling, misses) = (nil, 0)
    }
}
