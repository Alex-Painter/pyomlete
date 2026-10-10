import SwiftUI

/// Cook: one step at a time in large type, only the ingredients that step
/// uses, timers started with a tap, and a servings control that scales every
/// amount. Full screen, screen kept awake. Opened for any meal whatever has or
/// hasn't been checked off, and finishing it leaves you in Cook: only the
/// close button goes back to where it was opened from.
struct CookScreen: View {
    let recipeID: RecipeID

    @Environment(Kitchen.self) private var kitchen
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        let store = kitchen.cook(recipeID)
        NavigationStack {
            Group {
                switch store.phase {
                case .loading:
                    ProgressView()
                case .gone:
                    ContentUnavailableView("This recipe has been deleted.", systemImage: "trash")
                case .unavailable:
                    ContentUnavailableView {
                        Label("Couldn't reach Omlete. Check your connection.", systemImage: "wifi.slash")
                    } actions: {
                        Button("Try again") {
                            Task { await store.open() }
                        }
                        .accessibilityIdentifier("cook.retryButton")
                    }
                case .cooking(let session):
                    cooking(session, in: store)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Stop cooking", systemImage: "xmark") { navigation.leaveImmersive() }
                        .accessibilityIdentifier("cook.closeButton")
                }
            }
        }
        .task { await store.open() }
        .keepsScreenAwake()
        .interactiveDismissDisabled(true)
    }

    private func cooking(_ session: CookSession, in store: CookStore) -> some View {
        let page = session.page
        return Group {
            switch page {
            case .overview(let needs):
                CookOverview(servings: session.servings, needs: needs, onFewer: store.fewer, onMore: store.more)
            case .step(let step):
                CookStep(page: step, onStartTimer: store.startTimer)
            case .finished:
                CookFinished(rating: store.rating, onRate: store.rate)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if case .step(let step) = page {
                    StepProgress(page: step)
                }
                if !session.timers.isEmpty {
                    TimerChips(timers: session.timers, onDismiss: store.dismissTimer)
                }
            }
            .background(.bar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            controls(for: page, canStart: session.canStart, in: store)
                .controlSize(.large)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.bar)
        }
        .animation(.snappy, value: session.stage)
        .animation(.snappy, value: session.timers.map(\.id))
        .navigationTitle(session.recipe.title)
    }

    @ViewBuilder
    private func controls(for page: CookSession.Page, canStart: Bool, in store: CookStore) -> some View {
        switch page {
        case .overview:
            Button(action: store.start) {
                Text("Start cooking")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStart)
            .accessibilityIdentifier("cook.startButton")
        case .step(let step):
            HStack(spacing: 12) {
                Button(action: store.back) {
                    Label("Back", systemImage: "arrow.left")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("cook.backButton")

                Button(action: store.next) {
                    Group {
                        if step.isLast {
                            Label("Finish", systemImage: "checkmark")
                        } else {
                            // Laid out by hand: a Label puts its icon first, and this arrow points onward.
                            HStack(spacing: 6) {
                                Text("Next")
                                Image(systemName: "arrow.right")
                            }
                        }
                    }
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("cook.nextButton")
            }
        case .finished:
            Button(action: store.back) {
                Label("Last step", systemImage: "arrow.left")
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("cook.lastStepButton")
        }
    }
}

private struct StepProgress: View {
    let page: CookSession.StepPage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Step \(page.number) of \(page.count)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            ProgressView(value: page.progress)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
