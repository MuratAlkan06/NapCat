import os

// Alert-channel healing (issue #23) — the ONE abstraction over the network
// path. Everything above this protocol is implementation-blind: the real
// all-interface path monitor lives in `ConnectivityMonitor.swift` (the only
// Sources file that may import or name the Network framework), and the
// in-memory `ConnectivitySimulator` stands in for it in debug-simulator mode
// and in the tests. Same startup-swap shape as `PowerInterface`: in
// debugBattery mode the real monitor is never even constructed
// (`ConnectivityWiring.makeInterface`, the single construction site of both).
// `ConnectivityStructureTests` locks the confinement, the seam count and the
// log hygiene.

/// What one path update says about reachability. Log-safe by construction: a
/// fixed word, never an interface name, an address or a network name.
enum ConnectivityPathStatus: String, Equatable, Sendable {
    /// Some interface can carry traffic now — or could once a connection is
    /// attempted (the system's "requires connection" state is NOT evidence of
    /// an outage: the send itself is the probe).
    case satisfied
    /// No interface can carry traffic.
    case unsatisfied
}

/// An observer of the system network path, behind a protocol so the tests and
/// the debug simulator drive it by hand. Same lifecycle shape as
/// `MarkerDirectoryWatching`: started when the owner arms, stopped when it
/// disarms, so a disarmed NapCat holds no monitor and takes no wakeups.
protocol ConnectivityInterface: AnyObject {
    /// True while observing — between a `start` and the next `stop`.
    var isRunning: Bool { get }
    /// Starts observing. Every start observes through a FRESH underlying
    /// monitor (a cancelled one is terminal). `handler` receives the current
    /// status first, then one call per path update (an update may repeat the
    /// previous status — an interface change while satisfied). The real
    /// monitor calls it on a PRIVATE serial queue, never the main queue.
    /// Starting a running observer is a no-op.
    func start(handler: @escaping @Sendable (ConnectivityPathStatus) -> Void)
    /// Cancels the underlying monitor; no update is delivered after it
    /// returns. Idempotent; start → stop → start works.
    func stop()
}

/// The startup protocol swap (ADR §8 mirror, `PowerInterface` precedent):
/// the ONE place either implementation is constructed. In debugBattery mode
/// the real path monitor is never built, so no Network-framework object can
/// exist there. Construction does nothing observable: nothing is monitored
/// until the owner calls `start`.
enum ConnectivityWiring {
    static func makeInterface(debugBattery: Bool) -> ConnectivityInterface {
        debugBattery ? ConnectivitySimulator() : PathConnectivityMonitor()
    }
}

/// The ONLY "connectivity" log category. Every entry point takes fixed words
/// (`ConnectivityPathStatus`) or nothing at all — no String parameter exists,
/// so no interface name, network name, address, URL or topic can reach a
/// line (`ConnectivityStructureTests` locks the signatures and the lines).
enum ConnectivityLog {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "connectivity")

    /// A fresh path monitor began observing (one per arm cycle).
    static func monitorStarted() {
        logger.notice("connectivity: path monitor started")
    }

    /// The path monitor was cancelled (disarm, quit).
    static func monitorStopped() {
        logger.notice("connectivity: path monitor stopped")
    }

    /// The path status CHANGED (repeats of the same status are not logged).
    static func pathChanged(_ status: ConnectivityPathStatus) {
        logger.notice("connectivity: path \(status.rawValue, privacy: .public)")
    }
}
