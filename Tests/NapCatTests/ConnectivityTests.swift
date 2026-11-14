// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Network
import Testing
@testable import NapCat

/// Thread-safe record of what a path observer delivered, and on which thread.
final class PathDeliveryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(status: ConnectivityPathStatus, onMain: Bool)] = []

    func record(_ status: ConnectivityPathStatus) {
        let onMain = Thread.isMainThread
        lock.lock()
        entries.append((status, onMain))
        lock.unlock()
    }

    var statuses: [ConnectivityPathStatus] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map(\.status)
    }

    var anyOnMain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.contains { $0.onMain }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}

/// Polls `condition` every 20 ms for up to `seconds`; true once it holds.
func eventually(within seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// Alert-channel healing (issue #23), slice 1: the connectivity interface,
/// its in-memory simulator, the real all-interface path monitor, and the
/// startup protocol swap. Structure (confinement, seam count, log hygiene)
/// is locked separately in `ConnectivityStructureTests`.
struct ConnectivityTests {
    // MARK: - Simulator

    @Test func theSimulatorDeliversTheCurrentStatusFirst() {
        let sim = ConnectivitySimulator(status: .unsatisfied)
        let log = PathDeliveryLog()
        #expect(!sim.isRunning)
        sim.start { log.record($0) }
        #expect(sim.isRunning)
        #expect(log.statuses == [.unsatisfied], "like the real monitor, the current path arrives first")
        #expect(sim.startCount == 1)
    }

    @Test func theSimulatorDeliversChangesOnlyWhileRunning() {
        let sim = ConnectivitySimulator()
        let log = PathDeliveryLog()
        sim.status = .unsatisfied                      // not running: nothing to deliver to
        sim.start { log.record($0) }
        sim.status = .unsatisfied                      // no change: no delivery
        sim.status = .satisfied
        sim.status = .unsatisfied
        #expect(log.statuses == [.unsatisfied, .satisfied, .unsatisfied])
        sim.stop()
        sim.status = .satisfied                        // stopped: never delivered
        sim.redeliver()
        #expect(log.statuses == [.unsatisfied, .satisfied, .unsatisfied])
    }

    @Test func theSimulatorRedeliversAnUnchangedStatus() {
        let sim = ConnectivitySimulator()
        let log = PathDeliveryLog()
        sim.start { log.record($0) }
        sim.redeliver()
        #expect(log.statuses == [.satisfied, .satisfied], "an interface change while satisfied repeats the status")
    }

    @Test func theSimulatorStartAndStopAreIdempotentAndRestartable() {
        let sim = ConnectivitySimulator()
        let first = PathDeliveryLog()
        let second = PathDeliveryLog()
        sim.start { first.record($0) }
        sim.start { second.record($0) }                // running: a no-op, the first handler stays
        #expect(sim.startCount == 1)
        #expect(second.count == 0)
        sim.stop()
        sim.stop()
        #expect(sim.stopCount == 1)
        #expect(!sim.isRunning)
        sim.start { second.record($0) }
        #expect(sim.startCount == 2)
        #expect(sim.isRunning)
        sim.status = .unsatisfied
        #expect(first.statuses == [.satisfied], "a stopped cycle's handler is never called again")
        #expect(second.statuses == [.satisfied, .unsatisfied])
    }

    // MARK: - Real all-interface path monitor

    /// Construction alone creates no monitor: zero footprint until armed.
    @Test func theRealMonitorIsIdleUntilStarted() {
        let monitor = PathConnectivityMonitor()
        #expect(!monitor.isRunning)
        #expect(monitor.monitorsCreated == 0)
        monitor.stop()                                  // stopping an idle monitor is a no-op
        #expect(!monitor.isRunning)
        #expect(monitor.monitorsCreated == 0)
    }

    /// A live run against the system path (read-only — nothing is sent):
    /// the first update arrives OFF the main queue, a running start is a
    /// no-op, stop cancels, and every arm cycle uses a FRESH monitor.
    @Test func theRealMonitorUsesAFreshMonitorPerArmCycleOffTheMainQueue() async {
        let monitor = PathConnectivityMonitor()
        let firstCycle = PathDeliveryLog()
        monitor.start { firstCycle.record($0) }
        #expect(monitor.isRunning)
        #expect(monitor.monitorsCreated == 1)
        #expect(await eventually { firstCycle.count >= 1 }, "the current path is delivered after start")
        #expect(!firstCycle.anyOnMain, "path updates are delivered on a private queue, never the main queue")

        monitor.start { _ in Issue.record("a start while running must be a no-op") }
        #expect(monitor.monitorsCreated == 1)

        monitor.stop()
        #expect(!monitor.isRunning)

        let secondCycle = PathDeliveryLog()
        monitor.start { secondCycle.record($0) }
        #expect(monitor.isRunning)
        #expect(monitor.monitorsCreated == 2, "a cancelled monitor is terminal — each arm cycle builds a fresh one")
        #expect(await eventually { secondCycle.count >= 1 })
        #expect(!secondCycle.anyOnMain)
        monitor.stop()
        #expect(!monitor.isRunning)
        #expect(monitor.monitorsCreated == 2)
    }

    /// Only `.unsatisfied` is outage evidence; `.requiresConnection` means a
    /// connection attempt may bring the path up, so it must never hold alerts.
    @Test func onlyAnUnsatisfiedPathReadsAsAnOutage() {
        #expect(PathConnectivityMonitor.status(for: .unsatisfied) == .unsatisfied)
        #expect(PathConnectivityMonitor.status(for: .satisfied) == .satisfied)
        #expect(PathConnectivityMonitor.status(for: .requiresConnection) == .satisfied)
    }

    @Test func theStatusWordsAreFixed() {
        #expect(ConnectivityPathStatus.satisfied.rawValue == "satisfied")
        #expect(ConnectivityPathStatus.unsatisfied.rawValue == "unsatisfied")
    }

    // MARK: - Startup protocol swap

    /// debugBattery ⇒ the simulator, never the real monitor (ADR §8 mirror);
    /// otherwise the real monitor. Neither is observing after construction.
    @Test func theStartupSwapNeverBuildsTheRealMonitorInDebugMode() {
        let simulated = ConnectivityWiring.makeInterface(debugBattery: true)
        #expect(simulated is ConnectivitySimulator)
        #expect(!(simulated is PathConnectivityMonitor))
        #expect(!simulated.isRunning)

        let real = ConnectivityWiring.makeInterface(debugBattery: false)
        #expect(real is PathConnectivityMonitor)
        #expect(!real.isRunning)
        #expect((real as? PathConnectivityMonitor)?.monitorsCreated == 0, "construction does not monitor")
    }
}
