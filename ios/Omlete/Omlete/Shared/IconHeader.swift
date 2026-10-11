import SwiftUI

/// A section header with an icon before its title. Laid out by hand: inside a
/// List a Label takes the row style, with a wide icon gutter.
struct IconHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(title)
        }
        .accessibilityAddTraits(.isHeader)
    }
}
