import SwiftUI

/// One meal or idea in a list: its picture, title and a caption, with a mark
/// at the trailing edge saying what a tap does.
struct PictureRow<Caption: View, Mark: View>: View {
    let picture: URL?
    let title: String
    @ViewBuilder let caption: Caption
    @ViewBuilder let mark: Mark

    var body: some View {
        HStack(spacing: 12) {
            RecipePicture(url: picture)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                caption
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            mark
                .frame(width: 28)
        }
        .contentShape(Rectangle())
    }
}
