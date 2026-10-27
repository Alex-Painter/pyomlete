import PhotosUI
import SwiftUI

extension View {
    /// Chef's sheet over every screen but Shop and Cook (docs/PRD_CHEF.md):
    /// a slim bar with Chef's last line, half height with the screen above
    /// still in use, or full height. The Chef tab opens it.
    func chefSheet() -> some View {
        modifier(ChefSheetHost())
    }
}

extension PresentationDetent {
    static let chefBar = PresentationDetent.height(76)
}

private struct ChefSheetHost: ViewModifier {
    @Environment(ChefChat.self) private var chat
    @Environment(AppNavigation.self) private var navigation

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            // Shop and Cook take the whole screen; the height is kept for when they end.
            get: { chat.height != .closed && navigation.immersive == nil },
            set: { shown in if !shown, navigation.immersive == nil { chat.height = .closed } }
        )) {
            ChefSheet()
                .presentationDetents([.chefBar, .medium, .large], selection: Binding(
                    get: {
                        switch chat.height {
                        case .bar: .chefBar
                        case .full: .large
                        case .closed, .half: .medium
                        }
                    },
                    set: { chat.height = $0 == .chefBar ? .bar : $0 == .large ? .full : .half }))
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
        }
    }
}

private struct ChefSheet: View {
    @Environment(ChefChat.self) private var chat

    @FocusState private var typing: Bool
    /// The height to go back to when typing ends.
    @State private var heightBeforeTyping: ChefHeight?

    var body: some View {
        Group {
            if chat.height == .bar {
                bar
            } else {
                VStack(spacing: 0) {
                    header
                    ChefConversation()
                    ChefComposer(focus: $typing)
                }
            }
        }
        // While typing the sheet fills the space above the keyboard, and goes back after.
        .onChange(of: typing) {
            if typing {
                heightBeforeTyping = chat.height
                chat.height = .full
            } else if let before = heightBeforeTyping {
                heightBeforeTyping = nil
                if chat.height == .full { chat.height = before }
            }
        }
    }

    private var bar: some View {
        Button {
            chat.height = .half
        } label: {
            HStack(spacing: 10) {
                Image(systemName: ChefSymbol.name)
                Text(chat.isReplying ? "Chef is working…" : chat.lastLine ?? "Ask Chef")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chef.bar")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: ChefSymbol.name)
            Text("Chef")
                .font(.headline)
                .accessibilityIdentifier("chef.title")
            Spacer()
            Button("New chat", systemImage: "square.and.pencil") { chat.reset() }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("chef.newChatButton")
            Button("Close Chef", systemImage: "xmark") { chat.height = .closed }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("chef.closeButton")
        }
        .font(.title3)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }
}

enum ChefSymbol {
    static let name = "bubble.left.and.text.bubble.right"
}

/// The messages, each change Chef made with its own Undo, and how the last request went.
private struct ChefConversation: View {
    @Environment(ChefChat.self) private var chat
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if chat.messages.isEmpty { emptyState }
                ForEach(chat.messages) { message in
                    if message.role == .user {
                        UserMessage(message: message)
                    } else {
                        ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                            ChefPartView(part: part)
                        }
                    }
                }
                if chat.isReplying, chat.messages.last?.role == .user {
                    ProgressView()
                        .accessibilityLabel("Chef is thinking")
                        .accessibilityIdentifier("chef.thinking")
                }
                if let failure = chat.failure {
                    Text(failure)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("chef.failure")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("chef.messages")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What can I do for you?")
                .font(.headline)
            Text("Find a recipe and put it on a list, add things to the list you're on, or save a recipe from a photo.")
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text("Prefer a form?")
                    .foregroundStyle(.secondary)
                Button("Add a recipe yourself") {
                    navigation.addRecipe()
                    // Down to the bar, so the form is not under the sheet.
                    chat.height = .bar
                }
                .fontWeight(.semibold)
                .accessibilityIdentifier("chef.addRecipeButton")
            }
        }
        .font(.subheadline)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chef.empty")
    }
}

private struct UserMessage: View {
    let message: ChefMessage

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .photo(let photo):
                    if let image = UIImage(data: photo.jpeg) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                case .text(let text):
                    Text(text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 16))
                case .tool:
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 32)
    }
}

private struct ChefPartView: View {
    let part: ChefPart
    @Environment(ChefChat.self) private var chat

    var body: some View {
        switch part {
        case .text(let text) where !text.isEmpty:
            Text(Self.markdown(text))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .tool(let tool):
            if case .running = tool.state {
                HStack(spacing: 6) {
                    if tool.isWebSearch { Image(systemName: "globe") } else { ProgressView().controlSize(.small) }
                    Text(tool.isWebSearch ? "Searching the web…" : "Working…")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else if let change = tool.change {
                changeRow(change)
            }
        default:
            EmptyView()
        }
    }

    private func changeRow(_ change: ChefChange) -> some View {
        let isUndone = chat.undone.contains(change.undo)
        return HStack(spacing: 8) {
            Text(change.done)
                .strikethrough(isUndone)
                .foregroundStyle(isUndone ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("chef.change.\(change.undo.rawValue)")
            if !isUndone {
                Button("Undo", systemImage: "arrow.uturn.backward") { chat.undo([change]) }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("chef.undo.\(change.undo.rawValue)")
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Chef writes Markdown; bold and links read better drawn than as asterisks.
    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// The message box, the photos to send with it, and what Chef is looking at.
private struct ChefComposer: View {
    @FocusState.Binding var focus: Bool
    @Environment(ChefChat.self) private var chat

    @State private var text = ""
    @State private var photos: [RecipePhoto] = []
    @State private var picked: [PhotosPickerItem] = []

    private static let maxPhotos = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !photos.isEmpty { photoStrip }
            ChefContextLine()
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(
                    selection: $picked, maxSelectionCount: Self.maxPhotos - photos.count, matching: .images
                ) {
                    Image(systemName: "photo.badge.plus")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .disabled(photos.count >= Self.maxPhotos)
                .accessibilityLabel("Add photos")
                .accessibilityIdentifier("chef.addPhotosButton")
                TextField("Ask Chef", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focus)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityIdentifier("chef.messageField")
                Button("Send", systemImage: "arrow.up.circle.fill") {
                    chat.send(text, photos: photos)
                    text = ""
                    photos = []
                }
                .labelStyle(.iconOnly)
                .font(.title)
                .disabled(chat.isReplying || (text.trimmed.isEmpty && photos.isEmpty))
                .accessibilityIdentifier("chef.sendButton")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onChange(of: picked) {
            let items = picked
            guard !items.isEmpty else { return }
            picked = []
            Task {
                for item in items {
                    let data = try? await item.loadTransferable(type: Data.self)
                    // Detached: decoding and re-encoding a full-size photo would stall the main actor.
                    let jpeg = await Task.detached { data.flatMap { PhotoEncoder.jpeg(from: $0) } }.value
                    if let jpeg, photos.count < Self.maxPhotos { photos.append(RecipePhoto(id: UUID(), jpeg: jpeg)) }
                }
            }
        }
    }

    private var photoStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    ZStack(alignment: .topTrailing) {
                        if let image = UIImage(data: photo.jpeg) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        Button("Remove photo \(index + 1)", systemImage: "xmark.circle.fill") {
                            photos.removeAll { $0.id == photo.id }
                        }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .accessibilityIdentifier("chef.removePhoto.\(index)")
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

/// What Chef is looking at: the list or recipe on screen by name, or else the
/// page. "This list" in a message means this one.
private struct ChefContextLine: View {
    @Environment(AppNavigation.self) private var navigation
    @Environment(Library.self) private var library
    @Environment(Kitchen.self) private var kitchen

    var body: some View {
        let (symbol, name) = focus
        Label(name, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .accessibilityLabel("Chef is looking at: \(name)")
            .accessibilityIdentifier("chef.context")
    }

    private var focus: (symbol: String, name: String) {
        switch navigation.chefPage {
        case .list(let id), .shop(let id):
            let name = library.rows.first { $0.id == id }?.name ?? library.list(id).replica.current?.name
            return ("checklist", name ?? "List")
        case .recipe(let id), .cook(let id):
            var name = library.meal(id)?.title
            if name == nil, case .ready(let recipe) = kitchen.cook(id).page { name = recipe.title }
            return ("book", name ?? "Recipe")
        case .home: return ("globe", "Home")
        case .discover: return ("globe", "Discover")
        case .recipes: return ("globe", "Recipes")
        case .addRecipe: return ("globe", "New recipe")
        case .settings: return ("globe", "Settings")
        }
    }
}
