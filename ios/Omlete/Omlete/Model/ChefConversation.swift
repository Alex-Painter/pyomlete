import Foundation

/// One message in the chat with Chef: what was sent, or Chef's reply as it
/// streams in.
nonisolated struct ChefMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Equatable, Sendable {
        case user, assistant
    }

    /// The server may rename a reply when it starts.
    var id: String
    let role: Role
    var parts: [ChefPart]

    /// The changes in this reply, oldest first, each with its own Undo.
    var changes: [ChefChange] {
        parts.compactMap { if case .tool(let tool) = $0 { tool.change } else { nil } }
    }

    /// The last thing Chef said, for the slim bar.
    var lastLine: String? {
        parts.lazy.reversed().compactMap { if case .text(let text) = $0, !text.isEmpty { text } else { nil } }.first
    }

    /// Folds one stream event into the reply being built, as `applyEvent` does on the web.
    mutating func apply(_ event: ChefStreamEvent) {
        switch event {
        case .start(let messageID):
            if let messageID { id = messageID }
        case .textStart:
            parts.append(.text(""))
        case .textDelta(let delta):
            if let last = parts.lastIndex(where: \.isText), case .text(let text) = parts[last] {
                parts[last] = .text(text + delta)
            } else {
                parts.append(.text(delta))
            }
        case .toolInput(let callID, let name, let input, let providerExecuted):
            if let index = toolIndex(callID), case .tool(var tool) = parts[index] {
                tool.input = input ?? tool.input
                parts[index] = .tool(tool)
            } else {
                parts.append(.tool(ChefTool(
                    callID: callID, name: name, input: input, state: .running, providerExecuted: providerExecuted)))
            }
        case .toolOutput(let callID, let output):
            updateTool(callID) { $0.state = .done(output) }
        case .toolFailed(let callID, let error):
            updateTool(callID) { $0.state = .failed(error) }
        case .failed, .other:
            break
        }
    }

    private func toolIndex(_ callID: String) -> Int? {
        parts.firstIndex { if case .tool(let tool) = $0 { tool.callID == callID } else { false } }
    }

    private mutating func updateTool(_ callID: String, _ change: (inout ChefTool) -> Void) {
        guard let index = toolIndex(callID), case .tool(var tool) = parts[index] else { return }
        change(&tool)
        parts[index] = .tool(tool)
    }
}

nonisolated enum ChefPart: Equatable, Sendable {
    case text(String)
    /// Only in what was sent: a photo of a recipe.
    case photo(RecipePhoto)
    case tool(ChefTool)

    var isText: Bool {
        if case .text = self { true } else { false }
    }
}

/// One tool Chef ran for a reply.
nonisolated struct ChefTool: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case running
        case done(JSONValue)
        case failed(String)
    }

    let callID: String
    let name: String
    var input: JSONValue?
    var state: State
    /// Run by Anthropic (web search), not by Omlete's server.
    let providerExecuted: Bool

    var isWebSearch: Bool { name == "web_search" }

    /// A tool that changed something answers with what it did and the id that undoes it.
    var change: ChefChange? {
        guard case .done(let output) = state, let done = output["done"]?.string, let undo = output["undo"]?.string
        else { return nil }
        return ChefChange(done: done, undo: ChefActionID(undo))
    }
}

/// A change Chef made, with the id that undoes it.
nonisolated struct ChefChange: Hashable, Sendable {
    let done: String
    let undo: ChefActionID
}

/// Where the user is, as the web names it. Each message to Chef carries the
/// path, and the server reads the list or recipe id from it.
nonisolated enum ChefPage: Equatable, Sendable {
    case home, discover, recipes, addRecipe, settings
    case list(ListID)
    case recipe(RecipeID)
    case shop(ListID)
    case cook(RecipeID)

    /// The web route for the same screen, which `server/chef/chat.py` reads.
    var path: String {
        switch self {
        case .home: "/"
        case .discover: "/discover"
        case .recipes: "/recipes"
        case .addRecipe: "/create"
        case .settings: "/settings"
        case .list(let id): "/list/\(id.rawValue)"
        case .recipe(let id): "/recipe/\(id.rawValue)"
        case .shop(let id): "/shop/\(id.rawValue)"
        case .cook(let id): "/cook/\(id.rawValue)"
        }
    }
}
