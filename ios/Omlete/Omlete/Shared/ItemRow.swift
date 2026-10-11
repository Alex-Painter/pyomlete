import SwiftUI

/// One list item. Without `onEdit` the whole row toggles (Shop). With it, only
/// the circle toggles and the rest of the row opens the item for editing (Plan).
struct ItemRow: View {
    let item: ListItem
    let identifier: String
    var large = false
    let onToggle: () -> Void
    var onEdit: (() -> Void)?

    private var quantity: String { formatQuantity(item.amount, item.unit) }
    private var mealCount: Int { item.sources.count(where: { $0.recipeID != nil }) }

    var body: some View {
        Group {
            if let onEdit {
                HStack(spacing: 12) {
                    Button(action: onToggle) {
                        circle
                            // Grows the tap target to 44pt without growing the row.
                            .padding(10)
                            .contentShape(Rectangle())
                            .padding(-10)
                    }
                    // Two buttons in one List row both fire on a tap unless each has an explicit style.
                    .buttonStyle(.plain)
                    .accessibilityLabel("Check off \(item.name)")
                    .accessibilityIdentifier(identifier.replacing(".itemRow.", with: ".itemCheck."))
                    .accessibilityAddTraits(item.checked ? .isSelected : [])

                    Button(action: onEdit) {
                        HStack(spacing: 12) {
                            details
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: large ? 44 : 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit \(item.name)")
                    .accessibilityValue(quantity)
                    .accessibilityIdentifier(identifier)
                }
            } else {
                Button(action: onToggle) {
                    HStack(spacing: 12) {
                        circle
                        details
                    }
                    .frame(minHeight: large ? 44 : 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(identifier)
                .accessibilityAddTraits(item.checked ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: item.checked)
    }

    private var circle: some View {
        Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
            .font(large ? .title2 : .title3)
            .foregroundStyle(item.checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
    }

    @ViewBuilder private var details: some View {
        Text(item.name)
            .font(large ? .title3 : .body)
            .strikethrough(item.checked)
            .foregroundStyle(item.checked ? .secondary : .primary)
        if mealCount > 1 {
            Text("\(mealCount) meals")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        Spacer(minLength: 8)
        if !quantity.isEmpty {
            Text(quantity)
                .font(large ? .body : .subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
