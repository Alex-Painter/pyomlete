import SwiftUI

/// Five stars, one tap to rate. The ids are `<identifier>.1` to `<identifier>.5`.
struct StarRating: View {
    let stars: Int?
    let identifier: String
    var size: CGFloat = 36
    let onRate: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { star in
                let isLit = star <= stars ?? 0
                Button {
                    onRate(star)
                } label: {
                    Image(systemName: isLit ? "star.fill" : "star")
                        .font(.system(size: size))
                        .foregroundStyle(isLit ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
                        .frame(width: size + 20, height: size + 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                .accessibilityAddTraits(stars == star ? .isSelected : [])
                .accessibilityIdentifier("\(identifier).\(star)")
            }
        }
        .sensoryFeedback(.selection, trigger: stars)
    }
}
