import Testing
@testable import NapCat

/// Pure display mappings behind the SwiftUI menu panel (the view itself gets
/// its sign-off from the user's screenshot review — PLAN.md decision log).
struct MenuStateModelTests {
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
