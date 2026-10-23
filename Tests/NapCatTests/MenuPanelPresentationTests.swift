// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import ServiceManagement
import Testing
@testable import NapCat

/// Menu-panel redesign (2026-10-18, PLAN.md "UI Redesign — Menu Panel"): the
/// pure mappings the panel renders — the Claude status (since the 2026-10-21
/// declutter: the footer disclosure's text), F2 armed downgrade, severity
/// classification, the iron rule (nothing non-nominal stays behind Details),
/// the collapsed badge — plus the model's panel state (in-memory disclosure).
/// The design froze on one layout the same day.
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

    /// The footer shares its row with Quit, so its text is a SHORT
    /// FIXED vocabulary — exactly these three strings, never anything else
    /// (plus the plain "Details" name when detection is absent, see
    /// `debugWiringKeepsThePlainDetailsLabel`).
    @Test func theFooterLabelVocabularyIsFixed() {
        var rendered = Set<String>()
        for inFlight in [false, true] {
            for paused in [false, true] {
                rendered.insert(MenuStateModel.claudeFooterLabel(inFlight: inFlight, paused: paused).text)
            }
        }
        #expect(rendered == ["Claude: paused", "Claude: running", "Claude: idle"])
        #expect(MenuStateModel.plainDetailsLabel == PanelLine(text: "Details", severity: .nominal))
        for text in rendered.union([MenuStateModel.plainDetailsLabel.text]) {
            #expect(text.count <= 15, "'\(text)' is too long for the footer row")
        }
    }

    /// The iron rule for the Claude status: paused is non-nominal, so the
    /// footer renders it with the warning icon (and its tint, lint-locked in
    /// MenuPanelStructureTests) — at top level, never behind Details. The old
    /// "where to undo it" hint is gone by design: clicking the label opens
    /// Details, where the Pause toggle explains its own consequence.
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

    /// "Claude is holding the Mac awake" is a tucked Details line, present
    /// ONLY while the sleep-assertion reader says so — never invented.
    @Test func theHoldingAwakeLineExistsOnlyWhileHolding() {
        #expect(MenuStateModel.claudeHoldingAwakeLine(holdingAwake: true)
                == PanelLine(text: "Claude is holding the Mac awake", severity: .nominal))
        #expect(MenuStateModel.claudeHoldingAwakeLine(holdingAwake: false) == nil)
    }

    /// Lock Screen availability as a Details › General line: nominal while
    /// the lock entry point resolved, the unavailable explanation as a
    /// warning (which surfaces) otherwise.
    @Test func theLockScreenStatusLine() {
        let available = MenuStateModel.lockScreenStatus(available: true)
        #expect(available == PanelLine(
            text: "Lock Screen: available — locks and turns the display off; the Mac keeps running",
            severity: .nominal))
        #expect(MenuStateModel.placement(ofDetailsLine: available.severity) == .details)
        let unavailable = MenuStateModel.lockScreenStatus(available: false)
        #expect(unavailable.severity == .warning)
        #expect(unavailable.text == MenuStateModel.lockScreenPresentation(available: false).caption)
        #expect(MenuStateModel.placement(ofDetailsLine: unavailable.severity) == .topLevel)
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
            // Iron rule: only the current copy may stay tucked in Details.
            #expect(MenuStateModel.placement(ofDetailsLine: line.severity)
                    == (line.severity == .nominal ? .details : .topLevel))
            #expect(Self.readsLikeAProblem(line.text) == (line.severity != .nominal), "\(line.text)")
        }
    }

    /// No duplicate of the hook line: a missing hook (no marker dir, no
    /// readable copy) is said ONCE, by `claudeHookStatus`.
    @Test func aMissingHookIsReportedOnlyByTheHookLine() {
        #expect(MenuStateModel.claudeHookVersionStatus(installedVersion: nil, expectedVersion: 4,
                                                       markerDirExists: false) == nil)
        #expect(MenuStateModel.claudeHookStatus(installed: false, everSeen: false, lastSeenSeconds: nil).text
                .contains("not installed"))
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
        "Session alerts: ntfy is rate-limiting this Mac — alerts are held and folded for a while"

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
                               text: "Session alerts: the last message did not go out — re-run Send test message",
                               severity: .error)
        default:
            armed = SessionRow(state: .armed, outcome: outcome,
                               text: "Session alerts: armed — a push when a Claude session finishes or waits for you",
                               severity: .nominal)
        }
        return [
            SessionRow(state: .off, outcome: outcome, text: "Session alerts: off", severity: .nominal),
            SessionRow(state: .needsTopic, outcome: outcome,
                       text: "Session alerts: set an ntfy topic to arm them", severity: .warning),
            SessionRow(state: .needsTestSend, outcome: outcome,
                       text: "Session alerts: send the test message to check your phone gets it", severity: .warning),
            SessionRow(state: .paused, outcome: outcome,
                       text: "Session alerts: on — but Claude detection is paused; alerts cannot fire",
                       severity: .warning),
            SessionRow(state: .hookNotInstalled, outcome: outcome,
                       text: "Session alerts: on — waiting for the Claude hook (no marker folder to watch yet)",
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

    static let sessionDegradedPhrases = ["set an ntfy topic", "send the test message", "cannot fire",
                                         "waiting for the Claude hook", "did not go out", "rate-limiting"]

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
        #expect(line.text.contains("armed —") == (row.state == .armed && row.severity == .nominal))
    }

    // MARK: Session caption recovery (C6)

    /// The failed-send caption tells the user to re-run the test send, so an
    /// ACCEPTED lid-lane send (that test send, or a lid alert) STRICTLY LATER
    /// than the failed session send clears the armed downgrade. Nothing else
    /// does. The Details "Last session alert" line never changes (history).
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

    static let sessionArmedText = "Session alerts: armed — a push when a Claude session finishes or waits for you"
    static let sessionFailedText = "Session alerts: the last message did not go out — re-run Send test message"

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
                               text: "Session alerts: on — but Claude detection is paused; alerts cannot fire",
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
                               text: "Session alerts: on — waiting for the Claude hook (no marker folder to watch yet)",
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
        #expect(line.text.contains("armed —") == (row.state == .armed && row.severity == .nominal))
        // The Details history line takes no lid input: a refused / failed
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
    /// error and ESCAPES Details; unconfirmed is a warning and escapes too.
    @Test(arguments: sessionLastSendRows)
    func sessionAlertsLastSendTable(_ row: SessionLastSendRow) {
        let line = MenuStateModel.finishAlertLastSend(outcome: row.outcome, kind: row.kind, at: row.at,
                                                      now: Self.lastSendNow)
        #expect(line == PanelLine(text: row.text, severity: row.severity))
        #expect(line.text == MenuStateModel.finishAlertLastSendCaption(outcome: row.outcome, kind: row.kind,
                                                                       at: row.at, now: Self.lastSendNow))
        #expect(MenuStateModel.placement(ofDetailsLine: line.severity)
                == (row.severity == .nominal ? .details : .topLevel))
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

        // (The Lock Screen line moved to Details › General on 2026-10-21 —
        // `theLockScreenStatusLine`.)

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
                                 "unconfirmed", "Waiting for approval", "not found", "paused", "unavailable",
                                 "out of date", "no version stamp", "newer than"]

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
        // Track C: the last session alert lives in the same Details group.
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
        // availability became Details-home lines.
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
        // The Claude status is NOT a Details line: it is the footer
        // disclosure's own text, always visible (`claudeFooterLabelTable`).
        return lines
    }

    @Test func noNonNominalLineStaysBehindTheDisclosure() {
        let lines = Self.everyDetailsHomeLine()
        // 8 hook + 5 topic + 6 server + 10 last-send + 30 last-session-alert
        // + 2 login captions + 1 holding-awake + 2 lock-screen + 9 hook-version
        // (S7: 10 rows, one of which — no stamp, no dir — is no line).
        #expect(lines.count == 73, "vacuity guard — update when the input set changes")
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
                       PanelSymbol.sessionAlerts, PanelSymbol.info, PanelSymbol.warning, PanelSymbol.error]
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
        _ body: (MenuStateModel, UserDefaults, String) throws -> Void
    ) rethrows {
        let suite = "com.muratalkan.napcat.tests.menupanel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let power = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        let limiter = ChargeLimiter(power: power, isAppleSilicon: true, defaults: defaults)
        let model = MenuStateModel(power: power, sleep: SleepStateController(), limiter: limiter,
                                   screenLock: lockAvailable ? ScreenLockController() : nil,
                                   detection: detection, lidGuard: lidGuard, finishAlert: finishAlert)
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
    @Test @MainActor func absentSubsystemsNeverRaiseTheBadge() throws {
        try withModel { model, _, _ in
            #expect(!model.claudeDetectionVisible && !model.lidGuardVisible)
            try #require(model.lockScreenAvailable, "canary: see lockSymbolResolvesOnThisMachine")
            #expect(model.detailsBadge == .nominal)
        }
    }

    /// Without the detection stack there is no Claude state to report, so the
    /// footer keeps its plain "Details" name instead of claiming "idle".
    @Test @MainActor func debugWiringKeepsThePlainDetailsLabel() throws {
        withModel { model, _, _ in
            #expect(!model.claudeDetectionVisible)
            #expect(model.detailsLabel == MenuStateModel.plainDetailsLabel)
            #expect(model.claudeAwakeLine == nil)
        }
        try withDetection { detection in
            detection.sample()
            withModel(detection: detection) { model, _, _ in
                #expect(model.detailsLabel == PanelLine(text: "Claude: idle", severity: .nominal))
            }
        }
    }

    /// THE BADGE RULE (2026-10-21): the Claude status is the disclosure's own
    /// text and carries its own warning, so a PAUSED Claude does not raise
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
                    #expect(model.detailsLabel.severity == .warning)
                    #expect(model.lidStatus.severity == .warning && model.lidStatus.text.contains("cannot fire"))
                    #expect(model.finishAlertDisplayState == .paused)
                    #expect(model.finishAlertStatus.severity == .warning)
                    #expect(model.detailsBadge == .nominal, "the pause's echoes must not raise the badge")
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
                #expect(model.detailsLabel == PanelLine(text: "Claude: paused", severity: .warning))
                #expect(model.hookStatus.severity == .nominal)
                #expect(model.claudeAwakeLine == PanelLine(text: "Claude is holding the Mac awake",
                                                           severity: .nominal),
                        "the awake fact is still reported while paused")
                #expect(model.detailsBadge == .nominal, "a paused Claude must not raise the badge")
            }
        }
        // A hook problem raises it (and still surfaces through its twin).
        try withDetection(hookInstalled: false) { detection in
            detection.sample()
            withModel(detection: detection) { model, _, _ in
                #expect(model.detailsLabel.severity == .nominal)
                #expect(model.hookStatus.severity == .warning)
                #expect(model.detailsBadge == .warning)
            }
        }
        // An unavailable Lock Screen raises it.
        withModel(lockAvailable: false) { model, _, _ in
            #expect(model.lockScreenStatus.severity == .warning)
            #expect(model.detailsBadge == .warning)
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
                    #expect(model.detailsBadge == .error)
                }
            }
        }
        // (A refused SESSION send: `aRefusedSessionAlertSurfacesAndRaisesTheBadge`.)
    }

    /// S7 end to end: the installed hook's stamp, sampled by the detection
    /// controller, reaches the panel — an out-of-date copy is a top-level
    /// warning that raises the badge; re-running the installer (the current
    /// stamp) tucks it back into Details as nominal.
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
            #expect(MenuStateModel.placement(ofDetailsLine: model.hookVersionStatus?.severity ?? .nominal) == .topLevel)
            #expect(model.detailsBadge == .warning)

            store.installedVersion = .some(ClaudeBusyConstants.hookVersion)
            detection.sample()
            model.refresh()
            #expect(model.hookVersionStatus == PanelLine(text: Self.hookVersionCurrentText, severity: .nominal))
            #expect(model.detailsBadge == .nominal)
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
                #expect(model.detailsLabel == PanelLine(text: "Claude: paused", severity: .warning))
                #expect(model.lidStatus.text.contains("cannot fire"))
                #expect(model.lidStatus.severity == .warning)
                #expect(MenuStateModel.placement(ofDetailsLine: model.lidStatus.severity) == .topLevel)
                try #require(model.lockScreenAvailable, "canary: see lockSymbolResolvesOnThisMachine")
                #expect(model.detailsBadge == .nominal, "the pause's echo in the lid line must not raise the badge")

                detection.setPaused(false)
                detection.sample()
                model.refresh()
                #expect(model.detailsLabel == PanelLine(text: "Claude: idle", severity: .nominal))
                #expect(model.lidStatus.text.contains("best-effort push"))
                #expect(model.lidStatus.severity == .nominal)
                #expect(model.detailsBadge == .nominal)
            }
        }
    }

    /// FA-4 end to end: a session alert refused by the server (403 here —
    /// never retried, the controller's half) reaches the panel as an error
    /// status, a last-send line that ESCAPES Details, and an error badge —
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
                    text: "Session alerts: the last message did not go out — re-run Send test message",
                    severity: .error))
                let last = model.finishAlertLastSend(now: Double(H.t0) + 120)
                #expect(last == PanelLine(
                    text: "Last session alert: refused by the server 2m ago (finished) (HTTP 403) — check the topic and server",
                    severity: .error))
                #expect(MenuStateModel.placement(ofDetailsLine: last.severity) == .topLevel)
                #expect(model.detailsBadge == .error)

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
                    text: "Session alerts: armed — a push when a Claude session finishes or waits for you",
                    severity: .nominal))
                // …while the Details history line is untouched and still
                // escapes Details (so the badge stays an error).
                #expect(model.finishAlertLastSend(now: Double(H.t0) + 120) == last)
                #expect(model.detailsBadge == .error)
            }
        }
    }

    /// B-1 end to end: a session alert refused with 429 holds the session
    /// lane (the controller's flush sits at the hold end) and the status
    /// says so as a WARNING — no "re-run Send test message" advice — while
    /// the Details history line still reports the refusal as an error that
    /// escapes Details (so the badge is an error). The C6 recovery rule
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
                #expect(MenuStateModel.placement(ofDetailsLine: model.finishAlertStatus.severity) == .topLevel)
                let last = model.finishAlertLastSend(now: Double(H.t0) + 120)
                #expect(last == PanelLine(
                    text: "Last session alert: refused by the server 2m ago (finished) (HTTP 429) — check the topic and server",
                    severity: .error))
                #expect(MenuStateModel.placement(ofDetailsLine: last.severity) == .topLevel)
                #expect(model.detailsBadge == .error, "the history line still raises the badge")

                // A LATER accepted lid-lane send clears the held caption too.
                lid.clock.advance(Double(H.t0) - lid.clock.now + 60)
                lid.controller.sendTestMessage()
                model.refresh()
                #expect(model.finishAlertStatus == PanelLine(text: Self.sessionArmedText, severity: .nominal))
                #expect(model.finishAlertLastSend(now: Double(H.t0) + 120) == last)
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
                #expect(model.detailsBadge == .nominal)
            }
        }
    }
}

// MARK: - Detection stubs (no filesystem scan, no process enumeration, no IOKit)
// Module-internal, so any suite can wire a hermetic detection controller into
// the real model or panel.

final class StubMarkerStore: BusyMarkerStore {
    /// false ⇒ no marker dir: the hook reads "not installed" (a warning).
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
