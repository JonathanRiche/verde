import Foundation
import Network

/// `id` is an opaque local route description; it only tells the core that the
/// route changed (for example Tailscale toggling its tunnel interface).
struct NetworkState: Equatable {
    var available: Bool
    var id: String

    init(available: Bool, id: String) { self.available = available; self.id = id }

    init(_ path: NWPath) {
        let available = path.status == .satisfied
        // Interface names change when a VPN tunnel or Wi-Fi/cellular route changes.
        let names = path.availableInterfaces.map { "\($0.type)-\($0.name)" }.joined(separator: ",")
        self.init(available: available, id: available ? names : "")
    }
}

/// Process-wide connectivity feed. `NWPathMonitor` delivers its initial path
/// promptly after `start`, then every change; updates hop to the main queue.
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.verdeai.app.network")

    func start(_ update: @escaping @MainActor (NetworkState) -> Void) {
        monitor.pathUpdateHandler = { path in
            let state = NetworkState(path)
            // The main queue is FIFO, so route changes reach the cores in order.
            DispatchQueue.main.async { MainActor.assumeIsolated { update(state) } }
        }
        monitor.start(queue: queue)
    }

    func stop() { monitor.cancel() }
    deinit { monitor.cancel() }
}
