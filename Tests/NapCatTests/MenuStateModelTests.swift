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
        simulator: DebugPowerSimulator = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true),
        turnOn: StayAwakeTurnOnFeedback? = nil
    ) -> MenuStateModel {
        let defaults = UserDefaults(suiteName: Self.testSuite)!
        defaults.removePersistentDomain(forName: Self.testSuite)
        let limiter = ChargeLimiter(power: simulator, isAppleSilicon: true, defaults: defaults)
        guard let turnOn else {
            return MenuStateModel(power: simulator, sleep: SleepStateController(), limiter: limiter, simulator: simulator)
        }
        return MenuStateModel(power: simulator, sleep: SleepStateController(), limiter: limiter, simulator: simulator,
                              stayAwakeTurnOn: turnOn)
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

    // MARK: Stay Awake "Turning on…" (owner ruling e) — injected clock, no sleeps

    /// The three locked cases, each on a manual clock (time only moves when
    /// the test advances it). Fast confirm: pmset confirms inside the hold, so
    /// the caption never appears, not even when the hold runs out later.
    @Test @MainActor func aFastConfirmNeverShowsTheCaption() {
        let clock = ManualTurnOnClock()
        let feedback = StayAwakeTurnOnFeedback(after: clock.clock)
        feedback.flippedOn()
        #expect(clock.scheduledDelays == [PanelMotion.turnOnCaptionDelay])
        #expect(Self.slot(observed: false, feedback) == nil, "no caption inside the hold")
        clock.advance(to: 0.2)
        feedback.observed(true)
        #expect(feedback.phase == .idle)
        clock.advance(to: 0.5)
        #expect(feedback.phase == .idle, "the expired hold cannot resurrect a confirmed turn-on")
        #expect(Self.slot(observed: true, feedback) == nil)
    }

    /// Slow confirm: still unconfirmed when the hold runs out ⇒ "Turning on…".
    @Test @MainActor func aSlowConfirmShowsTheCaptionWhenTheHoldRunsOut() throws {
        let clock = ManualTurnOnClock()
        let feedback = StayAwakeTurnOnFeedback(after: clock.clock)
        feedback.flippedOn()
        clock.advance(to: 0.399)
        #expect(feedback.phase == .waiting)
        #expect(Self.slot(observed: false, feedback) == nil, "not before the ~400 ms hold")
        clock.advance(to: 0.4)
        #expect(feedback.phase == .showing)
        let line = try #require(Self.slot(observed: false, feedback))
        #expect(line == PanelLine(text: "Turning on…", severity: .nominal))
    }

    /// Confirm clears: the caption goes as soon as pmset reports ON, and a
    /// later OFF does not bring it back.
    @Test @MainActor func theConfirmClearsTheCaption() {
        let clock = ManualTurnOnClock()
        let feedback = StayAwakeTurnOnFeedback(after: clock.clock)
        feedback.flippedOn()
        clock.advance(to: 0.5)
        #expect(Self.slot(observed: false, feedback) != nil, "vacuity: the caption was showing")
        feedback.observed(false)
        #expect(feedback.phase == .showing, "an unconfirmed read keeps it")
        clock.advance(to: 0.9)
        feedback.observed(true)
        #expect(feedback.phase == .idle)
        #expect(Self.slot(observed: true, feedback) == nil)
        feedback.observed(false)
        #expect(Self.slot(observed: false, feedback) == nil, "turning off later shows nothing")
    }

    /// One hold per flip: a repeat flip while pending schedules nothing, and a
    /// hold left over from an earlier, confirmed flip cannot promote a newer
    /// one early.
    @Test @MainActor func aStaleHoldNeverPromotesANewerFlip() {
        let clock = ManualTurnOnClock()
        let feedback = StayAwakeTurnOnFeedback(after: clock.clock)
        feedback.flippedOn()
        clock.advance(to: 0.05)
        feedback.flippedOn()
        #expect(clock.scheduledDelays.count == 1, "a repeat flip while pending starts no second hold")
        clock.advance(to: 0.1)
        feedback.observed(true)
        clock.advance(to: 0.2)
        feedback.flippedOn()                       // a new turn-on: its hold ends at 0.2 + 0.4
        clock.advance(to: 0.4)                     // the FIRST hold ends here
        #expect(feedback.phase == .waiting, "the stale hold was ignored")
        clock.advance(to: 0.65)                    // past the second hold (0.2 + 0.4 is not exactly 0.6 in binary)
        #expect(feedback.phase == .showing)
    }

    /// Every menu open starts clean: a failed attempt (reported by its own
    /// alert, with the menu closed) never leaves a stale caption.
    @Test @MainActor func openingThePanelClearsAStaleCaption() {
        let clock = ManualTurnOnClock()
        let feedback = StayAwakeTurnOnFeedback(after: clock.clock)
        feedback.flippedOn()
        clock.advance(to: 1)
        #expect(feedback.phase == .showing)
        feedback.panelOpened()
        #expect(feedback.phase == .idle)
        #expect(Self.slot(observed: false, feedback) == nil)
    }

    /// Through the model: flipping ON starts the hold BEFORE the request is
    /// forwarded (so a confirm published during the forward clears it).
    /// Flipping OFF — the disable path — forwards exactly as before and never
    /// touches the feedback: no phase change, no hold, ever.
    @Test @MainActor func onlyFlippingOnStartsTheTurnOnFeedback() {
        let clock = ManualTurnOnClock()
        let model = makeModel(turnOn: StayAwakeTurnOnFeedback(after: clock.clock))
        var forwarded: [(desired: Bool, phase: StayAwakeTurnOnPhase)] = []
        model.requestStayAwakeToggle = { forwarded.append(($0, model.stayAwakeTurnOn.phase)) }

        model.setStayAwake(false)
        #expect(forwarded.map(\.desired) == [false])
        #expect(model.stayAwakeTurnOn.phase == .idle)
        #expect(clock.scheduledDelays.isEmpty, "the disable path schedules nothing")
        clock.advance(to: 10)
        #expect(model.stayAwakeTurnOn.phase == .idle)

        model.setStayAwake(true)
        #expect(forwarded.map(\.desired) == [false, true])
        #expect(forwarded.last?.phase == .waiting, "the hold starts before the forward")
        #expect(clock.scheduledDelays == [PanelMotion.turnOnCaptionDelay])
        model.refresh()
        #expect(model.stayAwakeTurnOn.phase == .waiting, "an unconfirmed refresh keeps it pending")
        clock.advance(to: 10.4)
        #expect(model.stayAwakeTurnOn.phase == .showing)
    }

    @MainActor
    private static func slot(observed: Bool?, _ feedback: StayAwakeTurnOnFeedback) -> PanelLine? {
        MenuStateModel.stayAwakeSlot(observed: observed, turnOn: feedback.phase)
    }

    /// Track C: flipping the detection pause tells the owner (MenuContentView
    /// re-gates the finish alert there). No detection stack here, so no flag
    /// file is written anywhere.
    @Test @MainActor func aPauseToggleNotifiesTheOwner() {
        let model = makeModel()
        var calls = 0
        model.onDetectionPausedChange = { calls += 1 }
        model.setDetectionPaused(true)
        model.setDetectionPaused(false)
        #expect(calls == 2)
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

    /// #58 end to end through the model, under #84's contract: the user's
    /// SAVED toggle + limit are kept as-is, but the panel row is hidden and
    /// carries no caption; nothing is written.
    @Test @MainActor func controlUnavailableKeepsTheSavedStateAndHidesTheRow() {
        let suite = "com.muratalkan.napcat.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: DefaultsKey.limitEnabled)
        defaults.set(85, forKey: DefaultsKey.limit)
        let simulator = DebugPowerSimulator(batteryPercent: 95, adapterConnected: true)
        simulator.chargeControlReadiness = .controlUnavailable
        let limiter = ChargeLimiter(power: simulator, isAppleSilicon: true, defaults: defaults)
        limiter.start()
        let model = MenuStateModel(power: simulator, sleep: SleepStateController(), limiter: limiter,
                                   simulator: simulator)

        #expect(model.featureState == .controlUnavailable)
        #expect(model.limitEnabled && model.limit == 85, "saved intent kept as-is")
        #expect(!model.chargeLimitRowVisible, "the panel row is hidden")
        #expect(model.chargeLimitCaption == nil, "and has no caption")
        #expect(simulator.writeCalls.isEmpty)
    }

    /// #84 revival, through the model: while the firmware gates control the
    /// row is hidden and Settings › General shows the one note; once the
    /// menu-open probe reads the keys again (readiness → .ready, the limiter
    /// re-evaluates, the model re-reads), the row is back with the SAVED
    /// toggle and limit, and the note has given way to the controls.
    @Test @MainActor func aRevivedProbeBringsTheRowBackWithTheSavedState() {
        let suite = "com.muratalkan.napcat.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: DefaultsKey.limitEnabled)
        defaults.set(85, forKey: DefaultsKey.limit)
        let simulator = DebugPowerSimulator(batteryPercent: 60, adapterConnected: true)
        simulator.chargeControlReadiness = .controlUnavailable
        let limiter = ChargeLimiter(power: simulator, isAppleSilicon: true, defaults: defaults)
        limiter.start()
        let model = MenuStateModel(power: simulator, sleep: SleepStateController(), limiter: limiter,
                                   simulator: simulator)
        let note = SettingsSection(title: "Charge Limit", rows: [.note(MenuStateModel.chargeControlUnavailableText)])

        #expect(model.featureState == .controlUnavailable)
        #expect(!model.chargeLimitRowVisible)
        #expect(model.generalPane.sections.contains(note), "the gated Mac's one note")

        simulator.chargeControlReadiness = .ready
        limiter.evaluate(reason: "menu open")
        model.refresh()

        #expect(model.featureState == .active)
        #expect(model.chargeLimitRowVisible, "the row is back")
        #expect(model.limitEnabled && model.limit == 85, "with the saved toggle and limit")
        #expect(model.chargeLimitCaption == PanelLine(text: "Charging — pauses at the limit", severity: .nominal))
        let charge = model.generalPane.sections.filter { $0.title == "Charge Limit" }
        #expect(charge == [SettingsSection(title: "Charge Limit", rows: [
            .chargeLimit(header: "Pause charging at 85%", isOn: true, switchEnabled: true, limit: 85, sliderEnabled: true,
                         caption: PanelLine(text: "Charging — pauses at the limit", severity: .nominal)),
        ])], "the note gave way to the controls")
        #expect(simulator.writeCalls.isEmpty, "below the limit: nothing to write")
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
        // #58 → #84: no row caption — the row is hidden; the limitation's one
        // plain note lives in Settings › General.
        #expect(MenuStateModel.featureMessage(for: .controlUnavailable) == nil)
        #expect(MenuStateModel.featureMessage(for: .active)?.contains("pause") == true)
        #expect(MenuStateModel.featureMessage(for: .paused)?.hasPrefix("Paused") == true)
        #expect(MenuStateModel.featureMessage(for: .error("smc exploded")) == "smc exploded",
                "error text passes through verbatim")
    }

    // MARK: Track B / B2 — lid-alert presentation

    @Test func lidAlertStatusLineNamesTheNextStep() {
        // The not-armed wording never depends on the last send outcome.
        let everyOutcome: [MessageSendOutcome?] =
            [nil, .accepted, .rejected(404), .timedOutUnconfirmed, .sendFailed("boom")]
        for outcome in everyOutcome {
            #expect(MenuStateModel.lidAlertStatusLine(for: .off, lastOutcome: outcome, detectionPaused: false) == "Off")
            #expect(MenuStateModel.lidAlertStatusLine(for: .needsTopic, lastOutcome: outcome, detectionPaused: false).contains("ntfy topic"))
            #expect(MenuStateModel.lidAlertStatusLine(for: .needsTestSend, lastOutcome: outcome, detectionPaused: false).contains("test message"))
        }
        // Armed reads "Armed" when the last publish worked, is unconfirmed, or
        // has not happened yet.
        for outcome: MessageSendOutcome? in [nil, .accepted, .timedOutUnconfirmed] {
            let line = MenuStateModel.lidAlertStatusLine(for: .armed, lastOutcome: outcome, detectionPaused: false)
            #expect(line.hasPrefix("Armed"))
            // The armed line must stay honest about what is promised.
            #expect(line.contains("best-effort"))
        }
        // No TCC vocabulary survives the channel swap.
        for state: LidGuardArmingState in [.off, .needsTopic, .needsTestSend, .armed] {
            let line = MenuStateModel.lidAlertStatusLine(for: state, lastOutcome: nil, detectionPaused: false)
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
            let line = MenuStateModel.lidAlertStatusLine(for: .armed, lastOutcome: outcome, detectionPaused: false)
            #expect(!line.lowercased().contains("armed"), "must not claim armed after a message failed to go out")
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

        // UI audit M3: the topic field opens masked, so the topic sentence
        // points at the "Show" checkbox that reveals it — the topic sentence
        // only, and it stays attached to it when both fields are invalid.
        #expect(badTopic == "Nothing was saved. The topic can only contain letters, digits, “_” and “-”, "
                + "up to \(LidGuardTuning.maxTopicLength) characters. Tick Show to check what you typed.")
        #expect(TopicFieldVisibility.checkboxTitle == "Show", "the hint names the checkbox as it is labelled")
        #expect(!badServer.contains("Tick"))
        #expect(both.hasPrefix(badTopic + " The server"))
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

    // MARK: Track C — session alerts (finish + waiting pushes)

    /// refresh() mirrors the finish-alert controller: its live display state
    /// (`.armed` only once the watcher runs) and its last send — outcome,
    /// time and kind — with the toggle read off the lid guard.
    @Test @MainActor func refreshMirrorsTheFinishAlertController() async throws {
        typealias H = FinishAlertHarness
        try await withFinishAlertHarness { h in
            let suite = "com.muratalkan.napcat.tests.menustatemodel.finish.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let lid = LidGuardHarness(defaults: defaults, sender: RecordingMessageSender())
            defaults.set(true, forKey: DefaultsKey.claudeFinishAlertEnabled)
            let simulator = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
            let limiter = ChargeLimiter(power: simulator, isAppleSilicon: true, defaults: defaults)
            h.store.put(H.s1, ts: H.t0 - 600)
            let model = MenuStateModel(power: simulator, sleep: SleepStateController(), limiter: limiter,
                                       lidGuard: lid.controller, finishAlert: h.controller)

            #expect(model.finishAlertVisible)
            #expect(model.finishAlertEnabled)
            #expect(model.finishAlertDisplayState == .hookNotInstalled,
                    "armable but not watching yet — never shown as armed")
            #expect(model.finishAlertLastOutcome == nil && model.finishAlertLastOutcomeAt == nil
                    && model.finishAlertLastKind == nil)

            h.controller.reconcile()
            #expect(model.finishAlertDisplayState == .hookNotInstalled, "mirrors update on refresh(), not by magic")
            model.refresh()
            #expect(model.finishAlertDisplayState == .armed)
            #expect(model.finishAlertStatus.severity == .nominal)

            h.store.remove(H.s1)
            await h.settle()
            model.refresh()
            #expect(model.finishAlertLastOutcome == .accepted)
            #expect(model.finishAlertLastOutcomeAt == Double(H.t0))
            #expect(model.finishAlertLastKind == .sessionFinished(minutes: 10, folded: 1, stillWorking: 0))
            #expect(model.finishAlertLastSend(now: Double(H.t0) + 60)
                    == PanelLine(text: "Last session alert: accepted by ntfy 1m ago (finished)", severity: .nominal))

            defaults.set(false, forKey: DefaultsKey.claudeFinishAlertEnabled)
            model.refresh()
            #expect(!model.finishAlertEnabled)

            // Issue #34: the run floor the ntfy settings editor is fed with
            // is the controller's live value, re-read on refresh.
            #expect(model.finishAlertMinimumRunSeconds == 60)
            h.runFloor.value = 120
            #expect(model.finishAlertMinimumRunSeconds == 60, "mirrors update on refresh(), not by magic")
            model.refresh()
            #expect(model.finishAlertMinimumRunSeconds == 120)
        }
    }

    /// Alert healing (issue #23): refresh() mirrors the controller's OFFLINE
    /// flag — true only while healing is armed and holding; false once it
    /// heals, and false whenever there is no controller at all.
    @Test @MainActor func refreshMirrorsTheAlertHealingOfflineFlag() async throws {
        typealias H = FinishAlertHarness
        try await withFinishAlertHarness(connectivity: ConnectivitySimulator()) { h in
            let suite = "com.muratalkan.napcat.tests.menustatemodel.healing.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let lid = LidGuardHarness(defaults: defaults, sender: RecordingMessageSender())
            defaults.set(true, forKey: DefaultsKey.claudeFinishAlertEnabled)
            let simulator = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
            let limiter = ChargeLimiter(power: simulator, isAppleSilicon: true, defaults: defaults)
            h.store.put(H.s1, ts: H.t0 - 600)
            h.controller.reconcile()
            await drainMain()
            let model = MenuStateModel(power: simulator, sleep: SleepStateController(), limiter: limiter,
                                       lidGuard: lid.controller, finishAlert: h.controller)
            #expect(!model.sessionAlertsOffline)

            await h.goOfflineByPath()
            #expect(!model.sessionAlertsOffline, "mirrors update on refresh(), not by magic")
            model.refresh()
            #expect(model.sessionAlertsOffline)
            #expect(model.finishAlertStatus == MenuStateModel.sessionAlertsOfflineLine)

            await h.pathUp()
            model.refresh()
            #expect(!model.sessionAlertsOffline, "healed: the line is gone")
            #expect(model.finishAlertStatus.severity == .nominal)
        }
        #expect(!makeModel().sessionAlertsOffline, "no controller (debugBattery wiring): never offline")
    }

    /// No controller (debugBattery wiring): the row is absent and everything
    /// reads off/none, even with the stored toggle on.
    @Test @MainActor func withoutTheControllerTheSessionAlertsRowIsAbsentAndOff() {
        withLidGuardHarness { lid in
            lid.defaults.set(true, forKey: DefaultsKey.claudeFinishAlertEnabled)
            let simulator = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
            let limiter = ChargeLimiter(power: simulator, isAppleSilicon: true, defaults: lid.defaults)
            let model = MenuStateModel(power: simulator, sleep: SleepStateController(), limiter: limiter,
                                       lidGuard: lid.controller)
            #expect(!model.finishAlertVisible)
            #expect(!model.finishAlertEnabled)
            #expect(model.finishAlertDisplayState == .off)
            #expect(model.finishAlertLastOutcome == nil && model.finishAlertLastOutcomeAt == nil
                    && model.finishAlertLastKind == nil)
            lid.defaults.set(120, forKey: DefaultsKey.finishAlertMinimumRunSeconds)
            model.refresh()
            #expect(model.finishAlertMinimumRunSeconds == FinishAlertTuning.minimumRunSeconds,
                    "no controller: the editor shows no floor group, the mirror stays the default")
        }
        #expect(!makeModel().finishAlertVisible)
    }

    /// Issue #34: the "Session alerts" group of the ntfy settings editor.
    /// Its strings are fixed (the title is the panel row's own name), and the
    /// popup offers five presets — both clamp bounds and the default among
    /// them — as formatted durations.
    @Test func theSessionAlertsFloorGroupPresentation() {
        #expect(MenuStateModel.sessionAlertsFloorGroupTitle == "Session alerts")
        #expect(MenuStateModel.sessionAlertsFloorLabel == "Only alert for runs longer than:")
        #expect(MenuStateModel.sessionAlertsFloorAccessibilityLabel == "Minimum run before alerting")
        #expect(MenuStateModel.sessionAlertsFloorCaption == "Shorter runs finish silently.")

        let presets = MenuStateModel.sessionAlertsFloorPresets
        let range = FinishAlertTuning.minimumRunSecondsRange
        #expect(presets == [30, 60, 120, 300, 600])
        #expect(presets.map(MenuStateModel.sessionAlertsFloorText(seconds:))
                == ["30 seconds", "1 minute", "2 minutes", "5 minutes", "10 minutes"])
        #expect(presets == presets.sorted() && Set(presets).count == presets.count)
        #expect(presets.first == range.lowerBound && presets.last == range.upperBound, "both bounds are reachable")
        #expect(presets.contains(FinishAlertTuning.minimumRunSeconds), "the default is a preset — no reset row")
    }

    /// Issue #34: the popup's formatter. Under a minute in seconds, whole
    /// minutes in minutes, anything else as "N min S s" — never raw seconds
    /// above 59. Across the whole clamp range every floor gets its own text
    /// (a popup merges rows with the same title).
    @Test func theSessionAlertsFloorFormatter() {
        let rows: [(seconds: Int, text: String)] = [
            (1, "1 second"), (30, "30 seconds"), (45, "45 seconds"), (59, "59 seconds"),
            (60, "1 minute"), (61, "1 min 1 s"), (90, "1 min 30 s"), (119, "1 min 59 s"),
            (120, "2 minutes"), (150, "2 min 30 s"), (300, "5 minutes"), (599, "9 min 59 s"),
            (600, "10 minutes"),
        ]
        for row in rows {
            #expect(MenuStateModel.sessionAlertsFloorText(seconds: row.seconds) == row.text, "\(row.seconds) s")
        }

        let range = FinishAlertTuning.minimumRunSecondsRange
        var seen = Set<String>()
        for seconds in range {
            let text = MenuStateModel.sessionAlertsFloorText(seconds: seconds)
            let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            #expect(!numbers.isEmpty && numbers.allSatisfy { $0 <= 59 }, "\(seconds) s reads '\(text)'")
            #expect(seen.insert(text).inserted, "'\(text)' is shown for two floors")
        }
    }

    /// Issue #34: the popup's rows. A preset floor (the default included)
    /// gets exactly the five presets; a floor that is not one — 90 written
    /// with `defaults write` — gets ONE extra row of its own, in order,
    /// rather than being snapped to a neighbour.
    @Test func aNonPresetFloorGetsOneExtraRowOfItsOwn() {
        let presets = MenuStateModel.sessionAlertsFloorPresets
        for preset in presets {
            #expect(MenuStateModel.sessionAlertsFloorChoices(seconds: preset) == presets, "\(preset) s")
        }
        #expect(MenuStateModel.sessionAlertsFloorChoices(seconds: 90) == [30, 60, 90, 120, 300, 600])
        #expect(MenuStateModel.sessionAlertsFloorChoices(seconds: 31) == [30, 31, 60, 120, 300, 600])
        #expect(MenuStateModel.sessionAlertsFloorChoices(seconds: 599) == [30, 60, 120, 300, 599, 600])
    }

    /// The real owner wired to fakes: a MenuContentView whose finish alert
    /// reads the REAL lid guard's config (shared destination + priming) but
    /// watches a fake store / temp dir — never the real marker dir.
    @MainActor
    private func withSessionAlertsMenu(
        topic: String?,
        _ body: (MenuContentView, LidGuardHarness, RecordingMessageSender, FinishAlertController) throws -> Void
    ) throws {
        let suite = "com.muratalkan.napcat.tests.menustatemodel.toggle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("napcat-sessiontoggle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sender = RecordingMessageSender()
        let lid = LidGuardHarness(defaults: defaults, sender: sender, topicStore: FakeTopicStore(topic))
        let factory = WatcherFactory()
        let finish = FinishAlertController(
            store: FakeMarkerStore(),
            markerDirURL: dir,
            config: lid.controller,
            sender: sender,
            makeWatcher: { factory.make($0) },
            scheduler: ManualScheduler(),
            now: { 1_800_000_000 }
        )
        let simulator = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        let menu = MenuContentView(
            sleep: SleepStateController(),
            watchdog: WatchdogController(),
            power: simulator,
            limiter: ChargeLimiter(power: simulator, isAppleSilicon: true, defaults: defaults),
            lidGuard: lid.controller,
            finishAlert: finish,
            defaults: defaults
        )
        try body(menu, lid, sender, finish)
    }

    /// The toggle persists `claudeFinishAlertEnabled` and, against a usable
    /// but never-tested topic, fires the SHARED priming test send — so the
    /// first message on the topic is never a session alert. Once primed,
    /// re-toggling sends nothing; the lid alert's own toggle is untouched.
    @Test @MainActor func theSessionAlertsTogglePersistsAndPrimesThroughTheSharedTestSend() throws {
        try withSessionAlertsMenu(topic: "napcat-session-7h2k9q") { menu, lid, sender, finish in
            let model = menu.model
            #expect(model.finishAlertVisible)
            #expect(!model.finishAlertEnabled)
            #expect(model.finishAlertDisplayState == .off)
            #expect(lid.controller.storedDestination != nil && lid.controller.primedAt == 0,
                    "usable topic, never primed")

            model.setFinishAlertEnabled(true)
            #expect(lid.defaults.object(forKey: DefaultsKey.claudeFinishAlertEnabled) as? Bool == true)
            #expect(sender.sends.map(\.kind) == [.test], "the shared test send — never a session alert first")
            #expect(lid.controller.primedAt > 0, "an accepted test send primes the shared destination")
            #expect(!lid.controller.isEnabled, "the lid alert's own toggle is untouched")
            #expect(finish.isWatching)
            #expect(model.finishAlertEnabled)
            #expect(model.finishAlertDisplayState == .armed, "no not-watching flash after the toggle")

            model.setFinishAlertEnabled(false)
            #expect(lid.defaults.object(forKey: DefaultsKey.claudeFinishAlertEnabled) as? Bool == false)
            #expect(!finish.isWatching)
            #expect(!model.finishAlertEnabled)
            #expect(model.finishAlertDisplayState == .off)

            model.setFinishAlertEnabled(true)
            #expect(sender.sends.count == 1, "already primed — no second test send")
            #expect(model.finishAlertDisplayState == .armed)
        }
    }

    /// Without a usable topic there is nothing to test: the toggle persists,
    /// sends nothing, and the row names the next step.
    @Test @MainActor func theSessionAlertsToggleWithoutATopicSendsNothing() throws {
        try withSessionAlertsMenu(topic: nil) { menu, lid, sender, finish in
            menu.model.setFinishAlertEnabled(true)
            #expect(lid.defaults.bool(forKey: DefaultsKey.claudeFinishAlertEnabled))
            #expect(sender.sends.isEmpty)
            #expect(!finish.isWatching)
            #expect(menu.model.finishAlertDisplayState == .needsTopic)
            #expect(menu.model.finishAlertStatus == PanelLine(text: "Not armed — set an ntfy topic in Settings",
                                                              severity: .warning))
        }
    }
}

/// The injected clock for `StayAwakeTurnOnFeedback` (owner ruling e): it
/// records each scheduled hold and fires it only when a test advances time
/// past its due moment, so no test ever sleeps.
@MainActor
final class ManualTurnOnClock {
    private(set) var now = 0.0
    private(set) var scheduledDelays: [Double] = []
    private var pending: [(due: Double, fire: @MainActor @Sendable () -> Void)] = []

    var clock: StayAwakeTurnOnFeedback.Clock {
        { [self] delay, fire in
            scheduledDelays.append(delay)
            pending.append((now + delay, fire))
        }
    }

    func advance(to time: Double) {
        now = time
        let due = pending.filter { $0.due <= time }
        pending.removeAll { $0.due <= time }
        for hold in due { hold.fire() }
    }
}
