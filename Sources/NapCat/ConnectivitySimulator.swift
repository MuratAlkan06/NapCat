/// In-memory `ConnectivityInterface` for debug-battery mode and tests — the
/// `DebugPowerSimulator` of the network path. The simulated status is driven
/// by hand (`status`, `redeliver()`); nothing here observes the real network.
///
/// ISOLATION GUARANTEE: like `DebugPowerSimulator.swift`, this file has NO
/// import statements at all — only the implicitly available standard library
/// — so it structurally cannot reach the Network framework, a dispatch queue,
/// a timer, a logger or a socket. `ConnectivityStructureTests` fails the test
/// gate if an import or any such token ever appears here.
///
/// Used from the main actor only (the protocol itself is not actor-isolated).
/// Delivery is SYNCHRONOUS, from inside `start` / the `status` setter; the
/// owner hops to the main actor itself, exactly as it does for the real
/// monitor's private-queue deliveries.
final class ConnectivitySimulator: ConnectivityInterface {
    /// The simulated path. Every CHANGE is delivered to a running observer.
    var status: ConnectivityPathStatus {
        didSet { if status != oldValue { handler?(status) } }
    }

    private var handler: (@Sendable (ConnectivityPathStatus) -> Void)?

    /// Calls to `start` that began observing (a no-op start is not counted).
    private(set) var startCount = 0
    /// Calls to `stop` that ended observing (a no-op stop is not counted).
    private(set) var stopCount = 0

    init(status: ConnectivityPathStatus = .satisfied) {
        self.status = status
    }

    var isRunning: Bool { handler != nil }

    /// Delivers the current status first, like the real monitor's initial
    /// update.
    func start(handler: @escaping @Sendable (ConnectivityPathStatus) -> Void) {
        guard self.handler == nil else { return }
        startCount += 1
        self.handler = handler
        handler(status)
    }

    func stop() {
        guard handler != nil else { return }
        stopCount += 1
        handler = nil
    }

    /// Re-delivers the CURRENT status — a path update that changed nothing
    /// the owner can see (an interface change while still satisfied).
    func redeliver() {
        handler?(status)
    }
}
