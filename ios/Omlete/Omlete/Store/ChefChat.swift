import Foundation
import Observation

struct ChefChatDependencies {
    let api: APIClient
    let undo: UndoCenter
    let library: Library
    /// Discover's cards and Chef's week, which a change may touch.
    let chef: Chef
    let kitchen: Kitchen
    /// Where the user is: each message carries the screen, and the sheet is hidden over Shop and Cook.
    let navigation: AppNavigation
    var newID: () -> String = { UUID().uuidString }
}

/// How much of the screen Chef's sheet takes. Shop and Cook hide it without
/// changing this, so it comes back as it was.
enum ChefHeight: Equatable {
    case closed
    /// One line: what Chef said last.
    case bar
    /// The screen above stays in use.
    case half
    case full
}

/// The chat with Chef, app-wide like `Library`, so closing the sheet or
/// changing screen keeps it. Like the web it lasts until the app is closed.
///
/// Chef acts at once and every change it makes comes with Undo: beside the
/// change in the chat while the chat is on screen, and as one banner for the
/// reply when it is not. The screens a change may touch refresh as it lands.
@Observable final class ChefChat {
    var height = ChefHeight.closed
    private(set) var messages: [ChefMessage] = []
    private(set) var isReplying = false
    /// The last request or Undo that failed, said in the chat.
    private(set) var failure: String?
    private(set) var undone: Set<ChefActionID> = []

    @ObservationIgnored private let deps: ChefChatDependencies
    @ObservationIgnored private var chatID: String
    @ObservationIgnored private var replying: Task<Void, Never>?

    init(deps: ChefChatDependencies) {
        self.deps = deps
        chatID = deps.newID()
    }

    /// The conversation, with its own Undo buttons, is on screen.
    var isInView: Bool {
        (height == .half || height == .full) && deps.navigation.immersive == nil
    }

    /// The Chef tab: opens at half height, or closes.
    func toggle() {
        height = height == .closed ? .half : .closed
    }

    /// What the slim bar shows.
    var lastLine: String? {
        messages.last { $0.role == .assistant }?.lastLine
    }

    /// Sends a message from the screen on show. Ignored while Chef is replying, or when there is nothing to send.
    func send(_ text: String, photos: [RecipePhoto]) {
        let text = text.trimmed
        guard !isReplying, !text.isEmpty || !photos.isEmpty else { return }
        let sent = ChefMessage(
            id: deps.newID(), role: .user, parts: photos.map(ChefPart.photo) + (text.isEmpty ? [] : [.text(text)]))
        let history = messages + [sent]
        messages = history
        failure = nil
        isReplying = true
        let chat = chatID
        let page = deps.navigation.chefPage
        replying = Task {
            defer { if chat == chatID { isReplying = false } }
            var reply = ChefMessage(id: deps.newID(), role: .assistant, parts: [])
            do throws(APIError) {
                let events = try await deps.api.askChef(chat: chat, messages: history, from: page)
                do {
                    for try await event in events {
                        guard chat == chatID else { return }
                        if case .failed = event {
                            failure = Self.couldNotAnswer
                            break
                        }
                        let landed = reply.changes.count
                        reply.apply(event)
                        messages = history + [reply]
                        if reply.changes.count > landed { Task { await refresh() } }
                    }
                } catch {
                    guard chat == chatID, !Task.isCancelled else { return }
                    failure = Self.couldNotAnswer
                }
            } catch {
                guard chat == chatID else { return }
                failure = error == .unreachable ? "Chef needs a connection." : Self.couldNotAnswer
            }
            let changes = reply.changes
            guard chat == chatID, !changes.isEmpty, !isInView else { return }
            deps.undo.offer(
                changes.count == 1 ? changes[0].done : "\(changes.count) changes",
                undo: { [weak self] in self?.undo(changes) }, lasting: .seconds(8))
        }
    }

    private static let couldNotAnswer = "Chef couldn't answer. Try again?"

    /// Puts changes back newest first, so each finds what it left. Stops at
    /// the first that cannot be undone.
    func undo(_ changes: [ChefChange]) {
        Task {
            var message: String?
            for change in changes.reversed() where !undone.contains(change.undo) {
                do throws(APIError) {
                    try await deps.api.undoChefAction(change.undo)
                    undone.insert(change.undo)
                } catch {
                    message = error == .rejected(409)
                        ? "That's changed since, so it can't be undone" : "Couldn't undo that. Try again?"
                    break
                }
            }
            if let message {
                if isInView { failure = message } else { deps.undo.offer(message) }
            } else if !isInView {
                deps.undo.offer(changes.count == 1 ? "Undid: \(changes[0].done)" : "Undid those changes")
            }
            await refresh()
        }
    }

    /// New chat: forgets the conversation, and stops a reply still coming.
    func reset() {
        replying?.cancel()
        replying = nil
        chatID = deps.newID()
        messages = []
        failure = nil
        isReplying = false
    }

    /// Everything a change may have touched: the lists and recipes, the recipe
    /// on screen, Discover's cards and Chef's week.
    private func refresh() async {
        async let everything: Void = deps.library.refreshEverything()
        async let cards: Bool = deps.chef.load()
        async let week: Void = deps.chef.week.load()
        switch deps.navigation.chefPage {
        case .recipe(let id), .cook(let id): await deps.kitchen.cook(id).load()
        default: break
        }
        _ = await (everything, cards, week)
    }
}
