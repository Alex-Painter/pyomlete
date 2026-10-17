import Foundation
import Observation

/// The editor's state: the draft, and how far a tap on Save has got. Owned by
/// `RecipeEditor` and apart from it, so what Save does and says is tested
/// without a view.
@Observable final class RecipeEditorModel {
    enum Phase: Equatable {
        case editing
        case saving
        /// Save was tapped and nothing was saved; this says why.
        case stopped(String)
        /// Saved, or there was nothing to save. The sheet closes.
        case finished
    }

    var draft: RecipeDraft {
        didSet {
            guard draft != oldValue else { return }
            outcome = draft.outcome
            if case .stopped = phase { phase = .editing }
        }
    }

    private(set) var phase: Phase = .editing
    /// What Save would send. Kept, because every row reads it and working it out walks them all.
    private(set) var outcome: RecipeDraft.Outcome

    @ObservationIgnored private let untouched: RecipeDraft.Outcome
    @ObservationIgnored private let store: CookStore

    init(draft: RecipeDraft, store: CookStore) {
        self.draft = draft
        self.store = store
        outcome = draft.outcome
        untouched = draft.untouchedOutcome
    }

    var hasChanges: Bool { outcome != untouched }

    /// The rows whose quantity cannot be saved.
    var unreadable: [RecipeDraft.RowID] {
        if case .fix(let rows) = outcome { rows } else { [] }
    }

    /// Does nothing while a save is out: what that one sent is what closes the sheet.
    func save() async {
        guard phase != .saving, phase != .finished else { return }
        switch outcome {
        case .fix(let rows):
            let names = draft.ingredients.filter { rows.contains($0.id) }.map(\.name.trimmed)
            phase = .stopped("The quantity for \(names.formatted(.list(type: .and))) has to be a plain number, or empty.")
        case .save where !hasChanges:
            phase = .finished
        case .save(let edit):
            phase = .saving
            do throws(APIError) {
                try await store.save(edit)
                phase = .finished
            } catch {
                phase = .stopped(Self.message(for: error))
            }
        }
    }

    /// An edit is never queued, so each of these says plainly that the recipe is not saved.
    private static func message(for failure: APIError) -> String {
        switch failure {
        case .unreachable:
            "Couldn't reach Omlete, so this may not be saved. Saving an edit needs a connection. Your changes are still here, and saving again is safe."
        case .rejected(404):
            "This recipe doesn't exist any more, so it can't be saved."
        case .serverFault, .rejected, .undecodable:
            "Couldn't save. Your changes are still here, so try again."
        }
    }
}
