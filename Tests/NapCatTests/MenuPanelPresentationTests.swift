// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import ServiceManagement
import Testing
@testable import NapCat
@testable import NapCatWire

/// Menu-panel redesign (2026-10-18, re-shaped by Panel 2.0): the pure
/// mappings the panel renders — the Claude status (the footer's caption),
/// F2 armed downgrade, severity classification, the iron rule (nothing
/// non-nominal lives only in Settings), the gear badge — plus the model's
/// panel state.
struct MenuPanelPresentationTests {
    // MARK: - Status-as-disclosure: the footer label (2026-10-21)

    /// Full truth table: 4 input combinations. Paused wins over running.
    @Test(arguments: [
        (false, false, "Claude: idle", PanelSeverity.nominal),
        (true, false, "Claude: running", .nominal),
        (false, true, "Claude: paused", .warning),
        (true, true, "Claude: paused", .warning),
    ])
    func claudeFooterLabelTable(inFlight: Bool, paused: Bool, text: String, severity: PanelSeverity) {
        #expect(MenuStateModel.claudeFooterLabel(inFlight: inFlight, paused: paused)
                == PanelLine(text: text, severity: severity))
    }

    /// The footer shares its row with the gear and Quit, so its text is a
    /// SHORT FIXED vocabulary — exactly these three strings, never anything
    /// else (and no caption at all when detection is absent, see
    /// `debugWiringShowsNoClaudeStatus`).
    @Test func theFooterLabelVocabularyIsFixed() {
        var rendered = Set<String>()
        for inFlight in [false, true] {
            for paused in [false, true] {
                rendered.insert(MenuStateModel.claudeFooterLabel(inFlight: inFlight, paused: paused).text)
            }
        }
        #expect(rendered == ["Claude: paused", "Claude: running", "Claude: idle"])
        for text in rendered {
            #expect(text.count <= 15, "'\(text)' is too long for the footer row")
        }
    }

    /// The iron rule for the Claude status: paused is non-nominal, so the
    /// footer renders it with the warning icon (and its tint, lint-locked in
    /// MenuPanelStructureTests) — at top level, always. The old "where to
    /// undo it" hint is gone by design: the Pause toggle sits in Settings ›
    /// Claude, behind the gear beside the label, and explains its own
    /// consequence.
    @Test func thePausedLabelWarnsAtTopLevel() {
        let paused = MenuStateModel.claudeFooterLabel(inFlight: false, paused: true)
        #expect(paused.severity == .warning)
        #expect(MenuStateModel.severitySymbol(paused.severity) == PanelSymbol.warning)
        #expect(MenuStateModel.severityAccessibilityPrefix(paused.severity) == "Warning")
        #expect(Self.readsLikeAProblem(paused.text))
        for inFlight in [false, true] {
            let line = MenuStateModel.claudeFooterLabel(inFlight: inFlight, paused: false)
            #expect(MenuStateModel.severitySymbol(line.severity) == nil)
            #expect(!Self.readsLikeAProblem(line.text))
        }
        #expect(MenuStateModel.pauseDetectionCaption.contains("cannot fire"),
                "the toggle itself warns about the lid-alert consequence")
    }

    /// "Claude is holding the Mac awake" is a Settings › Claude line, present
    /// ONLY while the sleep-assertion reader says so — never invented.
    @Test func theHoldingAwakeLineExistsOnlyWhileHolding() {
        #expect(MenuStateModel.claudeHoldingAwakeLine(holdingAwake: true)
                == PanelLine(text: "Claude is holding the Mac awake", severity: .nominal))
        #expect(MenuStateModel.claudeHoldingAwakeLine(holdingAwake: false) == nil)
    }

    /// Lock Screen availability as a Settings › General line: nominal while
    /// the lock entry point resolved, the unavailable explanation as a
    /// warning (which surfaces) otherwise.
    @Test func theLockScreenStatusLine() {
        let available = MenuStateModel.lockScreenStatus(available: true)
        #expect(available == PanelLine(
            text: "Lock Screen: available — locks and turns the display off; the Mac keeps running",
            severity: .nominal))
        #expect(MenuStateModel.placement(ofSettingsLine: available.severity) == .settings)
        let unavailable = MenuStateModel.lockScreenStatus(available: false)
        #expect(unavailable.severity == .warning)
        #expect(unavailable.text == MenuStateModel.lockScreenPresentation(available: false).caption)
        #expect(MenuStateModel.placement(ofSettingsLine: unavailable.severity) == .topLevel)
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
                               fragment: "Cannot fire — Claude detection is paused", severity: .warning)
            } else {
                switch outcome {
                case .rejected?, .sendFailed?:
                    armed = LidRow(state: .armed, outcome: outcome, paused: false,
                                   fragment: "the last message did not go out", severity: .error)
                default:
                    armed = LidRow(state: .armed, outcome: outcome, paused: false,
                                   fragment: "Armed — a best-effort push", severity: .nominal)
                }
            }
            return [
                LidRow(state: .off, outcome: outcome, paused: paused, fragment: "Off", severity: .nominal),
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
            #expect(line.text.hasPrefix("Cannot fire"))
            #expect(!line.text.contains("best-effort push"))
            #expect(line.severity != .nominal)
            #expect(MenuStateModel.placement(ofSettingsLine: line.severity) == .topLevel)
        }
    }

    // MARK: - Severity classification of every line that can be a problem

    /// H1 truth table (UI audit, owner ruling 2026-11-19): every liveness
    /// class × both alert toggles. A liveness problem is a warning only while
    /// the lid alert or session alerts need the hook; with both off it is the
    /// same text, nominal, in Settings only. The toggles never change the text.
    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func hookStatusSeverity(lidAlertEnabled: Bool, sessionAlertsEnabled: Bool) {
        let problem: PanelSeverity = lidAlertEnabled || sessionAlertsEnabled ? .warning : .nominal
        let rows: [(installed: Bool, everSeen: Bool, lastSeen: Int?, severity: PanelSeverity)] = [
            (false, false, nil, problem),        // not installed (a fresh install)
            (true, false, nil, problem),         // installed, never seen
            (true, true, nil, problem),          // seen, but no readable time
            (true, true, 65, .nominal),          // healthy
            (true, true, 9_000_000, .nominal),   // a long gap is NOT a problem — Claude may simply be unused
        ]
        for row in rows {
            let line = MenuStateModel.claudeHookStatus(
                installed: row.installed, everSeen: row.everSeen, lastSeenSeconds: row.lastSeen,
                lidAlertEnabled: lidAlertEnabled, sessionAlertsEnabled: sessionAlertsEnabled)
            #expect(line.severity == row.severity, "\(row) lid=\(lidAlertEnabled) session=\(sessionAlertsEnabled)")
            #expect(line.text == MenuStateModel.claudeHookLine(
                installed: row.installed, everSeen: row.everSeen, lastSeenSeconds: row.lastSeen))
            #expect(MenuStateModel.placement(ofSettingsLine: line.severity)
                    == (row.severity == .nominal ? .settings : .topLevel))
        }
        #expect(MenuStateModel.claudeHookStatus(installed: true, everSeen: true, lastSeenSeconds: 65,
                                                lidAlertEnabled: lidAlertEnabled,
                                                sessionAlertsEnabled: sessionAlertsEnabled)
                == PanelLine(text: "Busy hook: last seen 1m ago", severity: .nominal))
    }

    // MARK: - S7: is the installed hook copy current?

    struct HookVersionRow: CustomTestStringConvertible, Sendable {
        let installed: Int?
        let markerDirExists: Bool
        let line: PanelLine?
        var testDescription: String { "installed=\(installed.map(String.init) ?? "nil") dir=\(markerDirExists)" }
    }

    static let hookVersionCurrentText = "Busy hook: installed copy is current"
    static let hookVersionOutOfDateText = "Busy hook: installed copy is out of date — re-run "
        + "scripts/install-claude-busy-hook.sh and open a new Claude session"
    static let hookVersionNoStampText = "Busy hook: installed copy has no version stamp — re-run the installer"
    static let hookVersionNewerText = "Busy hook: installed copy is newer than this NapCat — rebuild NapCat to match"

    /// Every input class × marker dir present/absent (expected = 4).
    static let hookVersionRows: [HookVersionRow] = [false, true].flatMap { dir -> [HookVersionRow] in
        [
            HookVersionRow(installed: 4, markerDirExists: dir,
                           line: PanelLine(text: hookVersionCurrentText, severity: .nominal)),
            HookVersionRow(installed: 3, markerDirExists: dir,
                           line: PanelLine(text: hookVersionOutOfDateText, severity: .warning)),
            HookVersionRow(installed: 1, markerDirExists: dir,
                           line: PanelLine(text: hookVersionOutOfDateText, severity: .warning)),
            HookVersionRow(installed: 5, markerDirExists: dir,
                           line: PanelLine(text: hookVersionNewerText, severity: .info)),
            // No stamp: a warning only while the marker dir exists — without
            // it the "not installed" hook line already says to run the installer.
            HookVersionRow(installed: nil, markerDirExists: dir,
                           line: dir ? PanelLine(text: hookVersionNoStampText, severity: .warning) : nil),
        ]
    }

    @Test(arguments: hookVersionRows)
    func hookVersionStatusTable(_ row: HookVersionRow) {
        let line = MenuStateModel.claudeHookVersionStatus(installedVersion: row.installed, expectedVersion: 4,
                                                          markerDirExists: row.markerDirExists)
        #expect(line == row.line)
        if let line {
            // Iron rule: only the current copy may live in Settings alone.
            #expect(MenuStateModel.placement(ofSettingsLine: line.severity)
                    == (line.severity == .nominal ? .settings : .topLevel))
            #expect(Self.readsLikeAProblem(line.text) == (line.severity != .nominal), "\(line.text)")
        }
    }

    /// No duplicate of the hook line: a missing hook (no marker dir, no
    /// readable copy) is said ONCE, by `claudeHookStatus`.
    @Test func aMissingHookIsReportedOnlyByTheHookLine() {
        #expect(MenuStateModel.claudeHookVersionStatus(installedVersion: nil, expectedVersion: 4,
                                                       markerDirExists: false) == nil)
        for alertsOn in [false, true] {
            #expect(MenuStateModel.claudeHookStatus(installed: false, everSeen: false, lastSeenSeconds: nil,
                                                    lidAlertEnabled: alertsOn, sessionAlertsEnabled: false).text
                    .contains("not installed"))
        }
        #expect(Self.hookVersionRows.count == 10)
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

    // MARK: - Track C: session alerts (finish + waiting pushes)

    struct SessionRow: CustomTestStringConvertible, Sendable {
        let state: FinishAlertDisplayState
        let outcome: MessageSendOutcome?
        let text: String
        let severity: PanelSeverity
        /// A session outcome always carries its timestamp. The grammar table
        /// has NO lid-lane send, so no row in it can count as recovered (the
        /// recovery rule has its own table below).
        var outcomeAt: Double? { outcome == nil ? nil : MenuPanelPresentationTests.sessionSendAt }
        var testDescription: String { "\(state) / \(String(describing: outcome))" }
    }

    static let sessionSendAt = 1_000_000.0

    static let sessionOutcomes: [MessageSendOutcome?] =
        [nil, .accepted, .timedOutUnconfirmed, .rejected(429), .sendFailed("boom"), .rejected(403)]

    static let sessionRateLimitedText =
        "Held — ntfy is rate-limiting this Mac; alerts are folded for a while"

    /// Every display state × every last outcome (6 × 6 = 36 rows), exact
    /// strings. Only `.armed` reads the last outcome. B-1: a 429 is the
    /// rate-limit WARNING (alerts are held, not lost — and "re-run Send test
    /// message" would only burn quota); every other refusal / failure keeps
    /// the generic error.
    static let sessionRows: [SessionRow] = sessionOutcomes.flatMap { outcome -> [SessionRow] in
        let armed: SessionRow
        switch outcome {
        case .rejected(429)?:
            armed = SessionRow(state: .armed, outcome: outcome, text: sessionRateLimitedText, severity: .warning)
        case .rejected?, .sendFailed?:
            armed = SessionRow(state: .armed, outcome: outcome,
                               text: "Failed — the last message did not go out; re-run Send test message in Settings",
                               severity: .error)
        default:
            armed = SessionRow(state: .armed, outcome: outcome,
                               text: "Armed — a push when a Claude session finishes or waits for you",
                               severity: .nominal)
        }
        return [
            SessionRow(state: .off, outcome: outcome, text: "Off", severity: .nominal),
            SessionRow(state: .needsTopic, outcome: outcome,
                       text: "Not armed — set an ntfy topic in Settings", severity: .warning),
            SessionRow(state: .needsTestSend, outcome: outcome,
                       text: "Not armed — send the test message in Settings to check your phone gets it", severity: .warning),
            SessionRow(state: .paused, outcome: outcome,
                       text: "Cannot fire — Claude detection is paused",
                       severity: .warning),
            SessionRow(state: .hookNotInstalled, outcome: outcome,
                       text: "Not armed — install the Claude busy hook first (see below)",
                       severity: .warning),
            armed,
        ]
    }

    @Test func sessionRowsCoverEveryStateAndOutcome() {
        #expect(Self.sessionRows.count == 36, "vacuity guard — 6 states × 6 outcomes")
        let armedSeverities = Set(Self.sessionRows.filter { $0.state == .armed }.map(\.severity))
        #expect(armedSeverities == [.nominal, .warning, .error], "armed shows healthy, held (429) and failed lines")
    }

    @Test(arguments: sessionRows)
    func sessionAlertsStatusGrammarTable(_ row: SessionRow) {
        #expect(MenuStateModel.finishAlertStatusLine(
            for: row.state, lastOutcome: row.outcome, lastOutcomeAt: row.outcomeAt,
            lidLastOutcome: nil, lidLastOutcomeAt: nil) == row.text)
        #expect(MenuStateModel.finishAlertStatus(
            for: row.state, lastOutcome: row.outcome, lastOutcomeAt: row.outcomeAt,
            lidLastOutcome: nil, lidLastOutcomeAt: nil).text == row.text)
    }

    static let sessionDegradedPhrases = ["set an ntfy topic", "send the test message", "Cannot fire",
                                         "install the Claude busy hook", "did not go out", "rate-limiting"]

    /// Severity per row, cross-checked against the text in BOTH directions (a
    /// degraded line is never nominal; a nominal one never reads degraded),
    /// and only a nominal armed line may claim "armed".
    @Test(arguments: sessionRows)
    func sessionAlertsStatusSeverityTable(_ row: SessionRow) {
        let line = MenuStateModel.finishAlertStatus(
            for: row.state, lastOutcome: row.outcome, lastOutcomeAt: row.outcomeAt,
            lidLastOutcome: nil, lidLastOutcomeAt: nil)
        #expect(line.severity == row.severity)
        #expect(Self.sessionDegradedPhrases.contains { line.text.contains($0) } == (line.severity != .nominal),
                "\(line.text)")
        #expect(line.text.hasPrefix("Armed —") == (row.state == .armed && row.severity == .nominal))
    }

    // MARK: Alert healing (issue #23): the offline warning owns the slot

    static let sessionAlertsOfflineText =
        "Offline — session alerts are held until the connection returns; lid alerts may be missed"
    static let sessionAlertsArmedText = "Armed — a push when a Claude session finishes or waits for you"

    struct SlotRow: CustomTestStringConvertible, Sendable {
        let id: String
        let offline: Bool
        let state: FinishAlertDisplayState
        let outcome: MessageSendOutcome?
        let expected: PanelLine
        var testDescription: String { id }
    }

    /// Precedence in the session-alerts slot: offline > 429 hold > nominal —
    /// and no offline line at all while healing is not offline (disarmed).
    static let slotRows: [SlotRow] = [
        SlotRow(id: "P1 offline beats the 429-hold caption", offline: true, state: .armed, outcome: .rejected(429),
                expected: PanelLine(text: sessionAlertsOfflineText, severity: .warning)),
        SlotRow(id: "P2 the 429-hold caption beats nominal", offline: false, state: .armed, outcome: .rejected(429),
                expected: PanelLine(text: sessionRateLimitedText, severity: .warning)),
        SlotRow(id: "P3 nominal when neither", offline: false, state: .armed, outcome: .accepted,
                expected: PanelLine(text: sessionAlertsArmedText, severity: .nominal)),
        SlotRow(id: "P4 offline beats nominal", offline: true, state: .armed, outcome: .accepted,
                expected: PanelLine(text: sessionAlertsOfflineText, severity: .warning)),
        SlotRow(id: "P5 offline beats a failed-send downgrade", offline: true, state: .armed,
                outcome: .sendFailed("this Mac had no internet connection"),
                expected: PanelLine(text: sessionAlertsOfflineText, severity: .warning)),
        SlotRow(id: "P6 lid-only mode (session alerts off): the same one line", offline: true, state: .off,
                outcome: nil, expected: PanelLine(text: sessionAlertsOfflineText, severity: .warning)),
        SlotRow(id: "P7 not offline (healing disarmed) ⇒ no offline line", offline: false, state: .off, outcome: nil,
                expected: PanelLine(text: "Off", severity: .nominal)),
        SlotRow(id: "P8 not offline: a failed send keeps its error", offline: false, state: .armed,
                outcome: .sendFailed("this Mac had no internet connection"),
                expected: PanelLine(text: "Failed — the last message did not go out; re-run Send test message in Settings",
                                    severity: .error)),
    ]

    @Test(arguments: slotRows)
    func sessionAlertsSlotPrecedenceTable(_ row: SlotRow) {
        let status = MenuStateModel.finishAlertStatus(
            for: row.state, lastOutcome: row.outcome, lastOutcomeAt: row.outcome == nil ? nil : Self.sessionSendAt,
            lidLastOutcome: nil, lidLastOutcomeAt: nil)
        #expect(MenuStateModel.sessionAlertsSlot(offline: row.offline, status: status) == row.expected, "\(row.id)")
    }

    /// ONE fixed, neutral line: a WARNING (so it can only render at top level
    /// — the iron rule), the exact text, and nothing variable in it.
    @Test func theOfflineWarningIsOneFixedTopLevelWarning() {
        let line = MenuStateModel.sessionAlertsOfflineLine
        #expect(line == PanelLine(text: Self.sessionAlertsOfflineText, severity: .warning))
        #expect(MenuStateModel.placement(ofSettingsLine: line.severity) == .topLevel)
        #expect(MenuStateModel.severitySymbol(line.severity) == PanelSymbol.warning, "icon + text, never color alone")
        #expect(!line.text.contains { $0.isNumber }, "no count, minute or address in the fixed line")
        for secret in ["ntfy.sh", "https", "topic", "Topic"] {
            #expect(!line.text.contains(secret))
        }
    }

    /// PLACEMENT LINT: the offline warning reaches the panel ONLY through the
    /// session-alerts slot (`model.finishAlertStatus`, rendered once, as the
    /// Session alerts row's top-level caption inside the Alerts card) — no
    /// view names the mirror or the line, no surfaced twin renders the slot,
    /// and the model's slot really applies the precedence.
    static func offlinePlacementFailures(_ sources: [(name: String, text: String)]) -> [String] {
        var failures: [String] = []
        let owners: [String: Set<String>] = [
            "sessionAlertsOfflineLine": ["MenuStateModel.swift"],
            "sessionAlertsOffline": ["MenuStateModel.swift"],
            "connectivityOffline": ["MenuStateModel.swift", "FinishAlertController.swift"],
        ]
        for (token, allowed) in owners {
            for (name, text) in sources where text.contains(token) && !allowed.contains(name) {
                failures.append("'\(token)' in \(name) — the offline line reaches the panel only via the slot")
            }
        }
        let views = sources.filter { MenuPanelStructureTests.viewFiles.contains($0.name) }.map(\.text)
            .joined(separator: "\n")
        if views.components(separatedBy: "model.finishAlertStatus").count - 1 != 1 {
            failures.append("model.finishAlertStatus must be rendered exactly once")
        }
        let layout = MenuPanelStructureTests.structChunk(MenuPanelStructureTests.layout,
                                                         in: sources.first { $0.name == MenuPanelStructureTests.layoutFile }?.text ?? "") ?? ""
        let alertsCard = MenuPanelStructureTests.cardBlocks(in: layout).last.map { layout[$0] } ?? ""
        if !alertsCard.contains("indentedCaption(model.finishAlertStatus)") {
            failures.append("the layout must render the slot as the Session alerts row's caption in the Alerts card")
        }
        let panelView = sources.first { $0.name == "MenuPanelView.swift" }?.text ?? ""
        for twin in ["ClaudeSurfacedLines", "LidAlertSurfacedLines", "SessionAlertsSurfacedLines", "GeneralSurfacedLines"] {
            let chunk = MenuPanelStructureTests.structChunk(twin, in: panelView) ?? ""
            if chunk.isEmpty || chunk.contains("finishAlertStatus") {
                failures.append("\(twin) must never render the session-alerts slot")
            }
        }
        let model = sources.first { $0.name == "MenuStateModel.swift" }?.text ?? ""
        if !model.contains("Self.sessionAlertsSlot(offline: sessionAlertsOffline, status: finishAlertStatusWithoutOffline)") {
            failures.append("the model's finishAlertStatus must apply the offline precedence")
        }
        return failures
    }

    @Test func theOfflineWarningOnlyRendersThroughTheTopLevelSessionAlertsSlot() throws {
        let sources = try LidGuardStructureTests.swiftSources()
        #expect(Self.offlinePlacementFailures(sources).isEmpty, "\(Self.offlinePlacementFailures(sources))")
        func mutate(_ name: String, _ transform: (String) -> String) -> [(name: String, text: String)] {
            sources.map { $0.name == name ? ($0.name, transform($0.text)) : $0 }
        }
        let twinAnchor = "        SurfacedLine(line: model.finishAlertLastSend(now: Date().timeIntervalSince1970))\n"
        let canaries: [(String, [(name: String, text: String)])] = [
            ("a view names the mirror", mutate("MenuPanelView.swift") {
                $0 + "\nstruct Canary: View { @ObservedObject var model: MenuStateModel\n"
                    + "    var body: some View { if model.sessionAlertsOffline { Text(\"x\") } } }" }),
            ("a view renders the line directly", mutate("MenuPanelVariants.swift") {
                $0 + "\nlet canary = MenuStateModel.sessionAlertsOfflineLine" }),
            ("a surfaced twin renders the slot", mutate("MenuPanelView.swift") {
                $0.replacingOccurrences(of: twinAnchor,
                                        with: twinAnchor + "        SurfacedLine(line: model.finishAlertStatus)\n") }),
            ("the slot leaves the Alerts card", mutate("MenuPanelVariants.swift") {
                $0.replacingOccurrences(of: "indentedCaption(model.finishAlertStatus)", with: "EmptyView()") }),
            ("the slot loses its precedence", mutate("MenuStateModel.swift") {
                $0.replacingOccurrences(
                    of: "Self.sessionAlertsSlot(offline: sessionAlertsOffline, status: finishAlertStatusWithoutOffline)",
                    with: "finishAlertStatusWithoutOffline") }),
            ("the menu owner reads the flag", mutate("MenuContentView.swift") {
                $0 + "\nlet canary = finishAlert?.connectivityOffline" }),
        ]
        for (name, mutant) in canaries {
            #expect(mutant.map(\.text) != sources.map(\.text), "canary setup '\(name)'")
            #expect(!Self.offlinePlacementFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: Session caption recovery (C6)

    /// The failed-send caption tells the user to re-run the test send, so an
    /// ACCEPTED lid-lane send (that test send, or a lid alert) STRICTLY LATER
    /// than the failed session send clears the armed downgrade. Nothing else
    /// does. The "Last session alert" History line never changes.
    struct SessionRecoveryRow: CustomTestStringConvertible, Sendable {
        let id: String
        var state: FinishAlertDisplayState = .armed
        let outcome: MessageSendOutcome?
        let outcomeAt: Double?
        let lidOutcome: MessageSendOutcome?
        let lidOutcomeAt: Double?
        let text: String
        let severity: PanelSeverity
        var testDescription: String { id }
    }

    static let sessionArmedText = "Armed — a push when a Claude session finishes or waits for you"
    static let sessionFailedText = "Failed — the last message did not go out; re-run Send test message in Settings"

    static let sessionRecoveryRows: [SessionRecoveryRow] = {
        let t = sessionSendAt
        return [
            SessionRecoveryRow(id: "R1 failed session send, then a LATER accepted test send ⇒ armed",
                               outcome: .sendFailed("boom"), outcomeAt: t, lidOutcome: .accepted, lidOutcomeAt: t + 60,
                               text: sessionArmedText, severity: .nominal),
            SessionRecoveryRow(id: "R2 refused (429) session send, then a later accepted test send ⇒ armed",
                               outcome: .rejected(429), outcomeAt: t, lidOutcome: .accepted, lidOutcomeAt: t + 1,
                               text: sessionArmedText, severity: .nominal),
            SessionRecoveryRow(id: "R3 accepted test send BEFORE the failure ⇒ still error",
                               outcome: .sendFailed("boom"), outcomeAt: t, lidOutcome: .accepted, lidOutcomeAt: t - 60,
                               text: sessionFailedText, severity: .error),
            SessionRecoveryRow(id: "R4 equal timestamps ⇒ still error (strictly later only)",
                               outcome: .rejected(403), outcomeAt: t, lidOutcome: .accepted, lidOutcomeAt: t,
                               text: sessionFailedText, severity: .error),
            SessionRecoveryRow(id: "R5 later lid send only unconfirmed ⇒ still error",
                               outcome: .sendFailed("boom"), outcomeAt: t, lidOutcome: .timedOutUnconfirmed,
                               lidOutcomeAt: t + 60, text: sessionFailedText, severity: .error),
            SessionRecoveryRow(id: "R6 later lid send refused ⇒ still error",
                               outcome: .rejected(403), outcomeAt: t, lidOutcome: .rejected(429), lidOutcomeAt: t + 60,
                               text: sessionFailedText, severity: .error),
            SessionRecoveryRow(id: "R7 later lid send failed ⇒ still error",
                               outcome: .sendFailed("boom"), outcomeAt: t, lidOutcome: .sendFailed("boom"),
                               lidOutcomeAt: t + 60, text: sessionFailedText, severity: .error),
            SessionRecoveryRow(id: "R8 accepted lid send without a timestamp ⇒ still error",
                               outcome: .sendFailed("boom"), outcomeAt: t, lidOutcome: .accepted, lidOutcomeAt: nil,
                               text: sessionFailedText, severity: .error),
            SessionRecoveryRow(id: "R9 failed session send without a timestamp ⇒ still error",
                               outcome: .sendFailed("boom"), outcomeAt: nil, lidOutcome: .accepted,
                               lidOutcomeAt: t + 60, text: sessionFailedText, severity: .error),
            SessionRecoveryRow(id: "R10 recovery never overrides a non-armed state", state: .paused,
                               outcome: .sendFailed("boom"), outcomeAt: t, lidOutcome: .accepted, lidOutcomeAt: t + 60,
                               text: "Cannot fire — Claude detection is paused",
                               severity: .warning),
            SessionRecoveryRow(id: "R11 a failed LID send never downgrades a healthy session line",
                               outcome: .accepted, outcomeAt: t, lidOutcome: .sendFailed("boom"), lidOutcomeAt: t + 60,
                               text: sessionArmedText, severity: .nominal),
            SessionRecoveryRow(id: "R12 an unconfirmed session send stays nominal whatever the lid did",
                               outcome: .timedOutUnconfirmed, outcomeAt: t, lidOutcome: .rejected(403),
                               lidOutcomeAt: t + 60, text: sessionArmedText, severity: .nominal),
            // B-1: a 429 reads "held", a WARNING — same recovery rule (R2).
            SessionRecoveryRow(id: "R13 refused (429) session send, no lid send ⇒ rate-limit warning",
                               outcome: .rejected(429), outcomeAt: t, lidOutcome: nil, lidOutcomeAt: nil,
                               text: sessionRateLimitedText, severity: .warning),
            SessionRecoveryRow(id: "R14 429, accepted test send BEFORE it ⇒ still the rate-limit warning",
                               outcome: .rejected(429), outcomeAt: t, lidOutcome: .accepted, lidOutcomeAt: t - 60,
                               text: sessionRateLimitedText, severity: .warning),
            SessionRecoveryRow(id: "R15 429, equal timestamps ⇒ still the rate-limit warning (strictly later only)",
                               outcome: .rejected(429), outcomeAt: t, lidOutcome: .accepted, lidOutcomeAt: t,
                               text: sessionRateLimitedText, severity: .warning),
            SessionRecoveryRow(id: "R16 429, later lid send refused too ⇒ still the rate-limit warning",
                               outcome: .rejected(429), outcomeAt: t, lidOutcome: .rejected(429), lidOutcomeAt: t + 60,
                               text: sessionRateLimitedText, severity: .warning),
            SessionRecoveryRow(id: "R17 429 never overrides a non-armed state", state: .hookNotInstalled,
                               outcome: .rejected(429), outcomeAt: t, lidOutcome: nil, lidOutcomeAt: nil,
                               text: "Not armed — install the Claude busy hook first (see below)",
                               severity: .warning),
        ]
    }()

    @Test(arguments: sessionRecoveryRows)
    func sessionAlertsCaptionRecoveryTable(_ row: SessionRecoveryRow) {
        let line = MenuStateModel.finishAlertStatus(
            for: row.state, lastOutcome: row.outcome, lastOutcomeAt: row.outcomeAt,
            lidLastOutcome: row.lidOutcome, lidLastOutcomeAt: row.lidOutcomeAt)
        #expect(line == PanelLine(text: row.text, severity: row.severity))
        #expect(line.text == MenuStateModel.finishAlertStatusLine(
            for: row.state, lastOutcome: row.outcome, lastOutcomeAt: row.outcomeAt,
            lidLastOutcome: row.lidOutcome, lidLastOutcomeAt: row.lidOutcomeAt))
        // Same text ⇔ severity cross-check as the grammar table.
        #expect(Self.sessionDegradedPhrases.contains { line.text.contains($0) } == (line.severity != .nominal))
        #expect(line.text.hasPrefix("Armed —") == (row.state == .armed && row.severity == .nominal))
        // The History line takes no lid input: a refused / failed
        // session send stays an error there even once the caption recovered.
        let history = MenuStateModel.finishAlertLastSend(outcome: row.outcome, kind: Self.finishedKind,
                                                         at: row.outcomeAt, now: Self.sessionSendAt + 120)
        #expect(history.severity == MenuStateModel.finishAlertLastSendSeverity(row.outcome, at: row.outcomeAt))
        // B-1 (fact vs state): the caption may say "held" (a warning), but the
        // history line still reports the 429 refusal as an error.
        if row.outcome == .rejected(429), row.outcomeAt != nil {
            #expect(history.severity == .error)
            #expect(history.text.contains("(HTTP 429)"))
        }
    }

    @Test func sessionRecoveryRowsAreUniqueAndCoverBothVerdicts() {
        #expect(Self.sessionRecoveryRows.count == 17)
        #expect(Set(Self.sessionRecoveryRows.map(\.id)).count == Self.sessionRecoveryRows.count)
        let downgradable = Self.sessionRecoveryRows.filter {
            $0.state == .armed && ($0.outcome == .sendFailed("boom") || $0.outcome == .rejected(403))
        }
        #expect(downgradable.contains { $0.severity == .nominal } && downgradable.contains { $0.severity == .error },
                "vacuity guard — the table must show recovery AND non-recovery")
        // B-1: the 429 caption recovers by the same rule (R2) and otherwise warns.
        let rateLimited = Self.sessionRecoveryRows.filter { $0.state == .armed && $0.outcome == .rejected(429) }
        #expect(rateLimited.contains { $0.severity == .nominal } && rateLimited.contains { $0.severity == .warning },
                "vacuity guard — the 429 rows must show recovery AND the held warning")
        #expect(!rateLimited.contains { $0.severity == .error }, "an armed 429 caption is never an error")
    }

    struct SessionLastSendRow: CustomTestStringConvertible, Sendable {
        let name: String
        let outcome: MessageSendOutcome?
        let kind: LidGuardMessageKind?
        let at: Double?
        let text: String
        let severity: PanelSeverity
        var testDescription: String { name }
    }

    static let lastSendNow = 1_000_000.0
    static let finishedKind = LidGuardMessageKind.sessionFinished(minutes: 42, folded: 1, stillWorking: 0)
    static let waitingKind = LidGuardMessageKind.needsAttention(minutes: 12, stillWorking: 1)

    static let sessionLastSendRows: [SessionLastSendRow] = [
        SessionLastSendRow(name: "none", outcome: nil, kind: nil, at: nil,
                           text: "Last session alert: none since NapCat started", severity: .nominal),
        SessionLastSendRow(name: "accepted finished", outcome: .accepted, kind: finishedKind, at: lastSendNow - 120,
                           text: "Last session alert: accepted by ntfy 2m ago (finished)", severity: .nominal),
        SessionLastSendRow(name: "accepted waiting", outcome: .accepted, kind: waitingKind, at: lastSendNow - 120,
                           text: "Last session alert: accepted by ntfy 2m ago (waiting)", severity: .nominal),
        SessionLastSendRow(name: "unconfirmed", outcome: .timedOutUnconfirmed, kind: finishedKind, at: lastSendNow - 120,
                           text: "Last session alert: unconfirmed 2m ago (finished) — it may still have gone out",
                           severity: .warning),
        SessionLastSendRow(name: "rejected 429", outcome: .rejected(429), kind: finishedKind, at: lastSendNow - 120,
                           text: "Last session alert: refused by the server 2m ago (finished) (HTTP 429) — check the topic and server",
                           severity: .error),
        SessionLastSendRow(name: "failed", outcome: .sendFailed("boom"), kind: waitingKind, at: lastSendNow - 120,
                           text: "Last session alert: failed 2m ago (waiting) — boom", severity: .error),
        // Same guard as the lid line: no timestamp ⇒ "none", and nominal.
        SessionLastSendRow(name: "untimed rejected", outcome: .rejected(429), kind: finishedKind, at: nil,
                           text: "Last session alert: none since NapCat started", severity: .nominal),
        // The lid kinds never reach the finish controller; they get no label.
        SessionLastSendRow(name: "lid kind unlabelled", outcome: .accepted, kind: .lidAlert(busySessionCount: 1),
                           at: lastSendNow - 120, text: "Last session alert: accepted by ntfy 2m ago", severity: .nominal),
        SessionLastSendRow(name: "test kind unlabelled", outcome: .accepted, kind: .test,
                           at: lastSendNow - 120, text: "Last session alert: accepted by ntfy 2m ago", severity: .nominal),
    ]

    /// FA-4 (panel half): a refused (429) or failed last session send is an
    /// error and SURFACES in the panel; unconfirmed is a warning and surfaces too.
    @Test(arguments: sessionLastSendRows)
    func sessionAlertsLastSendTable(_ row: SessionLastSendRow) {
        let line = MenuStateModel.finishAlertLastSend(outcome: row.outcome, kind: row.kind, at: row.at,
                                                      now: Self.lastSendNow)
        #expect(line == PanelLine(text: row.text, severity: row.severity))
        #expect(line.text == MenuStateModel.finishAlertLastSendCaption(outcome: row.outcome, kind: row.kind,
                                                                       at: row.at, now: Self.lastSendNow))
        #expect(MenuStateModel.placement(ofSettingsLine: line.severity)
                == (row.severity == .nominal ? .settings : .topLevel))
    }

    /// Mirrors the lid mapping exactly: same severity for every outcome, with
    /// and without a timestamp.
    @Test func sessionLastSendSeverityMatchesTheLidMapping() {
        for outcome in Self.everyOutcome {
            for at: Double? in [nil, 999_880] {
                #expect(MenuStateModel.finishAlertLastSendSeverity(outcome, at: at)
                        == MenuStateModel.lidAlertLastSendSeverity(outcome, at: at))
            }
        }
    }

    @Test func topLevelCaptionSeverity() throws {
        #expect(MenuStateModel.stayAwakeCaption(forObserved: true) == nil)
        #expect(MenuStateModel.stayAwakeCaption(forObserved: false) == nil)
        #expect(try #require(MenuStateModel.stayAwakeCaption(forObserved: nil)).severity == .warning)

        // (The Lock Screen line became a Settings-home line —
        // `theLockScreenStatusLine`.)

        #expect(MenuStateModel.chargeLimitCaption(for: .hidden) == nil)
        #expect(MenuStateModel.chargeLimitCaption(for: .off) == nil)
        #expect(MenuStateModel.chargeLimitCaption(for: .active)?.severity == .nominal)
        #expect(MenuStateModel.chargeLimitCaption(for: .paused)?.severity == .nominal)
        #expect(MenuStateModel.chargeLimitCaption(for: .notSupported)?.severity == .info)
        #expect(MenuStateModel.chargeLimitCaption(for: .setupRequired)?.severity == .warning)
        // #58 → #84: no caption at all, not even a calm info line — the row
        // itself is hidden, and Settings › General carries the one plain note.
        #expect(MenuStateModel.chargeLimitCaption(for: .controlUnavailable) == nil)
        #expect(MenuStateModel.chargeLimitCaption(for: .error("smc exploded"))
                == PanelLine(text: "smc exploded", severity: .error))

        #expect(MenuStateModel.launchAtLoginCaption(for: .enabled) == nil)
        #expect(MenuStateModel.launchAtLoginCaption(for: .notRegistered) == nil)
        #expect(MenuStateModel.launchAtLoginCaption(for: .requiresApproval)?.severity == .warning)
        #expect(MenuStateModel.launchAtLoginCaption(for: .notFound)?.severity == .warning)
    }

    /// Canon C2 (slice P): every ROW caption — the Stay Awake slot, the
    /// Charge Limit row's, the Lid alert's and the Session alerts' slot, the
    /// surfaced Launch at Login row's — is a fragment with its state word
    /// first: it opens with one word or phrase from this CLOSED list, never
    /// repeats its row's title as a prefix, and ends without a period. (The
    /// charge-limit `.error` message is the limiter's own text, outside the
    /// closed vocabulary. Lines that surface below the cards keep a "Subject:"
    /// label — "Busy hook:", "Topic:" — since no row title sits above them.)
    static let rowCaptionStateWords = ["Off", "Armed", "Not armed", "Cannot fire", "Failed", "Held", "Offline",
                                       "Unknown", "Turning on…", "Charging", "Paused", "Setup needed", "Unavailable",
                                       "Waiting for approval", "Not found", "Local only", "Not listening", "Not paired"]

    static func everyRowCaption() -> [PanelLine] {
        var lines: [PanelLine] = []
        for observed: Bool? in [nil, false, true] {
            for phase in [StayAwakeTurnOnPhase.idle, .waiting, .showing] {
                if let line = MenuStateModel.stayAwakeSlot(observed: observed, turnOn: phase) { lines.append(line) }
            }
        }
        for state: ChargeLimitFeatureState in [.hidden, .off, .notSupported, .setupRequired, .controlUnavailable,
                                               .active, .paused] {
            if let line = MenuStateModel.chargeLimitCaption(for: state) { lines.append(line) }
        }
        lines += lidRows.map { MenuStateModel.lidAlertStatus(for: $0.state, lastOutcome: $0.outcome, detectionPaused: $0.paused) }
        for row in sessionRows {
            let status = MenuStateModel.finishAlertStatus(for: row.state, lastOutcome: row.outcome, lastOutcomeAt: row.outcomeAt,
                                                          lidLastOutcome: nil, lidLastOutcomeAt: nil)
            lines += [status, MenuStateModel.sessionAlertsSlot(offline: true, status: status)]
        }
        for status: SMAppService.Status in [.notRegistered, .enabled, .requiresApproval, .notFound] {
            if let caption = MenuStateModel.launchAtLoginCaption(for: status) { lines.append(caption) }
        }
        // F4 slice S2: the Remote approvals row, every phase — and (#205)
        // every answer of what holds remote answers.
        for phase: RemoteApprovalsPhase in [.off, .listening, .unavailable] {
            for hold: RemoteApprovalsHold? in [nil, .off, .notPaired, .noRecordPath] {
                lines.append(MenuStateModel.remoteApprovalsStatus(phase: phase, hold: hold))
            }
        }
        return lines
    }

    @Test func rowCaptionsAreStateFirstFragments() {
        let lines = Self.everyRowCaption()
        // Charge Limit contributes 4 (#84: `.controlUnavailable` has no caption — its row is hidden).
        #expect(lines.count == 4 + 4 + 40 + 72 + 2 + 12, "vacuity guard — update when the input set changes")
        for line in lines {
            #expect(Self.rowCaptionStateWords.contains { line.text == $0 || line.text.hasPrefix($0 + " ") },
                    "'\(line.text)' does not open with a state word")
            #expect(!line.text.hasSuffix("."), "'\(line.text)' is a sentence, not a fragment")
            for title in ["Stay Awake", "Charge Limit", "Charge limit", "Lid alert", "Session alerts", "Launch at Login",
                          "Login item", "Remote approvals"] {
                #expect(!line.text.hasPrefix(title), "'\(line.text)' repeats its row title")
            }
        }
        // Every state word is used: the closed list holds no dead entry.
        for word in Self.rowCaptionStateWords {
            #expect(lines.contains { $0.text == word || $0.text.hasPrefix(word + " ") }, "'\(word)' is never used")
        }
    }

    @Test func chargeLimitValueText() {
        #expect(MenuStateModel.chargeLimitValueText(limit: 90) == "90%")
        #expect(MenuStateModel.chargeLimitValueText(limit: 50) == "50%")
        #expect(MenuStateModel.chargeLimitValueText(limit: 100) == "No limit")
    }

    // MARK: - THE IRON RULE (acceptance criterion 3)

    @Test func placementKeepsOnlyNominalLinesInSettingsAlone() {
        for severity in PanelSeverity.allCases {
            #expect(MenuStateModel.placement(ofSettingsLine: severity) == (severity == .nominal ? .settings : .topLevel))
        }
    }

    /// Phrases that only ever describe a problem. Used to cross-check the
    /// severity mappings against the strings they classify, in BOTH directions:
    /// a problem string must never be nominal (it would live only in Settings), and a
    /// nominal string must never read like a problem.
    static let problemPhrases = ["not installed", "not seen yet", "not usable", "refused", "failed",
                                 "unconfirmed", "Waiting for approval", "Not found", "paused", "unavailable",
                                 "out of date", "no version stamp", "newer than"]

    static func readsLikeAProblem(_ text: String) -> Bool {
        problemPhrases.contains { text.contains($0) }
    }

    /// H1 (owner ruling 2026-11-19) — the ONE sanctioned exception to "a
    /// problem string is never nominal": the hook-liveness texts while
    /// neither alert needs the hook. Nothing is broken then, so the line is a
    /// tucked fact; the same text warns at top level as soon as either alert
    /// is on (`hookStatusSeverity`). The lint counts these lines exactly, so
    /// the exception cannot quietly widen.
    static let quietHookTexts: Set<String> = [
        MenuStateModel.claudeHookLine(installed: false, everSeen: false, lastSeenSeconds: nil),
        MenuStateModel.claudeHookLine(installed: true, everSeen: false, lastSeenSeconds: nil),
    ]

    /// Every line whose HOME is a Settings pane, across every input that can
    /// produce it. Zero non-nominal lines may live there alone.
    static func everySettingsHomeLine() -> [PanelLine] {
        var lines: [PanelLine] = []
        // H1: every liveness input × both alert toggles (8 × 4).
        for installed in [false, true] {
            for everSeen in [false, true] {
                for lastSeen: Int? in [nil, 65] {
                    for (lid, session) in [(false, false), (true, false), (false, true), (true, true)] {
                        lines.append(MenuStateModel.claudeHookStatus(
                            installed: installed, everSeen: everSeen, lastSeenSeconds: lastSeen,
                            lidAlertEnabled: lid, sessionAlertsEnabled: session))
                    }
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
        // Track C: the last session alert lives in the same History group.
        for outcome in everyOutcome {
            for at: Double? in [nil, 999_880] {
                for kind: LidGuardMessageKind? in [nil, finishedKind, waitingKind] {
                    lines.append(MenuStateModel.finishAlertLastSend(outcome: outcome, kind: kind, at: at,
                                                                    now: 1_000_000))
                }
            }
        }
        for status: SMAppService.Status in [.notRegistered, .enabled, .requiresApproval, .notFound] {
            if let caption = MenuStateModel.launchAtLoginCaption(for: status) { lines.append(caption) }
        }
        // 2026-10-21 declutter: the awake fact and the Lock Screen
        // availability became Settings-home lines.
        for holding in [false, true] {
            if let line = MenuStateModel.claudeHoldingAwakeLine(holdingAwake: holding) { lines.append(line) }
        }
        for available in [false, true] {
            lines.append(MenuStateModel.lockScreenStatus(available: available))
        }
        // S7: the installed hook copy's version, every class × dir state.
        for row in hookVersionRows {
            if let line = MenuStateModel.claudeHookVersionStatus(
                installedVersion: row.installed, expectedVersion: 4, markerDirExists: row.markerDirExists) {
                lines.append(line)
            }
        }
        // F3 stage 1: the phone transport line (toggle on; off is no line),
        // entitled or not × every outcome × with / without a timestamp.
        for available in [false, true] {
            for outcome in everyOutcome {
                for at: Double? in [nil, 999_880] {
                    if let line = MenuStateModel.phoneAlertLine(enabled: true, available: available,
                                                                outcome: outcome, at: at, now: 1_000_000) {
                        lines.append(line)
                    }
                }
            }
        }
        // F4 slice S2: the channel-policy line, every reading (no reading
        // is no line).
        for finding: ChannelPolicyFinding? in [nil] + ChannelPolicyFinding.allCases {
            if let line = MenuStateModel.remoteApprovalsPolicyLine(finding: finding) { lines.append(line) }
        }
        // The Claude status is NOT a Settings-home line: it is the footer's
        // own caption, always visible (`claudeFooterLabelTable`).
        return lines
    }

    @Test func noNonNominalLineLivesOnlyInSettings() {
        let lines = Self.everySettingsHomeLine()
        // 32 hook (H1: 8 liveness inputs × 4 alert-toggle states) + 5 topic
        // + 6 server + 10 last-send + 30 last-session-alert + 2 login captions
        // + 1 holding-awake + 2 lock-screen + 9 hook-version (S7: 10 rows, one
        // of which — no stamp, no dir — is no line) + 20 phone transport (F3:
        // 2 entitlement states × 5 outcomes × 2 timestamps) + 6 channel-policy
        // readings (F4 slice S2).
        #expect(lines.count == 123, "vacuity guard — update when the input set changes")
        var surfaced = 0
        var quietHook = 0
        for line in lines {
            if line.severity == .nominal, Self.quietHookTexts.contains(line.text) {
                // H1: nothing needs the hook, so it is a Settings-only fact.
                quietHook += 1
                #expect(MenuStateModel.placement(ofSettingsLine: line.severity) == .settings)
                continue
            }
            let problem = Self.readsLikeAProblem(line.text)
            #expect(problem == (line.severity != .nominal),
                    "severity \(line.severity) disagrees with the text: \(line.text)")
            let placement = MenuStateModel.placement(ofSettingsLine: line.severity)
            if problem {
                surfaced += 1
                #expect(placement == .topLevel, "a problem would live only in Settings: \(line.text)")
            } else {
                #expect(placement == .settings)
            }
        }
        #expect(surfaced > 10, "vacuity guard — the input set must include problems")
        // Exactly the 7 problem liveness inputs with BOTH toggles off — one
        // more would mean an alert that needs the hook no longer warns.
        #expect(quietHook == 7, "the H1 exception must stay exactly the alerts-off hook lines")
    }

    /// Tier-2 lines are always top level, but they must still be classified:
    /// a degraded lid status is never rendered as a plain caption.
    @Test func degradedLidStatusIsNeverNominal() {
        let degraded = ["set an ntfy topic", "send the test message", "did not go out", "Cannot fire"]
        for row in Self.lidRows {
            let line = MenuStateModel.lidAlertStatus(for: row.state, lastOutcome: row.outcome, detectionPaused: row.paused)
            let isDegraded = degraded.contains { line.text.contains($0) }
            #expect(isDegraded == (line.severity != .nominal), "\(line.text)")
        }
    }

    // MARK: - The gear badge + icon/VoiceOver for every severity

    @Test func theBadgeIsTheWorstSeverity() {
        #expect(MenuStateModel.worstSeverity([]) == .nominal)
        #expect(MenuStateModel.worstSeverity([.nominal, .nominal]) == .nominal)
        #expect(MenuStateModel.worstSeverity([.nominal, .info]) == .info)
        #expect(MenuStateModel.worstSeverity([.warning, .info, .nominal]) == .warning)
        #expect(MenuStateModel.worstSeverity([.warning, .error, .nominal]) == .error)
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
    /// leading symbol column — the feature-row symbols, plus (conservatively)
    /// the severity symbols, which sat there in the deleted Claude row — fits
    /// the column at the panel's symbol size, so no symbol crowds into the gap
    /// before its title. OS-drift canary: a wider glyph in a future macOS
    /// fails here. Since the 2026-10-21 declutter the Lock Screen glyph is an
    /// icon-only button (in the header's top-right corner since 2026-10-22),
    /// not a leading symbol (it stays in `PanelSymbol.all`, so it still must
    /// resolve), and the Claude glyph is gone.
    @Test func leadingSymbolsFitTheSymbolColumn() throws {
        let config = NSImage.SymbolConfiguration(pointSize: PanelMetrics.symbolSize, weight: .regular)
        let leading = [PanelSymbol.stayAwake, PanelSymbol.chargeLimit, PanelSymbol.lidAlert,
                       PanelSymbol.sessionAlerts, PanelSymbol.remoteApprovals, PanelSymbol.info, PanelSymbol.warning,
                       PanelSymbol.error]
        #expect(PanelSymbol.all.contains(PanelSymbol.lockScreen), "the header's lock glyph must still resolve")
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

    // MARK: - The test-send button (#67)

    /// What the button renders: phase × whether the destination is usable.
    /// "Sending…" is disabled whatever the destination; idle and "Sent"
    /// follow it. Only "Sent" carries a symbol (the checkmark, after it).
    @Test(arguments: [
        (TestSendPhase.idle, true, "Send test message", String?.none, true),
        (.idle, false, "Send test message", nil, false),
        (.sending, true, "Sending…", nil, false),
        (.sending, false, "Sending…", nil, false),
        (.sent, true, "Sent", PanelSymbol.sent, true),
        (.sent, false, "Sent", PanelSymbol.sent, false),
    ])
    func testSendButtonTable(phase: TestSendPhase, available: Bool, title: String, symbol: String?, enabled: Bool) {
        #expect(MenuStateModel.testSendButton(phase: phase, available: available)
                == TestSendButtonPresentation(title: title, symbol: symbol, enabled: enabled))
    }

    /// How the button moves: every phase × every event. A tap always means
    /// "Sending…"; only an ACCEPTED outcome while sending earns "Sent" — a
    /// refused, rate-limited, failed or unconfirmed one goes straight back to
    /// idle (the surfaced last-send line is the error signal); the hold's end
    /// reverts only "Sent"; and an outcome outside "Sending…" (a priming send
    /// from a toggle) never moves the button.
    @Test(arguments: [
        ("idle, tapped", TestSendPhase.idle, TestSendEvent.tapped, TestSendPhase.sending),
        ("sending, tapped", .sending, .tapped, .sending),
        ("sent, tapped", .sent, .tapped, .sending),
        ("sending, accepted", .sending, .outcome(.accepted), .sent),
        ("sending, refused", .sending, .outcome(.rejected(403)), .idle),
        ("sending, rate-limited", .sending, .outcome(.rejected(429)), .idle),
        ("sending, failed", .sending, .outcome(.sendFailed("the ntfy server could not be reached")), .idle),
        ("sending, unconfirmed", .sending, .outcome(.timedOutUnconfirmed), .idle),
        ("sending, no outcome", .sending, .outcome(nil), .idle),
        ("idle, accepted elsewhere", .idle, .outcome(.accepted), .idle),
        ("idle, refused elsewhere", .idle, .outcome(.rejected(403)), .idle),
        ("sent, refused elsewhere", .sent, .outcome(.rejected(403)), .sent),
        ("sent, hold elapsed", .sent, .revertElapsed, .idle),
        ("sending, hold elapsed", .sending, .revertElapsed, .sending),
        ("idle, hold elapsed", .idle, .revertElapsed, .idle),
    ])
    func testSendPhaseTable(id: String, from: TestSendPhase, event: TestSendEvent, to: TestSendPhase) {
        #expect(MenuStateModel.testSendPhase(from, on: event) == to, "\(id)")
    }

    /// The fixed vocabulary, exactly: the ellipsis is the one character
    /// U+2026 (as in "ntfy settings…"), and the success mark is an SF Symbol
    /// in `PanelSymbol` (so it is resolve-checked), never a text glyph.
    @Test func theTestSendVocabularyIsFixed() {
        let labels = TestSendPhase.allCases.map { MenuStateModel.testSendButton(phase: $0, available: true) }
        #expect(labels.map(\.title) == ["Send test message", "Sending\u{2026}", "Sent"])
        #expect(labels.map(\.symbol) == [nil, nil, "checkmark"])
        #expect(PanelSymbol.all.contains(PanelSymbol.sent))
        for title in labels.map(\.title) {
            #expect(!title.contains("✓") && !title.contains("✔") && !title.contains("..."), "'\(title)'")
        }
    }

    /// Reserved width, headless: the button lays out every phase's label
    /// (`SendFeedbackButton`), so it is as wide as the widest. At the small
    /// control font the widest is the idle title — so every phase keeps the
    /// width the plain "Send test message" button had — and the inline
    /// checkmark is no taller than the text line, so "Sent" adds no height.
    @Test @MainActor func theIdleTitleIsTheWidestTestSendLabel() throws {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        let checkmark = try #require(NSImage(systemSymbolName: PanelSymbol.sent, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)))
        let idle = width(MenuStateModel.testSendButton(phase: .idle, available: true).title)
        let sending = width(MenuStateModel.testSendButton(phase: .sending, available: true).title)
        let sent = width(MenuStateModel.testSendButton(phase: .sent, available: true).title + " ") + checkmark.size.width
        #expect(idle > sending, "\"Sending…\" (\(sending)pt) outgrows the idle title (\(idle)pt)")
        #expect(idle > sent, "\"Sent\" + checkmark (\(sent)pt) outgrows the idle title (\(idle)pt)")
        #expect(checkmark.size.height <= NSLayoutManager().defaultLineHeight(for: font),
                "the inline checkmark is taller than the text line")
    }

    // MARK: - Stay Awake "Turning on…" (owner ruling e)

    /// How the turn-on phase moves: every phase × every event. A flip starts
    /// the hold from idle only; only a hold elapsing while waiting shows the
    /// caption; an observed ON (the confirm) or the menu opening clears it from
    /// anywhere; an observed OFF or unreadable state changes nothing (the
    /// command may still be running).
    @Test(arguments: [
        ("idle, flipped on", StayAwakeTurnOnPhase.idle, StayAwakeTurnOnEvent.flippedOn, StayAwakeTurnOnPhase.waiting),
        ("waiting, flipped on", .waiting, .flippedOn, .waiting),
        ("showing, flipped on", .showing, .flippedOn, .showing),
        ("idle, hold elapsed", .idle, .holdElapsed, .idle),
        ("waiting, hold elapsed", .waiting, .holdElapsed, .showing),
        ("showing, hold elapsed", .showing, .holdElapsed, .showing),
        ("idle, observed on", .idle, .observed(true), .idle),
        ("waiting, observed on (fast confirm)", .waiting, .observed(true), .idle),
        ("showing, observed on (slow confirm)", .showing, .observed(true), .idle),
        ("waiting, observed off", .waiting, .observed(false), .waiting),
        ("showing, observed off", .showing, .observed(false), .showing),
        ("waiting, unreadable", .waiting, .observed(nil), .waiting),
        ("showing, unreadable", .showing, .observed(nil), .showing),
        ("idle, panel opened", .idle, .panelOpened, .idle),
        ("waiting, panel opened", .waiting, .panelOpened, .idle),
        ("showing, panel opened", .showing, .panelOpened, .idle),
    ])
    func stayAwakeTurnOnPhaseTable(id: String, from: StayAwakeTurnOnPhase, event: StayAwakeTurnOnEvent,
                                   to: StayAwakeTurnOnPhase) {
        #expect(MenuStateModel.stayAwakeTurnOnPhase(from, on: event) == to, "\(id)")
    }

    /// The Stay Awake slot's precedence: the unreadable warning first (it is
    /// the problem), then "Turning on…" — nominal, the quiet caption style —
    /// only once the hold ran out unconfirmed, then nothing. A confirmed ON
    /// never shows "Turning on…", whatever the phase says.
    @Test(arguments: [
        (Bool?.none, StayAwakeTurnOnPhase.idle, "Unknown — the sleep state could not be read", PanelSeverity?.some(.warning)),
        (nil, .waiting, "Unknown — the sleep state could not be read", .warning),
        (nil, .showing, "Unknown — the sleep state could not be read", .warning),
        (false, .idle, nil, nil),
        (false, .waiting, nil, nil),
        (false, .showing, "Turning on…", .nominal),
        (true, .idle, nil, nil),
        (true, .waiting, nil, nil),
        (true, .showing, nil, nil),
    ] as [(Bool?, StayAwakeTurnOnPhase, String?, PanelSeverity?)])
    func stayAwakeSlotTable(observed: Bool?, phase: StayAwakeTurnOnPhase, text: String?, severity: PanelSeverity?) {
        let line = MenuStateModel.stayAwakeSlot(observed: observed, turnOn: phase)
        #expect(line?.text == text)
        #expect(line?.severity == severity)
    }

    /// The fixed wording (owner ruling e): the real U+2026 ellipsis, as in
    /// "Sending…" and "ntfy settings…"; nominal, so it never escalates the
    /// badge or reaches VoiceOver as a warning.
    @Test func theTurningOnWordingIsFixed() {
        #expect(MenuStateModel.stayAwakeTurningOnText == "Turning on\u{2026}")
        #expect(!MenuStateModel.stayAwakeTurningOnText.contains("..."))
        #expect(PanelMotion.turnOnCaptionDelay == 0.4, "the ~400 ms hold")
    }

    // MARK: - Model panel state

    /// `lockAvailable` wires the REAL ScreenLockController (resolution only —
    /// side-effect-free, and canary-locked to resolve on this machine by
    /// `lockSymbolResolvesOnThisMachine`), so the Lock Screen line is nominal
    /// and cannot mask what a test asserts about the badge. `false` wires none
    /// (the model then reports the lock as unavailable — never assumed).
    @MainActor
    private func withModel(
        lockAvailable: Bool = true,
        detection: ClaudeActivityController? = nil,
        lidGuard: LidGuardController? = nil,
        finishAlert: FinishAlertController? = nil,
        remoteApprovals: RemoteApprovalsController? = nil,
        pairing: PairingController? = nil,
        _ body: (MenuStateModel, UserDefaults, String) throws -> Void
    ) rethrows {
        let suite = "com.muratalkan.napcat.tests.menupanel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let power = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        let limiter = ChargeLimiter(power: power, isAppleSilicon: true, defaults: defaults)
        let model = MenuStateModel(power: power, sleep: SleepStateController(), limiter: limiter,
                                   screenLock: lockAvailable ? ScreenLockController() : nil,
                                   detection: detection, lidGuard: lidGuard, finishAlert: finishAlert,
                                   remoteApprovals: remoteApprovals, pairing: pairing)
        try body(model, defaults, suite)
    }

    /// A hermetic detection controller over a temp marker dir (the DISABLED
    /// flag lands there, never in the real state dir).
    @MainActor
    private func withDetection(
        hookInstalled: Bool = true,
        holdingAwake: Bool = false,
        _ body: (ClaudeActivityController) throws -> Void
    ) throws {
        let markerDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("napcat-menupanel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: markerDir) }
        let detection = ClaudeActivityController(
            store: StubMarkerStore(hookInstalled: hookInstalled), prober: StubProber(),
            assertions: StubAssertions(holdingAwake: holdingAwake), markerDirURL: markerDir)
        try body(detection)
    }

    /// An armed lid guard + a REAL finish-alert controller on its shared
    /// config, both on, watching a temp marker dir that holds the DISABLED
    /// flag — so the session row reads `.paused`. Fakes only: no network, no
    /// real marker dir, no watcher.
    @MainActor
    private func withPausedSessionAlerts(_ body: (LidGuardHarness, FinishAlertController) throws -> Void) throws {
        let suite = "com.muratalkan.napcat.tests.menupanel.sessionpaused.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("napcat-sessionpaused-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #require(FileManager.default.createFile(
            atPath: dir.appendingPathComponent(ClaudeBusyConstants.disabledFlagName).path, contents: nil))
        let sender = RecordingMessageSender()
        let lid = LidGuardHarness(defaults: defaults, sender: sender)
        lid.arm()
        defaults.set(true, forKey: DefaultsKey.claudeFinishAlertEnabled)
        let factory = WatcherFactory()
        let finish = FinishAlertController(
            store: FakeMarkerStore(), markerDirURL: dir, config: lid.controller, sender: sender,
            makeWatcher: { factory.make($0) }, scheduler: ManualScheduler(), now: { 1_800_000_000 })
        try body(lid, finish)
    }

    /// H1 acceptance harness: a FRESH INSTALL (no busy hook, no marker dir)
    /// with the lid guard and a real finish-alert controller wired as in the
    /// app. Each switched-on alert gets a set, primed destination, so its own
    /// row is as healthy as it can be without the hook: the lid row reads
    /// armed; the session row reads `.hookNotInstalled` (nothing to watch).
    /// Fakes only: no network, no watcher, no real marker dir.
    @MainActor
    private func withFreshInstall(
        lidAlert: Bool,
        sessionAlerts: Bool,
        _ body: (MenuStateModel) throws -> Void
    ) throws {
        try withDetection(hookInstalled: false) { detection in
            detection.sample()
            let suite = "com.muratalkan.napcat.tests.menupanel.freshinstall.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let sender = RecordingMessageSender()
            let lid = LidGuardHarness(defaults: defaults, sender: sender,
                                      topicStore: FakeTopicStore(lidAlert || sessionAlerts ? "napcat-fresh-7q2m9x" : nil))
            if lidAlert || sessionAlerts {
                defaults.set(lid.clock.now, forKey: DefaultsKey.lidGuardPrimedAt)
            }
            defaults.set(lidAlert, forKey: DefaultsKey.lidGuardEnabled)
            defaults.set(sessionAlerts, forKey: DefaultsKey.claudeFinishAlertEnabled)
            lid.controller.refreshArming()
            let store = FakeMarkerStore()
            store.dirExists = false
            let factory = WatcherFactory()
            let finish = FinishAlertController(
                store: store,
                markerDirURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("napcat-freshinstall-absent-\(UUID().uuidString)"),
                config: lid.controller, sender: sender,
                makeWatcher: { factory.make($0) }, scheduler: ManualScheduler(), now: { 1_800_000_000 })
            try withModel(detection: detection, lidGuard: lid.controller, finishAlert: finish) { model, _, _ in
                try #require(model.lockScreenAvailable, "canary: see lockSymbolResolvesOnThisMachine")
                try body(model)
            }
        }
    }

    /// Every line the hook and alert wiring can put on the panel: the footer
    /// label, the top-level captions and every Settings-home line. (Stay
    /// Awake's caption reads pmset state this hermetic harness never samples;
    /// it has its own tests and does not depend on the hook.)
    @MainActor
    private static func hookAndAlertLines(_ model: MenuStateModel, now: Double) -> [PanelLine] {
        let always = [model.hookStatus, model.lidStatus, model.lidTopicStatus,
                      model.lidServerStatus, model.lidLastSend(now: now), model.finishAlertStatus,
                      model.finishAlertLastSend(now: now), model.lockScreenStatus]
        let optional = [model.footerLabel, model.hookVersionStatus, model.claudeAwakeLine, model.launchAtLoginCaption,
                        model.chargeLimitCaption]
        return always + optional.compactMap { $0 }
    }

    static let hookNotInstalledText =
        "Busy hook: not installed — run install-claude-busy-hook.sh from the NapCat repository"

    // MARK: H1 acceptance — a fresh install opens without a hook warning

    /// No hook, both alerts off (someone who only wants Stay Awake or the
    /// charge limit): the hook line keeps its text but is NOMINAL and lives
    /// in Settings alone, so the panel shows no non-nominal line and no badge.
    @Test @MainActor func aFreshInstallWithBothAlertsOffShowsNoHookWarning() throws {
        try withFreshInstall(lidAlert: false, sessionAlerts: false) { model in
            #expect(!model.claudeHookInstalled, "vacuity: no hook")
            #expect(model.hookStatus == PanelLine(text: Self.hookNotInstalledText, severity: .nominal))
            #expect(MenuStateModel.placement(ofSettingsLine: model.hookStatus.severity) == .settings)
            let lines = Self.hookAndAlertLines(model, now: 1_800_000_000)
            #expect(lines.count >= 9, "vacuity guard")
            let loud = lines.filter { $0.severity != .nominal }
            #expect(loud.isEmpty, "a fresh install must open quiet: \(loud)")
            #expect(model.settingsBadge == .nominal)
        }
    }

    /// No hook, lid alert on: the lid alert cannot fire without a busy
    /// marker, so the hook line warns at top level and raises the badge. The
    /// lid row is armed and nominal, and session alerts are off, so the
    /// warning can only be the hook's.
    @Test @MainActor func aFreshInstallWithTheLidAlertOnSurfacesTheHookWarning() throws {
        try withFreshInstall(lidAlert: true, sessionAlerts: false) { model in
            #expect(model.lidStatus.severity == .nominal, "vacuity: the lid row is armed")
            #expect(model.finishAlertStatus == PanelLine(text: "Off", severity: .nominal))
            #expect(model.hookStatus == PanelLine(text: Self.hookNotInstalledText, severity: .warning))
            #expect(MenuStateModel.placement(ofSettingsLine: model.hookStatus.severity) == .topLevel)
            #expect(model.settingsBadge == .warning)
        }
    }

    /// No hook, session alerts on: the session row says to install the hook
    /// "(see below)", and the hook warning it points at is surfaced.
    @Test @MainActor func aFreshInstallWithSessionAlertsOnSurfacesTheHookWarning() throws {
        try withFreshInstall(lidAlert: false, sessionAlerts: true) { model in
            #expect(model.lidStatus == PanelLine(text: "Off", severity: .nominal))
            #expect(model.finishAlertDisplayState == .hookNotInstalled)
            #expect(model.finishAlertStatus == PanelLine(
                text: "Not armed — install the Claude busy hook first (see below)", severity: .warning))
            #expect(model.hookStatus == PanelLine(text: Self.hookNotInstalledText, severity: .warning))
            #expect(MenuStateModel.placement(ofSettingsLine: model.hookStatus.severity) == .topLevel)
            #expect(model.settingsBadge == .warning)
        }
    }

    /// debugBattery wiring (no detection, no lid guard): absent subsystems
    /// cannot raise the badge.
    @Test @MainActor func absentSubsystemsNeverRaiseTheBadge() throws {
        try withModel { model, _, _ in
            #expect(!model.claudeDetectionVisible && !model.lidGuardVisible)
            try #require(model.lockScreenAvailable, "canary: see lockSymbolResolvesOnThisMachine")
            #expect(model.settingsBadge == .nominal)
        }
    }

    /// Issue #205, through the model with the real toggle over a scratch
    /// socket (ApprovalsWorld) and the real pairing controller over an
    /// in-memory slot (PairingWorld): on with nothing paired, the row says to
    /// pair first; it follows the slot as the controller last read it (the
    /// menu and Settings opens re-read it — SettingsWindowTests'
    /// `theSettingsRefreshMirrorsTheMenuOpenReads`), so a phone committed
    /// behind its back changes nothing until that read; an unreadable slot
    /// is not paired. The host never hears of the pairing: a forwardable
    /// prompt stays local while paired.
    @Test @MainActor func theRemoteApprovalsRowSaysToPairFirstWhileNothingIsPaired() throws {
        let approvals = try ApprovalsWorld()
        let pairing = PairingWorld()
        let off = PanelLine(text: "Off", severity: .nominal)
        let notPaired = PanelLine(text: "Not paired — pair your iPhone in Settings › Claude", severity: .info)
        let localOnly = PanelLine(text: "Local only — the iPhone app cannot answer prompts yet", severity: .info)
        try withModel(remoteApprovals: approvals.controller, pairing: pairing.controller) { model, _, _ in
            #expect(model.remoteApprovalsStatus == off)
            model.setRemoteApprovalsEnabled(true)
            #expect(model.remoteApprovalsEnabled && !model.remoteApprovalsPaired)
            #expect(model.remoteApprovalsStatus == notPaired)

            let phone: PairedPhone = try PairedKeyStoreTests.phone()
            #expect(PairedKeyStore(items: pairing.items).commit(phone))
            model.refresh()
            #expect(model.remoteApprovalsStatus == notPaired, "the slot as last read: a model refresh does not read it")
            pairing.controller.refreshPaired()
            model.refresh()
            #expect(model.remoteApprovalsPaired && model.remoteApprovalsStatus == localOnly)
            approvals.prompt("abcde")
            #expect(approvals.nextPrompt(endingIn: "suppressed.notArmed") != nil, "paired, the host still stays unarmed")

            pairing.items.replaceValue("not a pairing")
            pairing.controller.refreshPaired()
            model.refresh()
            #expect(!model.remoteApprovalsPaired && model.remoteApprovalsStatus == notPaired, "an unreadable slot is not paired")

            model.setRemoteApprovalsEnabled(false)
            #expect(model.remoteApprovalsStatus == off)
        }
    }

    /// Issue #240, through the model: after the keychain refused Unpair's
    /// deletion (the key still reads back) the pairing line is a warning in
    /// Settings › Claude, on the gear's badge and below the cards; the
    /// Remote approvals toggle, switched back on, counts no pairing — it
    /// says to pair first, never "Local only" over the key the owner asked
    /// to remove. Try Again through the model clears it all.
    @Test @MainActor func aRefusedUnpairIsAWarningAndPairsNothing() throws {
        let approvals = try ApprovalsWorld()
        let pairing = PairingWorld()
        let notPaired = PanelLine(text: "Not paired — pair your iPhone in Settings › Claude", severity: .info)
        try withDetection { detection in
            detection.sample()
            try withModel(detection: detection, remoteApprovals: approvals.controller, pairing: pairing.controller) { model, _, _ in
                let phone: PairedPhone = try PairedKeyStoreTests.phone()
                #expect(PairedKeyStore(items: pairing.items).commit(phone))
                pairing.controller.refreshPaired()
                model.refresh()
                #expect(model.remoteApprovalsPaired && model.pairingLine?.severity == .nominal)
                #expect(model.settingsBadge == .nominal, "vacuity: nothing else raises the badge")

                pairing.items.setFailDeletes(true)
                pairing.controller.unpair()
                model.refresh()
                let warning = MenuStateModel.pairingStatusLine(.unpairFailed)
                #expect(model.pairingPane == .unpairFailed && model.pairingLine == warning && warning.severity == .warning)
                #expect(model.claudePane.sections.last?.rows.suffix(2) == ArraySlice(MenuStateModel.pairingRows(.unpairFailed)))
                #expect(model.settingsBadge == .warning, "the gear says where it lives")
                #expect(MenuStateModel.placement(ofSettingsLine: warning.severity) == .topLevel, "and its twin renders")
                #expect(!model.remoteApprovalsPaired, "a refused Unpair is not a pairing")
                model.setRemoteApprovalsEnabled(true)
                #expect(model.remoteApprovalsEnabled && model.remoteApprovalsStatus == notPaired, "on again, it pairs nothing")
                model.setRemoteApprovalsEnabled(false)

                pairing.items.setFailDeletes(false)
                model.retryUnpair()
                #expect(model.pairingPane == .notPaired && pairing.items.storedValue == nil)
                #expect(model.pairingLine?.severity == .nominal && !model.remoteApprovalsPaired && model.settingsBadge == .nominal)
            }
        }
    }

    /// Without the detection stack there is no Claude state to report, so the
    /// footer shows no status caption at all instead of claiming "idle".
    @Test @MainActor func debugWiringShowsNoClaudeStatus() throws {
        withModel { model, _, _ in
            #expect(!model.claudeDetectionVisible)
            #expect(model.footerLabel == nil)
            #expect(model.claudeAwakeLine == nil)
        }
        try withDetection { detection in
            detection.sample()
            withModel(detection: detection) { model, _, _ in
                #expect(model.footerLabel == PanelLine(text: "Claude: idle", severity: .nominal))
            }
        }
    }

    /// THE BADGE RULE (2026-10-21): the Claude status is the footer's own
    /// caption and carries its own warning, so a PAUSED Claude does not raise
    /// the badge — neither directly nor through its echoes in the lid and
    /// session lines — but every OTHER problem still does: a hook problem, an
    /// unavailable Lock Screen, and a lid / session send failure.
    @Test @MainActor func aPausedClaudeDoesNotRaiseTheBadgeButOtherTuckedProblemsDo() throws {
        // Paused with the lid alert AND session alerts armed (the realistic
        // paused panel): both status captions warn at top level, the label
        // warns, the badge stays nominal.
        try withDetection { detection in
            detection.setPaused(true)
            detection.sample()
            try withPausedSessionAlerts { lid, finish in
                try withModel(detection: detection, lidGuard: lid.controller, finishAlert: finish) { model, _, _ in
                    try #require(model.lockScreenAvailable, "canary: see lockSymbolResolvesOnThisMachine")
                    #expect(model.footerLabel?.severity == .warning)
                    #expect(model.lidStatus.severity == .warning && model.lidStatus.text.hasPrefix("Cannot fire"))
                    #expect(model.finishAlertDisplayState == .paused)
                    #expect(model.finishAlertStatus.severity == .warning)
                    #expect(model.settingsBadge == .nominal, "the pause's echoes must not raise the badge")
                }
            }
        }
        // Paused, hook healthy, lock available, no lid guard: label warns,
        // badge stays nominal.
        try withDetection(holdingAwake: true) { detection in
            detection.setPaused(true)
            detection.sample()
            try withModel(detection: detection) { model, _, _ in
                try #require(model.lockScreenAvailable, "canary: see lockSymbolResolvesOnThisMachine")
                #expect(model.footerLabel == PanelLine(text: "Claude: paused", severity: .warning))
                #expect(model.hookStatus.severity == .nominal)
                #expect(model.claudeAwakeLine == PanelLine(text: "Claude is holding the Mac awake",
                                                           severity: .nominal),
                        "the awake fact is still reported while paused")
                #expect(model.settingsBadge == .nominal, "a paused Claude must not raise the badge")
            }
        }
        // A hook problem an alert needs raises it (and still surfaces through
        // its twin). With both alerts off it is a quiet, Settings-only fact (H1 —
        // `aFreshInstallWithBothAlertsOffShowsNoHookWarning`).
        try withFreshInstall(lidAlert: true, sessionAlerts: false) { model in
            #expect(model.footerLabel?.severity == .nominal)
            #expect(model.hookStatus.severity == .warning)
            #expect(model.settingsBadge == .warning)
        }
        // An unavailable Lock Screen raises it.
        withModel(lockAvailable: false) { model, _, _ in
            #expect(model.lockScreenStatus.severity == .warning)
            #expect(model.settingsBadge == .warning)
        }
        // A refused lid send raises it (to an error), paused Claude or not.
        try withDetection { detection in
            detection.setPaused(true)
            detection.sample()
            withLidGuardHarness(sender: RecordingMessageSender(outcome: .rejected(403))) { lid in
                lid.arm()
                lid.controller.sendTestMessage()
                withModel(detection: detection, lidGuard: lid.controller) { model, _, _ in
                    #expect(model.lidLastSend(now: lid.clock.now).severity == .error)
                    #expect(model.settingsBadge == .error)
                }
            }
        }
        // (A refused SESSION send: `aRefusedSessionAlertSurfacesAndRaisesTheBadge`.)
    }

    /// S7 end to end: the installed hook's stamp, sampled by the detection
    /// controller, reaches the panel — an out-of-date copy is a top-level
    /// warning that raises the badge; re-running the installer (the current
    /// stamp) returns it to Settings alone, as nominal.
    @Test @MainActor func anOutOfDateHookCopySurfacesAndRaisesTheBadge() throws {
        let markerDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("napcat-menupanel-hookversion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: markerDir) }
        let store = StubMarkerStore(hookInstalled: true)
        store.installedVersion = .some(ClaudeBusyConstants.hookVersion - 1)
        let detection = ClaudeActivityController(store: store, prober: StubProber(), assertions: StubAssertions(),
                                                 markerDirURL: markerDir)
        detection.sample()
        #expect(detection.installedHookVersion == ClaudeBusyConstants.hookVersion - 1, "sample() records it")
        try withModel(detection: detection) { model, _, _ in
            try #require(model.lockScreenAvailable, "canary: see lockSymbolResolvesOnThisMachine")
            #expect(model.hookStatus.severity == .nominal, "the liveness line itself is healthy")
            #expect(model.hookVersionStatus == PanelLine(text: Self.hookVersionOutOfDateText, severity: .warning))
            #expect(MenuStateModel.placement(ofSettingsLine: model.hookVersionStatus?.severity ?? .nominal) == .topLevel)
            #expect(model.settingsBadge == .warning)

            store.installedVersion = .some(ClaudeBusyConstants.hookVersion)
            detection.sample()
            model.refresh()
            #expect(model.hookVersionStatus == PanelLine(text: Self.hookVersionCurrentText, severity: .nominal))
            #expect(model.settingsBadge == .nominal)
        }
    }

    /// F2 end to end: the DISABLED flag read by the detection controller is
    /// threaded into the lid status the panel renders — armed + paused shows
    /// the downgrade (still a top-level warning caption), and the footer label
    /// says "Claude: paused". The badge does NOT rise: the downgrade is the
    /// pause's echo, which the label already carries (2026-10-21 badge rule).
    /// Removing the flag restores plain "armed".
    @Test @MainActor func pausedDetectionDowngradesTheArmedLineThroughTheModel() throws {
        try withDetection { detection in
            let lidSuite = "com.muratalkan.napcat.tests.menupanel.lid.\(UUID().uuidString)"
            let lidDefaults = UserDefaults(suiteName: lidSuite)!
            defer { lidDefaults.removePersistentDomain(forName: lidSuite) }
            let harness = LidGuardHarness(defaults: lidDefaults, sender: RecordingMessageSender())
            harness.arm()
            try withModel(detection: detection, lidGuard: harness.controller) { model, _, _ in
                detection.setPaused(true)
                detection.sample()
                model.refresh()
                #expect(model.footerLabel == PanelLine(text: "Claude: paused", severity: .warning))
                #expect(model.lidStatus.text.hasPrefix("Cannot fire"))
                #expect(model.lidStatus.severity == .warning)
                #expect(MenuStateModel.placement(ofSettingsLine: model.lidStatus.severity) == .topLevel)
                try #require(model.lockScreenAvailable, "canary: see lockSymbolResolvesOnThisMachine")
                #expect(model.settingsBadge == .nominal, "the pause's echo in the lid line must not raise the badge")

                detection.setPaused(false)
                detection.sample()
                model.refresh()
                #expect(model.footerLabel == PanelLine(text: "Claude: idle", severity: .nominal))
                #expect(model.lidStatus.text.contains("best-effort push"))
                #expect(model.lidStatus.severity == .nominal)
                #expect(model.settingsBadge == .nominal)
            }
        }
    }

    /// FA-4 end to end: a session alert refused by the server (403 here —
    /// never retried, the controller's half) reaches the panel as an error
    /// status, a last-send line that SURFACES in the panel, and an error badge —
    /// while the lid half is perfectly healthy, so the badge can only come
    /// from the session send. C6: re-running the test send as the caption
    /// says clears the status downgrade only once ntfy accepts it LATER than
    /// the refusal; the history line stays truthful. (A 429 has its own
    /// caption — `aRateLimitedSessionAlertSaysAlertsAreHeld`.)
    @Test @MainActor func aRefusedSessionAlertSurfacesAndRaisesTheBadge() async throws {
        typealias H = FinishAlertHarness
        try await withFinishAlertHarness(sender: RecordingMessageSender(outcome: .rejected(403))) { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.controller.reconcile()
            h.store.remove(H.s1)
            await h.settle()
            #expect(h.controller.lastSendOutcome == .rejected(403))
            #expect(h.pendingRetries.isEmpty)

            let lidSuite = "com.muratalkan.napcat.tests.menupanel.session.\(UUID().uuidString)"
            let lidDefaults = UserDefaults(suiteName: lidSuite)!
            defer { lidDefaults.removePersistentDomain(forName: lidSuite) }
            let lid = LidGuardHarness(defaults: lidDefaults, sender: RecordingMessageSender())
            lid.arm()
            lidDefaults.set(true, forKey: DefaultsKey.claudeFinishAlertEnabled)

            withModel(lidGuard: lid.controller, finishAlert: h.controller) { model, _, _ in
                #expect(model.finishAlertVisible)
                #expect(model.lidStatus.severity == .nominal)
                #expect(model.finishAlertStatus == PanelLine(
                    text: "Failed — the last message did not go out; re-run Send test message in Settings",
                    severity: .error))
                let last = model.finishAlertLastSend(now: Double(H.t0) + 120)
                #expect(last == PanelLine(
                    text: "Last session alert: refused by the server 2m ago (finished) (HTTP 403) — check the topic and server",
                    severity: .error))
                #expect(MenuStateModel.placement(ofSettingsLine: last.severity) == .topLevel)
                #expect(model.settingsBadge == .error)

                // An accepted test send that PREDATES the refusal is no
                // recovery (the lid clock starts far before H.t0).
                lid.controller.sendTestMessage()
                model.refresh()
                #expect(lid.controller.lastSendOutcome == .accepted)
                #expect((lid.controller.lastSendOutcomeAt ?? .infinity) < Double(H.t0))
                #expect(model.finishAlertStatus.severity == .error)

                // Re-run it a minute AFTER the refusal: the caption recovers.
                lid.clock.advance(Double(H.t0) - lid.clock.now + 60)
                lid.controller.sendTestMessage()
                model.refresh()
                #expect(model.finishAlertStatus == PanelLine(
                    text: "Armed — a push when a Claude session finishes or waits for you",
                    severity: .nominal))
                // …while the History line is untouched and still surfaces
                // (so the badge stays an error).
                #expect(model.finishAlertLastSend(now: Double(H.t0) + 120) == last)
                #expect(model.settingsBadge == .error)
            }
        }
    }

    /// B-1 end to end: a session alert refused with 429 holds the session
    /// lane (the controller's flush sits at the hold end) and the status
    /// says so as a WARNING — no "re-run Send test message" advice — while
    /// the History line still reports the refusal as an error that surfaces
    /// in the panel (so the badge is an error). The C6 recovery rule
    /// applies unchanged: a LATER accepted lid-lane send clears the caption.
    @Test @MainActor func aRateLimitedSessionAlertSaysAlertsAreHeld() async throws {
        typealias H = FinishAlertHarness
        try await withFinishAlertHarness(sender: RecordingMessageSender(outcome: .rejected(429))) { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.controller.reconcile()
            h.store.remove(H.s1)
            await h.settle()
            #expect(h.controller.lastSendOutcome == .rejected(429))
            #expect(h.pendingRetries.isEmpty)
            #expect(h.scheduler.pending(delay: FinishAlertTuning.rateLimitHoldSeconds).count == 1,
                    "the session lane is held")

            let lidSuite = "com.muratalkan.napcat.tests.menupanel.ratelimit.\(UUID().uuidString)"
            let lidDefaults = UserDefaults(suiteName: lidSuite)!
            defer { lidDefaults.removePersistentDomain(forName: lidSuite) }
            let lid = LidGuardHarness(defaults: lidDefaults, sender: RecordingMessageSender())
            lid.arm()
            lidDefaults.set(true, forKey: DefaultsKey.claudeFinishAlertEnabled)

            withModel(lidGuard: lid.controller, finishAlert: h.controller) { model, _, _ in
                #expect(model.lidStatus.severity == .nominal)
                #expect(model.finishAlertStatus == PanelLine(text: Self.sessionRateLimitedText, severity: .warning))
                #expect(!model.finishAlertStatus.text.contains("Send test message"),
                        "a re-run test send would only burn more quota")
                #expect(MenuStateModel.placement(ofSettingsLine: model.finishAlertStatus.severity) == .topLevel)
                let last = model.finishAlertLastSend(now: Double(H.t0) + 120)
                #expect(last == PanelLine(
                    text: "Last session alert: refused by the server 2m ago (finished) (HTTP 429) — check the topic and server",
                    severity: .error))
                #expect(MenuStateModel.placement(ofSettingsLine: last.severity) == .topLevel)
                #expect(model.settingsBadge == .error, "the history line still raises the badge")

                // A LATER accepted lid-lane send clears the held caption too.
                lid.clock.advance(Double(H.t0) - lid.clock.now + 60)
                lid.controller.sendTestMessage()
                model.refresh()
                #expect(model.finishAlertStatus == PanelLine(text: Self.sessionArmedText, severity: .nominal))
                #expect(model.finishAlertLastSend(now: Double(H.t0) + 120) == last)
            }
        }
    }

    /// Alert healing end to end: a 429-held session lane shows the rate-limit
    /// caption; the path dropping hands the slot to the ONE offline warning
    /// (offline > 429 hold); the path coming back — the flush deferred to the
    /// still-open hold — hands it back to the rate-limit caption.
    @Test @MainActor func theOfflineWarningOutranksTheRateLimitCaptionEndToEnd() async throws {
        typealias H = FinishAlertHarness
        try await withFinishAlertHarness(sender: RecordingMessageSender(outcome: .rejected(429)),
                                         connectivity: ConnectivitySimulator()) { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.store.put(H.s2, ts: H.t0 - 600)
            h.controller.reconcile()
            await drainMain()
            h.store.remove(H.s1)
            await h.settle()
            #expect(h.controller.lastSendOutcome == .rejected(429))

            let lidSuite = "com.muratalkan.napcat.tests.menupanel.offline.\(UUID().uuidString)"
            let lidDefaults = UserDefaults(suiteName: lidSuite)!
            defer { lidDefaults.removePersistentDomain(forName: lidSuite) }
            let lid = LidGuardHarness(defaults: lidDefaults, sender: RecordingMessageSender())
            lid.arm()
            lidDefaults.set(true, forKey: DefaultsKey.claudeFinishAlertEnabled)

            withModel(lidGuard: lid.controller, finishAlert: h.controller) { model, _, _ in
                #expect(model.finishAlertStatus == PanelLine(text: Self.sessionRateLimitedText, severity: .warning))
            }
            await h.goOfflineByPath()
            withModel(lidGuard: lid.controller, finishAlert: h.controller) { model, _, _ in
                #expect(model.sessionAlertsOffline)
                #expect(model.finishAlertStatus == PanelLine(text: Self.sessionAlertsOfflineText, severity: .warning),
                        "offline > 429 hold")
                #expect(MenuStateModel.placement(ofSettingsLine: model.finishAlertStatus.severity) == .topLevel)
            }
            await h.pathUp()
            #expect(h.controller.healing.phase == .flushing, "the flush waits for the open 429 hold")
            withModel(lidGuard: lid.controller, finishAlert: h.controller) { model, _, _ in
                #expect(!model.sessionAlertsOffline)
                #expect(model.finishAlertStatus == PanelLine(text: Self.sessionRateLimitedText, severity: .warning))
            }
        }
    }

    /// The offline warning has no Settings home, so it never raises the
    /// gear badge (everything else here is healthy).
    @Test @MainActor func theOfflineWarningNeverRaisesTheGearBadge() async throws {
        typealias H = FinishAlertHarness
        try await withFinishAlertHarness(connectivity: ConnectivitySimulator()) { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.controller.reconcile()
            await drainMain()
            await h.goOfflineByPath()
            #expect(h.controller.connectivityOffline)

            let lidSuite = "com.muratalkan.napcat.tests.menupanel.offlinebadge.\(UUID().uuidString)"
            let lidDefaults = UserDefaults(suiteName: lidSuite)!
            defer { lidDefaults.removePersistentDomain(forName: lidSuite) }
            let lid = LidGuardHarness(defaults: lidDefaults, sender: RecordingMessageSender())
            lid.arm()
            lidDefaults.set(true, forKey: DefaultsKey.claudeFinishAlertEnabled)

            try withModel(lidGuard: lid.controller, finishAlert: h.controller) { model, _, _ in
                try #require(model.lockScreenAvailable, "canary: see lockSymbolResolvesOnThisMachine")
                #expect(model.finishAlertStatus == MenuStateModel.sessionAlertsOfflineLine)
                #expect(model.settingsBadge == .nominal, "the offline warning must not raise the badge")
            }
        }
    }

    /// Without the controller (debugBattery wiring) the session row cannot
    /// raise the badge — even with the stored toggle on.
    @Test @MainActor func anAbsentFinishAlertNeverRaisesTheBadge() {
        withLidGuardHarness { lid in
            lid.arm()
            lid.defaults.set(true, forKey: DefaultsKey.claudeFinishAlertEnabled)
            withModel(lidGuard: lid.controller) { model, _, _ in
                #expect(!model.finishAlertVisible)
                #expect(model.settingsBadge == .nominal)
            }
        }
    }
}

// MARK: - Detection stubs (no filesystem scan, no process enumeration, no IOKit)
// Module-internal, so any suite can wire a hermetic detection controller into
// the real model or panel.

final class StubMarkerStore: BusyMarkerStore {
    /// false ⇒ no marker dir: the hook reads "not installed" (a warning
    /// while an alert needs the hook, else a tucked fact — H1).
    let hookInstalled: Bool
    init(hookInstalled: Bool = true) { self.hookInstalled = hookInstalled }
    func markers() -> [BusyMarker] { [] }
    func identifiedMarkers() -> [IdentifiedBusyMarker] { [] }
    func markerDirExists() -> Bool { hookInstalled }
    func hookLogExists() -> Bool { hookInstalled }
    func lastActivityEpoch() -> Int? { hookInstalled ? Int(Date().timeIntervalSince1970) - 60 : nil }
    /// Installed ⇒ the current stamp (a healthy hook raises nothing), unless
    /// a test pins another version.
    var installedVersion: Int?? = nil
    func installedHookVersion() -> Int? {
        installedVersion ?? (hookInstalled ? ClaudeBusyConstants.hookVersion : nil)
    }
}

final class StubProber: ClaudeProcessProber {
    func probe() -> ProcessProbe { ProcessProbe(enumerationSucceeded: true, confirmedCount: 0, inconclusiveCount: 0) }
}

final class StubAssertions: SleepAssertionReader {
    let holdingAwake: Bool
    init(holdingAwake: Bool = false) { self.holdingAwake = holdingAwake }
    func claudeIsHoldingAwake() -> Bool { holdingAwake }
}
