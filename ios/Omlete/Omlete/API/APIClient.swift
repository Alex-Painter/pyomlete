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

    func addRecipe(_ recipe: RecipeID, to list: ListID) async throws(APIError) {
        _ = try await call("POST", "lists/\(list.rawValue)/recipes", body: try Wire.encode(["recipe_id": recipe.rawValue]))
    }

    func aisleOrder() async throws(APIError) -> [String] {
        try await decode(Wire.aisleOrder, from: call("GET", "settings/categories"))
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

    private func call(_ method: String, _ path: String, body: Data? = nil) async throws(APIError) -> Data {
        guard let url = URL(string: "api/\(path)", relativeTo: baseURL) else { throw .rejected(400) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw .unreachable
        }
        if let failure = APIError(status: response.statusCode) { throw failure }
        return data
    }

    private func decode<Value>(_ parse: (Data) throws -> Value, from data: Data) throws(APIError) -> Value {
        do {
            return try parse(data)
        } catch {
            throw .undecodable
        }
    }
}
