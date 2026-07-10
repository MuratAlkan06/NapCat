/// In-memory PowerInterface for debug-battery mode and tests (PLAN.md ADR §8).
///
/// ISOLATION GUARANTEE: this file deliberately has NO import statements at
/// all — only the implicitly available standard library — so it structurally
/// cannot launch external programs or touch privileged helpers. A lint-style
/// test (DebugPowerSimulatorTests.simulatorSourceIsStructurallyIsolated)
/// fails the build's test gate if any import statement or program-launching
/// API name ever appears here. Keep it that way.
@MainActor
final class DebugPowerSimulator: PowerInterface {
    /// One recorded charge-control write, in call order, for assertions.
    enum WriteCall: Equatable, Sendable {
        case disableCharging
        case enableCharging
    }

    // MARK: Simulated inputs (settable from tests / debug menu section)

    /// Simulated charge 0–100; nil simulates an unreadable battery.
    var batteryPercent: Int? {
        didSet { if batteryPercent != oldValue { notifyChange() } }
    }
    /// Simulated external power connection.
    var adapterConnected: Bool {
        didSet { if adapterConnected != oldValue { notifyChange() } }
    }
    /// Simulated battery presence (false = desktop Mac).
    let hasBattery: Bool
    /// Outcome returned by both writes; set to a failure case to simulate a
    /// write error. Failed writes are still recorded but change nothing.
    var writeResult: PrivilegedCommandResult = .success
    /// Simulated charge-control availability; tests set `.setupRequired` /
    /// `.probeFailed` to exercise those feature states. Defaults to ready —
    /// the simulator needs no privileged helper.
    var chargeControlReadiness: ChargeControlReadiness = .ready {
        didSet { if chargeControlReadiness != oldValue { notifyChange() } }
    }

    // MARK: Observable outputs

    /// True after a successful `disableCharging()` until a successful
    /// `enableCharging()` — the simulated "paused at limit" circuit state.
    private(set) var chargingInhibited = false

    /// Derived exactly like a real machine: charging only with the adapter
    /// connected, a battery present, not inhibited, and not already full.
    /// An unreadable percent reads as not charging — unknown is never
    /// guessed as an active state (matches the P2 observed-state rule).
    var isCharging: Bool {
        guard hasBattery, adapterConnected, !chargingInhibited,
              let percent = batteryPercent else { return false }
        return percent < 100
    }

    /// Every write call in order, for test assertions.
    private(set) var writeCalls: [WriteCall] = []

    /// Single observer per PowerInterface — fired after any simulated value
    /// change, exactly like the real interface pushes IOKit updates.
    var onPowerChange: (() -> Void)?

    init(
        batteryPercent: Int? = 80,
        adapterConnected: Bool = false,
        hasBattery: Bool = true
    ) {
        self.batteryPercent = batteryPercent
        self.adapterConnected = adapterConnected
        self.hasBattery = hasBattery
    }

    private func notifyChange() {
        onPowerChange?()
    }

    // MARK: PowerInterface availability

    /// Nothing to probe in simulation.
    func reprobeChargeControlIfNeeded() {}

    /// The simulator always knows its own inhibit state.
    func readChargingInhibited() -> Bool? { chargingInhibited }

    // MARK: PowerInterface writes

    @discardableResult
    func disableCharging() -> PrivilegedCommandResult {
        writeCalls.append(.disableCharging)
        if writeResult == .success, !chargingInhibited {
            chargingInhibited = true
            notifyChange()
        }
        return writeResult
    }

    @discardableResult
    func enableCharging() -> PrivilegedCommandResult {
        writeCalls.append(.enableCharging)
        if writeResult == .success, chargingInhibited {
            chargingInhibited = false
            notifyChange()
        }
        return writeResult
    }
}
