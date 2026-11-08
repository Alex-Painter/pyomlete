import SwiftUI

/// A meal offered for the evening with its reason: the top three, and Narrow
/// it down's finalists. A clash's reason is orange.
struct MealPickCard: View {
    let ranked: FitScore.Ranked
    let mark: MealLibrary.Mark
    let identifier: String
    let onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            PictureRow(picture: ranked.recipe.imageURL, title: ranked.recipe.title) {
                VStack(alignment: .leading, spacing: 2) {
                    if let reason = ranked.fit.reason {
                        Text(reason)
                            .foregroundStyle(ranked.fit.clash ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                    if let minutes = ranked.recipe.totalMinutes {
                        Label(formatMinutes(minutes), systemImage: "clock")
                            .labelStyle(.captionLabel)
                            .foregroundStyle(.secondary)
                    }
                }
            } mark: {
                if mark == .added {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                } else {
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(mark == .busy)
        .accessibilityAddTraits(mark == .added ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}
