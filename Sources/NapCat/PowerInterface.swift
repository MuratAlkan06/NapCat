/// The single abstraction over ALL power reads and charge-control writes
/// (PLAN.md ADR §8). Everything above this protocol (ChargeLimiter, menu UI)
/// is implementation-blind: in debug-battery mode the app is handed a
/// DebugPowerSimulator, so simulated mode structurally cannot reach sudo or
/// the smc binary.
///
/// Implementations:
/// - `DebugPowerSimulator` (P3a): fully in-memory, records writes.
/// - `IOKitPowerSource` (P3b): IOPSCopyPowerSourcesInfo reads pushed via
///   IOPSNotificationCreateRunLoopSource; smc writes through the exact
///   PrivilegedCommand argv strings, verified by unprivileged read-back
///   (ADR §2).

/// Whether the charge-control write path can be used at all (ADR §2 probe
/// chain). Reads (battery %, charging state) are IOKit-only and work in
/// every case.
enum ChargeControlReadiness: Equatable, Sendable {
    /// Key family probed successfully — writes may be attempted.
    case ready
    /// The privileged helper is not installed — the user has not run
    /// scripts/setup.sh yet. The app must degrade gracefully forever.
    case setupRequired
    /// The helper exists but the key-family probe failed (message shown in
    /// the menu error state).
    case probeFailed(String)
}

@MainActor
protocol PowerInterface: AnyObject {
    // MARK: Reads
    /// Current battery charge 0–100, or nil when unreadable / no battery.
    var batteryPercent: Int? { get }
    /// True while the battery is actually accepting charge.
    var isCharging: Bool { get }
    /// True while external power (AC adapter) is connected.
    var adapterConnected: Bool { get }
    /// False on desktop Macs — charge-limit UI is hidden entirely (ADR §12).
    var hasBattery: Bool { get }

    // MARK: Push updates (P3b)
    /// Single observer, invoked on the main actor after any read value
    /// changed. ChargeLimiter owns this hook and re-publishes to the UI.
    var onPowerChange: (() -> Void)? { get set }

    // MARK: Charge-control availability (P3b)
    /// Result of the ADR §2 probe chain (or `.ready` for the simulator).
    var chargeControlReadiness: ChargeControlReadiness { get }
    /// Re-run the probe when it previously failed (e.g. the user just ran
    /// setup.sh) — called on menu open so no app restart is needed.
    /// No-op once ready and in the simulator.
    func reprobeChargeControlIfNeeded()
    /// Best-effort unprivileged read of whether charging is currently
    /// inhibited (launch reconciliation after a crash-while-paused).
    /// nil = unknown / not readable.
    func readChargingInhibited() -> Bool?

    // MARK: Charge-control writes
    /// Inhibit charging (pause at limit). Returns the privileged-command
    /// outcome; the caller must treat anything but `.success` as a visible
    /// error state, never a false "paused" (ADR §2).
    @discardableResult
    func disableCharging() -> PrivilegedCommandResult
    /// Allow charging again. Same result contract as `disableCharging()`.
    @discardableResult
    func enableCharging() -> PrivilegedCommandResult
}
