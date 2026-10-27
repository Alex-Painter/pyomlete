import SwiftUI

/// The selected evening: its meal with Cook, Swap and Clear, an open evening
/// with a one-tap Out, or Out with Plan anyway.
struct DayCard: View {
    let day: PlanDay
    /// The planned meal, known by its title at least.
    let meal: RecipeSummary?
    let onOpen: (RecipeID) -> Void
    let onCook: (RecipeID) -> Void
    let onSwap: () -> Void
    let onClear: () -> Void
    let onOut: (Bool) -> Void

    var body: some View {
        switch day.plan {
        case .meal(let recipe):
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    onOpen(recipe)
                } label: {
                    PictureRow(picture: meal?.imageURL, title: meal?.title ?? "Meal") {
                        HStack(spacing: 10) {
                            if let minutes = meal?.totalMinutes {
                                Label(formatMinutes(minutes), systemImage: "clock")
                            }
                            if let rating = meal?.rating {
                                Label("\(rating)", systemImage: "star.fill")
                                    .accessibilityLabel("\(rating) star\(rating == 1 ? "" : "s")")
                            }
                        }
                        .labelStyle(.captionLabel)
                    } mark: {
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("plan.day.openRecipeButton")

                HStack(spacing: 8) {
                    Button { onCook(recipe) } label: { actionLabel("Cook", systemImage: "frying.pan") }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("plan.day.cookButton")
                    Button(action: onSwap) { actionLabel("Swap", systemImage: "arrow.left.arrow.right") }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("plan.day.swapButton")
                    Button(action: onClear) { actionLabel("Clear", systemImage: "xmark") }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("plan.day.clearButton")
                }
            }

        case .open:
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nothing planned yet")
                        .fontWeight(.medium)
                    Text("Pick a meal below.")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .padding(.horizontal, 12)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
                Button("Out", systemImage: "moon") { onOut(true) }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 56)
                    .accessibilityLabel("Out on \(day.date.dayLong)")
                    .accessibilityIdentifier("plan.day.outButton")
            }

        case .out:
            HStack(spacing: 12) {
                Image(systemName: "moon.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Out this evening")
                        .fontWeight(.medium)
                    Text("No dinner to plan.")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Plan anyway") { onOut(false) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("plan.day.planAnywayButton")
            }
            .frame(minHeight: 56)
        }
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 36)
    }
}
