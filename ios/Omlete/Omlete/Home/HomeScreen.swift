import SwiftUI

struct HomeScreen: View {
    @Environment(Library.self) private var library
    @Environment(AppNavigation.self) private var navigation

    @State private var renaming: ListSummary?
    @State private var isCreating = false
    @State private var actionFailure: APIError?

    var body: some View {
        let rows = library.rows
        List {
            if let actionFailure {
                Label(message(for: actionFailure), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("home.actionError")
            }
            if !rows.isEmpty {
                Section("Lists") {
                    ForEach(rows) { row in
                        listRow(row)
                    }
                }
            }
        }
        .overlay {
            if rows.isEmpty { emptyState }
        }
        .contentMargins(.bottom, 72, for: .scrollContent)
        .undoBanner()
        .navigationTitle("Home")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    create { try await library.newList() }
                } label: {
                    // A toolbar shows a Label as its icon alone, and this is the screen's main action.
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("New list")
                    }
                }
                .disabled(isCreating)
                .accessibilityIdentifier("home.newListButton")
            }
        }
        .refreshable { await library.refresh() }
        .task { await library.refresh() }
        .sheet(item: $renaming) { row in
            RenameListSheet(name: row.name) { library.list(row.id).rename($0) }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if library.hasLoaded {
            ContentUnavailableView(
                "No lists yet", systemImage: "cart",
                description: Text("Start one, add a few meals, and the ingredients collect themselves."))
        } else if let failure = library.loadFailure {
            ContentUnavailableView {
                Label(message(for: failure), systemImage: failure == .unreachable ? "wifi.slash" : "exclamationmark.circle")
                    .font(.headline)
            } actions: {
                Button("Try again") {
                    Task { await library.refresh() }
                }
                .accessibilityIdentifier("home.retryButton")
            }
        } else {
            ProgressView()
        }
    }

    private func listRow(_ row: ListSummary) -> some View {
        HStack(alignment: .top) {
            Button {
                navigation.path.append(.plan(row.id))
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
                navigation.path.append(.plan(try await make()))
            } catch {
                actionFailure = error as? APIError ?? .undecodable
            }
        }
    }
}
