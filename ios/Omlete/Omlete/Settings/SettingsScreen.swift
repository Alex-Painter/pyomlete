import SwiftUI

/// Settings: the aisles, in the order lists are grouped by. Pushed on the tab
/// it was opened from, not a sheet: every change saves as it is made, so there
/// is nothing for a Done or a Cancel to mean, and Back returns to that tab.
///
/// The rules are `AisleOrder`'s and the saving is `Library`'s. This view turns
/// gestures into one or the other and words a refusal.
struct SettingsScreen: View {
    @Environment(Library.self) private var library
    @Environment(AppNavigation.self) private var navigation

    @State private var newName = ""
    /// Why the last name typed was not taken, until the next change.
    @State private var refusal: String?
    @State private var isLoading = false

    var body: some View {
        let order = AisleOrder(library.aisleOrder)
        List {
            Section {
                if !library.aislesLoaded {
                    waiting
                }
                if let refusal {
                    Label(refusal, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("settings.refusal")
                }
                ForEach(order.names, id: \.self) { name in
                    AisleRow(name: name) { rename(name, to: $0, in: order) } onDelete: {
                        refusal = nil
                        library.deleteAisle(name)
                    }
                }
                .onMove { offsets, destination in
                    refusal = nil
                    library.setAisles(order.moving(offsets, to: destination))
                }
                newAisle(in: order)
            } header: {
                Text("Aisles")
            } footer: {
                Text("""
                    Lists are grouped in this order. Put them in the order you walk your shop: drag an aisle by its handle. \
                    Items already in an aisle you rename or delete keep the old one until you move them.
                    """)
            }
            .disabled(!library.aislesLoaded)
        }
        // Always in edit mode, which is what shows the handles that move an aisle.
        .environment(\.editMode, .constant(.active))
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("settings.list")
        .contentMargins(.bottom, 72, for: .scrollContent)
        .undoBanner(isCovered: navigation.immersive != nil)
        .navigationTitle("Settings")
        .refreshable { await library.refresh() }
        .task {
            isLoading = true
            await library.refresh()
            isLoading = false
        }
    }

    /// Shown until the server has answered for the aisles this launch.
    @ViewBuilder private var waiting: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
        } else {
            Label("Couldn't reach Omlete. Aisles can be changed once it answers.", systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.unavailable")
        }
    }

    private func newAisle(in order: AisleOrder) -> some View {
        HStack {
            TextField("New aisle, e.g. World foods", text: $newName)
                .submitLabel(.done)
                .onSubmit { add(to: order) }
                .accessibilityIdentifier("settings.newAisleField")
            Button("Add", systemImage: "plus") { add(to: order) }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderless)
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("settings.addAisleButton")
        }
    }

    private func add(to order: AisleOrder) {
        do {
            library.setAisles(try order.adding(newName))
            newName = ""
            refusal = nil
        } catch {
            refusal = message(for: error)
        }
    }

    private func rename(_ name: String, to typed: String, in order: AisleOrder) {
        do {
            library.setAisles(try order.renaming(name, to: typed))
            refusal = nil
        } catch {
            refusal = message(for: error)
        }
    }

    private func message(for refusal: AisleOrder.Refusal) -> String? {
        switch refusal {
        case .empty: nil
        case .taken(let other): "There's already an aisle called \(other)."
        }
    }
}

/// One aisle: its name, editable where it stands, and a button to delete it.
/// A rename is offered when Return is pressed or the field is left.
private struct AisleRow: View {
    let name: String
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var text: String
    @FocusState private var isFocused: Bool

    init(name: String, onRename: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
        self.name = name
        self.onRename = onRename
        self.onDelete = onDelete
        _text = State(initialValue: name)
    }

    var body: some View {
        HStack {
            TextField("Aisle name", text: $text)
                .submitLabel(.done)
                .focused($isFocused)
                .onChange(of: isFocused) {
                    guard !isFocused, text != name else { return }
                    onRename(text)
                    // A name that was taken shows in a new row; this one is the old name's.
                    text = name
                }
                .accessibilityIdentifier("settings.aisle.\(name)")
            Button("Delete \(name)", systemImage: "minus.circle.fill", role: .destructive, action: onDelete)
                .labelStyle(.iconOnly)
                .tint(.red)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("settings.deleteAisle.\(name)")
        }
    }
}
