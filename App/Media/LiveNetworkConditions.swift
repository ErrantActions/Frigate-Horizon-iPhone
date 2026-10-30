import Foundation
import Network

@MainActor
final class LiveNetworkConditions {
    static let shared = LiveNetworkConditions()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "Horizon.live-network")
    private(set) var restricted = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let restricted = path.status != .satisfied || path.isExpensive || path.isConstrained
            Task { @MainActor [weak self] in self?.restricted = restricted }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
