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
    private let baseURL: URL
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

    func aisleOrder() async throws(APIError) -> [String] {
        try await decode(Wire.aisleOrder, from: call("GET", "settings/categories"))
    }

    /// Replaces the whole order. Sending the same order twice is harmless.
    func saveAisleOrder(_ names: [String]) async throws(APIError) {
        _ = try await call("PUT", "settings/categories", body: try Wire.aisleOrder(names))
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

    /// Hands the request to the server, which answers at once and makes the
    /// recipe in its own time. Never throws: not reaching the server is the
    /// one failure the user can do something about, and it is named here.
    func startRecipe(_ request: RecipeRequest) async -> RecipeStart {
        do throws(APIError) {
            let upload = try Wire.jobStart(request)
            let answer = try await exchange("POST", upload.path, body: upload.body, contentType: upload.contentType)
            if let failure = APIError(status: answer.status) { throw failure }
            return .started(RecipeJob(id: try decode(Wire.startedJob, from: answer.data), kind: request.kind))
        } catch {
            return .failed(error == .unreachable ? .unreachable : .other)
        }
    }

    /// Asks how a job stands. Never throws: an answer that could not be had
    /// is `.unanswered`, which is for asking again, and a job the server no
    /// longer knows has failed. A saved job's recipe is fetched here, so
    /// `.finished(.saved)` always carries it.
    func checkRecipe(_ job: RecipeJob) async -> RecipeJobCheck {
        do throws(APIError) {
            switch try decode(Wire.jobAnswer, from: try await call("GET", "recipe-jobs/\(job.id.rawValue)")) {
            case .working: return .working
            case .saved(let id): return .finished(.saved(try await recipe(id)))
            case .alreadySaved(let id): return .finished(.alreadySaved(id))
            case .failed(let failure): return .finished(.failed(failure))
            }
        } catch {
            return error.isRetryable ? .unanswered : .finished(.failed(.other))
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

    /// Tidying only: the server learns nothing about taste from it.
    func clearSuggestions(_ ids: [SuggestionID]) async throws(APIError) {
        _ = try await call("POST", "suggestions/clear", body: try Wire.clearing(ids))
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
        guard let url = URL(string: "api/\(path)", relativeTo: baseURL) else { throw .rejected(400) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if patience == .slow { request.timeoutInterval = Self.slowTimeout }
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await transport.send(request)
            return (response.statusCode, data)
        } catch {
            throw .unreachable
        }
    }

    private func decode<Value>(_ parse: (Data) throws -> Value, from data: Data) throws(APIError) -> Value {
        do {
            return try parse(data)
        } catch {
            throw .undecodable
        }
    }
}
