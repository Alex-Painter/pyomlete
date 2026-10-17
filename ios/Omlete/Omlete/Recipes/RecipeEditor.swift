import SwiftUI

/// Editing a recipe: its title, ingredients and method, saved together by one
/// tap on Save. A sheet, so Save and Cancel stay in the bar however far down
/// the edit goes and the page underneath is untouched until the save lands.
///
/// Nothing typed is lost by accident. A draft with changes cannot be swiped
/// away, a save that fails leaves the sheet up as it was, and Cancel hands the
/// draft to `onDiscard` so the page can offer it back with Undo.
struct RecipeEditor: View {
    let aisles: [String]
    let unitChoices: [String]
    let onDiscard: (RecipeDraft) -> Void

    @State private var model: RecipeEditorModel
    /// The row whose first field has the keyboard, so an added row is ready to type in.
    @FocusState private var focus: RecipeDraft.RowID?
    @Environment(\.dismiss) private var dismiss

    /// The units the web's editor offers on top of the ones recipes already use.
    nonisolated static let extraUnits = ["to taste", "whole", "pinch"]

    init(
        draft: RecipeDraft, store: CookStore, aisles: [String], units: [String],
        onDiscard: @escaping (RecipeDraft) -> Void
    ) {
        self.aisles = aisles
        unitChoices = Self.unitChoices(server: units)
        self.onDiscard = onDiscard
        _model = State(initialValue: RecipeEditorModel(draft: draft, store: store))
    }

    /// The units to offer: the server's, then the web's extra three, each once.
    nonisolated static func unitChoices(server: [String]) -> [String] {
        var seen: Set<String> = []
        return (server + extraUnits).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    var body: some View {
        @Bindable var model = model
        let draft = model.draft
        let phase = model.phase
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $model.draft.title, axis: .vertical)
                        .font(.headline)
                        .accessibilityIdentifier("recipeEditor.titleField")
                }
                Section("Ingredients") {
                    ForEach($model.draft.ingredients) { $row in
                        ingredient($row, at: draft.ingredients.firstIndex { $0.id == row.id } ?? 0)
                    }
                    Button("Add ingredient", systemImage: "plus") { focus = model.draft.addIngredient() }
                        .accessibilityIdentifier("recipeEditor.addIngredientButton")
                }
                Section {
                    ForEach($model.draft.steps) { $row in
                        step($row, at: draft.steps.firstIndex { $0.id == row.id } ?? 0)
                    }
                    .onMove { model.draft.steps.move(fromOffsets: $0, toOffset: $1) }
                    Button("Add step", systemImage: "plus") { focus = model.draft.addStep() }
                        .accessibilityIdentifier("recipeEditor.addStepButton")
                } header: {
                    Text("Method")
                } footer: {
                    if draft.steps.count > 1 { Text("Drag a step by its handle to move it.") }
                }
            }
            // What Save sent is what closes the sheet, so nothing typed meanwhile can be dropped with it.
            .disabled(phase == .saving)
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
                        Button("Save") {
                            Task { await model.save() }
                        }
                        .accessibilityIdentifier("recipeEditor.saveButton")
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.hasChanges || phase == .saving)
        .onChange(of: phase) {
            if phase == .finished { dismiss() }
        }
    }

    private func ingredient(_ row: Binding<RecipeDraft.IngredientRow>, at position: Int) -> some View {
        let id = "recipeEditor.ingredient.\(position)"
        let name = row.wrappedValue.name.trimmed
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                TextField("Ingredient", text: row.name)
                    .textInputAutocapitalization(.never)
                    .focused($focus, equals: row.wrappedValue.id)
                    .accessibilityIdentifier("\(id).nameField")
                removeButton("Remove \(name.isEmpty ? "ingredient" : name)") {
                    model.draft.ingredients.removeAll { $0.id == row.wrappedValue.id }
                }
                .accessibilityIdentifier("\(id).removeButton")
            }
            HStack(spacing: 8) {
                TextField("Qty", text: row.quantity)
                    .keyboardType(.decimalPad)
                    .foregroundStyle(model.unreadable.contains(row.wrappedValue.id) ? .red : .primary)
                    .frame(width: 52)
                    .accessibilityLabel("Quantity")
                    .accessibilityIdentifier("\(id).quantityField")
                TextField("Unit", text: row.unit)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("\(id).unitField")
                Menu("Choose a unit", systemImage: "chevron.up.chevron.down") {
                    ForEach(unitChoices, id: \.self) { unit in
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
                    ForEach(aisleChoices(with: row.wrappedValue.aisle), id: \.self) { aisle in
                        Text(aisle).accessibilityIdentifier("recipeEditor.aisle.\(aisle)")
                    }
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
                model.draft.steps.removeAll { $0.id == row.wrappedValue.id }
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
        if case .stopped(let message) = model.phase {
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

    private func aisle(of row: Binding<RecipeDraft.IngredientRow>) -> Binding<String> {
        Binding(get: { row.wrappedValue.aisle ?? ListLayout.fallbackAisle }, set: { row.wrappedValue.aisle = $0 })
    }

    private func aisleChoices(with current: String?) -> [String] {
        let current = current ?? ListLayout.fallbackAisle
        return aisles.contains(current) ? aisles : aisles + [current]
    }

    private func cancel() {
        if model.hasChanges { onDiscard(model.draft) }
        dismiss()
    }
}
