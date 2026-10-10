import Foundation
import Testing
@testable import Omlete

/// An `HTTPTransport` that answers from a script and records what it was asked.
@MainActor final class ScriptedTransport: HTTPTransport {
    struct Call: Equatable, CustomStringConvertible {
        let method: String
        let path: String
        var description: String { "\(method) \(path)" }
    }

    enum Reply {
        case status(Int, String = "{}")
        case unreachable
    }

    /// Requests in arrival order, without the `/categorize` lookups that adds fire on the side.
    var calls: [Call] { allCalls.filter { $0.path != "/api/categorize" } }
    private(set) var allCalls: [Call] = []
    private(set) var bodies: [[String: Any]] = []
    /// The most list requests that were ever in flight at once.
    private(set) var peakInFlight = 0
    private var inFlight = 0

    var reply: (Call) -> Reply = { _ in .status(200) }
    /// While set, every request waits here until `release()`.
    var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func release() {
        holding = false
        held.forEach { $0.resume() }
        held = []
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await answer(request)
    }

    private func answer(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let call = Call(method: request.httpMethod ?? "GET", path: request.url?.path() ?? "")
        allCalls.append(call)
        let isListRequest = call.path != "/api/categorize"
        if isListRequest {
            bodies.append(request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:])
            inFlight += 1
            peakInFlight = max(peakInFlight, inFlight)
        }
        defer { if isListRequest { inFlight -= 1 } }
        if holding { await withCheckedContinuation { held.append($0) } }
        switch reply(call) {
        case .unreachable:
            throw URLError(.notConnectedToInternet)
        case .status(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }
}

@MainActor final class MemoryStorage: ReplicaStorage {
    var replicas: [ListID: ListReplica] = [:]
    var index: LibraryIndex?

    func loadAll() -> [ListReplica] { Array(replicas.values) }
    func save(_ replica: ListReplica) { replicas[replica.id] = replica }
    func discard(_ id: ListID) { replicas[id] = nil }
    func loadIndex() -> LibraryIndex? { index }
    func save(_ index: LibraryIndex) { self.index = index }
}

/// A phone with a scripted server and an in-memory disk. `relaunch()` builds a
/// fresh `Library` over the same disk, as a cold start would.
@MainActor final class Phone {
    static let listID: ListID = "list"
    static let server = ListDetail(
        id: listID, name: "Week", recipes: ["curry"],
        items: [
            ListItem(id: "bread", name: "bread", amount: nil, unit: nil, category: "Bakery", checked: false, sources: []),
            ListItem(id: "milk", name: "milk", amount: 2, unit: "l", category: "Dairy", checked: false, sources: []),
        ])
    static let serverJSON = """
        {"id":"list","name":"Week","created_at":null,"recipes":["curry"],"items":[
        {"id":"bread","name":"bread","amount":null,"unit":null,"category":"Bakery","checked":false,"sources":[]},
        {"id":"milk","name":"milk","amount":2,"unit":"l","category":"Dairy","checked":false,"sources":[]}]}
        """

    let transport = ScriptedTransport()
    let storage = MemoryStorage()
    private(set) var undo = UndoCenter()
    private(set) var library: Library!

    /// `fetched` starts with the list already saved on the phone.
    init(fetched: Bool = true) {
        if fetched {
            var replica = ListReplica(id: Self.listID)
            replica.rebase(onto: Self.server)
            storage.save(replica)
        }
        relaunch()
    }

    var store: ListStore { library.list(Self.listID) }

    func relaunch() {
        undo = UndoCenter()
        library = Library(deps: StoreDependencies(
            api: APIClient(baseURL: URL(string: "http://phone.test")!, transport: transport),
            disk: storage, undo: undo, connectivity: Connectivity(), retryDelay: nil))
    }

    /// Scripts the server: the list GET returns the fixture, everything else 200,
    /// except where `override` says otherwise.
    func serverAnswers(_ override: @escaping (ScriptedTransport.Call) -> ScriptedTransport.Reply? = { _ in nil }) {
        transport.reply = { call in
            if let reply = override(call) { return reply }
            if call == .init(method: "GET", path: "/api/lists/list") { return .status(200, Self.serverJSON) }
            return call.path == "/api/categorize" ? .unreachable : .status(200)
        }
    }

    func serverIsUnreachable() {
        transport.reply = { _ in .unreachable }
    }
}

/// Lets queued main-actor work run until `condition` holds.
@MainActor func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<2000 where !condition() {
        try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(condition(), "condition never held", sourceLocation: sourceLocation)
}
