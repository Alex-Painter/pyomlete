import SwiftUI

struct MealsStrip: View {
    let meals: [RecipeSummary]
    let onRemove: (RecipeSummary) -> Void
    let onCook: (RecipeSummary) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(meals) { meal in
                    Menu {
                        Button("Cook this", systemImage: "frying.pan") { onCook(meal) }
                            .accessibilityIdentifier("plan.cookMealAction")
                        Button("Remove from list", systemImage: "trash", role: .destructive) { onRemove(meal) }
                            .accessibilityIdentifier("plan.removeMealAction")
                    } label: {
                        chip(meal)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("plan.mealChip.\(meal.id.rawValue)")
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ meal: RecipeSummary) -> some View {
        HStack(spacing: 8) {
            AsyncImage(url: meal.imageURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "fork.knife")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
            .frame(width: 48, height: 48)
            .clipped()
            Text(meal.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.trailing, 12)
        }
        .frame(maxWidth: 240, alignment: .leading)
        .background(.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
