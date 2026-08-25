// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Pure Track B / B2 decision logic — the fire gate, the wall-clock cooldown,
/// recipient validation, the app-generated message bodies, the send-outcome
/// classifier, and the Automation-status mapping. Table-driven like
/// HysteresisEngineTests; nothing here sends anything or touches IOKit.
struct LidGuardPolicyTests {
    // MARK: - Fire gate

    /// One row of the gate table. The baseline is "everything is right, fire";
    /// each row flips exactly one condition unless noted.
    struct GateRow: Sendable {
        let id: String
        let enabled: Bool
        let recipientValid: Bool
        let primed: Bool
        let stayAwakeObserved: Bool?
        let taskInFlight: Bool
        let sendInFlight: Bool
        let lastFiredAt: Double?
        let now: Double
        let expected: LidGuardGateDecision

        init(
            _ id: String,
            enabled: Bool = true,
            recipientValid: Bool = true,
            primed: Bool = true,
            stayAwakeObserved: Bool? = false,
            taskInFlight: Bool = true,
            sendInFlight: Bool = false,
            lastFiredAt: Double? = nil,
            now: Double = 1_000_000,
            expected: LidGuardGateDecision
        ) {
            self.id = id
            self.enabled = enabled
            self.recipientValid = recipientValid
            self.primed = primed
            self.stayAwakeObserved = stayAwakeObserved
            self.taskInFlight = taskInFlight
            self.sendInFlight = sendInFlight
            self.lastFiredAt = lastFiredAt
            self.now = now
            self.expected = expected
        }

        var inputs: LidGuardGateInputs {
            LidGuardGateInputs(
                snapshot: LidGuardSnapshot(
                    enabled: enabled,
                    recipient: recipientValid ? "+15551234567" : "",
                    recipientValid: recipientValid,
                    primed: primed,
                    stayAwakeObserved: stayAwakeObserved,
                    taskInFlight: taskInFlight,
                    busySessionCount: taskInFlight ? 1 : 0
                ),
                sendInFlight: sendInFlight,
                lastFiredAt: lastFiredAt,
                now: now
            )
        }
    }

    static let gateRows: [GateRow] = [
        .init("G1 everything true", expected: .fire),
        .init("G2 feature off", enabled: false, expected: .skip(.disabled)),
        .init("G3 recipient invalid", recipientValid: false, expected: .skip(.invalidRecipient)),
        .init("G4 never primed", primed: false, expected: .skip(.notPrimed)),
        .init("G5 stay-awake is ON — the Mac is not really sleeping on us",
              stayAwakeObserved: true, expected: .skip(.stayAwakeOn)),
        .init("G6 stay-awake UNREADABLE fires (fail toward notify)",
              stayAwakeObserved: nil, expected: .fire),
        .init("G7 no Claude task in flight", taskInFlight: false, expected: .skip(.noTaskInFlight)),
        .init("G8 cooldown still running", lastFiredAt: 1_000_000 - 60, expected: .skip(.cooldown)),
        .init("G9 cooldown expired exactly at the boundary",
              lastFiredAt: 1_000_000 - LidGuardTuning.cooldownSeconds, expected: .fire),
        .init("G10 cooldown one second short of the boundary",
              lastFiredAt: 1_000_000 - LidGuardTuning.cooldownSeconds + 1, expected: .skip(.cooldown)),
        .init("G11 cooldown expired across an overnight sleep (wall clock +8h)",
              lastFiredAt: 1_000_000 - 8 * 3_600, expected: .fire),
        .init("G12 a send is already in flight (single-flight)",
              sendInFlight: true, expected: .skip(.sendInFlight)),
        .init("G13 disabled beats every other reason",
              enabled: false, recipientValid: false, primed: false,
              stayAwakeObserved: true, taskInFlight: false, sendInFlight: true,
              expected: .skip(.disabled)),
        .init("G14 clock jumped backwards — hold the cooldown, never double-text",
              lastFiredAt: 1_000_000 + 3_600, expected: .skip(.cooldown)),
    ]

    @Test(arguments: gateRows)
    func fireGateTable(row: GateRow) {
        #expect(LidGuardPolicy.decide(row.inputs) == row.expected, "\(row.id)")
    }

    /// Guard against a row being silently dropped or duplicated.
    @Test func gateTableRowsAreUniqueAndComplete() {
        #expect(Self.gateRows.count == 14)
        #expect(Set(Self.gateRows.map(\.id)).count == Self.gateRows.count)
        // Every skip reason must be exercised by at least one row.
        let reasons: Set<LidGuardSkipReason> = Set(Self.gateRows.compactMap { row in
            if case .skip(let reason) = row.expected { return reason }
            return nil
        })
        let all: Set<LidGuardSkipReason> = [
            .disabled, .invalidRecipient, .notPrimed, .stayAwakeOn,
            .noTaskInFlight, .cooldown, .sendInFlight,
        ]
        #expect(reasons == all)
    }

    // MARK: - Cooldown clock

    /// The cooldown MUST be measured on a clock that keeps ticking while the
    /// Mac is asleep. This encodes the difference: after an 8 h sleep a wall
    /// clock has advanced 8 h (cooldown expired), while an uptime/monotonic
    /// clock — `mach_absolute_time`, `SuspendingClock`, `DispatchTime` — has
    /// barely moved, so a cooldown built on one would never expire overnight.
    @Test func cooldownNeedsAClockThatAdvancesAcrossSleep() {
        let firedAt = 1_000_000.0
        let sleptEightHours = 8.0 * 3_600

        // Uptime-style: only the few awake seconds are counted.
        #expect(!LidGuardPolicy.cooldownExpired(lastFiredAt: firedAt, now: firedAt + 3))
        // Wall-clock over the same real interval.
        #expect(LidGuardPolicy.cooldownExpired(lastFiredAt: firedAt, now: firedAt + sleptEightHours))
    }

    @Test func neverFiredMeansCooldownIsExpired() {
        #expect(LidGuardPolicy.cooldownExpired(lastFiredAt: nil, now: 0))
    }

    @Test func cooldownIsAtLeastFifteenMinutes() {
        #expect(LidGuardTuning.cooldownSeconds >= 15 * 60)
    }

    /// The single tunable the design fixes by value.
    @Test func ackHoldBudgetIsTheLockedValue() {
        #expect(LidGuardTuning.ackHoldBudget == 1.5)
        #expect(LidGuardTuning.forceAckCeiling < 30, "must never approach the OS ceiling")
        #expect(LidGuardTuning.ackHoldBudget < LidGuardTuning.forceAckCeiling)
    }

    // MARK: - Recipient validation

    @Test(arguments: [
        ("+15551234567", RecipientValidation.valid("+15551234567")),
        ("  you@example.com  ", .valid("you@example.com")),
        ("", .empty),
        ("   ", .empty),
        ("\n", .empty),
        ("+1555\n1234567", .invalid),
        ("+1555\r1234567", .invalid),
        ("a\u{0000}b", .invalid),
        ("a\u{007F}b", .invalid),
        ("a\u{0085}b", .invalid),
        // Interior Unicode line/paragraph separators survive the trim; reject.
        ("a\u{2028}b", .invalid),
        ("a\u{2029}b", .invalid),
        (String(repeating: "9", count: 128), .valid(String(repeating: "9", count: 128))),
        (String(repeating: "9", count: 129), .invalid),
    ])
    func recipientValidationTable(raw: String, expected: RecipientValidation) {
        #expect(LidGuardPolicy.validateRecipient(raw) == expected)
    }

    @Test func invalidRecipientLeavesTheFeatureInert() {
        #expect(LidGuardPolicy.normalizedRecipient("bad\nvalue") == nil)
        #expect(LidGuardPolicy.armingState(enabled: true, recipient: "bad\nvalue", primedAt: 1) == .needsRecipient)
    }

    // MARK: - Arming

    @Test(arguments: [
        (false, "+15551234567", 1.0, LidGuardArmingState.off),
        (true, "", 1.0, .needsRecipient),
        (true, "   ", 1.0, .needsRecipient),
        (true, "+15551234567", 0.0, .needsTestSend),
        (true, "+15551234567", 1.0, .armed),
    ])
    func armingStateTable(enabled: Bool, recipient: String, primedAt: Double, expected: LidGuardArmingState) {
        #expect(LidGuardPolicy.armingState(enabled: enabled, recipient: recipient, primedAt: primedAt) == expected)
    }

    // MARK: - Message body (app-generated only)

    @Test func clockTimeIsFormattedFromTheGivenCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 2023-11-14 22:13:20 UTC
        #expect(LidGuardPolicy.clockTime(Date(timeIntervalSince1970: 1_700_000_000), calendar: calendar) == "22:13")
        // Zero-padding both fields.
        #expect(LidGuardPolicy.clockTime(Date(timeIntervalSince1970: 3_660), calendar: calendar) == "01:01")
    }

    /// The body is a fixed template + the clock time + the COUNT. It must never
    /// contain anything that could have come from a session.
    @Test(arguments: [0, 1, 2, 7])
    func lidAlertBodyIsTemplatePlusTimeAndCount(count: Int) {
        let body = LidGuardPolicy.messageBody(kind: .lidAlert(busySessionCount: count), clockTime: "22:49")
        #expect(body.contains("NapCat"))
        #expect(body.contains("22:49"))
        #expect(body.contains("Stay Awake is off"))
        if count > 1 {
            #expect(body.contains("\(count) Claude Code tasks"))
        } else if count == 1 {
            #expect(body.contains("1 Claude Code task"))
        } else {
            #expect(body.contains("a Claude Code task"))
        }
        // No placeholder ever leaks through.
        #expect(!body.contains("%"))
        #expect(!body.contains("nil"))
    }

    @Test func testMessageBodyIsSelfExplaining() {
        let body = LidGuardPolicy.messageBody(kind: .test, clockTime: "09:05")
        #expect(body.contains("NapCat test message"))
        #expect(body.contains("09:05"))
    }

    /// The set of message kinds is CLOSED and carries no free text: the only
    /// associated value in the whole enum is an Int count.
    @Test func messageKindsCarryNoFreeText() {
        let kinds: [LidGuardMessageKind] = [.test, .lidAlert(busySessionCount: 3)]
        for kind in kinds {
            let mirrored = Mirror(reflecting: kind)
            for child in mirrored.children {
                #expect(!(child.value is String), "a message kind must never carry a String payload")
            }
        }
        // A count is all that distinguishes two lid alerts.
        #expect(LidGuardMessageKind.lidAlert(busySessionCount: 3) != .lidAlert(busySessionCount: 4))
    }

    // MARK: - Send-outcome classifier (fixtures)

    @Test func exitZeroIsHandedToMessagesNotSent() {
        #expect(LidGuardPolicy.classifySend(exitStatus: 0, stderr: "") == .handedToMessages)
    }

    @Test(arguments: [
        "execution error: Not authorized to send Apple events to Messages. (-1743)",
        "errAEEventNotPermitted",
        "execution error: Messages got an error: AppleEvent timed out. (-1712)",
    ])
    func permissionFailuresAreClassifiedAsDenied(stderr: String) {
        #expect(LidGuardPolicy.classifySend(exitStatus: 1, stderr: stderr) == .permissionDenied)
    }

    @Test func stillRunningAtTheBudgetIsUnconfirmed() {
        #expect(LidGuardPolicy.classifySend(exitStatus: nil, stderr: "") == .timedOutUnconfirmed)
        // Even with denial text on stderr, "did not exit" wins — we cannot
        // claim to know the outcome.
        #expect(LidGuardPolicy.classifySend(exitStatus: nil, stderr: "(-1743)") == .timedOutUnconfirmed)
    }

    @Test func anythingElseIsASendFailure() {
        #expect(LidGuardPolicy.classifySend(exitStatus: 1, stderr: "  syntax error: Expected end of line. (-2741)  ")
                == .sendFailed("syntax error: Expected end of line. (-2741)"))
        #expect(LidGuardPolicy.classifySend(exitStatus: 2, stderr: "") == .sendFailed("the send helper exited 2"))
    }

    // MARK: - Outcome log split (recipient PII must never reach a .public line)

    /// The free-form `sendFailed` detail is raw osascript stderr, which can echo
    /// the recipient. The split locks that detail into the PRIVATE field while
    /// the public category stays free of it — so the logging path can route the
    /// detail through `privacy: .private`.
    @Test func outcomeLogSplitKeepsTheFreeFormDetailOutOfThePublicCategory() {
        for outcome in [MessageSendOutcome.handedToMessages, .permissionDenied, .timedOutUnconfirmed] {
            let fields = LidGuardPolicy.outcomeLogFields(outcome)
            #expect(fields.privateDetail == nil, "\(outcome) carries no free-form detail")
            #expect(!fields.publicCategory.isEmpty)
        }
        let fields = LidGuardPolicy.outcomeLogFields(.sendFailed("error: +15551234567 not authorized"))
        #expect(fields.publicCategory == "sendFailed")
        #expect(fields.privateDetail == "error: +15551234567 not authorized")
        // The recipient echoed in stderr must never leak into the public category.
        #expect(!fields.publicCategory.contains("+15551234567"))
    }

    // MARK: - Automation permission mapping

    @Test(arguments: [
        (Int32(0), AutomationPermission.granted),
        (-1743, .denied),
        (-1744, .wouldRequireConsent),
        (-600, .targetNotRunning),
        (-42, .unknown(-42)),
    ])
    func automationStatusMapping(status: Int32, expected: AutomationPermission) {
        #expect(LidGuardPolicy.automationPermission(fromStatus: status) == expected)
    }

    /// "Messages is not running" must never be mistaken for a verdict.
    @Test func targetNotRunningIsNeitherGrantedNorDenied() {
        let permission = LidGuardPolicy.automationPermission(fromStatus: LidGuardPolicy.procNotFoundStatus)
        #expect(permission != .granted)
        #expect(permission != .denied)
        #expect(permission == .targetNotRunning)
    }

    // MARK: - Wiring predicate

    @Test func debugSimulatorModeMayNotConstructTheSubsystem() {
        #expect(!LidGuardPolicy.lidGuardMayBeConstructed(debugBattery: true))
        #expect(LidGuardPolicy.lidGuardMayBeConstructed(debugBattery: false))
    }

    // MARK: - B1 reuse: fresh marker count

    @Test func freshMarkerCountCountsOnlyFreshMarkers() {
        let now = 1_000_000
        let markers = [
            BusyMarker(ts: now - 10, event: "UserPromptSubmit", pid: 1, src: "cli"),
            BusyMarker(ts: now - 60, event: "UserPromptSubmit", pid: 2, src: "cli"),
            // stale (>12h) and future-dated markers never count
            BusyMarker(ts: now - ClaudeBusyConstants.freshnessCapSeconds - 1, event: "UserPromptSubmit", pid: 3, src: "cli"),
            BusyMarker(ts: now + 60, event: "UserPromptSubmit", pid: 4, src: "cli"),
        ]
        #expect(ClaudeActivityPolicy.freshMarkerCount(markers: markers, now: now) == 2)
        #expect(ClaudeActivityPolicy.freshMarkerCount(markers: [], now: now) == 0)
    }
}
