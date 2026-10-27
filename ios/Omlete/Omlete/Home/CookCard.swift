import SwiftUI

struct CookCard: View {
    let meal: RecipeSummary
    /// Marked in place: the card keeps its size and its position.
    let cooked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AsyncImage(url: meal.imageURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "fork.knife")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
            .frame(width: 160, height: 120)
            .clipped()
            .overlay(alignment: .topLeading) {
                if cooked { CookedBadge().padding(4) }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(meal.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 12) {
                    caption("Cook", systemImage: "frying.pan")
                        .fontWeight(.medium)
                        .foregroundStyle(.tint)
                    if let minutes = meal.totalMinutes {
                        caption("\(minutes) min", systemImage: "clock")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
            }
            .padding(12)
        }
        .frame(width: 160, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    /// Laid out by hand: inside a List a Label takes the row style, with a wide icon gutter that wraps the text.
    private func caption(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .fixedSize()
    }
}
