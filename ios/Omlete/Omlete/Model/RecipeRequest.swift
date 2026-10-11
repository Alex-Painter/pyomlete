import Foundation

nonisolated struct RecipePhoto: Equatable, Sendable, Identifiable {
    let id: UUID
    let jpeg: Data
}

/// What one tap on Add a recipe asks for. Photos win over text; text that is
/// one web address is a link; anything else is a description.
nonisolated enum RecipeRequest: Equatable, Sendable {
    case link(String)
    case describe(String)
    /// Read together as one recipe, such as two pages of a cookbook.
    case photos([RecipePhoto])

    enum Kind: String, Codable, Equatable, Sendable {
        case link, describe, photos
    }

    var kind: Kind {
        switch self {
        case .link: .link
        case .describe: .describe
        case .photos: .photos
        }
    }

    /// nil when there is nothing to send: no photos and fewer than three characters.
    init?(text: String, photos: [RecipePhoto]) {
        let text = text.trimmed
        if !photos.isEmpty {
            self = .photos(photos)
        } else if text.wholeMatch(of: /https?:\/\/\S+\.\S+/) != nil {
            self = .link(text)
        } else if text.count > 2 {
            self = .describe(text)
        } else {
            return nil
        }
    }
}

/// Everything adding a recipe can end in. Total, so nothing after the API
/// client catches an error or reads a status.
nonisolated enum RecipeCreation: Equatable, Sendable {
    case saved(Recipe)
    /// The link was imported before; this is the recipe it made.
    case alreadySaved(RecipeID)
    case failed(Failure)

    enum Failure: Equatable, Sendable {
        /// The request never became a job. Once the server has one, losing touch with it is not a failure.
        case unreachable
        case linkBlocked
        case noRecipeOnPage
        case siteDidNotRespond
        case other

        var message: String {
            switch self {
            case .unreachable: "Couldn't reach Omlete. Check your connection and try again."
            case .linkBlocked: "That link can't be fetched. Check it's a full, public recipe URL."
            case .noRecipeOnPage:
                "Couldn't find a recipe on that page. Try the recipe's own page rather than a listing or a video."
            case .siteDidNotRespond: "That site didn't respond. It may be down or blocking us. Try again in a minute."
            case .other: "Something went wrong making that recipe. Try again."
            }
        }
    }
}

/// A recipe the server is making. The server owns the work, so this is all
/// the phone has to remember to find out how it went.
nonisolated struct RecipeJob: Codable, Equatable, Sendable {
    let id: RecipeJobID
    let kind: RecipeRequest.Kind
}

/// What handing a request to the server ends in.
nonisolated enum RecipeStart: Equatable, Sendable {
    case started(RecipeJob)
    case failed(RecipeCreation.Failure)
}

/// One look at a job.
nonisolated enum RecipeJobCheck: Equatable, Sendable {
    case working
    case finished(RecipeCreation)
    /// The server could not be asked, which says nothing about the job.
    case unanswered
}
