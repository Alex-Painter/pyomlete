import SwiftUI

/// Cooked, or not yet, for a meal on a list. The same size either way, so
/// ticking a meal never moves anything.
struct CookedToggle: View {
    let cooked: Bool
    let title: String
    let identifier: String
    let onChange: (Bool) -> Void

    var body: some View {
        Button {
            onChange(!cooked)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: cooked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(cooked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text("Cooked")
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 36)
        }
        .buttonStyle(.bordered)
        .tint(cooked ? .accentColor : .secondary)
        .accessibilityLabel("\(title) cooked")
        .accessibilityValue(cooked ? "Cooked" : "Not cooked")
        .accessibilityAddTraits(cooked ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// The mark over a cooked meal's picture. Its parent places it.
struct CookedBadge: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.body.weight(.semibold))
            .foregroundStyle(.white, Color.accentColor)
            .background(Circle().fill(.white).padding(2))
            .padding(4)
            .accessibilityHidden(true)
    }
}
