import SwiftUI

/// One item: tap anywhere on it to check or uncheck. Shop uses the large size.
struct ItemRow: View {
    let item: ListItem
    let identifier: String
    var large = false
    let onToggle: () -> Void

    private var quantity: String { formatQuantity(item.amount, item.unit) }
    private var mealCount: Int { item.sources.count(where: { $0.recipeID != nil }) }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
                    .font(large ? .title2 : .title3)
                    .foregroundStyle(item.checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
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
            .frame(minHeight: large ? 44 : 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: item.checked)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(item.checked ? .isSelected : [])
    }
}
