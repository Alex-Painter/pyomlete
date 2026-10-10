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
                StarRating(stars: rating.stars, identifier: "cook.star", onRate: onRate)
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
