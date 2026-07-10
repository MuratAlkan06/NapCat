// AppKit, not Foundation (CLT cross-import overlay — PLAN.md decision log).
import AppKit
import Testing
@testable import NapCat

/// ChargeLimiter behavior against the full-interface simulator: state only
/// advances after successful writes, failures surface visibly (never a false
/// "paused"), sleep/wake policy, the 60s re-assert, and feature-state
/// mapping. No test here can reach sudo or smc — the power interface is
/// always the simulator or an in-memory stub (ADR §8).
@MainActor
struct ChargeLimiterTests {
    /// Fresh isolated defaults per test; the suite file is removed again.
    private func withLimiter(
        sim: DebugPowerSimulator,
        appleSilicon: Bool = true,
        enabled: Bool = true,
        limit: Int = 90,
        start: Bool = true,
        _ body: (ChargeLimiter) -> Void
    ) {
        let suite = "com.muratalkan.napcat.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(enabled, forKey: DefaultsKey.limitEnabled)
        defaults.set(limit, forKey: DefaultsKey.limit)
        let limiter = ChargeLimiter(power: sim, isAppleSilicon: appleSilicon, defaults: defaults)
        if start { limiter.start() }
        body(limiter)
    }

    // MARK: - Ramp cycle through power-change pushes

    @Test func rampPausesAtLimitAndResumesAtBandExit() {
        let sim = DebugPowerSimulator(batteryPercent: 88, adapterConnected: true)
        withLimiter(sim: sim) { limiter in
            #expect(limiter.featureState == .active)
            sim.batteryPercent = 89
            #expect(sim.writeCalls.isEmpty, "below limit — no write")

            sim.batteryPercent = 90
            #expect(sim.writeCalls == [.disableCharging], "pause exactly at limit")
            #expect(sim.chargingInhibited)
            #expect(limiter.controlState == .paused)
            #expect(limiter.featureState == .paused)

            sim.batteryPercent = 89
            sim.batteryPercent = 86
            #expect(sim.writeCalls == [.disableCharging], "inside band — hold pause")

            sim.batteryPercent = 85
            #expect(sim.writeCalls == [.disableCharging, .enableCharging],
                    "percent <= limit-5 resumes")
            #expect(limiter.controlState == .normal)
            #expect(limiter.featureState == .active)
            #expect(sim.isCharging)
        }
    }

    @Test func pausedWithUnknownPercentFailsOpen() {
        let sim = DebugPowerSimulator(batteryPercent: 90, adapterConnected: true)
        withLimiter(sim: sim) { limiter in
            #expect(limiter.controlState == .paused)
            sim.batteryPercent = nil
            #expect(sim.writeCalls.last == .enableCharging,
                    "unreadable percent must never hold a blind pause (row P10)")
            #expect(limiter.controlState == .normal)
        }
    }

    @Test func unplugWhilePausedReleases() {
        let sim = DebugPowerSimulator(batteryPercent: 90, adapterConnected: true)
        withLimiter(sim: sim) { limiter in
            #expect(limiter.controlState == .paused)
            sim.adapterConnected = false
            #expect(sim.writeCalls == [.disableCharging, .enableCharging],
                    "never leave charging inhibited on battery (row P8)")
            #expect(limiter.controlState == .normal)
        }
    }

    @Test func toggleOffWhilePausedReleases() {
        let sim = DebugPowerSimulator(batteryPercent: 90, adapterConnected: true)
        withLimiter(sim: sim) { limiter in
            #expect(limiter.controlState == .paused)
            limiter.setEnabled(false)
            #expect(sim.writeCalls == [.disableCharging, .enableCharging], "row P6")
            #expect(limiter.controlState == .normal)
            #expect(limiter.featureState == .off)
        }
    }

    // MARK: - Write failures are visible, never a false "paused"

    @Test func failedWriteKeepsStateAndShowsError() {
        let sim = DebugPowerSimulator(batteryPercent: 88, adapterConnected: true)
        withLimiter(sim: sim) { limiter in
            sim.writeResult = .commandFailed(exitStatus: 1, stderr: "write went sideways")
            sim.batteryPercent = 92
            #expect(sim.writeCalls == [.disableCharging], "the attempt was made")
            #expect(limiter.controlState == .normal,
                    "state advances only after a SUCCESSFUL write")
            #expect(!sim.chargingInhibited)
            guard case .error(let message) = limiter.featureState else {
                Issue.record("expected .error, got \(limiter.featureState)")
                return
            }
            #expect(message.contains("write went sideways"))

            // Recovery: the write starts succeeding (e.g. transient failure).
            sim.writeResult = .success
            limiter.evaluate(reason: "test retry")
            #expect(limiter.controlState == .paused)
            #expect(limiter.featureState == .paused)
        }
    }

    @Test func sudoDeniedRendersSetupRequired() {
        let sim = DebugPowerSimulator(batteryPercent: 95, adapterConnected: true)
        withLimiter(sim: sim, start: false) { limiter in
            sim.writeResult = .sudoDenied
            limiter.start()
            #expect(limiter.controlState == .normal)
            #expect(limiter.featureState == .setupRequired)
        }
    }

    // MARK: - Availability gating (engine inert unless operable)

    @Test func setupRequiredReadinessKeepsEngineInert() {
        let sim = DebugPowerSimulator(batteryPercent: 95, adapterConnected: true)
        sim.chargeControlReadiness = .setupRequired
        withLimiter(sim: sim) { limiter in
            #expect(sim.writeCalls.isEmpty, "no writes may even be attempted")
            #expect(limiter.featureState == .setupRequired)
        }
    }

    @Test func probeFailureSurfacesAsErrorEvenWhenOff() {
        let sim = DebugPowerSimulator(batteryPercent: 95, adapterConnected: true)
        sim.chargeControlReadiness = .probeFailed("smc read exited 1: no SMC found")
        withLimiter(sim: sim, enabled: false) { limiter in
            #expect(sim.writeCalls.isEmpty)
            guard case .error(let message) = limiter.featureState else {
                Issue.record("expected .error, got \(limiter.featureState)")
                return
            }
            #expect(message.contains("probe failed"))
        }
    }

    @Test func intelShowsNotSupportedAndNeverWrites() {
        let sim = DebugPowerSimulator(batteryPercent: 95, adapterConnected: true)
        withLimiter(sim: sim, appleSilicon: false) { limiter in
            #expect(sim.writeCalls.isEmpty)
            #expect(limiter.featureState == .notSupported)
            #expect(!limiter.reassertTimerActive)
        }
    }

    @Test func noBatteryHidesFeatureAndNeverWrites() {
        let sim = DebugPowerSimulator(batteryPercent: nil, adapterConnected: true, hasBattery: false)
        withLimiter(sim: sim) { limiter in
            #expect(sim.writeCalls.isEmpty)
            #expect(limiter.featureState == .hidden)
        }
    }

    @Test func disabledFeatureIsOffAndInert() {
        let sim = DebugPowerSimulator(batteryPercent: 95, adapterConnected: true)
        withLimiter(sim: sim, enabled: false) { limiter in
            #expect(sim.writeCalls.isEmpty, "row N6")
            #expect(limiter.featureState == .off)
        }
    }

    // MARK: - Sleep / wake policy (injectable handlers)

    @Test func preSleepPausesWhenInsideBand() {
        let sim = DebugPowerSimulator(batteryPercent: 88, adapterConnected: true)
        withLimiter(sim: sim) { limiter in
            #expect(sim.writeCalls.isEmpty, "88 < 90: nothing before sleep is announced")
            limiter.handleWillSleep()
            #expect(sim.writeCalls == [.disableCharging],
                    "% >= limit-5 pauses before sleep")
            #expect(limiter.controlState == .paused)

            limiter.handleDidWake()
            #expect(sim.writeCalls == [.disableCharging],
                    "still inside band on wake — pause holds (row P3)")

            sim.batteryPercent = 84
            #expect(sim.writeCalls == [.disableCharging, .enableCharging],
                    "band exit after wake releases")
        }
    }

    @Test func preSleepIgnoresAdapterState() {
        // Plugged in while the lid is closed: the app cannot react while
        // asleep, so the pre-sleep pause happens even on battery.
        let sim = DebugPowerSimulator(batteryPercent: 89, adapterConnected: false)
        withLimiter(sim: sim) { limiter in
            limiter.handleWillSleep()
            #expect(sim.writeCalls == [.disableCharging])
            #expect(limiter.controlState == .paused)

            // Wake still on battery → row P9 releases the pause.
            limiter.handleDidWake()
            #expect(sim.writeCalls == [.disableCharging, .enableCharging])
            #expect(limiter.controlState == .normal)
        }
    }

    @Test func preSleepNoOpsBelowBandWithUncappedLimitOrDisabled() {
        let below = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        withLimiter(sim: below) { limiter in
            limiter.handleWillSleep()
            #expect(below.writeCalls.isEmpty, "80 < 85: cannot reach the limit while asleep")
        }

        let uncapped = DebugPowerSimulator(batteryPercent: 99, adapterConnected: true)
        withLimiter(sim: uncapped, limit: 100) { limiter in
            limiter.handleWillSleep()
            #expect(uncapped.writeCalls.isEmpty, "limit 100 = uncapped, never pause")
        }

        let disabled = DebugPowerSimulator(batteryPercent: 95, adapterConnected: true)
        withLimiter(sim: disabled, enabled: false) { limiter in
            limiter.handleWillSleep()
            #expect(disabled.writeCalls.isEmpty)
        }
    }

    // MARK: - 60s re-assert timer

    @Test func reassertTimerRunsOnlyWhileEnabledOnAC() {
        let sim = DebugPowerSimulator(batteryPercent: 50, adapterConnected: true)
        withLimiter(sim: sim) { limiter in
            #expect(limiter.reassertTimerActive, "enabled on AC → timer on")
            sim.adapterConnected = false
            #expect(!limiter.reassertTimerActive, "unplugged → timer off")
            sim.adapterConnected = true
            #expect(limiter.reassertTimerActive)
            limiter.setEnabled(false)
            #expect(!limiter.reassertTimerActive, "feature off → timer off")
        }
    }

    @Test func reassertTickRewritesTheDisableWhilePaused() {
        let sim = DebugPowerSimulator(batteryPercent: 90, adapterConnected: true)
        withLimiter(sim: sim) { limiter in
            #expect(sim.writeCalls == [.disableCharging])
            limiter.reassertTick()
            #expect(sim.writeCalls == [.disableCharging, .disableCharging],
                    "field reports: charging re-enables itself — re-assert")
            #expect(limiter.controlState == .paused)
            #expect(limiter.featureState == .paused)
        }
    }

    // MARK: - IsCharging-flip verification (≤60s) with an in-memory stub
    // whose write "succeeds" without actually stopping the charge.

    @MainActor
    final class StubPower: PowerInterface {
        var batteryPercent: Int? = 90
        var isCharging = true
        var adapterConnected = true
        var hasBattery = true
        var onPowerChange: (() -> Void)?
        var chargeControlReadiness: ChargeControlReadiness = .ready
        var inhibitedReading: Bool? = false
        private(set) var disableCount = 0
        private(set) var enableCount = 0
        func reprobeChargeControlIfNeeded() {}
        func readChargingInhibited() -> Bool? { inhibitedReading }
        func disableCharging() -> PrivilegedCommandResult { disableCount += 1; return .success }
        func enableCharging() -> PrivilegedCommandResult { enableCount += 1; return .success }
    }

    @Test func chargingThatNeverStopsBecomesVisibleErrorAndRecovers() {
        let suite = "com.muratalkan.napcat.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: DefaultsKey.limitEnabled)
        defaults.set(90, forKey: DefaultsKey.limit)

        let stub = StubPower()
        let limiter = ChargeLimiter(power: stub, isAppleSilicon: true, defaults: defaults)
        var fakeNow = Date(timeIntervalSinceReferenceDate: 1_000_000)
        limiter.now = { fakeNow }
        limiter.start()

        #expect(stub.disableCount == 1)
        #expect(limiter.controlState == .paused)
        #expect(limiter.featureState == .paused, "within the window — no error yet")

        // 61 seconds later charging STILL runs → visible error, still paused
        // underneath (the re-assert keeps trying), never silently "paused".
        fakeNow = fakeNow.addingTimeInterval(61)
        limiter.reassertTick()
        #expect(stub.disableCount >= 2, "re-assert rewrote the key")
        guard case .error(let message) = limiter.featureState else {
            Issue.record("expected .error, got \(limiter.featureState)")
            return
        }
        #expect(message.contains("did not stop"))

        // The flip finally happens → error clears, honest paused state.
        stub.isCharging = false
        limiter.evaluate(reason: "test: flip observed")
        #expect(limiter.featureState == .paused)
    }

    // MARK: - Launch reconciliation + shutdown release

    @Test func launchAdoptsExistingInhibitionAndTableReleasesIt() {
        // A previous session crashed while paused: the simulated circuit is
        // still inhibited when the limiter starts with the feature OFF.
        let sim = DebugPowerSimulator(batteryPercent: 88, adapterConnected: true)
        sim.disableCharging()
        #expect(sim.chargingInhibited)
        withLimiter(sim: sim, enabled: false) { limiter in
            // start(): observed inhibited → adopt paused → row P6 releases.
            #expect(sim.writeCalls == [.disableCharging, .enableCharging])
            #expect(limiter.controlState == .normal)
            #expect(!sim.chargingInhibited)
            #expect(limiter.featureState == .off)
        }
    }

    @Test func shutdownReleasesAnActivePause() {
        let sim = DebugPowerSimulator(batteryPercent: 90, adapterConnected: true)
        withLimiter(sim: sim) { limiter in
            #expect(limiter.controlState == .paused)
            limiter.releasePauseForShutdown()
            #expect(sim.writeCalls == [.disableCharging, .enableCharging])
            #expect(!sim.chargingInhibited, "never leave charging inhibited after quit")
        }
    }

    // MARK: - Feature-state mapping (pure, exhaustive precedence)

    @Test func featureStatePrecedence() {
        typealias Map = ChargeLimiter
        // hidden (no battery) beats everything.
        #expect(Map.featureState(hasBattery: false, isAppleSilicon: false,
                                 readiness: .setupRequired, enabled: true,
                                 controlState: .paused, failure: .sudoDenied) == .hidden)
        // Intel beats setup/error states.
        #expect(Map.featureState(hasBattery: true, isAppleSilicon: false,
                                 readiness: .setupRequired, enabled: true,
                                 controlState: .paused, failure: .sudoDenied) == .notSupported)
        // setupRequired: via readiness (helper missing) even when off…
        #expect(Map.featureState(hasBattery: true, isAppleSilicon: true,
                                 readiness: .setupRequired, enabled: false,
                                 controlState: .normal, failure: nil) == .setupRequired)
        // …and via a sudo-denied write (sudoers missing).
        #expect(Map.featureState(hasBattery: true, isAppleSilicon: true,
                                 readiness: .ready, enabled: true,
                                 controlState: .normal, failure: .sudoDenied) == .setupRequired)
        // probe failure is an error even when the toggle is off.
        #expect(Map.featureState(hasBattery: true, isAppleSilicon: true,
                                 readiness: .probeFailed("x"), enabled: false,
                                 controlState: .normal, failure: nil)
            == .error("SMC key probe failed: x"))
        // off.
        #expect(Map.featureState(hasBattery: true, isAppleSilicon: true,
                                 readiness: .ready, enabled: false,
                                 controlState: .normal, failure: nil) == .off)
        // write failure / flip failure → error.
        #expect(Map.featureState(hasBattery: true, isAppleSilicon: true,
                                 readiness: .ready, enabled: true,
                                 controlState: .normal, failure: .writeFailed("boom"))
            == .error("boom"))
        if case .error(let message) = Map.featureState(
            hasBattery: true, isAppleSilicon: true, readiness: .ready,
            enabled: true, controlState: .paused, failure: .chargingDidNotStop) {
            #expect(message.contains("did not stop"))
        } else {
            Issue.record("chargingDidNotStop must map to .error")
        }
        // healthy states.
        #expect(Map.featureState(hasBattery: true, isAppleSilicon: true,
                                 readiness: .ready, enabled: true,
                                 controlState: .normal, failure: nil) == .active)
        #expect(Map.featureState(hasBattery: true, isAppleSilicon: true,
                                 readiness: .ready, enabled: true,
                                 controlState: .paused, failure: nil) == .paused)
    }

    // MARK: - Persistence clamps

    @Test func limitClampsToSliderRangeAndDefaults() {
        let sim = DebugPowerSimulator(batteryPercent: 50, adapterConnected: false)
        withLimiter(sim: sim, start: false) { limiter in
            #expect(limiter.limit == 90, "seeded by the helper")
            limiter.setLimit(45)
            #expect(limiter.limit == 50)
            limiter.setLimit(120)
            #expect(limiter.limit == 100)
        }
        // Untouched defaults → 90.
        let suite = "com.muratalkan.napcat.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let limiter = ChargeLimiter(power: sim, isAppleSilicon: true, defaults: defaults)
        #expect(limiter.limit == ChargeLimiter.defaultLimit)
        #expect(!limiter.enabled)
    }
}
