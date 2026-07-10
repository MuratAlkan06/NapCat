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

    // MARK: Simulated inputs (settable from tests / hidden debug menu)

    /// Simulated charge 0–100; nil simulates an unreadable battery.
    var batteryPercent: Int?
    /// Simulated external power connection.
    var adapterConnected: Bool
    /// Simulated battery presence (false = desktop Mac).
    let hasBattery: Bool
    /// Outcome returned by both writes; set to a failure case to simulate a
    /// write error. Failed writes are still recorded but change nothing.
    var writeResult: PrivilegedCommandResult = .success

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

    init(
        batteryPercent: Int? = 80,
        adapterConnected: Bool = false,
        hasBattery: Bool = true
    ) {
        self.batteryPercent = batteryPercent
        self.adapterConnected = adapterConnected
        self.hasBattery = hasBattery
    }

    // MARK: PowerInterface writes

    @discardableResult
    func disableCharging() -> PrivilegedCommandResult {
        writeCalls.append(.disableCharging)
        if writeResult == .success { chargingInhibited = true }
        return writeResult
    }

    @discardableResult
    func enableCharging() -> PrivilegedCommandResult {
        writeCalls.append(.enableCharging)
        if writeResult == .success { chargingInhibited = false }
        return writeResult
    }
}
