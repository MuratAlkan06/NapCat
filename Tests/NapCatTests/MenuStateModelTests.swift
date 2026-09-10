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

    // MARK: Track B / B2 — lid-alert presentation

    @Test func lidAlertStatusLineNamesTheNextStep() {
        // The not-armed wording never depends on the last send outcome.
        let everyOutcome: [MessageSendOutcome?] =
            [nil, .accepted, .rejected(404), .timedOutUnconfirmed, .sendFailed("boom")]
        for outcome in everyOutcome {
            #expect(MenuStateModel.lidAlertStatusLine(for: .off, lastOutcome: outcome) == "Lid alert: off")
            #expect(MenuStateModel.lidAlertStatusLine(for: .needsTopic, lastOutcome: outcome).contains("ntfy topic"))
            #expect(MenuStateModel.lidAlertStatusLine(for: .needsTestSend, lastOutcome: outcome).contains("test message"))
        }
        // Armed reads "armed" when the last publish worked, is unconfirmed, or
        // has not happened yet.
        for outcome: MessageSendOutcome? in [nil, .accepted, .timedOutUnconfirmed] {
            let line = MenuStateModel.lidAlertStatusLine(for: .armed, lastOutcome: outcome)
            #expect(line.contains("armed"))
            // The armed line must stay honest about what is promised.
            #expect(line.contains("best-effort"))
        }
        // No TCC vocabulary survives the channel swap.
        for state: LidGuardArmingState in [.off, .needsTopic, .needsTestSend, .armed] {
            let line = MenuStateModel.lidAlertStatusLine(for: state, lastOutcome: nil)
            for token in ["Messages", "iMessage", "Automation", "permission"] {
                #expect(!line.contains(token), "'\(token)' must not appear in: \(line)")
            }
        }
    }

    /// `primedAt` (hence `.armed`) survives in UserDefaults even after the feed
    /// stops working — a deleted topic, an instance that now needs auth. When
    /// the LAST publish was refused or failed, the primary line must NOT claim
    /// armed; it points back at the test send. (Arming logic is untouched.)
    @Test func lidAlertStatusLineDowngradesAfterAFailedSend() {
        for outcome: MessageSendOutcome in [.rejected(403), .rejected(404), .sendFailed("boom")] {
            let line = MenuStateModel.lidAlertStatusLine(for: .armed, lastOutcome: outcome)
            #expect(!line.contains("armed"), "must not claim armed after a message failed to go out")
            #expect(line.contains("did not go out"))
            #expect(line.contains("test message"))
        }
    }

    /// SECURITY: the topic is the only password on an ntfy feed, so the panel
    /// says whether one is set — never what it is.
    @Test func lidAlertTopicLineNeverEchoesTheTopic() {
        let topic = "napcat-lid-8f3k2p"
        let line = MenuStateModel.lidAlertTopicLine(topic)
        #expect(!line.contains(topic), "the topic is a password — it must not be rendered in the panel")
        #expect(line.contains("set"))
        #expect(MenuStateModel.lidAlertTopicLine("") == "Topic: none set")
        #expect(MenuStateModel.lidAlertTopicLine("bad/topic").contains("not usable"))
        #expect(MenuStateModel.lidAlertTopicLine("  napcat-x  ").contains("hidden"))
    }

    @Test func lidAlertServerLineShowsTheServerAndFlagsAnUnusableOne() {
        #expect(MenuStateModel.lidAlertServerLine("https://ntfy.sh") == "Server: https://ntfy.sh")
        #expect(MenuStateModel.lidAlertServerLine("https://ntfy.example.com:8443/")
                == "Server: https://ntfy.example.com:8443")
        #expect(MenuStateModel.lidAlertServerLine("") == "Server: https://ntfy.sh")
        #expect(MenuStateModel.lidAlertServerLine("http://ntfy.sh").contains("not usable"))
    }

    @Test func lidAlertLastSendCaptionIsHonestAndTimestamped() {
        let now = 1_000_000.0
        #expect(MenuStateModel.lidAlertLastSendCaption(outcome: nil, at: nil, now: now)
                == "Last message: none since NapCat started")
        let accepted = MenuStateModel.lidAlertLastSendCaption(outcome: .accepted, at: now - 120, now: now)
        #expect(accepted.contains("accepted by ntfy"), "never claims the phone got it")
        #expect(!accepted.contains("delivered"))
        #expect(accepted.contains("2m ago"))
        let rejected = MenuStateModel.lidAlertLastSendCaption(outcome: .rejected(404), at: now, now: now)
        #expect(rejected.contains("refused"))
        #expect(rejected.contains("404"))
        #expect(MenuStateModel.lidAlertLastSendCaption(outcome: .timedOutUnconfirmed, at: now, now: now)
                .contains("unconfirmed"))
        #expect(MenuStateModel.lidAlertLastSendCaption(outcome: .sendFailed("boom"), at: now, now: now)
                .contains("boom"))
    }

    /// M1 (security review 2026-09-09): the editor used to drop the validation
    /// results, so an unusable value silently left the OLD configuration in
    /// place while the panel still claimed the feature was armed. This mapping
    /// is what the modal shows instead — and it names the offending field.
    @Test func lidAlertSettingsErrorNamesTheUnusableField() throws {
        // Both usable ⇒ nothing to say.
        #expect(MenuStateModel.lidAlertSettingsError(
            topic: .valid("napcat-x"), server: .valid("https://ntfy.sh")) == nil)
        // Empty is a legitimate edit, not an error: it clears the topic /
        // reverts the server to the public instance.
        #expect(MenuStateModel.lidAlertSettingsError(topic: .empty, server: .empty) == nil)
        #expect(MenuStateModel.lidAlertSettingsError(
            topic: .valid("napcat-x"), server: .empty) == nil)

        let badTopic = try #require(MenuStateModel.lidAlertSettingsError(
            topic: .invalid, server: .valid("https://ntfy.sh")))
        #expect(badTopic.contains("topic"))
        #expect(badTopic.contains("Nothing was saved"))
        #expect(!badTopic.contains("server"), "only the offending field is named")

        let badServer = try #require(MenuStateModel.lidAlertSettingsError(
            topic: .valid("napcat-x"), server: .invalid))
        #expect(badServer.contains("server"))
        #expect(badServer.contains("https"))
        #expect(!badServer.contains("topic"))

        let both = try #require(MenuStateModel.lidAlertSettingsError(topic: .invalid, server: .invalid))
        #expect(both.contains("topic"))
        #expect(both.contains("server"))
    }

    /// The message is shown in a dialog the user can screenshot, so — like
    /// every other B2 caption — it must never echo the topic itself.
    @Test func lidAlertSettingsErrorNeverEchoesTheEnteredValues() {
        let message = MenuStateModel.lidAlertSettingsError(topic: .invalid, server: .invalid)
        // The mapping only ever sees the VALIDATION, never the raw text — this
        // locks that shape: nothing user-entered can reach the string.
        #expect(message?.contains("napcat") == false)
        #expect(MenuStateModel.lidAlertSettingsError(topic: .valid("secret-topic"), server: .invalid)?
            .contains("secret-topic") == false)
    }

    @Test func lidAlertNoteWarnsThatTheTopicIsThePassword() {
        #expect(MenuStateModel.lidAlertTopicSecrecyNote.contains("topic name"))
        #expect(MenuStateModel.lidAlertTopicSecrecyNote.contains("private"))
    }

    @Test func testSendIsOfferedOnlyWithAUsableDestination() {
        #expect(MenuStateModel.lidAlertTestSendAvailable(server: "https://ntfy.sh", topic: "napcat-x"))
        // An unset server means the public instance, which is usable.
        #expect(MenuStateModel.lidAlertTestSendAvailable(server: "", topic: "napcat-x"))
        #expect(!MenuStateModel.lidAlertTestSendAvailable(server: "https://ntfy.sh", topic: ""))
        #expect(!MenuStateModel.lidAlertTestSendAvailable(server: "https://ntfy.sh", topic: "bad/topic"))
        #expect(!MenuStateModel.lidAlertTestSendAvailable(server: "http://ntfy.sh", topic: "napcat-x"))
    }

    /// The panel section only exists when the subsystem does (absent in
    /// debugBattery mode) — same rule as the B1 detection section.
    @Test @MainActor func lidAlertSectionIsHiddenWithoutTheController() {
        #expect(!makeModel().lidGuardVisible)
    }
}
