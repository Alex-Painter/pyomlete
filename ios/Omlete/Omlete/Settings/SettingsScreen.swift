import SwiftUI

/// Settings: the aisles, in the order lists are grouped by, then what Chef
/// knows. Pushed on the tab
/// it was opened from, not a sheet: every change saves as it is made, so there
/// is nothing for a Done or a Cancel to mean, and Back returns to that tab.
///
/// The rules are `AisleOrder`'s, the saving is `AisleStore`'s and what is typed
/// is `AisleDrafts`'s. This view turns gestures into those.
struct SettingsScreen: View {
    @Environment(Library.self) private var library
    @Environment(AppNavigation.self) private var navigation
    @Environment(Chef.self) private var chef
    @Environment(ChefChat.self) private var chefChat

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
            WhatChefKnows(memory: chef.memory) { chefChat.height = .half }
        }
        // Always in edit mode, which is what shows the handles that move an aisle.
        .environment(\.editMode, .constant(.active))
        // A list drawn before the aisles loaded keeps its rows without handles, so it is drawn again.
        .id(store.isLoaded)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("settings.list")
        .contentMargins(.bottom, 72, for: .scrollContent)
        .undoBanner(isCovered: navigation.immersive != nil)
        .navigationTitle("Settings")
        .refreshable {
            async let aisles: Void = store.load()
            async let known: Void = chef.memory.load()
            _ = await (aisles, known)
        }
        .task { await load() }
        .task { await chef.memory.load() }
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

/// What Chef goes by when it suggests and plans: what you told it, then what
/// it noticed, each with what it's based on. Forget applies at once, with Undo.
private struct WhatChefKnows: View {
    let memory: ChefMemory
    let tellChef: () -> Void

    var body: some View {
        Section {
            Text("Chef goes by this when it suggests meals. Tell it more in chat, like \u{201C}no mushrooms\u{201D} or \u{201C}more fish\u{201D}.")
                .foregroundStyle(.secondary)
            switch memory.status {
            case .loading where memory.preferences.isEmpty:
                ProgressView()
                    .frame(maxWidth: .infinity)
            case .failed:
                Label("Couldn't load what Chef knows.", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
                Button("Try again") {
                    Task { await memory.load() }
                }
                .accessibilityIdentifier("settings.chefKnows.retryButton")
            default:
                if memory.preferences.isEmpty {
                    Text("Nothing yet. Chef learns from what you cook and rate, and from what you tell it.")
                        .accessibilityIdentifier("settings.chefKnows.empty")
                }
            }
        } header: {
            Text("What Chef knows")
        }
        group("You told Chef", memory.told)
        group("Chef noticed", memory.noticed)
        Section {
            Button("Tell Chef", systemImage: "bubble.left.and.text.bubble.right", action: tellChef)
                .accessibilityIdentifier("settings.tellChefButton")
        }
    }

    @ViewBuilder private func group(_ title: String, _ preferences: [Preference]) -> some View {
        if !preferences.isEmpty {
            Section(title) {
                ForEach(preferences) { preference in
                    PreferenceRow(preference: preference) { memory.forget(preference) }
                }
            }
        }
    }
}

private struct PreferenceRow: View {
    let preference: Preference
    let onForget: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text(preference.stance.label).fontWeight(.semibold)) \(preference.subject)")
                Text(preference.evidence)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.preference.\(preference.subject)")
            Spacer()
            Button("Forget \(preference.subject)", systemImage: "xmark", action: onForget)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.forgetPreference.\(preference.subject)")
        }
    }
}
