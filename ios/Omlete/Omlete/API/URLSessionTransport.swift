import Foundation

nonisolated struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// `requestTimeout` is how long a request may go without hearing from the
    /// server. A request that sets its own `timeoutInterval` keeps it, which is
    /// how the calls that wait on a model get longer.
    init(requestTimeout: TimeInterval = 20) {
        let configuration = URLSessionConfiguration.default
        // A request that hangs in a shop with one bar should give way to the retry.
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// Hands the body on a line at a time, so each event is read as soon as it ends.
    func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let lines = AsyncThrowingStream<Data, any Error> { continuation in
            let reading = Task {
                do {
                    var line = Data()
                    for try await byte in bytes {
                        line.append(byte)
                        if byte == UInt8(ascii: "\n") {
                            continuation.yield(line)
                            line = Data()
                        }
                    }
                    if !line.isEmpty { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reading.cancel() }
        }
        return (http, lines)
    }
}
