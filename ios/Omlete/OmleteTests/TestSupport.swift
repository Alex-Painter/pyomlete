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
        /// There is no network: the request never leaves.
        case unreachable
        /// The request left and nothing came back.
        case lost
        /// 200 with a body made from the request's own.
        case answering(([String: Any]) -> String)
    }

    /// Requests in arrival order, without the `/categorize` lookups that adds fire on the side.
    var calls: [Call] { allCalls.filter { $0.path != "/api/categorize" } }
    private(set) var allCalls: [Call] = []
    private(set) var bodies: [[String: Any]] = []
    /// Every request as sent, for what a `Call` leaves out: headers, timeout, a body that is not JSON.
    private(set) var requests: [URLRequest] = []
    /// The most list requests that were ever in flight at once.
    private(set) var peakInFlight = 0
    private var inFlight = 0

    var reply: (Call) -> Reply = { _ in .status(200) }
    /// While set, every request waits here until `release()`.
    var holding = false
    private var held: [(call: Call, resume: CheckedContinuation<Void, Never>)] = []
    /// Requests that have been answered, in the order their answers went back.
    private(set) var answered: [Call] = []

    func release() {
        holding = false
        held.forEach { $0.resume.resume() }
        held = []
    }

    /// Answers the held requests for `call` and keeps holding the rest, so a test chooses which answer arrives first.
    func release(only call: Call) {
        held.filter { $0.call == call }.forEach { $0.resume.resume() }
        held.removeAll { $0.call == call }
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await answer(request)
    }

    private func answer(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let call = Call(method: request.httpMethod ?? "GET", path: request.url?.path() ?? "")
        allCalls.append(call)
        requests.append(request)
        let isListRequest = call.path != "/api/categorize"
        let sent = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if isListRequest {
            bodies.append(sent)
            inFlight += 1
            peakInFlight = max(peakInFlight, inFlight)
        }
        defer {
            if isListRequest { inFlight -= 1 }
            answered.append(call)
        }
        if holding { await withCheckedContinuation { held.append((call, $0)) } }
        func response(_ status: Int, _ body: String) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        switch reply(call) {
        case .unreachable:
            throw URLError(.notConnectedToInternet)
        case .lost:
            throw URLError(.timedOut)
        case .status(let status, let body):
            return response(status, body)
        case .answering(let body):
            return response(200, body(sent))
        }
    }
}

@MainActor final class MemoryStorage: ReplicaStorage {
    var replicas: [ListID: ListReplica] = [:]
    var index: LibraryIndex?
    var aisles: AisleRecord?

    func loadAll() -> [ListReplica] { Array(replicas.values) }
    func save(_ replica: ListReplica) { replicas[replica.id] = replica }
    func discard(_ id: ListID) { replicas[id] = nil }
    func loadIndex() -> LibraryIndex? { index }
    func save(_ index: LibraryIndex) { self.index = index }
    func loadAisles() -> AisleRecord? { aisles }
    func save(_ aisles: AisleRecord) { self.aisles = aisles }
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

    /// What `GET /api/lists/` answers for a phone whose only list is the fixture.
    static let listsJSON = """
        [{"id":"list","name":"Week","created_at":null,"item_count":2,"checked_count":0,"recipes":[{"id":"curry","title":"Curry"}]}]
        """

    let transport = ScriptedTransport()
    let storage = MemoryStorage()
    let ticker = Ticker()
    /// The intake's wait between looks at a job, apart from Chef's so neither wakes the other.
    let pulse = Ticker()
    let defaults = UserDefaults(suiteName: "phone-\(UUID().uuidString)")!
    nonisolated static let apiAddress = "http://phone.test"
    /// The phone's clock, which a test puts forward.
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// Recipe jobs are keyed job1, job2, … in the order they were tapped.
    private var jobsKeyed = 0
    private(set) var undo = UndoCenter()
    private(set) var library: Library!
    private(set) var chef: Chef!
    private(set) var intake: RecipeIntake!

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

    /// A new process on the same phone. `comingToFront` is the scene becoming
    /// active, which a launch ends in; without it the app has been made and nothing more.
    func relaunch(against server: String = Phone.apiAddress, comingToFront: Bool = true) {
        undo = UndoCenter()
        // The intake that is replaced below was mid-wait, and that wait dies with its process.
        pulse.tick()
        let api = APIClient(baseURL: URL(string: server)!, transport: transport)
        library = Library(deps: StoreDependencies(
            api: api,
            disk: storage, undo: undo, connectivity: Connectivity(), retryDelay: nil))
        chef = Chef(deps: ChefDependencies(
            api: api, undo: undo, library: library, defaults: defaults,
            // Weak, because a poll still running when a test ends outlives the phone.
            now: { [weak self] in self?.now ?? .distantPast }, pause: { [ticker] _ in try await ticker.pause() }))
        intake = RecipeIntake(deps: IntakeDependencies(
            api: api, library: library, defaults: defaults, pause: { [pulse] in try await pulse.pause($0) },
            now: { [unowned self] in now },
            newKey: { [unowned self] in
                jobsKeyed += 1
                return RecipeJobID("job\(jobsKeyed)")
            }))
        if comingToFront { intake.resume() }
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

    /// `refresh()` returns before the aisles have answered, so a test that reads them waits for their requests to end.
    func aislesSettle() async {
        while let turn = library.aisles.working { await turn.value }
    }
}

/// Stands in for the wait between polls: each poll waits here until the test calls `tick()`.
@MainActor final class Ticker {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// How long each wait was asked to be, in order.
    private(set) var asked: [Duration] = []

    var isWaiting: Bool { !waiting.isEmpty }

    func pause(_ wanted: Duration = .zero) async throws {
        asked.append(wanted)
        await withCheckedContinuation { waiting.append($0) }
    }

    func tick() {
        let woken = waiting
        waiting = []
        woken.forEach { $0.resume() }
    }
}

@MainActor final class MemoryCookStorage: CookStorage {
    var records: [RecipeID: CookRecord] = [:]

    func loadAll() -> [CookRecord] { Array(records.values) }
    func save(_ record: CookRecord) { records[record.id] = record }
    func discard(_ id: RecipeID) { records[id] = nil }
}

/// A clock that only moves when a test says so. A sleeper wakes when the
/// clock is advanced past its date, or when its task is cancelled.
@MainActor final class TestClock {
    private(set) var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var sleepers: [Int: (until: Date, wake: CheckedContinuation<Void, Never>)] = [:]
    private var lastID = 0

    func advance(by seconds: TimeInterval) {
        now += seconds
        for (id, sleeper) in sleepers where sleeper.until <= now { wake(id) }
    }

    func sleep(until date: Date) async throws {
        guard date > now else { return }
        lastID += 1
        let id = lastID
        await withTaskCancellationHandler {
            await withCheckedContinuation { sleepers[id] = (date, $0) }
        } onCancel: {
            Task { @MainActor in self.wake(id) }
        }
        try Task.checkCancellation()
    }

    private func wake(_ id: Int) {
        sleepers.removeValue(forKey: id)?.wake.resume()
    }
}

/// A phone with one recipe on a scripted server, an in-memory disk and a clock
/// the test moves. `relaunch()` builds a fresh `Kitchen` over the same disk.
@MainActor final class Stove {
    static let recipeID: RecipeID = "curry"
    static let recipeJSON = """
        {"_id":"curry","title":"Curry","created_at":"2026-10-10T09:00:00","servings":4,"rating":null,
         "source_name":null,"total_minutes":35,
         "instructions":["Fry the onion with 200g rice for 5 mins.","Simmer 10–12 mins.","Rest for a minute.","Serve."],
         "ingredients":[
          {"name":"onions","amount":2,"unit":"whole","note":"finely chopped","category":"Produce","excluded_from_list":false},
          {"name":"rice","amount":200,"unit":"g","note":null,"group":null,"category":"Pantry","excluded_from_list":false},
          {"name":"coconut milk","amount":1,"unit":"tin","category":"Pantry","excluded_from_list":false}]}
        """

    let transport = ScriptedTransport()
    let storage = MemoryCookStorage()
    let clock = TestClock()
    /// Chimes since the test began, across relaunches.
    private(set) var chimes = 0
    /// Every recipe the kitchen reported as saved by an edit.
    private(set) var reportedSaves: [Recipe] = []
    private(set) var kitchen: Kitchen!

    init() {
        serverAnswers()
        relaunch()
    }

    var store: CookStore { kitchen.cook(Self.recipeID) }

    var session: CookSession? {
        if case .cooking(let session) = store.phase { session } else { nil }
    }

    func relaunch() {
        kitchen = Kitchen(deps: KitchenDependencies(
            api: APIClient(baseURL: URL(string: "http://phone.test")!, transport: transport),
            disk: storage,
            now: { [clock] in clock.now },
            sleepUntil: { [clock] in try await clock.sleep(until: $0) },
            chime: { [unowned self] in chimes += 1 },
            recipeSaved: { [unowned self] in reportedSaves.append($0) }))
    }

    func kill() {
        kitchen = nil
    }

    /// Scripts the server: the recipe GET returns the fixture, everything else
    /// 200, except where `override` says otherwise.
    func serverAnswers(_ override: @escaping (ScriptedTransport.Call) -> ScriptedTransport.Reply? = { _ in nil }) {
        transport.reply = { call in
            if let reply = override(call) { return reply }
            return call == .init(method: "GET", path: "/api/recipes/curry") ? .status(200, Self.recipeJSON) : .status(200)
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

extension Recipe {
    /// "Curry" with up to four steps; the first names two ingredients, an amount and a time.
    static func fixture(steps: Int = 3, servings: Int? = 4, rating: Int? = nil) -> Recipe {
        let all = ["Fry the onion with 200g rice for 5 mins.", "Simmer 10–12 mins.", "Rest for a minute.", "Serve."]
        return Recipe(
            id: "curry", title: "Curry", steps: Array(all.prefix(steps)),
            ingredients: [
                Ingredient(name: "onions", amount: 2, unit: "whole", note: "finely chopped"),
                Ingredient(name: "rice", amount: 200, unit: "g", note: nil),
                Ingredient(name: "coconut milk", amount: 1, unit: "tin", note: nil),
            ],
            baseServings: servings, rating: rating)
    }
}
