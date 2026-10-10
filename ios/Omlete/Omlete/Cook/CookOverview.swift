import SwiftUI

struct CookOverview: View {
    let servings: Servings
    let needs: [CookSession.IngredientLine]
    let onFewer: () -> Void
    let onMore: () -> Void

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(servings.title)
                            .font(.headline)
                        Text(servings.base == nil ? "This recipe doesn't say how many it serves." : "Every amount scales to match.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    stepButton("Fewer", systemImage: "minus", action: onFewer)
                        .disabled(!servings.canDecrease)
                        .accessibilityIdentifier("cook.fewerButton")
                    Text(servings.label)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .frame(minWidth: 44)
                        .accessibilityIdentifier("cook.servingsValue")
                    stepButton("More", systemImage: "plus", action: onMore)
                        .accessibilityIdentifier("cook.moreButton")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
            }

            if !needs.isEmpty {
                Section("You'll need") {
                    ForEach(needs) { line in
                        IngredientRow(line: line, showsNote: true)
                    }
                }
            }
        }
    }

    /// A fixed frame, because a button sized by its glyph makes the minus smaller than the plus.
    private func stepButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 24)
        }
        .accessibilityLabel(title)
    }
}

struct IngredientRow: View {
    let line: CookSession.IngredientLine
    var showsNote = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if showsNote, let note = line.note, !note.isEmpty {
                Text("\(line.name)\(Text(", \(note)").foregroundStyle(.secondary))")
            } else {
                Text(line.name)
            }
            Spacer(minLength: 8)
            Text(line.quantity)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.title3)
        .accessibilityElement(children: .combine)
    }
}
