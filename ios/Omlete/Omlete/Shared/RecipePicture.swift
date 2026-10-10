import SwiftUI

/// A recipe's or an idea's picture, filling whatever frame it is given, with a
/// placeholder while it loads and when there is none.
struct RecipePicture: View {
    let url: URL?

    var body: some View {
        Color(.tertiarySystemFill)
            .overlay {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "fork.knife")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .clipped()
            .accessibilityHidden(true)
    }
}
