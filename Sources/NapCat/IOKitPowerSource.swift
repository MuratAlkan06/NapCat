import AppKit
import IOKit.ps
import os

/// Real PowerInterface (PLAN.md ADR §2/§5):
/// - Reads: IOPSCopyPowerSourcesInfo / IOPSCopyPowerSourcesList /
///   IOPSGetPowerSourceDescription, pushed via
///   IOPSNotificationCreateRunLoopSource on the main run loop (common modes,
///   so updates arrive while the menu is open).
/// - Writes: the exact PrivilegedCommand smc argv strings, chosen by the
///   runtime key-family probe, and VERIFIED by an unprivileged read-back —
///   a write that does not stick reports failure, never a false success.
///
/// NEVER constructed in debugBattery mode (ADR §8) — the simulator replaces
/// this class entirely, so simulated mode cannot reach smc or sudo.
@MainActor
final class IOKitPowerSource: PowerInterface {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "power")

    // MARK: Reads (published)

    private(set) var batteryPercent: Int?
    private(set) var isCharging = false
    private(set) var adapterConnected = false
    private(set) var hasBattery = false
    var onPowerChange: (() -> Void)?

    // MARK: Charge-control state

    private(set) var keyFamily: SMCKeyFamily?
    private(set) var chargeControlReadiness: ChargeControlReadiness

    private var runLoopSource: CFRunLoopSource?

    init() {
        (keyFamily, chargeControlReadiness) = Self.probeKeyFamily(
            helperInstalled: SMCKeyReader.helperInstalled(),
            readKey: SMCKeyReader.readKey
        )
        Self.logger.notice("charge-control probe: family=\(String(describing: self.keyFamily), privacy: .public) readiness=\(String(describing: self.chargeControlReadiness), privacy: .public)")
        refresh()
        registerForPowerNotifications()
    }

    // MARK: - Key-family probe (ADR §2)

    /// Pure probe-chain decision (fixture-tested):
    /// - helper absent → setupRequired (battery reads still work — IOKit)
    /// - `smc -k CHTE -r` returns data → CHTE family
    /// - output containing "no data" → CH0B/CH0C fallback
    /// - anything else → visible probe failure, feature never silently on.
    nonisolated static func probeKeyFamily(
        helperInstalled: Bool,
        readKey: (String) -> SMCKeyReader.ReadOutcome
    ) -> (SMCKeyFamily?, ChargeControlReadiness) {
        guard helperInstalled else { return (nil, .setupRequired) }
        switch readKey("CHTE") {
        case .value: return (.chte, .ready)
        case .noData: return (.ch0bc, .ready)
        case .failed(let message): return (nil, .probeFailed(message))
        }
    }

    /// Menu-open hook: once the user has run setup.sh, the next menu open
    /// picks the helper up without an app restart.
    func reprobeChargeControlIfNeeded() {
        guard chargeControlReadiness != .ready else { return }
        let (family, readiness) = Self.probeKeyFamily(
            helperInstalled: SMCKeyReader.helperInstalled(),
            readKey: SMCKeyReader.readKey
        )
        guard family != keyFamily || readiness != chargeControlReadiness else { return }
        keyFamily = family
        chargeControlReadiness = readiness
        Self.logger.notice("charge-control re-probe: family=\(String(describing: family), privacy: .public) readiness=\(String(describing: readiness), privacy: .public)")
        onPowerChange?()
    }

    // MARK: - IOKit reads

    struct PowerReading: Equatable, Sendable {
        var hasBattery: Bool
        var batteryPercent: Int?
        var isCharging: Bool
        var adapterConnected: Bool
    }

    /// Pure mapping from IOPS description dictionaries to one reading
    /// (fixture-tested). Only the internal battery is considered; absence of
    /// one → desktop Mac → charge-limit UI hidden (ADR §12).
    nonisolated static func reading(fromDescriptions descriptions: [[String: Any]]) -> PowerReading {
        for description in descriptions {
            guard (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            var percent: Int?
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let capacity = description[kIOPSMaxCapacityKey] as? Int,
               capacity > 0, current >= 0 {
                percent = min(100, Int((Double(current) / Double(capacity) * 100).rounded()))
            }
            return PowerReading(
                hasBattery: true,
                batteryPercent: percent,
                // Missing/unreadable flags are never guessed as an active
                // state (P2 observed-state rule).
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                adapterConnected: (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            )
        }
        return PowerReading(hasBattery: false, batteryPercent: nil, isCharging: false, adapterConnected: false)
    }

    /// Re-reads the power sources and publishes on change.
    func refresh() {
        guard let reading = Self.currentReading() else {
            // Transient IOKit failure: percent becomes unknown (hysteresis
            // fails open on nil), presence/adapter keep their last value so
            // the UI does not flicker between layouts.
            Self.logger.error("IOPSCopyPowerSourcesInfo failed — battery state unknown")
            apply(PowerReading(
                hasBattery: hasBattery,
                batteryPercent: nil,
                isCharging: false,
                adapterConnected: adapterConnected
            ))
            return
        }
        apply(reading)
    }

    private static func currentReading() -> PowerReading? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return reading(fromDescriptions: descriptions)
    }

    private func apply(_ new: PowerReading) {
        let old = PowerReading(
            hasBattery: hasBattery,
            batteryPercent: batteryPercent,
            isCharging: isCharging,
            adapterConnected: adapterConnected
        )
        guard new != old else { return }
        hasBattery = new.hasBattery
        batteryPercent = new.batteryPercent
        isCharging = new.isCharging
        adapterConnected = new.adapterConnected
        Self.logger.debug("power update: %=\(new.batteryPercent.map(String.init) ?? "nil", privacy: .public) charging=\(new.isCharging) adapter=\(new.adapterConnected)")
        onPowerChange?()
    }

    /// IOKit pushes power-source changes to the main run loop; common modes
    /// keep updates flowing while the menu is open (menu tracking mode).
    private func registerForPowerNotifications() {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let source = Unmanaged<IOKitPowerSource>.fromOpaque(context).takeUnretainedValue()
            // The source is registered on the main run loop only.
            MainActor.assumeIsolated { source.refresh() }
        }, context)?.takeRetainedValue() else {
            Self.logger.error("IOPSNotificationCreateRunLoopSource failed — falling back to menu-open refreshes only")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
    }

    // MARK: - Charge-control writes (ADR §2)

    /// Expected unprivileged read-back after a successful write — the write
    /// counts as failed unless every key reports exactly these bytes.
    nonisolated static func expectedReadback(family: SMCKeyFamily, disable: Bool) -> [(key: String, bytesHex: String)] {
        switch family {
        case .chte:
            return [("CHTE", disable ? "01000000" : "00000000")]
        case .ch0bc:
            let value = disable ? "02" : "00"
            return [("CH0B", value), ("CH0C", value)]
        }
    }

    /// The exact PrivilegedCommand cases for one charge-control write.
    nonisolated static func commands(family: SMCKeyFamily, disable: Bool) -> [PrivilegedCommand] {
        switch family {
        case .chte:
            return disable ? [.chargingDisableCHTE] : [.chargingEnableCHTE]
        case .ch0bc:
            return disable
                ? [.chargingDisableCH0B, .chargingDisableCH0C]
                : [.chargingEnableCH0B, .chargingEnableCH0C]
        }
    }

    @discardableResult
    func disableCharging() -> PrivilegedCommandResult { performChargeWrite(disable: true) }

    @discardableResult
    func enableCharging() -> PrivilegedCommandResult { performChargeWrite(disable: false) }

    private func performChargeWrite(disable: Bool) -> PrivilegedCommandResult {
        guard chargeControlReadiness == .ready, let keyFamily else {
            // Defensive: ChargeLimiter never attempts writes unless ready.
            return .sudoDenied
        }
        for command in Self.commands(family: keyFamily, disable: disable) {
            let result = command.run()
            guard result == .success else {
                Self.logger.error("charge write failed: \(command.argv.joined(separator: " "), privacy: .public) → \(String(describing: result), privacy: .public)")
                return result
            }
        }
        // Read-back verification: sudo exiting 0 is not proof the value
        // stuck (ADR §2).
        for (key, expected) in Self.expectedReadback(family: keyFamily, disable: disable) {
            let outcome = SMCKeyReader.readKey(key)
            guard case .value(let bytes) = outcome, bytes == expected else {
                let detail = "read-back mismatch for \(key): expected \(expected), got \(String(describing: outcome))"
                Self.logger.error("\(detail, privacy: .public)")
                return .commandFailed(exitStatus: 0, stderr: detail)
            }
        }
        Self.logger.notice("charging \(disable ? "disabled" : "enabled", privacy: .public) via \(String(describing: keyFamily), privacy: .public), read-back verified")
        return .success
    }

    /// Launch reconciliation: reads the active key unprivileged so a pause
    /// left behind by a crash can be adopted (and then released by the
    /// hysteresis table). nil when the helper/probe is unavailable.
    func readChargingInhibited() -> Bool? {
        guard chargeControlReadiness == .ready, let keyFamily else { return nil }
        let key = keyFamily == .chte ? "CHTE" : "CH0B"
        guard case .value(let bytes) = SMCKeyReader.readKey(key) else { return nil }
        return SMCKeyReader.indicatesInhibited(bytesHex: bytes)
    }
}
