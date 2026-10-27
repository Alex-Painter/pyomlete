import SwiftUI

struct HomeScreen: View {
    @Environment(Library.self) private var library
    @Environment(Kitchen.self) private var kitchen
    @Environment(Chef.self) private var chef
    @Environment(AppNavigation.self) private var navigation

    @State private var renaming: ListSummary?
    @State private var isCreating = false
    @State private var actionFailure: APIError?

    var body: some View {
        let content = HomeContent(
            lists: library.rows, listsLoaded: library.hasLoaded, loadFailure: library.loadFailure,
            picks: chef.picks.shown, feedAnswered: chef.hasAnswered)
        List {
            if let actionFailure {
                Label(message(for: actionFailure), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("home.actionError")
            }
            if let shelf = library.cookShelf {
                cookSection(shelf)
            }
            if case .sections(let lists, let picks) = content {
                Section("Lists") {
                    if lists.isEmpty {
                        Label("\(HomeContent.noListsTitle). \(HomeContent.noListsInvitation)", systemImage: "calendar")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(lists) { row in
                        listRow(row)
                    }
                }
                if let week = chef.week.shown {
                    Section {
                        WeekCard(plan: week, scope: "home")
                    }
                }
                if !picks.isEmpty {
                    picksSection(picks)
                }
            }
        }
        .accessibilityIdentifier("home.list")
        // A List with no rows draws white, not the grouped grey, behind the cover.
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .overlay { cover(for: content) }
        .contentMargins(.bottom, 72, for: .scrollContent)
        .undoBanner(isCovered: navigation.immersive != nil)
        .navigationTitle("Home")
        .toolbar {
            SettingsCog(tab: .home)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    create { try await library.planWeek(today: .today()) }
                } label: {
                    // A toolbar shows a Label as its icon alone, and this is the screen's main action.
                    HStack(spacing: 4) {
                        Image(systemName: "calendar.badge.plus")
                        Text("Plan a week")
                    }
                }
                .disabled(isCreating)
                .accessibilityIdentifier("home.planWeekButton")
            }
        }
        .refreshable { await refresh() }
        .task { await appear() }
        .sheet(item: $renaming) { row in
            RenameListSheet(name: row.name) { library.list(row.id).rename($0) }
        }
    }

    /// Home asks for the feed itself, so the picks do not wait for a visit to Discover.
    private func appear() async {
        async let ideas: Void = chef.loadIfNeeded()
        async let week: Void = chef.week.load()
        await library.refresh()
        _ = await (ideas, week)
    }

    private func refresh() async {
        async let ideas: Bool = chef.load()
        async let week: Void = chef.week.load()
        await library.refresh()
        _ = await (ideas, week)
    }

    @ViewBuilder private func cover(for content: HomeContent) -> some View {
        switch content {
        case .sections:
            EmptyView()
        case .noLists:
            ContentUnavailableView(
                HomeContent.noListsTitle, systemImage: "calendar", description: Text(HomeContent.noListsInvitation))
        case .unavailable(let failure):
            ContentUnavailableView {
                Label(message(for: failure), systemImage: failure == .unreachable ? "wifi.slash" : "exclamationmark.circle")
                    .font(.headline)
            } actions: {
                Button("Try again") {
                    Task { await library.refresh() }
                }
                .accessibilityIdentifier("home.retryButton")
            }
        case .loading:
            ProgressView()
        }
    }

    /// "What's for dinner?" answered above the fold: the meals on the list
    /// last opened, one tap from cooking. Warming them means that tap usually
    /// works with no signal.
    private func cookSection(_ shelf: CookShelf) -> some View {
        Section("Cook from \(shelf.listName)") {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(shelf.meals) { meal in
                        Button {
                            navigation.startCooking(meal.id, from: shelf.listID)
                        } label: {
                            CookCard(meal: meal, cooked: shelf.cooked.contains(meal.id))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cook \(meal.title)")
                        .accessibilityValue(shelf.cooked.contains(meal.id) ? "Cooked" : "")
                        .accessibilityIdentifier("home.cookCard.\(meal.id.rawValue)")
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
        .task(id: shelf.meals.map(\.id)) {
            await kitchen.warm(shelf.meals.map(\.id))
        }
    }

    /// New ideas find you without going looking. Every row leads to Discover,
    /// where a card can be saved, added to a list or turned down.
    private func picksSection(_ picks: [Suggestion]) -> some View {
        Section {
            ForEach(picks) { card in
                Button {
                    navigation.tab = .discover
                } label: {
                    PictureRow(picture: card.imageURL, title: card.title) {
                        if let reason = card.reason {
                            Text(reason)
                                .lineLimit(2)
                        }
                    } mark: {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.pick.\(card.id.rawValue)")
            }
        } header: {
            HStack(spacing: 16) {
                IconHeader(title: "Chef's picks", systemImage: "sparkles")
                Spacer()
                Button("Clear") { chef.clear(.picks) }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("home.picks.clearButton")
                Button("See all") { navigation.tab = .discover }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("home.picks.seeAllButton")
            }
        }
    }

    private func listRow(_ row: ListSummary) -> some View {
        HStack(alignment: .top) {
            Button {
                navigation.push(.plan(row.id), on: .home)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.name)
                        .font(.headline)
                    Text(counts(for: row))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if row.itemCount > 0 {
                        ProgressView(value: Double(row.checkedCount), total: Double(row.itemCount))
                    }
                    if !row.meals.isEmpty {
                        Text(row.meals.map(\.title).joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.listRow.\(row.id.rawValue)")

            Menu {
                Button("Rename", systemImage: "pencil") { renaming = row }
                    .accessibilityIdentifier("home.renameAction")
                Button("Duplicate", systemImage: "doc.on.doc") {
                    create { try await library.duplicate(row.id) }
                }
                .accessibilityIdentifier("home.duplicateAction")
                Button("Delete list", systemImage: "trash", role: .destructive) { library.delete(row.id) }
                    .accessibilityIdentifier("home.deleteAction")
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("More for \(row.name)")
            .accessibilityIdentifier("home.listActions.\(row.id.rawValue)")
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { library.delete(row.id) }
        }
    }

    private func counts(for row: ListSummary) -> String {
        var parts = [
            "\(row.meals.count) meal\(row.meals.count == 1 ? "" : "s")",
            "\(row.itemCount - row.checkedCount) to get",
        ]
        if row.checkedCount > 0 { parts.append("\(row.checkedCount) got") }
        return parts.joined(separator: " · ")
    }

    private func message(for failure: APIError) -> String {
        failure == .unreachable ? "Couldn't reach Omlete. Check your connection." : "Something went wrong loading this."
    }

    private func create(_ make: @escaping () async throws -> ListID) {
        isCreating = true
        actionFailure = nil
        Task {
            defer { isCreating = false }
            do {
                navigation.push(.plan(try await make()), on: .home)
            } catch {
                actionFailure = error as? APIError ?? .undecodable
            }
        }
    }
}
