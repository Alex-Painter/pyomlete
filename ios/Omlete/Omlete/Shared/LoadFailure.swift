import SwiftUI

/// A screen that has nothing saved to show and could not load: what went wrong, and Try again.
struct LoadFailure: View {
    let failure: APIError
    let retryIdentifier: String
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label(
                failure == .unreachable ? "Couldn't reach Omlete. Check your connection." : "Something went wrong loading this.",
                systemImage: failure == .unreachable ? "wifi.slash" : "exclamationmark.circle")
                .font(.headline)
        } actions: {
            Button("Try again") {
                Task { await retry() }
            }
            .accessibilityIdentifier(retryIdentifier)
        }
    }
}
