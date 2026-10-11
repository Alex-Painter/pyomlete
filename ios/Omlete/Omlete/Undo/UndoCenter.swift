import Foundation
import Observation

/// The one Undo banner, app-wide. Destructive actions apply at once and offer
/// Undo here instead of asking first.
///
/// Invariant: for each offer exactly one of `undo` and `commit` runs, once.
/// `undo` runs on a tap. `commit` runs when the banner times out, when another
/// offer replaces it, or when the app leaves the foreground.
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
    @ObservationIgnored private var waiting: String?

    init(duration: Duration = .seconds(5)) {
        self.duration = duration
    }

    func offer(_ message: String, undo: (() -> Void)? = nil, commit: (() -> Void)? = nil) {
        settle(committing: true)
        lastID += 1
        banner = Banner(id: lastID, message: message, canUndo: undo != nil)
        self.undo = undo
        self.commit = commit
        timer = Task { [weak self, duration] in
            try? await Task.sleep(for: duration)
            if !Task.isCancelled { self?.commitNow() }
        }
    }

    /// News nobody tapped for, such as a save that failed in the background. It
    /// never costs the user an Undo: while a banner with Undo is up it waits,
    /// and shows once that banner has settled on its own.
    func inform(_ message: String) {
        if banner?.canUndo == true {
            waiting = message
        } else {
            offer(message)
        }
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
        guard let message = waiting, banner == nil else { return }
        waiting = nil
        offer(message)
    }

    private func settle(committing: Bool) {
        let commit = commit
        timer?.cancel()
        timer = nil
        banner = nil
        undo = nil
        self.commit = nil
        if committing { commit?() }
    }
}
