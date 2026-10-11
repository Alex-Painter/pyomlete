import SwiftUI

/// A Discover card: picture, title, time, source and the one-line reason it
/// was suggested, with Save, Add to list and Not for me.
struct SuggestionCard: View {
    static let width: CGFloat = 256

    let card: Suggestion

    @Environment(Chef.self) private var chef

    private var id: String { card.id.rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecipePicture(url: card.imageURL)
                .frame(width: Self.width, height: Self.width * 3 / 4)

            VStack(alignment: .leading, spacing: 8) {
                title
                details
                if let reason = card.reason {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "sparkles")
                        Text(reason)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                status
                AddToListButton(identifier: "discover.addToList.\(id)") { await chef.addToList(card.id, to: $0) }
                    .disabled(card.stage == .saving)
                HStack {
                    saveButton
                    Spacer(minLength: 8)
                    Button("Not for me", systemImage: "hand.thumbsdown") { chef.dismiss(card.id) }
                        .foregroundStyle(.secondary)
                        .disabled(card.stage == .saving)
                        .accessibilityLabel("Not for me: \(card.title)")
                        .accessibilityIdentifier("discover.notForMe.\(id)")
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
                .frame(minHeight: 40)
            }
            .padding(12)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var title: some View {
        let text = Text(card.title)
            .font(.headline)
            .multilineTextAlignment(.leading)
            .lineLimit(2)
        if case .saved(let recipe) = card.stage {
            NavigationLink(value: Route.recipe(recipe)) { text }
                .buttonStyle(.plain)
                .accessibilityIdentifier("discover.title.\(id)")
        } else {
            text
        }
    }

    @ViewBuilder private var details: some View {
        if card.totalMinutes != nil || card.source != nil {
            HStack(spacing: 12) {
                if let minutes = card.totalMinutes {
                    caption(formatMinutes(minutes), systemImage: "clock")
                }
                if let source = card.source {
                    if let url = source.url {
                        Link(destination: url) {
                            caption(source.name, systemImage: "arrow.up.right.square")
                                .underline()
                        }
                        .accessibilityIdentifier("discover.source.\(id)")
                    } else {
                        Text(source.name)
                            .lineLimit(1)
                    }
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        switch card.stage {
        case .saving:
            HStack(spacing: 8) {
                ProgressView()
                Text("Saving. The full recipe fills in shortly.")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        case .failed, .unsent:
            Label("Couldn't save this one.", systemImage: "exclamationmark.circle")
                .font(.subheadline)
                .foregroundStyle(.red)
        case .fresh, .saved:
            EmptyView()
        }
    }

    @ViewBuilder private var saveButton: some View {
        if case .saved(let recipe) = card.stage {
            NavigationLink(value: Route.recipe(recipe)) {
                Label("Saved", systemImage: "bookmark.fill")
            }
            .accessibilityIdentifier("discover.saved.\(id)")
        } else {
            Button(card.stage == .failed || card.stage == .unsent ? "Try again" : "Save", systemImage: "bookmark") { chef.save(card.id) }
                .disabled(card.stage == .saving)
                .accessibilityIdentifier("discover.save.\(id)")
        }
    }

    /// Laid out by hand so the icon and its text stay on one line and truncate together.
    private func caption(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
                .lineLimit(1)
        }
    }
}
