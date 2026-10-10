import Foundation
import Network
import Observation

/// Whether the phone has a network path, and a hook for the moment it gets one back.
@Observable final class Connectivity {
    private(set) var isOnline = true

    @ObservationIgnored var onRegain: (() -> Void)?
    @ObservationIgnored private var monitoring: Task<Void, Never>?

    func start() {
        guard monitoring == nil else { return }
        monitoring = Task { [weak self] in
            for await path in NWPathMonitor() {
                self?.update(isOnline: path.status == .satisfied)
            }
        }
    }

    private func update(isOnline: Bool) {
        let regained = isOnline && !self.isOnline
        self.isOnline = isOnline
        if regained { onRegain?() }
    }
}
