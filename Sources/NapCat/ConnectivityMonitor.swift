import Foundation
import Network

// Alert-channel healing (issue #23) — the REAL `ConnectivityInterface`. This
// is the ONLY Sources file that may import the Network framework or name its
// path monitor (`ConnectivityStructureTests`). It is a read-only observer: it
// reports whether ANY interface can carry traffic and nothing else — it never
// reads an interface's name or type, never restricts the monitor to one kind
// of interface (Wi-Fi-only would call a wired or tethered Mac offline), never
// sends anything and never schedules anything. Logging goes through
// `ConnectivityLog` (fixed words only).

/// All-interface path monitor. A FRESH `NWPathMonitor` per `start` — a
/// cancelled monitor can never be restarted — delivering on a private serial
/// queue (never the main queue). `stop` cancels it, so a disarmed NapCat holds
/// no monitor at all.
final class PathConnectivityMonitor: ConnectivityInterface, @unchecked Sendable {
    /// Private serial queue for the monitor's update handler.
    private let queue = DispatchQueue(label: "com.muratalkan.napcat.connectivity.path")

    private let lock = NSLock()
    /// Guarded by `lock`. Non-nil exactly while running.
    private var monitor: NWPathMonitor?
    /// Guarded by `lock`. How many monitors this observer has created — one
    /// per arm cycle (tests prove "fresh per start" with it). Doubles as the
    /// generation an update handler checks, so a late update from a stopped
    /// monitor is never delivered.
    private var created = 0
    /// Guarded by `lock`. The last status logged, so only CHANGES are logged.
    private var lastLogged: ConnectivityPathStatus?

    deinit {
        // An owner that forgets to stop must not leave the monitor running.
        monitor?.cancel()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return monitor != nil
    }

    /// Monitors created so far (one per `start` that was not a no-op).
    var monitorsCreated: Int {
        lock.lock()
        defer { lock.unlock() }
        return created
    }

    func start(handler: @escaping @Sendable (ConnectivityPathStatus) -> Void) {
        lock.lock()
        guard monitor == nil else {
            lock.unlock()
            return
        }
        let fresh = NWPathMonitor()
        monitor = fresh
        created += 1
        let generation = created
        lastLogged = nil
        lock.unlock()
        // Captures the generation, never the monitor itself (no retain cycle
        // through its own handler).
        fresh.pathUpdateHandler = { [weak self] path in
            let status = Self.status(for: path.status)
            // A late update from a monitor that has since been stopped (or
            // replaced) is dropped: nothing is delivered after `stop`.
            guard let self, self.isCurrent(generation, logging: status) else { return }
            handler(status)
        }
        ConnectivityLog.monitorStarted()
        fresh.start(queue: queue)
    }

    func stop() {
        lock.lock()
        let running = monitor
        monitor = nil
        lastLogged = nil
        lock.unlock()
        guard let running else { return }
        running.cancel()
        ConnectivityLog.monitorStopped()
    }

    /// True iff `generation` is still the live monitor's; logs the status when
    /// it differs from the last one logged.
    private func isCurrent(_ generation: Int, logging status: ConnectivityPathStatus) -> Bool {
        lock.lock()
        let current = monitor != nil && created == generation
        let changed = current && lastLogged != status
        if changed { lastLogged = status }
        lock.unlock()
        if changed { ConnectivityLog.pathChanged(status) }
        return current
    }

    /// Pure mapping. Only `.unsatisfied` is evidence of an outage:
    /// `.requiresConnection` means a connection attempt may bring the path up
    /// (the send itself is the probe), and an unknown future status fails
    /// toward sending rather than holding.
    static func status(for status: NWPath.Status) -> ConnectivityPathStatus {
        switch status {
        case .unsatisfied: return .unsatisfied
        case .satisfied, .requiresConnection: return .satisfied
        @unknown default: return .satisfied
        }
    }
}
