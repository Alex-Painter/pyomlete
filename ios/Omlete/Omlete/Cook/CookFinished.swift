import SwiftUI

/// "How was it?" One tap rates the meal, which is what Discover learns from.
/// The stars show at once and the rating is sent when it can be, so there is
/// never an error to dismiss with a pan in the other hand.
struct CookFinished: View {
    let rating: RatingView
    let onRate: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("How was it?")
                    .font(.largeTitle.bold())
                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { stars in
                        let isLit = stars <= rating.stars ?? 0
                        Button {
                            onRate(stars)
                        } label: {
                            Image(systemName: isLit ? "star.fill" : "star")
                                .font(.system(size: 36))
                                .foregroundStyle(isLit ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
                                .frame(width: 56, height: 56)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(stars) star\(stars == 1 ? "" : "s")")
                        .accessibilityAddTraits(rating.stars == stars ? .isSelected : [])
                        .accessibilityIdentifier("cook.star.\(stars)")
                    }
                }
                .sensoryFeedback(.selection, trigger: rating.stars)
                Text(rating.status.message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("cook.ratingStatus")
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 48)
        }
    }
}
