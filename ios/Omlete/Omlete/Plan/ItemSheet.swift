import SwiftUI

/// Edit one item: name, quantity, unit and aisle. Only what changed is sent.
struct ItemSheet: View {
    let item: ListItem
    let aisles: [String]
    let units: [String]
    let onSave: (ItemPatch) -> Void
    let onDelete: () -> Void

    @State private var draft: ItemDraft
    /// The amount as typed; it becomes `draft.amount` on save.
    @State private var amountText: String
    @Environment(\.dismiss) private var dismiss

    init(
        item: ListItem, aisles: [String], units: [String],
        onSave: @escaping (ItemPatch) -> Void, onDelete: @escaping () -> Void
    ) {
        self.item = item
        self.aisles = aisles
        self.units = units
        self.onSave = onSave
        self.onDelete = onDelete
        _draft = State(initialValue: ItemDraft(item))
        _amountText = State(initialValue: item.amount.map(formatAmount) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $draft.name)
                        .accessibilityIdentifier("itemSheet.nameField")
                }
                Section("Quantity") {
                    HStack {
                        TextField("Amount", text: $amountText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("itemSheet.amountField")
                        Stepper("Amount", onIncrement: { bump(1) }, onDecrement: { bump(-1) })
                            .labelsHidden()
                            .accessibilityIdentifier("itemSheet.amountStepper")
                    }
                    TextField("Unit", text: unitText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("itemSheet.unitField")
                    unitChips
                }
                Section {
                    Picker("Aisle", selection: $draft.category) {
                        ForEach(aisleChoices, id: \.self) { Text($0) }
                    }
                    .accessibilityIdentifier("itemSheet.categoryPicker")
                }
            }
            .navigationTitle("Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // In the bar, not the form, so it is in reach at the half-height detent.
                ToolbarItem(placement: .topBarLeading) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        dismiss()
                        onDelete()
                    }
                    .tint(.red)
                    .accessibilityIdentifier("itemSheet.deleteButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save)
                        .accessibilityIdentifier("itemSheet.saveButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var unitChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(unitChoices, id: \.self) { unit in
                    let selected = (draft.unit ?? "") == unit
                    Button(unit.isEmpty ? "No unit" : unit) { draft.unit = unit.isEmpty ? nil : unit }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(selected ? .accentColor : .secondary)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("itemSheet.unitChip.\(unit.isEmpty ? "none" : unit)")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var unitText: Binding<String> {
        Binding(get: { draft.unit ?? "" }, set: { draft.unit = $0.isEmpty ? nil : $0 })
    }

    /// "" stands for no unit. Recipe units that only spell out a common one add nothing.
    private var unitChoices: [String] {
        let common = ["g", "kg", "ml", "l", "pack", "tin", "bunch", "whole"]
        let spelledOut: Set = ["gram", "grams", "kilograms", "millilitres", "milliliters", "litres", "liters"]
        let fromRecipes = units.filter { $0.count <= 12 && !spelledOut.contains($0.lowercased()) }.prefix(8)
        var seen: Set<String> = []
        return ([""] + common + fromRecipes + [draft.unit ?? ""]).filter { seen.insert($0).inserted }
    }

    private var aisleChoices: [String] {
        aisles.contains(draft.category) ? aisles : aisles + [draft.category]
    }

    private var typedAmount: Double? {
        Double(amountText.trimmed.replacingOccurrences(of: ",", with: ".")).flatMap { $0.isFinite ? $0 : nil }
    }

    private func bump(_ direction: Double) {
        let step: Double = switch draft.unit {
        case "g", "ml", "grams": 50
        case "kg", "l": 0.5
        default: 1
        }
        let next = max(0, (typedAmount ?? 0) + direction * step)
        amountText = next == 0 ? "" : formatAmount(next)
    }

    private func save() {
        draft.amount = typedAmount
        onSave(draft.patch(from: item))
        dismiss()
    }
}
