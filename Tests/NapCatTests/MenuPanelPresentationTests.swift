// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import ServiceManagement
import Testing
@testable import NapCat

/// Menu-panel redesign (2026-10-18, PLAN.md "UI Redesign — Menu Panel"): the
/// pure mappings the panel renders — merged Claude row, F2 armed downgrade,
/// severity classification, the iron rule (nothing non-nominal stays behind
/// Details), the collapsed badge — plus the model's panel state (in-memory
/// disclosure). The design froze on one layout the same day.
struct MenuPanelPresentationTests {
    // MARK: - Merged Claude row (tier 1)

    /// Full truth table: 8 input combinations.
    @Test(arguments: [
        (false, false, false, "Claude: idle", PanelSeverity.nominal),
        (true, false, false, "Claude: running", .nominal),
        (false, true, false, "Claude: idle — keeping Mac awake", .nominal),
        (true, true, false, "Claude: running — keeping Mac awake", .nominal),
        (false, false, true, "Detection paused", .warning),
        (true, false, true, "Detection paused", .warning),
        (false, true, true, "Detection paused", .warning),
        (true, true, true, "Detection paused", .warning),
    ])
    func claudeStatusLineTruthTable(
        inFlight: Bool, holdingAwake: Bool, paused: Bool, text: String, severity: PanelSeverity
    ) {
        #expect(MenuStateModel.claudeStatusLine(inFlight: inFlight, holdingAwake: holdingAwake, paused: paused)
                == PanelLine(text: text, severity: severity))
    }

    /// F3: the toggle moved into Details, so the paused row says where it went.
    @Test func pausedRowSaysWhereTheToggleWent() throws {
        let hint = try #require(MenuStateModel.claudeStatusHint(paused: true))
        #expect(hint.contains("Details"))
        #expect(hint.contains("Pause detection"))
        #expect(MenuStateModel.claudeStatusHint(paused: false) == nil)
        #expect(MenuStateModel.pauseDetectionCaption.contains("cannot fire"),
                "the toggle itself warns about the lid-alert consequence")
    }

    // MARK: - F2: the armed line downgrades while detection is paused

    struct LidRow: CustomTestStringConvertible, Sendable {
        let state: LidGuardArmingState
        let outcome: MessageSendOutcome?
        let paused: Bool
        let fragment: String
        let severity: PanelSeverity
        var testDescription: String { "\(state) / \(String(describing: outcome)) / paused=\(paused)" }
    }

    static let everyOutcome: [MessageSendOutcome?] =
        [nil, .accepted, .rejected(403), .timedOutUnconfirmed, .sendFailed("boom")]

    /// Every state × every last outcome × paused on/off (5 × 4 × 2 = 40 rows).
    static let lidRows: [LidRow] = everyOutcome.flatMap { outcome in
        [false, true].flatMap { paused -> [LidRow] in
            let armed: LidRow
            if paused {
                armed = LidRow(state: .armed, outcome: outcome, paused: true,
                               fragment: "armed — but Claude detection is paused; alerts cannot fire", severity: .warning)
            } else {
                switch outcome {
                case .rejected?, .sendFailed?:
                    armed = LidRow(state: .armed, outcome: outcome, paused: false,
                                   fragment: "the last message did not go out", severity: .error)
                default:
                    armed = LidRow(state: .armed, outcome: outcome, paused: false,
                                   fragment: "armed — best-effort push", severity: .nominal)
                }
            }
            return [
                LidRow(state: .off, outcome: outcome, paused: paused, fragment: "Lid alert: off", severity: .nominal),
                LidRow(state: .needsTopic, outcome: outcome, paused: paused, fragment: "set an ntfy topic", severity: .warning),
                LidRow(state: .needsTestSend, outcome: outcome, paused: paused, fragment: "send the test message", severity: .warning),
                armed,
            ]
        }
    }

    @Test(arguments: lidRows)
    func lidAlertStatusTruthTable(_ row: LidRow) {
        let line = MenuStateModel.lidAlertStatus(for: row.state, lastOutcome: row.outcome, detectionPaused: row.paused)
        #expect(line.text.contains(row.fragment), "got: \(line.text)")
        #expect(line.severity == row.severity)
        #expect(line.text == MenuStateModel.lidAlertStatusLine(
            for: row.state, lastOutcome: row.outcome, detectionPaused: row.paused))
    }

    /// The honesty rule itself: an armed guard that CANNOT fire never reads as
    /// plain "armed", whatever the last outcome — and is never nominal.
    @Test func armedButPausedNeverClaimsPlainArmed() {
        for outcome in Self.everyOutcome {
            let line = MenuStateModel.lidAlertStatus(for: .armed, lastOutcome: outcome, detectionPaused: true)
            #expect(line.text.contains("cannot fire"))
            #expect(!line.text.contains("best-effort push"))
            #expect(line.severity != .nominal)
            #expect(MenuStateModel.placement(ofDetailsLine: line.severity) == .topLevel)
        }
    }

    // MARK: - Severity classification of every line that can be a problem

    @Test func hookStatusSeverity() {
        #expect(MenuStateModel.claudeHookStatus(installed: false, everSeen: false, lastSeenSeconds: nil).severity == .warning)
        #expect(MenuStateModel.claudeHookStatus(installed: true, everSeen: false, lastSeenSeconds: nil).severity == .warning)
        #expect(MenuStateModel.claudeHookStatus(installed: true, everSeen: true, lastSeenSeconds: nil).severity == .warning)
        let healthy = MenuStateModel.claudeHookStatus(installed: true, everSeen: true, lastSeenSeconds: 65)
        #expect(healthy == PanelLine(text: "Busy hook: last seen 1m ago", severity: .nominal))
        // A long gap is NOT a problem — Claude may simply not have been used.
        #expect(MenuStateModel.claudeHookStatus(installed: true, everSeen: true, lastSeenSeconds: 9_000_000).severity
                == .nominal)
    }

    @Test func topicAndServerSeverity() {
        #expect(MenuStateModel.lidAlertTopicStatus("napcat-x").severity == .nominal)
        #expect(MenuStateModel.lidAlertTopicStatus("").severity == .nominal, "none set is a setting, not a fault")
        #expect(MenuStateModel.lidAlertTopicStatus("bad/topic").severity == .warning)
        #expect(MenuStateModel.lidAlertServerStatus("https://ntfy.sh").severity == .nominal)
        #expect(MenuStateModel.lidAlertServerStatus("").severity == .nominal)
        #expect(MenuStateModel.lidAlertServerStatus("http://ntfy.sh").severity == .warning)
    }

    @Test func lastSendSeverity() {
        let now = 1_000_000.0
        #expect(MenuStateModel.lidAlertLastSend(outcome: nil, at: nil, now: now).severity == .nominal)
        #expect(MenuStateModel.lidAlertLastSend(outcome: .accepted, at: now, now: now).severity == .nominal)
        #expect(MenuStateModel.lidAlertLastSend(outcome: .timedOutUnconfirmed, at: now, now: now).severity == .warning)
        #expect(MenuStateModel.lidAlertLastSend(outcome: .rejected(403), at: now, now: now).severity == .error)
        #expect(MenuStateModel.lidAlertLastSend(outcome: .sendFailed("boom"), at: now, now: now).severity == .error)
        // Same guard as the caption: no timestamp ⇒ the text says "none", so
        // the severity must not contradict it.
        let untimed = MenuStateModel.lidAlertLastSend(outcome: .rejected(403), at: nil, now: now)
        #expect(untimed.text.contains("none"))
        #expect(untimed.severity == .nominal)
    }

    @Test func topLevelCaptionSeverity() throws {
        #expect(MenuStateModel.stayAwakeCaption(forObserved: true) == nil)
        #expect(MenuStateModel.stayAwakeCaption(forObserved: false) == nil)
        #expect(try #require(MenuStateModel.stayAwakeCaption(forObserved: nil)).severity == .warning)

        #expect(MenuStateModel.lockScreenCaption(available: true) == nil)
        #expect(try #require(MenuStateModel.lockScreenCaption(available: false)).severity == .warning)

        #expect(MenuStateModel.chargeLimitCaption(for: .hidden) == nil)
        #expect(MenuStateModel.chargeLimitCaption(for: .off) == nil)
        #expect(MenuStateModel.chargeLimitCaption(for: .active)?.severity == .nominal)
        #expect(MenuStateModel.chargeLimitCaption(for: .paused)?.severity == .nominal)
        #expect(MenuStateModel.chargeLimitCaption(for: .notSupported)?.severity == .info)
        #expect(MenuStateModel.chargeLimitCaption(for: .setupRequired)?.severity == .warning)
        #expect(MenuStateModel.chargeLimitCaption(for: .error("smc exploded"))
                == PanelLine(text: "smc exploded", severity: .error))

        #expect(MenuStateModel.launchAtLoginCaption(for: .enabled) == nil)
        #expect(MenuStateModel.launchAtLoginCaption(for: .notRegistered) == nil)
        #expect(MenuStateModel.launchAtLoginCaption(for: .requiresApproval)?.severity == .warning)
        #expect(MenuStateModel.launchAtLoginCaption(for: .notFound)?.severity == .warning)
    }

    @Test func chargeLimitValueText() {
        #expect(MenuStateModel.chargeLimitValueText(limit: 90) == "90%")
        #expect(MenuStateModel.chargeLimitValueText(limit: 50) == "50%")
        #expect(MenuStateModel.chargeLimitValueText(limit: 100) == "No limit")
    }

    // MARK: - THE IRON RULE (acceptance criterion 3)

    @Test func placementKeepsOnlyNominalLinesInDetails() {
        for severity in PanelSeverity.allCases {
            #expect(MenuStateModel.placement(ofDetailsLine: severity) == (severity == .nominal ? .details : .topLevel))
        }
    }

    /// Phrases that only ever describe a problem. Used to cross-check the
    /// severity mappings against the strings they classify, in BOTH directions:
    /// a problem string must never be nominal (it would hide in Details), and a
    /// nominal string must never read like a problem.
    static let problemPhrases = ["not installed", "not seen yet", "not usable", "refused", "failed",
                                 "unconfirmed", "Waiting for approval", "not found", "paused"]

    static func readsLikeAProblem(_ text: String) -> Bool {
        problemPhrases.contains { text.contains($0) }
    }

    /// Every line whose HOME is the Details disclosure, across every input that
    /// can produce it. Zero non-nominal lines may stay tucked.
    static func everyDetailsHomeLine() -> [PanelLine] {
        var lines: [PanelLine] = []
        for installed in [false, true] {
            for everSeen in [false, true] {
                for lastSeen: Int? in [nil, 65] {
                    lines.append(MenuStateModel.claudeHookStatus(
                        installed: installed, everSeen: everSeen, lastSeenSeconds: lastSeen))
                }
            }
        }
        for topic in ["", "   ", "napcat-x", "bad/topic", String(repeating: "a", count: 65)] {
            lines.append(MenuStateModel.lidAlertTopicStatus(topic))
        }
        for server in ["", "https://ntfy.sh", "https://ntfy.example.com:8443/", "http://ntfy.sh",
                       "https://ntfy.sh/path", "ftp://ntfy.sh"] {
            lines.append(MenuStateModel.lidAlertServerStatus(server))
        }
        for outcome in everyOutcome {
            for at: Double? in [nil, 999_880] {
                lines.append(MenuStateModel.lidAlertLastSend(outcome: outcome, at: at, now: 1_000_000))
            }
        }
        for status: SMAppService.Status in [.notRegistered, .enabled, .requiresApproval, .notFound] {
            if let caption = MenuStateModel.launchAtLoginCaption(for: status) { lines.append(caption) }
        }
        // The Claude status row is NOT a Details line since the design freeze:
        // only the deleted Status Hero variant tucked it there. It is always
        // top level (its full truth table is `claudeStatusLineTruthTable`).
        return lines
    }

    @Test func noNonNominalLineStaysBehindTheDisclosure() {
        let lines = Self.everyDetailsHomeLine()
        // 8 hook + 5 topic + 6 server + 10 last-send + 2 login captions.
        #expect(lines.count == 31, "vacuity guard — update when the input set changes")
        var surfaced = 0
        for line in lines {
            let problem = Self.readsLikeAProblem(line.text)
            #expect(problem == (line.severity != .nominal),
                    "severity \(line.severity) disagrees with the text: \(line.text)")
            let placement = MenuStateModel.placement(ofDetailsLine: line.severity)
            if problem {
                surfaced += 1
                #expect(placement == .topLevel, "a problem would hide behind Details: \(line.text)")
            } else {
                #expect(placement == .details)
            }
        }
        #expect(surfaced > 10, "vacuity guard — the input set must include problems")
    }

    /// Tier-2 lines are always top level, but they must still be classified:
    /// a degraded lid status is never rendered as a plain caption.
    @Test func degradedLidStatusIsNeverNominal() {
        let degraded = ["set an ntfy topic", "send the test message", "did not go out", "cannot fire"]
        for row in Self.lidRows {
            let line = MenuStateModel.lidAlertStatus(for: row.state, lastOutcome: row.outcome, detectionPaused: row.paused)
            let isDegraded = degraded.contains { line.text.contains($0) }
            #expect(isDegraded == (line.severity != .nominal), "\(line.text)")
        }
    }

    // MARK: - Collapsed badge + icon/VoiceOver for every severity

    @Test func detailsBadgeIsTheWorstSeverity() {
        #expect(MenuStateModel.detailsBadge([]) == .nominal)
        #expect(MenuStateModel.detailsBadge([.nominal, .nominal]) == .nominal)
        #expect(MenuStateModel.detailsBadge([.nominal, .info]) == .info)
        #expect(MenuStateModel.detailsBadge([.warning, .info, .nominal]) == .warning)
        #expect(MenuStateModel.detailsBadge([.warning, .error, .nominal]) == .error)
    }

    /// Never color alone: every non-nominal severity has an icon AND a spoken
    /// prefix; nominal has neither.
    @Test func everyNonNominalSeverityHasAnIconAndASpokenName() {
        for severity in PanelSeverity.allCases {
            let symbol = MenuStateModel.severitySymbol(severity)
            let spoken = MenuStateModel.severityAccessibilityPrefix(severity)
            if severity == .nominal {
                #expect(symbol == nil && spoken == nil)
            } else {
                #expect(symbol != nil && spoken != nil)
            }
        }
    }

    /// OS-drift canary: an SF Symbol that does not resolve renders as NOTHING,
    /// which would silently strip the icon from a warning.
    @Test func everyPanelSymbolResolvesOnThisMachine() {
        #expect(Set(PanelSymbol.all).count == PanelSymbol.all.count)
        for name in PanelSymbol.all {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) does not resolve")
        }
    }

    /// Density pass (curation round 1): every glyph that can sit in the
    /// leading symbol column — the feature symbols, plus the severity symbols
    /// that replace the Claude glyph while it is not nominal — fits the column
    /// at the panel's symbol size, so no symbol crowds into the gap before its
    /// title. OS-drift canary: a wider glyph in a future macOS fails here.
    @Test func leadingSymbolsFitTheSymbolColumn() throws {
        let config = NSImage.SymbolConfiguration(pointSize: PanelMetrics.symbolSize, weight: .regular)
        let leading = [PanelSymbol.stayAwake, PanelSymbol.lockScreen, PanelSymbol.chargeLimit,
                       PanelSymbol.claude, PanelSymbol.lidAlert, PanelSymbol.info, PanelSymbol.warning,
                       PanelSymbol.error]
        for name in leading {
            let image = try #require(NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config), "\(name) does not resolve")
            #expect(image.size.width <= PanelMetrics.symbolColumn,
                    "\(name) is \(image.size.width)pt wide at \(PanelMetrics.symbolSize)pt — wider than the \(PanelMetrics.symbolColumn)pt column")
        }
        #expect(PanelMetrics.symbolSize > 13, "leading symbols are larger than the 13pt body text")
        #expect(PanelMetrics.rowSpacing > PanelMetrics.tight, "rows breathe more than a row and its caption")
        #expect(PanelMetrics.titleIndent == PanelMetrics.symbolColumn + PanelMetrics.regular)
    }

    // MARK: - Model panel state

    @MainActor
    private func withModel(
        detection: ClaudeActivityController? = nil,
        lidGuard: LidGuardController? = nil,
        _ body: (MenuStateModel, UserDefaults, String) throws -> Void
    ) rethrows {
        let suite = "com.muratalkan.napcat.tests.menupanel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let power = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        let limiter = ChargeLimiter(power: power, isAppleSilicon: true, defaults: defaults)
        let model = MenuStateModel(power: power, sleep: SleepStateController(), limiter: limiter,
                                   detection: detection, lidGuard: lidGuard)
        try body(model, defaults, suite)
    }

    /// The disclosure is in-memory UI state: it survives refreshes (menu
    /// reopen) but writes NOTHING to defaults.
    @Test @MainActor func detailsDisclosureIsInMemoryOnly() {
        withModel { model, defaults, suite in
            #expect(!model.detailsExpanded, "starts collapsed")
            model.setDetailsExpanded(true)
            model.refresh()
            #expect(model.detailsExpanded)
            #expect((defaults.persistentDomain(forName: suite) ?? [:]).isEmpty,
                    "toggling Details must persist nothing")
            model.setDetailsExpanded(false)
            #expect(!model.detailsExpanded)
        }
    }

    /// debugBattery wiring (no detection, no lid guard): absent subsystems
    /// cannot raise the badge.
    @Test @MainActor func absentSubsystemsNeverRaiseTheBadge() {
        withModel { model, _, _ in
            #expect(!model.claudeDetectionVisible && !model.lidGuardVisible)
            #expect(model.detailsBadge == .nominal)
        }
    }

    /// F2 end to end: the DISABLED flag read by the detection controller is
    /// threaded into the lid status the panel renders — armed + paused shows
    /// the downgrade, the Claude row says "Detection paused", and the badge
    /// agrees. Removing the flag restores plain "armed".
    @Test @MainActor func pausedDetectionDowngradesTheArmedLineThroughTheModel() throws {
        let markerDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("napcat-menupanel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: markerDir) }
        let detection = ClaudeActivityController(store: StubMarkerStore(), prober: StubProber(),
                                                 assertions: StubAssertions(), markerDirURL: markerDir)
        let lidSuite = "com.muratalkan.napcat.tests.menupanel.lid.\(UUID().uuidString)"
        let lidDefaults = UserDefaults(suiteName: lidSuite)!
        defer { lidDefaults.removePersistentDomain(forName: lidSuite) }
        let harness = LidGuardHarness(defaults: lidDefaults, sender: RecordingMessageSender())
        harness.arm()
        do {
            try withModel(detection: detection, lidGuard: harness.controller) { model, _, _ in
                detection.setPaused(true)
                detection.sample()
                model.refresh()
                #expect(model.claudeStatus == PanelLine(text: "Detection paused", severity: .warning))
                #expect(model.lidStatus.text.contains("cannot fire"))
                #expect(model.lidStatus.severity == .warning)
                #expect(model.detailsBadge >= .warning, "the Pause toggle lives in Details")

                detection.setPaused(false)
                detection.sample()
                model.refresh()
                #expect(model.lidStatus.text.contains("best-effort push"))
                #expect(model.lidStatus.severity == .nominal)
            }
        }
    }
}

// MARK: - Detection stubs (no filesystem scan, no process enumeration, no IOKit)
// Module-internal, so any suite can wire a hermetic detection controller into
// the real model or panel.

final class StubMarkerStore: BusyMarkerStore {
    func markers() -> [BusyMarker] { [] }
    func identifiedMarkers() -> [IdentifiedBusyMarker] { [] }
    func markerDirExists() -> Bool { true }
    func hookLogExists() -> Bool { true }
    func lastActivityEpoch() -> Int? { Int(Date().timeIntervalSince1970) - 60 }
}

final class StubProber: ClaudeProcessProber {
    func probe() -> ProcessProbe { ProcessProbe(enumerationSucceeded: true, confirmedCount: 0, inconclusiveCount: 0) }
}

final class StubAssertions: SleepAssertionReader {
    func claudeIsHoldingAwake() -> Bool { false }
}
