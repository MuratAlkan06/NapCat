// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Pure display mappings behind the SwiftUI menu panel (the view itself gets
/// its sign-off from the user's screenshot review — PLAN.md decision log),
/// plus the live-wiring guarantees the open-menu panel relies on
/// (2026-07-10 menu-stays-open fix).
struct MenuStateModelTests {
    /// Isolated defaults suite so tests never touch com.muratalkan.napcat.
    private static let testSuite = "com.muratalkan.napcat.tests.menustatemodel"

    @MainActor
    private func makeModel(
        simulator: DebugPowerSimulator = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
    ) -> MenuStateModel {
        let defaults = UserDefaults(suiteName: Self.testSuite)!
        defaults.removePersistentDomain(forName: Self.testSuite)
        let limiter = ChargeLimiter(power: simulator, isAppleSilicon: true, defaults: defaults)
        return MenuStateModel(power: simulator, sleep: SleepStateController(), limiter: limiter, simulator: simulator)
    }

    // MARK: Live wiring (menu stays open; panel updates in place)

    /// The SwiftUI toggle binding forwards through the hook — it must NOT
    /// run any privileged flow itself (MenuContentView owns that, async).
    @Test @MainActor func setStayAwakeForwardsDesiredStateToTheHook() {
        let model = makeModel()
        var recorded: [Bool] = []
        model.requestStayAwakeToggle = { recorded.append($0) }
        model.setStayAwake(true)
        model.setStayAwake(false)
        #expect(recorded == [true, false])
    }

    /// refresh() re-reads every mirror from the controllers — this is the
    /// publish path that re-renders the OPEN panel (battery header, charging
    /// line, feature state) after an async command or power push completes.
    @Test @MainActor func refreshRereadsControllersSoTheOpenPanelUpdates() {
        let simulator = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        let model = makeModel(simulator: simulator)
        #expect(model.batteryPercent == 80)
        #expect(model.adapterConnected)
        #expect(model.isCharging)

        simulator.batteryPercent = 42
        simulator.adapterConnected = false
        #expect(model.batteryPercent == 80, "mirrors update on refresh(), not by magic")

        model.refresh()
        #expect(model.batteryPercent == 42)
        #expect(!model.adapterConnected)
        #expect(!model.isCharging)
    }
    // MARK: Stay-awake toggle = P2 checkmark semantics on a SwiftUI Toggle

    @Test func observedEnabledRendersOn() {
        let mapped = MenuStateModel.stayAwakeToggle(forObserved: true)
        #expect(mapped.isOn)
        #expect(mapped.caption == nil)
    }

    @Test func observedDisabledRendersOff() {
        let mapped = MenuStateModel.stayAwakeToggle(forObserved: false)
        #expect(!mapped.isOn)
        #expect(mapped.caption == nil)
    }

    @Test func unknownObservedStateRendersOffWithCaptionNeverSilently() {
        let mapped = MenuStateModel.stayAwakeToggle(forObserved: nil)
        #expect(!mapped.isOn)
        #expect(mapped.caption != nil, "unreadable state must be called out (ADR §6)")
    }

    // MARK: Battery header

    @Test func percentTextAndGaugeFraction() {
        #expect(MenuStateModel.percentText(82) == "82%")
        #expect(MenuStateModel.percentText(nil) == "—")
        #expect(MenuStateModel.gaugeFraction(82) == 0.82)
        #expect(MenuStateModel.gaugeFraction(nil) == 0, "unknown renders empty, never a guess")
        #expect(MenuStateModel.gaugeFraction(150) == 1.0)
        #expect(MenuStateModel.gaugeFraction(-5) == 0)
    }

    @Test func batteryHeadline() {
        #expect(MenuStateModel.batteryHeadline(hasBattery: true, percent: 82) == "Battery 82%")
        #expect(MenuStateModel.batteryHeadline(hasBattery: true, percent: nil) == "Battery —")
        #expect(MenuStateModel.batteryHeadline(hasBattery: false, percent: nil) == "NapCat")
    }

    @Test func chargingStatusLineVariants() {
        #expect(MenuStateModel.chargingStatusLine(
            hasBattery: true, percent: 82, isCharging: true, adapterConnected: true) == "Charging")
        #expect(MenuStateModel.chargingStatusLine(
            hasBattery: true, percent: 90, isCharging: false, adapterConnected: true)
            == "On AC power — not charging")
        #expect(MenuStateModel.chargingStatusLine(
            hasBattery: true, percent: 100, isCharging: false, adapterConnected: true)
            == "Fully charged")
        #expect(MenuStateModel.chargingStatusLine(
            hasBattery: true, percent: 55, isCharging: false, adapterConnected: false)
            == "On battery")
        #expect(MenuStateModel.chargingStatusLine(
            hasBattery: false, percent: nil, isCharging: false, adapterConnected: false)
            == "Desktop Mac — no battery")
    }

    // MARK: Charge-limit labels + feature-state messaging

    @Test func limitLabelLiveText() {
        #expect(MenuStateModel.limitLabel(limit: 90) == "Pause charging at 90%")
        #expect(MenuStateModel.limitLabel(limit: 50) == "Pause charging at 50%")
        #expect(MenuStateModel.limitLabel(limit: 100) == "No limit — charge to 100%")
    }

    @Test func featureMessages() {
        #expect(MenuStateModel.featureMessage(for: .hidden) == nil)
        #expect(MenuStateModel.featureMessage(for: .off) == nil)
        #expect(MenuStateModel.featureMessage(for: .notSupported)?.contains("Apple Silicon") == true)
        #expect(MenuStateModel.featureMessage(for: .setupRequired)?.contains("setup.sh") == true)
        #expect(MenuStateModel.featureMessage(for: .active)?.contains("pause") == true)
        #expect(MenuStateModel.featureMessage(for: .paused)?.contains("paused") == true)
        #expect(MenuStateModel.featureMessage(for: .error("smc exploded")) == "smc exploded",
                "error text passes through verbatim")
    }
}
