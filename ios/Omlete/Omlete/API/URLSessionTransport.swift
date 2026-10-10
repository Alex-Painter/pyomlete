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
}
