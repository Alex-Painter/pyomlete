import Foundation

/// Classified once at the boundary; nothing else looks at a status code.
nonisolated enum APIError: Error, Equatable, Sendable {
    /// No response: offline, timeout, DNS.
    case unreachable
    /// The server could not answer now: 5xx, 408 or 429.
    case serverFault(Int)
    /// Any other 4xx: the request is wrong or its target is gone.
    case rejected(Int)
    /// A 2xx whose body could not be read.
    case undecodable

    var isRetryable: Bool {
        switch self {
        case .unreachable, .serverFault: true
        case .rejected, .undecodable: false
        }
    }

    var isNotFound: Bool { self == .rejected(404) }

    var silence: Silence { self == .unreachable ? .noConnection : .serverTrouble }

    init?(status: Int) {
        switch status {
        case 200..<300: return nil
        case 408, 429, 500...: self = .serverFault(status)
        default: self = .rejected(status)
        }
    }
}

/// The network seam: bytes out, bytes back. Tests script a fake.
nonisolated protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Typed endpoints that return domain values and throw `APIError`. The JSON
/// shapes live in `Wire`, so a server rename touches one file.
nonisolated struct APIClient: Sendable {
    /// Which server this is. A recipe job belongs to the server it was sent to.
    let baseURL: URL
    private let transport: any HTTPTransport

    init(baseURL: URL, transport: any HTTPTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    func lists() async throws(APIError) -> [ListSummary] {
        try await decode(Wire.summaries, from: call("GET", "lists/"))
    }

    /// The server mints the id and the name, so this needs signal.
    func createList() async throws(APIError) -> ListSummary {
        try await decode(Wire.createdList, from: call("POST", "lists/"))
    }

    func list(_ id: ListID) async throws(APIError) -> ListDetail {
        try await decode(Wire.detail, from: call("GET", "lists/\(id.rawValue)"))
    }

    func duplicateList(_ id: ListID) async throws(APIError) -> ListSummary {
        try await decode(Wire.createdList, from: call("POST", "lists/\(id.rawValue)/duplicate"))
    }

    func deleteList(_ id: ListID) async throws(APIError) {
        _ = try await call("DELETE", "lists/\(id.rawValue)")
    }

    /// The whole op vocabulary through one door. The switch is exhaustive, so
    /// a new kind of op cannot ship without a route.
    func send(_ op: ListOp, to list: ListID) async throws(APIError) {
        let base = "lists/\(list.rawValue)"
        switch op {
        case .add(let item):
            _ = try await call("POST", "\(base)/items", body: try Wire.newItem(item))
        case .patch(let item, let patch):
            _ = try await call("PATCH", "\(base)/items/\(item.rawValue)", body: try Wire.encode(patch))
        case .delete(let item):
            _ = try await call("DELETE", "\(base)/items/\(item.rawValue)")
        case .removeRecipe(let recipe):
            _ = try await call("DELETE", "\(base)/recipes/\(recipe.rawValue)")
        case .reorder(let category, let itemIDs):
            _ = try await call("PUT", "\(base)/items/reorder", body: try Wire.reorder(category: category, itemIDs: itemIDs))
        case .rename(let name):
            _ = try await call("PATCH", base, body: try Wire.encode(["name": name]))
        }
    }

    /// The endpoint's one 400 means the recipe is already on that list.
    func addRecipe(_ recipe: RecipeID, to list: ListID) async throws(APIError) -> MealAdd {
        let answer = try await exchange(
            "POST", "lists/\(list.rawValue)/recipes", body: try Wire.encode(["recipe_id": recipe.rawValue]))
        if answer.status == 400 { return .alreadyOnList }
        if let failure = APIError(status: answer.status) { throw failure }
        return .added
    }

    func aisleOrder() async throws(APIError) -> AisleOrder {
        try await decode(Wire.aisleOrder, from: call("GET", "settings/categories"))
    }

    /// Replaces the whole order and answers with the order the server stored,
    /// which is cleaned and so may be shorter. Sending the same order twice is harmless.
    func saveAisleOrder(_ order: AisleOrder) async throws(APIError) -> AisleOrder {
        try await decode(Wire.aisleOrder, from: call("PUT", "settings/categories", body: try Wire.aisleOrderBody(order)))
    }

    /// May be slow: the server asks a model when its cache misses.
    func categorize(_ name: String) async throws(APIError) -> String {
        try await decode(Wire.category, from: call("POST", "categorize", body: try Wire.encode(["name": name])))
    }

    func units() async throws(APIError) -> [String] {
        try await decode(Wire.units, from: call("GET", "units"))
    }

    func recipes() async throws(APIError) -> [RecipeSummary] {
        try await decode(Wire.recipes, from: call("GET", "recipes/"))
    }

    /// A deleted recipe is `.rejected(404)`.
    func recipe(_ id: RecipeID) async throws(APIError) -> Recipe {
        try await decode(Wire.recipe, from: call("GET", "recipes/\(id.rawValue)"))
    }

    /// Setting the same rating twice is harmless, so a retry is safe.
    func rate(_ id: RecipeID, stars: Int) async throws(APIError) {
        _ = try await call("PATCH", "recipes/\(id.rawValue)/rating", body: try Wire.encode(["rating": stars]))
    }

    /// Replaces the title, method and whole ingredient list, and answers with
    /// the recipe as the server now has it. Sending the same edit twice is harmless.
    func updateRecipe(_ id: RecipeID, _ edit: RecipeEdit) async throws(APIError) -> Recipe {
        try await decode(Wire.recipe, from: call("PUT", "recipes/\(id.rawValue)", body: try Wire.recipeUpdate(edit)))
    }

    func deleteRecipe(_ id: RecipeID) async throws(APIError) {
        _ = try await call("DELETE", "recipes/\(id.rawValue)")
    }

    /// `index` is the ingredient's position in the recipe, which is how the server addresses it.
    func setOnList(_ recipe: RecipeID, ingredient index: Int, _ onList: Bool) async throws(APIError) {
        _ = try await call(
            "PATCH", "recipes/\(recipe.rawValue)/ingredients/\(index)/exclude", body: try Wire.encode(["excluded": !onList]))
    }

    /// Sends a job's start, which the server answers at once and is safe to
    /// send again: the key in the path is the job. Never throws.
    func startRecipe(_ request: RecipeRequest, as job: RecipeJob) async -> RecipeStart {
        do {
            let upload = try Wire.jobStart(request, key: job.key)
            let answer = try await transmit("PUT", upload.path, body: upload.body, contentType: upload.contentType)
            switch answer.status {
            case 200..<300: return .taken
            case 429: return .refused(.busy)
            case 408, 500...: return .unanswered(.serverTrouble)
            default: return .refused(.other)
            }
        } catch is APIError {
            return .refused(.other)
        } catch let error as URLError where Self.neverLeft.contains(error.code) {
            return .notSent
        } catch {
            return .unanswered(.noConnection)
        }
    }

    /// Failures that happen before a request can reach a server, so it cannot
    /// have been acted on. A timeout or a dropped connection is not one of them.
    private static let neverLeft: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .dataNotAllowed,
        .internationalRoamingOff,
    ]

    /// Asks how a job stands. Never throws, and only a clear answer is a
    /// verdict: a fault or a body this build cannot read is `.unanswered`. A
    /// saved job's recipe is fetched here, so `.finished(.saved)` carries it.
    func checkRecipe(_ job: RecipeJob) async -> RecipeJobCheck {
        let answer: Wire.JobAnswer
        do throws(APIError) {
            answer = try decode(Wire.jobAnswer, from: try await call("GET", "recipe-jobs/\(job.key.rawValue)"))
        } catch {
            return error.isNotFound ? .unknown : .unanswered(error.silence)
        }
        switch answer {
        case .working: return .working
        case .alreadySaved(let id): return .finished(.alreadySaved(id))
        case .failed(let failure): return .finished(.failed(failure))
        case .saved(let id):
            do throws(APIError) {
                return .finished(.saved(try await recipe(id)))
            } catch {
                return error.isNotFound ? .recipeGone : .unanswered(error.silence)
            }
        }
    }

    func suggestions() async throws(APIError) -> [Suggestion] {
        try await decode(Wire.suggestions, from: call("GET", "suggestions/"))
    }

    /// Asks a model for a new batch of cards, so it can take a minute.
    func findIdeas(_ tune: TuneSettings) async throws(APIError) {
        _ = try await call("POST", "suggestions/refresh", body: try Wire.tune(tune), patience: .slow)
    }

    /// Answers at once; the recipe is made in the background and goes on `list` when it exists.
    func saveSuggestion(_ id: SuggestionID, onto list: ListID?) async throws(APIError) {
        _ = try await call("POST", "suggestions/\(id.rawValue)/save", body: try Wire.saveSuggestion(onto: list))
    }

    /// "Not for me": a taste signal the server keeps.
    func dismissSuggestion(_ id: SuggestionID) async throws(APIError) {
        _ = try await call("PATCH", "suggestions/\(id.rawValue)", body: try Wire.dismissal())
    }

    /// Tidying only: the server learns nothing about taste from it. With
    /// `onlyNew` it leaves a card that has been saved or has failed since the phone read it.
    func clearSuggestions(_ ids: [SuggestionID], onlyNew: Bool) async throws(APIError) {
        _ = try await call("POST", "suggestions/clear", body: try Wire.clearing(ids, onlyNew: onlyNew))
    }

    private enum Patience {
        case quick
        /// For a call that waits on a model. Overrides the transport's short default.
        case slow
    }

    static let slowTimeout: TimeInterval = 180

    private func call(
        _ method: String, _ path: String, body: Data? = nil, patience: Patience = .quick
    ) async throws(APIError) -> Data {
        let answer = try await exchange(method, path, body: body, patience: patience)
        if let failure = APIError(status: answer.status) { throw failure }
        return answer.data
    }

    /// Bytes and a status with no judgement made. Throws only `.unreachable`,
    /// or `.rejected(400)` for a path that is not a URL.
    private func exchange(
        _ method: String, _ path: String, body: Data? = nil, contentType: String = Wire.json,
        patience: Patience = .quick
    ) async throws(APIError) -> (status: Int, data: Data) {
        do {
            return try await transmit(method, path, body: body, contentType: contentType, patience: patience)
        } catch let error as APIError {
            throw error
        } catch {
            throw .unreachable
        }
    }

    /// `exchange` with the transport's own error left as it is, for the one
    /// caller that tells a request that never left from one never answered.
    private func transmit(
        _ method: String, _ path: String, body: Data? = nil, contentType: String = Wire.json,
        patience: Patience = .quick
    ) async throws -> (status: Int, data: Data) {
        guard let url = URL(string: "api/\(path)", relativeTo: baseURL) else { throw APIError.rejected(400) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if patience == .slow { request.timeoutInterval = Self.slowTimeout }
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport.send(request)
        return (response.statusCode, data)
    }

    private func decode<Value>(_ parse: (Data) throws -> Value, from data: Data) throws(APIError) -> Value {
        do {
            return try parse(data)
        } catch {
            throw .undecodable
        }
    }
}
