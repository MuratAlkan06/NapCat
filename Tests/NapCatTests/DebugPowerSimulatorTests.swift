// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

@MainActor
struct DebugPowerSimulatorTests {
    // MARK: Full pause/resume cycle against the hysteresis engine

    /// PLAN.md P3a verification: ramp 88→92→84 with limit 90 — charging must
    /// be disabled exactly when the simulated percent hits 90 and re-enabled
    /// exactly at 85 (limit−5), with no other writes.
    @Test func rampCycleDisablesAt90EnablesAt85() {
        let sim = DebugPowerSimulator(batteryPercent: 88, adapterConnected: true)
        let limit = 90
        var state = ChargingControlState.normal
        var writesWithPercent: [(DebugPowerSimulator.WriteCall, Int)] = []

        let ramp = Array(88...92) + Array((84...91).reversed())
        for percent in ramp {
            sim.batteryPercent = percent
            let command = HysteresisEngine.decide(
                percent: sim.batteryPercent,
                adapterConnected: sim.adapterConnected,
                limit: limit,
                enabled: true,
                currentState: state
            )
            switch command {
            case .none:
                break
            case .disableCharging:
                #expect(sim.disableCharging() == .success)
                writesWithPercent.append((.disableCharging, percent))
            case .enableCharging:
                #expect(sim.enableCharging() == .success)
                writesWithPercent.append((.enableCharging, percent))
            }
            state = HysteresisEngine.nextState(after: command, from: state)
        }

        #expect(sim.writeCalls == [.disableCharging, .enableCharging])
        #expect(writesWithPercent.map(\.0) == [.disableCharging, .enableCharging])
        #expect(writesWithPercent.map(\.1) == [90, 85])
        #expect(state == .normal)
        #expect(sim.isCharging, "after resume at 85 on AC the simulator charges again")
    }

    // MARK: Simulated read semantics

    @Test func chargesOnlyWithAdapterBatteryAndHeadroom() {
        let sim = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        #expect(sim.isCharging)

        sim.adapterConnected = false
        #expect(!sim.isCharging, "no adapter — nothing charges")

        sim.adapterConnected = true
        sim.batteryPercent = 100
        #expect(!sim.isCharging, "full battery does not charge")

        sim.batteryPercent = nil
        #expect(!sim.isCharging, "unknown percent reads as not charging")
    }

    @Test func desktopMacNeverCharges() {
        let sim = DebugPowerSimulator(batteryPercent: nil, adapterConnected: true, hasBattery: false)
        #expect(!sim.hasBattery)
        #expect(!sim.isCharging)
    }

    // MARK: Write recording and effects

    @Test func successfulWritesToggleInhibitionAndAreRecordedInOrder() {
        let sim = DebugPowerSimulator(batteryPercent: 90, adapterConnected: true)
        #expect(sim.isCharging)

        #expect(sim.disableCharging() == .success)
        #expect(sim.chargingInhibited)
        #expect(!sim.isCharging, "inhibited — paused at limit")

        #expect(sim.enableCharging() == .success)
        #expect(!sim.chargingInhibited)
        #expect(sim.isCharging)

        #expect(sim.writeCalls == [.disableCharging, .enableCharging])
    }

    @Test func failedWriteIsRecordedButChangesNothing() {
        let sim = DebugPowerSimulator(batteryPercent: 90, adapterConnected: true)
        sim.writeResult = .commandFailed(exitStatus: 1, stderr: "simulated failure")

        let result = sim.disableCharging()
        #expect(result == .commandFailed(exitStatus: 1, stderr: "simulated failure"))
        #expect(!sim.chargingInhibited, "failed write must not fake a pause (ADR §2)")
        #expect(sim.isCharging)
        #expect(sim.writeCalls == [.disableCharging], "the attempt is still recorded")
    }

    // MARK: Structural isolation (PLAN.md ADR §8)

    /// Compile-level guarantee, lint-style: the simulator source file must
    /// contain no import statement at all and no token that could reach a
    /// subprocess or privileged helper. Combined with Swift's explicit-import
    /// rule (no Foundation import → no Foundation.Process symbol available),
    /// this makes "simulated mode can never invoke sudo/smc" structural.
    @Test func simulatorSourceIsStructurallyIsolated() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)  // Tests/NapCatTests/<this file>
            .deletingLastPathComponent()                 // Tests/NapCatTests
            .deletingLastPathComponent()                 // Tests
            .deletingLastPathComponent()                 // repo root
            .appendingPathComponent("Sources/NapCat/DebugPowerSimulator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        // Guard against path drift making the test vacuous.
        try #require(source.contains("final class DebugPowerSimulator"))

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            #expect(!trimmed.hasPrefix("import"),
                    "DebugPowerSimulator.swift must have zero imports, found: \(trimmed)")
        }

        let lowered = source.lowercased()
        for forbidden in ["process", "nstask", "posix_spawn", "system(", "popen",
                          "sudo", "smc", "/usr/", "exec"] {
            #expect(!lowered.contains(forbidden),
                    "forbidden token '\(forbidden)' in DebugPowerSimulator.swift")
        }
    }
}
