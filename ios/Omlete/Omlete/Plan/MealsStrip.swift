import SwiftUI

/// Meals on a list as chips, a cooked one marked in place. Each opens the
/// meal's actions: plan it for the selected evening on a week list, cook it,
/// tick it cooked or back, open it, or take it off the list.
struct MealsStrip: View {
    let meals: [RecipeSummary]
    let cooked: Set<RecipeID>
    /// The evening "Plan for" puts a meal on. nil on a plain list.
    var planDay: PlanDate? = nil
    let onCooked: (RecipeSummary, Bool) -> Void
    var onPlan: (RecipeSummary) -> Void = { _ in }
    let onCook: (RecipeSummary) -> Void
    let onOpen: (RecipeSummary) -> Void
    let onRemove: (RecipeSummary) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(meals) { meal in
                    Menu {
                        if let planDay {
                            Button("Plan for \(planDay.dayLong)", systemImage: "calendar") { onPlan(meal) }
                                .accessibilityIdentifier("plan.planMealAction")
                        }
                        Button("Cook this", systemImage: "frying.pan") { onCook(meal) }
                            .accessibilityIdentifier("plan.cookMealAction")
                        if cooked.contains(meal.id) {
                            Button("Not cooked yet", systemImage: "arrow.uturn.backward") { onCooked(meal, false) }
                                .accessibilityIdentifier("plan.cookedMealAction")
                        } else {
                            Button("Mark cooked", systemImage: "checkmark.circle") { onCooked(meal, true) }
                                .accessibilityIdentifier("plan.cookedMealAction")
                        }
                        Button("Open recipe", systemImage: "book") { onOpen(meal) }
                            .accessibilityIdentifier("plan.openRecipeAction")
                        Button("Remove from list", systemImage: "trash", role: .destructive) { onRemove(meal) }
                            .accessibilityIdentifier("plan.removeMealAction")
                    } label: {
                        chip(meal)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(cooked.contains(meal.id) ? "Cooked" : "")
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
            .overlay(alignment: .topLeading) {
                if cooked.contains(meal.id) { CookedBadge().scaleEffect(0.8, anchor: .topLeading) }
            }
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
