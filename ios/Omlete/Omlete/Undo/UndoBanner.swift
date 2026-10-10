import SwiftUI

extension View {
    /// Draws the current Undo banner at the bottom of this presentation. Needed
    /// at the root and again on each full-screen cover, which hides the root's.
    /// The root passes `isCovered` while a cover is up, so the banner and its
    /// Undo button exist once on screen and once in the accessibility tree.
    func undoBanner(isCovered: Bool = false) -> some View {
        modifier(UndoBannerHost(isCovered: isCovered))
    }
}

private struct UndoBannerHost: ViewModifier {
    let isCovered: Bool
    @Environment(UndoCenter.self) private var undo

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let banner = undo.banner, !isCovered {
                    UndoBanner(banner: banner) { undo.undoTapped() }
                        .id(banner.id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: undo.banner)
    }
}

private struct UndoBanner: View {
    let banner: UndoCenter.Banner
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(banner.message)
                .font(.subheadline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("undo.banner")
            if banner.canUndo {
                Button("Undo", action: onUndo)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("undo.button")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
