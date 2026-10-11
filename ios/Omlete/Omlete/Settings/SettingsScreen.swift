import SwiftUI

/// Settings: the aisles, in the order lists are grouped by. Pushed on the tab
/// it was opened from, not a sheet: every change saves as it is made, so there
/// is nothing for a Done or a Cancel to mean, and Back returns to that tab.
///
/// The rules are `AisleOrder`'s, the saving is `AisleStore`'s and what is typed
/// is `AisleDrafts`'s. This view turns gestures into those.
struct SettingsScreen: View {
    @Environment(Library.self) private var library
    @Environment(AppNavigation.self) private var navigation

    @State private var drafts = AisleDrafts()
    /// True from the start: the screen asks as it appears, and must not say it failed before it has.
    @State private var isLoading = true

    var body: some View {
        List {
            if !store.isLoaded {
                Section { waiting }
            }
            Section {
                ForEach(aisles.names, id: \.self) { name in
                    AisleRow(
                        name: name,
                        text: Binding(get: { drafts.text(for: name) }, set: { drafts.type($0, over: name) }),
                        refusal: drafts.refusal(at: name)
                    ) {
                        save(drafts.rename(name, in: aisles, beingDeleted: store.beingDeleted))
                    } onDelete: {
                        store.delete(drafts.deleting(name, from: aisles))
                    }
                }
                .onMove { offsets, destination in
                    drafts.moved()
                    store.set(aisles.moving(offsets, to: destination))
                }
                .moveDisabled(!store.isLoaded)
                newAisle
            } header: {
                Text("Aisles")
            } footer: {
                Text("""
                    Lists are grouped in this order. Put them in the order you walk your shop: drag an aisle by its handle. \
                    Items already in an aisle you rename or delete keep the old one until you move them.
                    """)
            }
            .disabled(!store.isLoaded)
        }
        // Always in edit mode, which is what shows the handles that move an aisle.
        .environment(\.editMode, .constant(.active))
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("settings.list")
        .contentMargins(.bottom, 72, for: .scrollContent)
        .undoBanner(isCovered: navigation.immersive != nil)
        .navigationTitle("Settings")
        .refreshable { await store.load() }
        .task { await load() }
        // Back takes no focus from a field, so a rename typed and not yet offered is offered here.
        // The screen's own going, not a row's: a row also goes when a long list scrolls it away.
        .onDisappear { save(drafts.renameAll(in: aisles, beingDeleted: store.beingDeleted)) }
        .onChange(of: aisles) { drafts.orderChanged(to: aisles) }
        .onChange(of: store.refused) {
            if let refused = store.refused { drafts.saveRefused(refused, now: aisles) }
        }
    }

    private var store: AisleStore { library.aisles }

    /// Read afresh by every gesture, so none acts on the order as it was when a row was drawn.
    private var aisles: AisleOrder { store.order }

    private func save(_ order: AisleOrder?) {
        if let order { store.set(order) }
    }

    /// Only the aisles: nothing else here comes from the server.
    private func load() async {
        isLoading = true
        await store.load()
        isLoading = false
    }

    /// Shown until the server has answered for the aisles this launch.
    @ViewBuilder private var waiting: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
        } else {
            Label("Couldn't reach Omlete. Aisles can be changed once it answers.", systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
            Button("Try again") {
                Task { await load() }
            }
            .accessibilityIdentifier("settings.retryButton")
        }
    }

    private var newAisle: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("New aisle, e.g. World foods", text: $drafts.newName)
                    .submitLabel(.done)
                    .onSubmit(add)
                    .accessibilityIdentifier("settings.newAisleField")
                Button("Add", systemImage: "plus", action: add)
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderless)
                    .disabled(drafts.newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("settings.addAisleButton")
            }
            RefusalText(message: drafts.refusal(at: nil))
        }
    }

    private func add() {
        save(drafts.add(to: aisles, beingDeleted: store.beingDeleted))
    }
}

private struct RefusalText: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("settings.refusal")
        }
    }
}

/// One aisle: its name, editable where it stands, and a button to delete it.
/// A rename is offered when the field is left, which Return does too. What is
/// typed is the screen's, so the row going off screen offers nothing.
private struct AisleRow: View {
    let name: String
    @Binding var text: String
    let refusal: String?
    let onRename: () -> Void
    let onDelete: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Aisle name", text: $text)
                    .submitLabel(.done)
                    .focused($isFocused)
                    .onChange(of: isFocused) {
                        if !isFocused { onRename() }
                    }
                    .accessibilityIdentifier("settings.aisle.\(name)")
                RefusalText(message: refusal)
            }
            Button("Delete \(name)", systemImage: "minus.circle.fill", role: .destructive, action: onDelete)
                .labelStyle(.iconOnly)
                .tint(.red)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("settings.deleteAisle.\(name)")
        }
    }
}
