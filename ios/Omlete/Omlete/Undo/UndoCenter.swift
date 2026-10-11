import Foundation
import Observation

/// The one Undo banner, app-wide. Destructive actions apply at once and offer
/// Undo here instead of asking first.
///
/// Invariant: for each offer exactly one of `undo` and `commit` runs, once.
/// `undo` runs on a tap. `commit` runs when the banner times out, when another
/// offer replaces it, or when the app leaves the foreground.
///
/// Invariant: news given to `inform` is said in the order it came and none is
/// dropped. A piece cut short, by an offer or by the app leaving, is said again.
@Observable final class UndoCenter {
    struct Banner: Identifiable, Equatable {
        let id: Int
        let message: String
        let canUndo: Bool
    }

    private(set) var banner: Banner?

    @ObservationIgnored private let duration: Duration
    @ObservationIgnored private var undo: (() -> Void)?
    @ObservationIgnored private var commit: (() -> Void)?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var lastID = 0
    /// News not yet said, oldest first.
    @ObservationIgnored private var waiting: [String] = []
    /// The banner now up is news, and this is its message. An offer or the app
    /// leaving cuts it short, and then it goes back to the head of `waiting`.
    @ObservationIgnored private var news: String?
    @ObservationIgnored private var isInFront = true

    init(duration: Duration = .seconds(5)) {
        self.duration = duration
    }

    func offer(_ message: String, undo: (() -> Void)? = nil, commit: (() -> Void)? = nil) {
        cutNewsShort()
        settle(committing: true)
        show(message, undo: undo, commit: commit)
    }

    private func show(_ message: String, undo: (() -> Void)? = nil, commit: (() -> Void)? = nil) {
        lastID += 1
        banner = Banner(id: lastID, message: message, canUndo: undo != nil)
        self.undo = undo
        self.commit = commit
        timer?.cancel()
        timer = Task { [weak self, duration] in
            try? await Task.sleep(for: duration)
            if !Task.isCancelled { self?.commitNow() }
        }
    }

    /// News nobody tapped for, such as a save that failed in the background. It
    /// never costs the user an Undo: while a banner with Undo is up it waits,
    /// and shows once that banner has settled on its own. It waits its turn
    /// behind earlier news too, and for the app to be in front, where it can
    /// be read. Only a message with nothing to undo gives way to it.
    func inform(_ message: String) {
        // Said once: the same failure met four times is still one thing to read.
        guard message != news, !waiting.contains(message) else { return }
        waiting.append(message)
        if banner?.canUndo == false, news == nil { settle(committing: true) }
        sayWhatWaited()
    }

    /// Leaving the app settles the banner, as closing the page does on the web.
    func appLeftFront() {
        isInFront = false
        cutNewsShort()
        settle(committing: true)
    }

    func appCameToFront() {
        isInFront = true
        sayWhatWaited()
    }

    func undoTapped() {
        let undo = undo
        settle(committing: false)
        undo?()
        sayWhatWaited()
    }

    func commitNow() {
        settle(committing: true)
        sayWhatWaited()
    }

    private func sayWhatWaited() {
        guard isInFront, banner == nil, !waiting.isEmpty else { return }
        let message = waiting.removeFirst()
        show(message)
        news = message
    }

    private func cutNewsShort() {
        if let news { waiting.insert(news, at: 0) }
    }

    private func settle(committing: Bool) {
        let commit = commit
        timer?.cancel()
        timer = nil
        banner = nil
        news = nil
        undo = nil
        self.commit = nil
        if committing { commit?() }
    }
}
