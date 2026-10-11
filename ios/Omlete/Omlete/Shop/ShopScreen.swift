import SwiftUI

/// Shop: the list as you walk the aisles. Full screen, screen kept awake, big
/// rows in your aisle order that you can tap anywhere. Works with no signal.
/// There is no "done shopping" step: leaving changes nothing, and anything
/// left unchecked stays on the list.
struct ShopScreen: View {
    let listID: ListID

    @Environment(Library.self) private var library
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        let store = library.list(listID)
        NavigationStack {
            Group {
                switch store.phase {
                case .loading:
                    ProgressView()
                case .gone:
                    ContentUnavailableView("This list has been deleted.", systemImage: "trash")
                case .unavailable:
                    ContentUnavailableView {
                        Label("Couldn't reach Omlete. Check your connection.", systemImage: "wifi.slash")
                    } actions: {
                        Button("Try again") {
                            Task { await store.refresh() }
                        }
                        .accessibilityIdentifier("shop.retryButton")
                    }
                case .ready(let list):
                    aisles(of: list, in: store)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Leave shopping mode", systemImage: "xmark") { navigation.leaveImmersive() }
                        .accessibilityIdentifier("shop.closeButton")
                }
                if let pill = store.syncStatus.pillText {
                    ToolbarItem(placement: .topBarTrailing) {
                        Label(pill, systemImage: "icloud.slash")
                            .labelStyle(.titleAndIcon)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .accessibilityIdentifier("shop.syncPill")
                    }
                }
            }
        }
        .task { await store.refresh() }
        .keepsScreenAwake()
        .undoBanner()
        .interactiveDismissDisabled(true)
    }

    private func aisles(of list: ListDetail, in store: ListStore) -> some View {
        let layout = ListLayout(list, aisleOrder: library.aisleOrder)
        return List {
            Section {
                QuickAddField(screen: "shop", placeholder: "Spotted something? Add it") { store.add($0) }
            }

            if layout.remaining == 0 {
                VStack(spacing: 8) {
                    Image(systemName: "party.popper")
                        .font(.largeTitle)
                        .foregroundStyle(.yellow)
                    Text("Everything's in the basket.")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .listRowBackground(Color.clear)
            }

            ForEach(layout.aisles) { aisle in
                Section(aisle.name) {
                    ForEach(aisle.items) { item in
                        row(item, in: store)
                    }
                }
            }

            if !layout.got.isEmpty {
                Section("Got it (\(layout.got.count))") {
                    ForEach(layout.got) { item in
                        row(item, in: store)
                    }
                }
            }
        }
        .animation(.default, value: layout)
        .contentMargins(.bottom, 72, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle(list.name)
        .navigationSubtitle(layout.remaining == 0 ? "Nothing left to get" : "\(layout.remaining) left to get")
    }

    private func row(_ item: ListItem, in store: ListStore) -> some View {
        ItemRow(item: item, identifier: "shop.itemRow.\(item.id.rawValue)", large: true) {
            store.setChecked(item.id, !item.checked, undoable: true)
        }
    }
}
