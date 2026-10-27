import Foundation
import Observation

/// Chef's week: the plan of five dinners waiting on Home and Discover, and
/// the only writer of it. Owned by `Chef`, so it lives as long as the app.
///
/// Planning waits on a model for minutes, and the list Make the list made
/// fills in as its new ideas save. Both run in tasks this owns, so leaving
/// the screen cancels neither. Nothing here navigates: Open is the banner's,
/// and only a tap runs it.
@Observable final class ChefWeek {
    /// The plan waiting for Make the list, as the server last gave it.
    private var plan: WeekPlan?
    /// A plan hidden by "Not this week" until the server has been told.
    private var skipped: WeekPlanID?
    private(set) var isPlanning = false
    private(set) var isMaking = false

    @ObservationIgnored private let deps: ChefDependencies
    /// Refreshes the made list until its new ideas have landed on it.
    @ObservationIgnored private var following: Task<Void, Never>?

    init(deps: ChefDependencies) {
        self.deps = deps
    }

    /// The card to show, if any.
    var shown: WeekPlan? {
        plan.flatMap { $0.id == skipped ? nil : $0 }
    }

    /// A failed load keeps the card already shown.
    func load() async {
        guard let waiting = try? await deps.api.waitingWeek() else { return }
        plan = waiting
    }

    /// Discover's Plan my week. Ignored while one is running.
    func planMyWeek() {
        guard !isPlanning else { return }
        isPlanning = true
        Task {
            do {
                plan = try await deps.api.planWeek()
            } catch {
                deps.undo.offer("Chef couldn't plan a week right now. Try again in a bit.")
                // A request that timed out here may still have finished on the server.
                await load()
            }
            isPlanning = false
        }
    }

    /// Makes the week's list at once, with Undo and `open` on the banner. The
    /// made list joins Home's Lists, and its evenings fill as the new ideas save.
    func make(open: @escaping (ListID) -> Void) {
        guard let plan = shown, !isMaking else { return }
        isMaking = true
        Task {
            defer { isMaking = false }
            let made: MadeWeek
            do {
                made = try await deps.api.makeWeek(plan.id)
            } catch {
                deps.undo.offer("Couldn't make the list. Try again.")
                await load()
                return
            }
            if self.plan?.id == plan.id { self.plan = nil }
            deps.undo.offer(
                "Made \(made.name). New ideas join it as they're ready.",
                undo: { [weak self] in self?.takeBack(made) },
                action: .init(label: "Open") { open(made.list) },
                lasting: .seconds(8))
            await deps.library.refresh()
            follow(made.list, ideas: plan.meals.count(where: \.isNew))
        }
    }

    /// "Not this week": hides the card at once and, unless undone, tells the
    /// server, which learns nothing about taste from it.
    func skip() {
        guard let plan = shown else { return }
        skipped = plan.id
        deps.undo.offer("Skipped this week", undo: { [weak self] in
            self?.skipped = nil
        }, commit: { [weak self, api = deps.api] in
            Task {
                // Left hidden if the server cannot be told, as Discover's cards are.
                guard (try? await api.skipWeek(plan.id)) != nil, let self, self.plan?.id == plan.id else { return }
                self.plan = nil
            }
        })
    }

    private func takeBack(_ made: MadeWeek) {
        following?.cancel()
        Task {
            do throws(APIError) {
                try await deps.api.undoChefAction(made.undo)
            } catch {
                deps.undo.offer(
                    error == .rejected(409) ? "That list has changed since, so it was kept." : "Couldn't undo that. Try again.")
            }
            await deps.library.refresh()
            deps.library.list(made.list).sync(refresh: true)
            await load()
        }
    }

    /// Refreshes the list every `Chef.pollEvery` until `ideas` more meals are
    /// on it than when it was made, or until the server would have given up
    /// on their saves. A save that fails says nothing to the phone, so the
    /// time limit is what ends polling for it.
    private func follow(_ list: ListID, ideas: Int) {
        following?.cancel()
        guard ideas > 0 else { return }
        following = Task { [deps] in
            let store = deps.library.list(list)
            await store.refresh()
            let meals = { store.replica.current?.recipes.count ?? 0 }
            let goal = meals() + ideas
            let deadline = deps.now() + Chef.giveUpAfter
            while meals() < goal, deps.now() < deadline, !store.isGone,
                  (try? await deps.pause(Chef.pollEvery)) != nil, !Task.isCancelled {
                let before = meals()
                await store.refresh()
                // A recipe the library has not seen: Home names a list's meals from it.
                if meals() > before { await deps.library.refresh() }
            }
        }
    }
}
