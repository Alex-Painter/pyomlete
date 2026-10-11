import SwiftUI

/// Discover: new things to cook, so the week does not need inventing from
/// scratch. Shelves of cards, each with the reason it is here. Save, Add to
/// list and Not for me are what Chef learns taste from; Clear all only tidies.
struct DiscoverScreen: View {
    @Environment(Chef.self) private var chef
    @Environment(AppNavigation.self) private var navigation

    @State private var isTuning = false

    var body: some View {
        let feed = chef.feed
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("New things to cook, picked for you by Chef.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                if chef.isFindingIdeas {
                    SkeletonShelf(title: "Finding new ideas…")
                } else if feed == .loading {
                    SkeletonShelf(title: "Loading")
                }
                if case .shelves(let shelves) = feed {
                    ForEach(shelves) { shelf in
                        ShelfRow(shelf: shelf)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("discover.feed")
        .overlay {
            if !chef.isFindingIdeas { stateMessage(for: feed) }
        }
        .contentMargins(.bottom, 72, for: .scrollContent)
        .background(Color(.systemGroupedBackground))
        .undoBanner(isCovered: navigation.immersive != nil)
        .navigationTitle("Discover")
        .toolbar {
            if case .shelves = feed {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear all") { chef.clearAll() }
                        .accessibilityIdentifier("discover.clearAllButton")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Tune suggestions", systemImage: "slider.horizontal.3") { isTuning = true }
                    .accessibilityIdentifier("discover.tuneButton")
                Button("Get new ideas", systemImage: "arrow.clockwise") { chef.findIdeas() }
                    .disabled(chef.isFindingIdeas)
                    .accessibilityIdentifier("discover.getIdeasButton")
            }
        }
        // Returns at once: Chef owns the request, and the shelf above says it is working.
        .refreshable { chef.findIdeas() }
        .task { await chef.load() }
        .sheet(isPresented: $isTuning) {
            TuneSheet(settings: chef.tune) { chef.findIdeas(tuned: $0) }
        }
    }

    @ViewBuilder private func stateMessage(for feed: DiscoverFeed) -> some View {
        switch feed {
        case .loading, .shelves:
            EmptyView()
        case .empty:
            ContentUnavailableView {
                Label("No ideas here yet", systemImage: "safari")
            } description: {
                Text("Ideas are based on what you rate, save and shop for. The more you cook, the better they get.")
            } actions: {
                Button("Get ideas") { chef.findIdeas() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("discover.emptyGetIdeasButton")
            }
        case .unavailable(let failure):
            LoadFailure(failure: failure, retryIdentifier: "discover.retryButton") { await chef.load() }
        }
    }
}

/// A titled row of cards that scrolls sideways, one card snapping into place at a time.
private struct ShelfRow: View {
    let shelf: Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shelf.section.title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(shelf.cards) { card in
                        SuggestionCard(card: card)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("discover.shelf.\(shelf.section.rawValue)")
        }
    }
}

private struct SkeletonShelf: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView()
                Text(title)
                    .font(.title3.weight(.semibold))
            }
            .padding(.horizontal, 16)
            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(.secondarySystemGroupedBackground))
                        .frame(width: SuggestionCard.width, height: 320)
                }
            }
            .padding(.horizontal, 16)
            .accessibilityHidden(true)
        }
        // Three cards are wider than the screen, and a placeholder should not scroll.
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}
