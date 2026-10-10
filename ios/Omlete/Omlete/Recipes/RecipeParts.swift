import SwiftUI

/// Time, servings and where it came from. Shows nothing for a recipe that has none of them.
struct RecipeMeta: View {
    let recipe: Recipe

    var body: some View {
        if recipe.totalMinutes != nil || recipe.baseServings != nil || recipe.source != nil {
            // Wraps to a second line as a whole when the source name is long.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { parts }
                VStack(alignment: .leading, spacing: 6) { parts }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var parts: some View {
        if let minutes = recipe.totalMinutes {
            caption(formatMinutes(minutes), systemImage: "clock")
        }
        if let servings = recipe.baseServings {
            caption("Serves \(servings)", systemImage: "person.2")
        }
        if let source = recipe.source {
            if let url = source.url {
                Link(destination: url) {
                    caption(source.name, systemImage: "arrow.up.right.square")
                        .underline()
                }
                .accessibilityIdentifier("recipe.sourceLink")
            } else {
                Text(source.name)
                    .lineLimit(1)
            }
        }
    }

    /// Laid out by hand: inside a List a Label takes the row style, with a wide icon gutter that wraps the text.
    private func caption(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
                .lineLimit(1)
        }
        .fixedSize()
    }
}

struct RecipeIngredientRow: View {
    let ingredient: Recipe.Ingredient

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group {
                if let note = ingredient.note, !note.isEmpty {
                    Text("\(ingredient.name)\(Text(", \(note)").foregroundStyle(.secondary))")
                } else {
                    Text(ingredient.name)
                }
            }
            .foregroundStyle(ingredient.isOnList ? .primary : .secondary)
            Spacer(minLength: 8)
            Text(formatQuantity(ingredient.amount, ingredient.unit))
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

struct RecipeStepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 20, alignment: .trailing)
            Text(text)
        }
        .accessibilityElement(children: .combine)
    }
}
