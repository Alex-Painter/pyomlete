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
        /// The server never took the job in the time a start is sent for.
        case unreachable
        /// The server is making as many recipes as it will at once.
        case busy
        /// Nothing said how the job ended in the longest a job can take, so the phone stopped waiting.
        case noAnswerInTime
        /// The app was closed before the photos arrived, and photos are not kept on the phone.
        case photosNotSent
        case linkBlocked
        case noRecipeOnPage
        case siteDidNotRespond
        case other

        var message: String {
            switch self {
            case .unreachable: "Couldn't reach Omlete. Check your connection and try again."
            case .busy: "Omlete is busy making other recipes. Try again shortly."
            case .noAnswerInTime: "Omlete didn't answer in time. Check your recipes before trying again."
            case .photosNotSent: "Your photos didn't reach Omlete before the app closed. Choose them again."
            case .linkBlocked: "That link can't be fetched. Check it's a full, public recipe URL."
            case .noRecipeOnPage:
                "Couldn't find a recipe on that page. Try the recipe's own page rather than a listing or a video."
            case .siteDidNotRespond: "That site didn't respond. It may be down or blocking us. Try again in a minute."
            case .other: "Something went wrong making that recipe. Try again."
            }
        }
    }
}

/// One tap on Add a recipe, as the server knows it. The phone mints the key
/// before anything is sent, so a start can be sent again and still be this job.
nonisolated struct RecipeJob: Codable, Equatable, Sendable {
    let key: RecipeJobID
    let kind: RecipeRequest.Kind
    /// When it was tapped, by the phone's clock.
    let startedAt: Date
}

/// Why the server said nothing that can be acted on.
nonisolated enum Silence: Equatable, Sendable {
    case noConnection
    /// It answered with a fault, or with something this build cannot read.
    case serverTrouble
}

/// What sending a job's start ends in.
nonisolated enum RecipeStart: Equatable, Sendable {
    /// The server has the job, from this send or an earlier one.
    case taken
    /// The server will not make it. The only way a start fails.
    case refused(RecipeCreation.Failure)
    /// It may or may not have arrived. Sending it again is safe.
    case unanswered(Silence)
}

/// One look at a job.
nonisolated enum RecipeJobCheck: Equatable, Sendable {
    case working
    case finished(RecipeCreation)
    /// It was saved, and the recipe has been deleted since.
    case recipeGone
    /// The server has never been sent this key, or was sent it over a day ago.
    case unknown
    /// Says nothing about the job.
    case unanswered(Silence)
}
