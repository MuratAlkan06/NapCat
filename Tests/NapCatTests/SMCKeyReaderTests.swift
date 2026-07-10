// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Fixtures for the unprivileged smc read parsing and the ADR §2 probe
/// chain. The "value" fixtures are the REAL outputs recorded during the S2
/// probe on the dev M4 Pro (PLAN.md Hardware spikes).
struct SMCKeyReaderTests {
    // MARK: - Output classification (pure)

    @Test func chtePresentWithDataIsValue() {
        // Real S2 output: CHTE exists, charging enabled (all-zero).
        let output = "  CHTE  [ui32]  0 (bytes 00 00 00 00)\n"
        #expect(SMCKeyReader.classify(exitStatus: 0, output: output)
            == .value(bytesHex: "00000000"))
    }

    @Test func chteDisabledValueParses() {
        let output = "  CHTE  [ui32]  1 (bytes 01 00 00 00)\n"
        #expect(SMCKeyReader.classify(exitStatus: 0, output: output)
            == .value(bytesHex: "01000000"))
    }

    @Test func hexTypeKeysParseWithoutDecodedValue() {
        // Real S2 outputs: hex_ typed keys print bytes only.
        #expect(SMCKeyReader.classify(exitStatus: 0, output: "  CH0B  [hex_]  (bytes 00)\n")
            == .value(bytesHex: "00"))
        #expect(SMCKeyReader.classify(exitStatus: 0, output: "  CH0C  [hex_]  (bytes 02)\n")
            == .value(bytesHex: "02"))
    }

    @Test func noDataTriggersKeyFamilyFallback() {
        // Vendored smc printVal with dataSize == 0 (key absent on machine).
        let output = "  CHTE  [    ]  no data\n"
        #expect(SMCKeyReader.classify(exitStatus: 0, output: output) == .noData)
    }

    @Test func errorOutputIsFailure() {
        let outcome = SMCKeyReader.classify(exitStatus: 1, output: "Error: SMCOpen() = e00002c1\n")
        guard case .failed(let message) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(message.contains("exited 1"))
        #expect(message.contains("SMCOpen"))
    }

    @Test func emptyOutputIsFailureNotValue() {
        let outcome = SMCKeyReader.classify(exitStatus: 0, output: "")
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
    }

    @Test func nonZeroExitWithValueLookingOutputIsFailure() {
        let outcome = SMCKeyReader.classify(exitStatus: 2, output: "  CHTE  [ui32]  0 (bytes 00 00 00 00)\n")
        guard case .failed = outcome else {
            Issue.record("expected .failed for non-zero exit, got \(outcome)")
            return
        }
    }

    // MARK: - Byte extraction (pure)

    @Test func parseBytesHexNormalizesAndValidates() {
        #expect(SMCKeyReader.parseBytesHex("  CHTE  [ui32]  0 (bytes 0A 1b 00 FF)\n") == "0a1b00ff")
        #expect(SMCKeyReader.parseBytesHex("no parens here") == nil)
        #expect(SMCKeyReader.parseBytesHex("(bytes )") == nil, "empty byte list is malformed")
        #expect(SMCKeyReader.parseBytesHex("(bytes zz)") == nil, "non-hex bytes are malformed")
        #expect(SMCKeyReader.parseBytesHex("(bytes 123)") == nil, "bytes come in two-digit pairs")
    }

    @Test func indicatesInhibitedMeansAnyNonZeroByte() {
        #expect(!SMCKeyReader.indicatesInhibited(bytesHex: "00000000"))
        #expect(!SMCKeyReader.indicatesInhibited(bytesHex: "00"))
        #expect(SMCKeyReader.indicatesInhibited(bytesHex: "01000000"))
        #expect(SMCKeyReader.indicatesInhibited(bytesHex: "02"))
    }

    // MARK: - Probe chain (ADR §2, pure decision)

    @Test func helperMissingIsSetupRequiredWithoutRunningAnything() {
        var probeRan = false
        let (family, readiness) = IOKitPowerSource.probeKeyFamily(
            helperInstalled: false,
            readKey: { _ in probeRan = true; return .noData }
        )
        #expect(family == nil)
        #expect(readiness == .setupRequired)
        #expect(!probeRan, "no helper → nothing must be executed")
    }

    @Test func chteWithDataSelectsChteFamily() {
        let (family, readiness) = IOKitPowerSource.probeKeyFamily(
            helperInstalled: true,
            readKey: { key in
                #expect(key == "CHTE", "probe starts with CHTE (ADR §2)")
                return .value(bytesHex: "00000000")
            }
        )
        #expect(family == .chte)
        #expect(readiness == .ready)
    }

    @Test func noDataFallsBackToCh0bc() {
        let (family, readiness) = IOKitPowerSource.probeKeyFamily(
            helperInstalled: true,
            readKey: { _ in .noData }
        )
        #expect(family == .ch0bc)
        #expect(readiness == .ready)
    }

    @Test func probeReadFailureIsVisibleNotSilent() {
        let (family, readiness) = IOKitPowerSource.probeKeyFamily(
            helperInstalled: true,
            readKey: { _ in .failed("smc read exited 1: Error: no SMC found") }
        )
        #expect(family == nil)
        #expect(readiness == .probeFailed("smc read exited 1: Error: no SMC found"))
    }

    // MARK: - Write plumbing stays locked to PrivilegedCommand

    @Test func writeCommandsAndReadbacksMatchPerFamily() {
        #expect(IOKitPowerSource.commands(family: .chte, disable: true) == [.chargingDisableCHTE])
        #expect(IOKitPowerSource.commands(family: .chte, disable: false) == [.chargingEnableCHTE])
        #expect(IOKitPowerSource.commands(family: .ch0bc, disable: true)
            == [.chargingDisableCH0B, .chargingDisableCH0C])
        #expect(IOKitPowerSource.commands(family: .ch0bc, disable: false)
            == [.chargingEnableCH0B, .chargingEnableCH0C])

        #expect(IOKitPowerSource.expectedReadback(family: .chte, disable: true)
            .map { [$0.key, $0.bytesHex] } == [["CHTE", "01000000"]])
        #expect(IOKitPowerSource.expectedReadback(family: .chte, disable: false)
            .map { [$0.key, $0.bytesHex] } == [["CHTE", "00000000"]])
        #expect(IOKitPowerSource.expectedReadback(family: .ch0bc, disable: true)
            .map { [$0.key, $0.bytesHex] } == [["CH0B", "02"], ["CH0C", "02"]])
        #expect(IOKitPowerSource.expectedReadback(family: .ch0bc, disable: false)
            .map { [$0.key, $0.bytesHex] } == [["CH0B", "00"], ["CH0C", "00"]])
    }

    // MARK: - IOKit description parsing (pure fixtures; literal key strings
    // double-check the kIOPS constants)

    @Test func internalBatteryChargingOnAC() {
        let reading = IOKitPowerSource.reading(fromDescriptions: [[
            "Type": "InternalBattery",
            "Current Capacity": 82,
            "Max Capacity": 100,
            "Is Charging": true,
            "Power Source State": "AC Power",
        ]])
        #expect(reading == IOKitPowerSource.PowerReading(
            hasBattery: true, batteryPercent: 82, isCharging: true, adapterConnected: true))
    }

    @Test func onBatteryNotCharging() {
        let reading = IOKitPowerSource.reading(fromDescriptions: [[
            "Type": "InternalBattery",
            "Current Capacity": 55,
            "Max Capacity": 100,
            "Is Charging": false,
            "Power Source State": "Battery Power",
        ]])
        #expect(reading == IOKitPowerSource.PowerReading(
            hasBattery: true, batteryPercent: 55, isCharging: false, adapterConnected: false))
    }

    @Test func capacityIsScaledWhenMaxIsNot100() {
        let reading = IOKitPowerSource.reading(fromDescriptions: [[
            "Type": "InternalBattery",
            "Current Capacity": 50,
            "Max Capacity": 200,
            "Is Charging": false,
            "Power Source State": "Battery Power",
        ]])
        #expect(reading.batteryPercent == 25)
    }

    @Test func missingKeysAreNeverGuessedAsActive() {
        let reading = IOKitPowerSource.reading(fromDescriptions: [[
            "Type": "InternalBattery",
        ]])
        #expect(reading.hasBattery)
        #expect(reading.batteryPercent == nil)
        #expect(!reading.isCharging)
        #expect(!reading.adapterConnected)
    }

    @Test func noInternalBatteryMeansDesktopMac() {
        #expect(IOKitPowerSource.reading(fromDescriptions: []) == IOKitPowerSource.PowerReading(
            hasBattery: false, batteryPercent: nil, isCharging: false, adapterConnected: false))
        // A UPS is not an internal battery.
        let ups = IOKitPowerSource.reading(fromDescriptions: [[
            "Type": "UPS",
            "Current Capacity": 90,
            "Max Capacity": 100,
        ]])
        #expect(!ups.hasBattery)
    }
}
