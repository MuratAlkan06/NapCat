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
                          "sudo", "smc", "/usr/", "exec",
                          // #58: the probe chain and its real host.
                          "probekeyfamily", "iokitpowersource"] {
            #expect(!lowered.contains(forbidden),
                    "forbidden token '\(forbidden)' in DebugPowerSimulator.swift")
        }
    }

    // MARK: Probe / write path isolation (#58)

    /// The ADR §2 probe chain (`probeKeyFamily`, incl. the #58
    /// controlUnavailable outcome), the helper reads (`SMCKeyReader.`) and
    /// the privileged charge-write cases are reachable ONLY through
    /// IOKitPowerSource — and IOKitPowerSource is built exactly once, in
    /// NapCatApp's NON-debug branch, while the debug branch builds the
    /// simulator. So debugBattery mode can never reach a probe or a write;
    /// the simulator expresses every readiness (incl. .controlUnavailable) as
    /// a plain settable value. Scans comment-stripped code.
    static func probeAndWritePathFailures(_ sources: [(name: String, text: String)]) -> [String] {
        var failures: [String] = []
        func files(containing token: String) -> Set<String> {
            Set(sources.filter { $0.text.contains(token) }.map(\.name))
        }
        let confined: [(token: String, allowed: Set<String>)] = [
            ("probeKeyFamily(", ["IOKitPowerSource.swift"]),
            ("SMCKeyReader.", ["IOKitPowerSource.swift", "SMCKeyReader.swift"]),
            ("chargingDisable", ["IOKitPowerSource.swift", "PrivilegedCommand.swift"]),
            ("chargingEnable", ["IOKitPowerSource.swift", "PrivilegedCommand.swift"]),
        ]
        for (token, allowed) in confined where !files(containing: token).isSubset(of: allowed) {
            failures.append("'\(token)' appears in \(files(containing: token).sorted()) — allowed only in \(allowed.sorted())")
        }
        if !files(containing: "probeKeyFamily(").contains("IOKitPowerSource.swift") {
            failures.append("vacuity: IOKitPowerSource no longer runs the probe chain")
        }
        let constructions = sources.flatMap { source in
            Array(repeating: source.name,
                  count: source.text.components(separatedBy: "IOKitPowerSource(").count - 1)
        }
        if constructions != ["NapCatApp.swift"] {
            failures.append("IOKitPowerSource( is constructed at \(constructions) — expected once, in NapCatApp.swift")
        }
        let app = sources.first { $0.name == "NapCatApp.swift" }?.text ?? ""
        guard let debugOpen = app.range(of: "if isDebugBattery {"),
              let elseOpen = app.range(of: "} else {", range: debugOpen.upperBound..<app.endIndex),
              let elseClose = app.range(of: "\n        }", range: elseOpen.upperBound..<app.endIndex)
        else {
            failures.append("NapCatApp's debugBattery power swap (if isDebugBattery { … } else { … }) not found")
            return failures
        }
        let debugBranch = app[debugOpen.upperBound..<elseOpen.lowerBound]
        let realBranch = app[elseOpen.upperBound..<elseClose.lowerBound]
        if !debugBranch.contains("DebugPowerSimulator(") || debugBranch.contains("IOKitPowerSource(") {
            failures.append("the debugBattery branch must build the simulator and never IOKitPowerSource")
        }
        if !realBranch.contains("IOKitPowerSource(") || realBranch.contains("DebugPowerSimulator(") {
            failures.append("only the non-debug branch may build IOKitPowerSource")
        }
        return failures
    }

    @Test func theSimulatorPathNeverReachesTheProbeOrWritePaths() throws {
        let sources = try LidGuardStructureTests.swiftSources()
        try #require(sources.contains { $0.name == "DebugPowerSimulator.swift" }, "vacuity: path drift")
        let failures = Self.probeAndWritePathFailures(sources)
        #expect(failures.isEmpty, "\(failures)")

        func mutate(_ name: String, _ transform: (String) -> String) -> [(name: String, text: String)] {
            sources.map { $0.name == name ? ($0.name, transform($0.text)) : $0 }
        }
        let canaries: [(String, [(name: String, text: String)])] = [
            ("simulator runs the probe", mutate("DebugPowerSimulator.swift") {
                $0 + "\nlet p = Prober.probeKeyFamily(helperInstalled: true, readKey: { _ in .noData })" }),
            ("simulator reads a key", mutate("DebugPowerSimulator.swift") {
                $0 + "\nlet r = SMCKeyReader.readKey(\"CHTE\")" }),
            ("simulator writes", mutate("DebugPowerSimulator.swift") {
                $0 + "\nlet w = PrivilegedCommand.chargingDisableCHTE.run()" }),
            ("menu re-probes on its own", mutate("MenuContentView.swift") {
                $0 + "\nlet m = SMCKeyReader.helperInstalled()" }),
            ("debug branch builds the real source", mutate("NapCatApp.swift") {
                $0.replacingOccurrences(of: "power = debugSimulator", with: "power = IOKitPowerSource()") }),
            ("second real source", mutate("MenuContentView.swift") {
                $0 + "\nlet s = IOKitPowerSource()" }),
            ("swap removed", mutate("NapCatApp.swift") {
                $0.replacingOccurrences(of: "if isDebugBattery {", with: "if true {") }),
        ]
        for (name, mutant) in canaries {
            #expect(!Self.probeAndWritePathFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }
}
