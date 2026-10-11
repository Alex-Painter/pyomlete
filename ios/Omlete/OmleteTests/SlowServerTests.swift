import Foundation
import Network
import Testing
@testable import Omlete

/// A real server on this machine that takes its time, for the one thing a
/// scripted transport cannot show: which timeout `URLSession` obeys.
nonisolated final class SlowServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "slow-server")

    init(answeringAfter delay: Duration) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                queue.asyncAfter(deadline: .now() + .milliseconds(Int(delay / .milliseconds(1)))) {
                    let reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n[]"
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
    }

    /// Starts listening and returns the address to call.
    func start() async throws -> URL {
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { ready in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: ready.resume(returning: listener.port!)
                case .failed(let error): ready.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        listener.stateUpdateHandler = nil
        return URL(string: "http://127.0.0.1:\(port.rawValue)")!
    }

    func stop() {
        listener.cancel()
    }
}

@MainActor struct SlowServerTests {
    @Test func aCallThatWaitsOnAModelOutlastsTheTimeoutThatEndsAnOrdinaryOne() async throws {
        let server = try SlowServer(answeringAfter: .milliseconds(1500))
        let api = APIClient(baseURL: try await server.start(), transport: URLSessionTransport(requestTimeout: 0.5))
        defer { server.stop() }

        await #expect(throws: APIError.unreachable) { try await api.lists() }
        try await api.findIdeas(TuneSettings())
    }
}
