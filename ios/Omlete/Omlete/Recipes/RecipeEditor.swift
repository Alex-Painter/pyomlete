import SwiftUI

/// Editing a recipe: its title, ingredients and method, saved together by one
/// tap on Save. A sheet, so Save and Cancel stay in the bar however far down
/// the edit goes and the page underneath is untouched until the save lands.
///
/// Nothing typed is lost by accident. A draft with changes cannot be swiped
/// away, a save that fails leaves the sheet up as it was, and Cancel hands the
/// draft to `onDiscard` so the page can offer it back with Undo.
struct RecipeEditor: View {
    let store: CookStore
    let aisles: [String]
    let units: [String]
    let onDiscard: (RecipeDraft) -> Void

    @State private var draft: RecipeDraft
    @State private var phase: Phase = .editing
    /// The row whose first field has the keyboard, so an added row is ready to type in.
    @FocusState private var focus: RecipeDraft.RowID?
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case editing
        case saving
        /// Save was tapped and nothing was saved; this says why.
        case stopped(String)
    }

    init(
        draft: RecipeDraft, store: CookStore, aisles: [String], units: [String],
        onDiscard: @escaping (RecipeDraft) -> Void
    ) {
        self.store = store
        self.aisles = aisles
        self.units = units
        self.onDiscard = onDiscard
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $draft.title, axis: .vertical)
                        .font(.headline)
                        .accessibilityIdentifier("recipeEditor.titleField")
                }
                Section("Ingredients") {
                    ForEach($draft.ingredients) { $row in
                        ingredient($row, at: draft.ingredients.firstIndex { $0.id == row.id } ?? 0)
                    }
                    Button("Add ingredient", systemImage: "plus") { focus = draft.addIngredient() }
                        .accessibilityIdentifier("recipeEditor.addIngredientButton")
                }
                Section {
                    ForEach($draft.steps) { $row in
                        step($row, at: draft.steps.firstIndex { $0.id == row.id } ?? 0)
                    }
                    .onMove { draft.steps.move(fromOffsets: $0, toOffset: $1) }
                    Button("Add step", systemImage: "plus") { focus = draft.addStep() }
                        .accessibilityIdentifier("recipeEditor.addStepButton")
                } header: {
                    Text("Method")
                } footer: {
                    if draft.steps.count > 1 { Text("Drag a step by its handle to move it.") }
                }
            }
            // Always in edit mode, which is what shows the handles that move a step.
            .environment(\.editMode, .constant(.active))
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("recipeEditor.form")
            .safeAreaInset(edge: .bottom) { stoppedMessage }
            .navigationTitle("Edit recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .disabled(phase == .saving)
                        .accessibilityIdentifier("recipeEditor.cancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if phase == .saving {
                        ProgressView()
                            .accessibilityIdentifier("recipeEditor.saving")
                    } else {
                        Button("Save", action: save)
                            .accessibilityIdentifier("recipeEditor.saveButton")
                    }
                }
            }
        }
        .interactiveDismissDisabled(draft.hasChanges || phase == .saving)
        .onChange(of: draft) {
            if case .stopped = phase { phase = .editing }
        }
    }

    private func ingredient(_ row: Binding<RecipeDraft.IngredientRow>, at position: Int) -> some View {
        let id = "recipeEditor.ingredient.\(position)"
        let name = row.wrappedValue.name.trimmed
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                TextField("Ingredient", text: row.name)
                    .focused($focus, equals: row.wrappedValue.id)
                    .accessibilityIdentifier("\(id).nameField")
                removeButton("Remove \(name.isEmpty ? "ingredient" : name)") {
                    draft.ingredients.removeAll { $0.id == row.wrappedValue.id }
                }
                .accessibilityIdentifier("\(id).removeButton")
            }
            HStack(spacing: 8) {
                TextField("Qty", text: row.quantity)
                    .keyboardType(.decimalPad)
                    .foregroundStyle(unreadable.contains(row.wrappedValue.id) ? .red : .primary)
                    .frame(width: 52)
                    .accessibilityLabel("Quantity")
                    .accessibilityIdentifier("\(id).quantityField")
                TextField("Unit", text: row.unit)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("\(id).unitField")
                Menu("Choose a unit", systemImage: "chevron.up.chevron.down") {
                    ForEach(RecipeDraft.unitChoices(server: units), id: \.self) { unit in
                        Button(unit) { row.wrappedValue.unit = unit }
                            .accessibilityIdentifier("recipeEditor.unit.\(unit)")
                    }
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("\(id).unitMenu")
            }
            .font(.subheadline)
            // On its own line: beside the unit, "Pantry & Dry Goods" and "tablespoons" cut each other short.
            HStack {
                Text("Aisle")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Picker("Aisle", selection: aisle(of: row)) {
                    ForEach(aisleChoices(with: row.wrappedValue.aisle), id: \.self) { Text($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("\(id).aislePicker")
            }
            .font(.subheadline)
        }
        .buttonStyle(.borderless)
    }

    private func step(_ row: Binding<RecipeDraft.StepRow>, at position: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(position + 1)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 20, alignment: .trailing)
            TextField("Step \(position + 1)", text: row.text, axis: .vertical)
                .focused($focus, equals: row.wrappedValue.id)
                .accessibilityIdentifier("recipeEditor.step.\(position).field")
            removeButton("Remove step \(position + 1)") {
                draft.steps.removeAll { $0.id == row.wrappedValue.id }
            }
            .accessibilityIdentifier("recipeEditor.step.\(position).removeButton")
        }
        .buttonStyle(.borderless)
    }

    private func removeButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, systemImage: "minus.circle.fill", role: .destructive, action: action)
            .labelStyle(.iconOnly)
            .tint(.red)
    }

    @ViewBuilder private var stoppedMessage: some View {
        if case .stopped(let message) = phase {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .accessibilityIdentifier("recipeEditor.message")
        }
    }

    private var unreadable: [RecipeDraft.RowID] {
        if case .fix(let rows) = draft.outcome { rows } else { [] }
    }

    private func aisle(of row: Binding<RecipeDraft.IngredientRow>) -> Binding<String> {
        Binding(get: { row.wrappedValue.aisle ?? ListLayout.fallbackAisle }, set: { row.wrappedValue.aisle = $0 })
    }

    private func aisleChoices(with current: String?) -> [String] {
        let current = current ?? ListLayout.fallbackAisle
        return aisles.contains(current) ? aisles : aisles + [current]
    }

    private func cancel() {
        if draft.hasChanges { onDiscard(draft) }
        dismiss()
    }

    private func save() {
        switch draft.outcome {
        case .fix(let rows):
            let names = draft.ingredients.filter { rows.contains($0.id) }.map(\.name.trimmed)
            phase = .stopped("The quantity for \(names.formatted(.list(type: .and))) has to be a number, or empty.")
        case .save where !draft.hasChanges:
            dismiss()
        case .save(let edit):
            phase = .saving
            Task {
                do throws(APIError) {
                    try await store.save(edit)
                    dismiss()
                } catch {
                    phase = .stopped(Self.message(for: error))
                }
            }
        }
    }

    /// An edit is never queued, so each of these says the recipe is not saved and the typing is safe.
    private static func message(for failure: APIError) -> String {
        switch failure {
        case .unreachable:
            "Couldn't reach Omlete, so this isn't saved yet. Saving an edit needs a connection. Your changes are still here."
        case .rejected(404):
            "This recipe doesn't exist any more, so it can't be saved."
        case .serverFault, .rejected, .undecodable:
            "Couldn't save. Your changes are still here, so try again."
        }
    }
}
