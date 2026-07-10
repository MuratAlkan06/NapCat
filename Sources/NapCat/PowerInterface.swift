/// The single abstraction over ALL power reads and charge-control writes
/// (PLAN.md ADR §8). Everything above this protocol (ChargeLimiter, menu UI)
/// is implementation-blind: in debug-battery mode the app is handed a
/// DebugPowerSimulator, so simulated mode structurally cannot reach sudo or
/// the smc binary.
///
/// Implementations:
/// - `DebugPowerSimulator` (P3a): fully in-memory, records writes.
/// - Real IOKit + PrivilegedCommand implementation arrives in P3b
///   (IOPSCopyPowerSourcesInfo reads, smc writes via sudoers entries,
///   read-back verification per ADR §2).
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
