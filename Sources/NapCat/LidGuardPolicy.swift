import Foundation

/// Tunables for the Track B lid guard (slice B2). These are CODE CONSTANTS, not
/// UserDefaults keys — PLAN.md §11 gains exactly three persisted lid-guard keys
/// (enable / recipient / primed-at) and nothing else.
enum LidGuardTuning {
    /// How long the WillSleep handler may hold the power-change acknowledgment
    /// while the send is handed to Messages (user-chosen 2026-08-24).
    ///
    /// HONEST LIMIT: even 1.5 s only guarantees that the AppleEvent reached
    /// Messages. iMessage (IDS) transmission is asynchronous and may well
    /// finish only after the Mac wakes — the outcome is reported as
    /// `handedToMessages`, never "sent".
    static let ackHoldBudget: TimeInterval = 1.5

    /// Unconditional force-ack ceiling. An unacknowledged power notification
    /// delays the sleep for the OS cap (~30 s), so we ack far below it no
    /// matter what the send path does.
    static let forceAckCeiling: TimeInterval = 20

    /// Minimum WALL-CLOCK gap between two alerts. Must be evaluated on a clock
    /// that advances across sleep (see `LidGuardPolicy.cooldownExpired`);
    /// generous enough that dark wakes / Power Nap cannot double-text.
    static let cooldownSeconds: TimeInterval = 15 * 60

    /// Hard budget for collecting the fire-gate snapshot. The Claude detection
    /// readers are main-actor isolated, so the sleep handler hops to the main
    /// queue; if that hop does not return inside this budget we skip (never
    /// fire blind) and acknowledge the power change.
    static let snapshotBudget: TimeInterval = 0.5

    /// Backstop that kills a stuck `osascript` child. Measured on a SUSPENDING
    /// (uptime) clock — see `OSAScriptMessageSender` — so an overnight sleep
    /// does not consume the budget and the child is not killed mid-send on wake.
    static let sendHardKillTimeout: TimeInterval = 15

    /// Upper bound on a stored recipient (an Apple ID or phone number); longer
    /// input is rejected rather than truncated.
    static let maxRecipientLength = 128

    /// Automation target for the permission probe and the send.
    static let messagesBundleID = "com.apple.MobileSMS"

    /// The FIXED AppleScript shipped in the app bundle (precedent:
    /// Resources/napcat-watchdog.sh). Invoked as
    /// `/usr/bin/osascript <path> <recipient> <body>` — argv, never
    /// string-interpolated into the script source.
    static let scriptResourceName = "napcat-send-imessage"
    static let scriptResourceExtension = "applescript"
}

// MARK: - Recipient validation

/// Result of validating a user-entered iMessage recipient. `invalid` keeps the
/// feature inert with an inline caption — no send path is reachable and nothing
/// crashes.
enum RecipientValidation: Equatable, Sendable {
    /// Trimmed, safe to pass as argv.
    case valid(String)
    /// Nothing entered yet.
    case empty
    /// Contains control characters (CR/LF included) or exceeds the length cap.
    case invalid
}

// MARK: - Arming

/// Whether the lid guard is armed, and if not, what is missing. The IOKit
/// sleep notification is registered ONLY in `.armed` — the OFF states have
/// zero sleep-path footprint.
enum LidGuardArmingState: Equatable, Sendable {
    /// Feature toggle is off.
    case off
    /// Enabled but no valid recipient stored.
    case needsRecipient
    /// Enabled with a recipient, but the config-time test send has never
    /// succeeded — arming REQUIRES it so the Automation (TCC) prompt is
    /// answered while the user is present, never at lid-close.
    case needsTestSend
    /// Enabled ∧ recipient valid ∧ primed.
    case armed
}

// MARK: - Fire gate

/// Everything the fire gate reads about the world, sampled FRESH at WillSleep.
struct LidGuardSnapshot: Equatable, Sendable {
    let enabled: Bool
    /// Normalized recipient; empty when `recipientValid` is false.
    let recipient: String
    let recipientValid: Bool
    let primed: Bool
    /// OBSERVED `pmset -g` SleepDisabled mirror. `nil` = unreadable, which
    /// satisfies "≠ true" and therefore FIRES (deliberate fail-toward-notify).
    let stayAwakeObserved: Bool?
    let taskInFlight: Bool
    let busySessionCount: Int
}

enum LidGuardSkipReason: String, Equatable, Sendable {
    case disabled
    case invalidRecipient
    case notPrimed
    case stayAwakeOn
    case noTaskInFlight
    case cooldown
    case sendInFlight
}

enum LidGuardGateDecision: Equatable, Sendable {
    case fire
    case skip(LidGuardSkipReason)
}

/// Inputs to the pure gate: the world snapshot plus the controller's own
/// in-memory bookkeeping and an injected wall clock.
struct LidGuardGateInputs: Equatable, Sendable {
    let snapshot: LidGuardSnapshot
    let sendInFlight: Bool
    /// Unix epoch seconds of the last fired alert; `nil` = never fired.
    /// In-memory only — persisting it would cache intent across relaunches.
    let lastFiredAt: Double?
    /// Unix epoch seconds NOW (wall clock — it advances across sleep).
    let now: Double
}

// MARK: - Message shape

/// The only two messages NapCat can ever send. There is deliberately no
/// free-text case: every body is built by `LidGuardPolicy.messageBody` from a
/// fixed template plus the event clock time and the busy-session COUNT, so
/// nothing from a Claude session, transcript, or working directory is reachable.
enum LidGuardMessageKind: Equatable, Sendable {
    case lidAlert(busySessionCount: Int)
    case test
}

/// Outcome of one send attempt. `handedToMessages` deliberately does NOT claim
/// delivery — the AppleEvent was accepted, IDS transmit is asynchronous.
enum MessageSendOutcome: Equatable, Sendable {
    case handedToMessages
    case permissionDenied
    /// The budget expired with the child still running: we do not know whether
    /// Messages accepted it.
    case timedOutUnconfirmed
    case sendFailed(String)
}

// MARK: - Automation (TCC) permission

/// Result of the SILENT `AEDeterminePermissionToAutomateTarget` probe
/// (`askUserIfNeeded: false` — it must never raise a prompt).
enum AutomationPermission: Equatable, Sendable {
    case granted
    case denied
    case wouldRequireConsent
    /// Messages is not running: the probe cannot tell — NEVER reported as
    /// ready or denied.
    case targetNotRunning
    case unknown(Int32)
}

/// Pure Track B / B2 decision logic: arming, the fire gate, recipient
/// validation, the app-generated message bodies, the send-outcome classifier,
/// and the debug-sim wiring predicate. No I/O, no subprocess, no syscalls —
/// `LidGuardStructureTests` keeps `Process`, `osascript`,
/// `IORegisterForSystemPower`, and `AEDeterminePermissionToAutomateTarget` out
/// of this file. Table-tested like `HysteresisEngine`.
enum LidGuardPolicy {
    // MARK: Wiring predicate (ADR §8 mirror, same shape as B1's)

    /// In debugBattery mode the ENTIRE B2 subsystem is structurally absent: no
    /// IOKit power registration, no sender, no osascript — ever.
    static func lidGuardMayBeConstructed(debugBattery: Bool) -> Bool {
        !debugBattery
    }

    // MARK: Recipient validation

    /// Trim, then reject empty, control characters (CR/LF included), and
    /// anything past the length cap. The accepted value is passed as argv, so
    /// it is never parsed as script source; the checks exist so a fat-fingered
    /// entry leaves the feature inert with a caption instead of producing a
    /// weird send.
    static func validateRecipient(_ raw: String) -> RecipientValidation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.count > LidGuardTuning.maxRecipientLength { return .invalid }
        if trimmed.unicodeScalars.contains(where: { isControlScalar($0) }) { return .invalid }
        return .valid(trimmed)
    }

    /// C0/C1 control characters, DEL, and the Unicode line/paragraph separators
    /// (U+2028/U+2029) — the class that could smuggle a newline into a log line
    /// or an argv boundary into a shell-looking string. U+2028/U+2029 are
    /// checked explicitly because an INTERIOR one survives the leading/trailing
    /// `.whitespacesAndNewlines` trim.
    private static func isControlScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
            || (scalar.value >= 0x80 && scalar.value <= 0x9F)
            || scalar.value == 0x2028 || scalar.value == 0x2029
    }

    /// Convenience: the normalized recipient, or nil when it is unusable.
    static func normalizedRecipient(_ raw: String) -> String? {
        if case .valid(let recipient) = validateRecipient(raw) { return recipient }
        return nil
    }

    // MARK: Arming

    /// Armed iff enabled ∧ recipient valid ∧ primed. Precedence of the "not
    /// armed" reasons is off → needsRecipient → needsTestSend, so the menu
    /// caption always names the NEXT thing the user has to do.
    static func armingState(enabled: Bool, recipient: String, primedAt: Double) -> LidGuardArmingState {
        guard enabled else { return .off }
        guard normalizedRecipient(recipient) != nil else { return .needsRecipient }
        guard primedAt > 0 else { return .needsTestSend }
        return .armed
    }

    // MARK: Fire gate (pure, table-tested)

    /// `fire iff enabled ∧ recipientValid ∧ primed ∧ stayAwakeObserved ≠ true
    /// ∧ taskInFlight ∧ cooldownExpired ∧ ¬sendInFlight`.
    ///
    /// The checks run in that order so the logged skip reason names the FIRST
    /// unmet condition. Note `stayAwakeObserved == nil` (pmset unreadable) does
    /// NOT block: unknown fails toward notifying.
    static func decide(_ inputs: LidGuardGateInputs) -> LidGuardGateDecision {
        let snapshot = inputs.snapshot
        guard snapshot.enabled else { return .skip(.disabled) }
        guard snapshot.recipientValid else { return .skip(.invalidRecipient) }
        guard snapshot.primed else { return .skip(.notPrimed) }
        guard snapshot.stayAwakeObserved != true else { return .skip(.stayAwakeOn) }
        guard snapshot.taskInFlight else { return .skip(.noTaskInFlight) }
        guard cooldownExpired(lastFiredAt: inputs.lastFiredAt, now: inputs.now) else { return .skip(.cooldown) }
        guard !inputs.sendInFlight else { return .skip(.sendInFlight) }
        return .fire
    }

    /// WALL-CLOCK cooldown. `now` and `lastFiredAt` are unix epoch seconds
    /// (`Date`), which keep advancing while the Mac is asleep — a monotonic /
    /// uptime clock would freeze overnight and the cooldown would never expire.
    /// A backwards clock jump (`now < lastFiredAt`) reads as "not expired",
    /// the conservative direction: never double-text.
    static func cooldownExpired(lastFiredAt: Double?, now: Double) -> Bool {
        guard let lastFiredAt else { return true }
        return now - lastFiredAt >= LidGuardTuning.cooldownSeconds
    }

    // MARK: App-generated message bodies

    /// `HH:mm` in the given calendar. Split from `messageBody` so both halves
    /// stay deterministically testable.
    static func clockTime(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    /// The ONLY place a message body is produced. Inputs are a fixed template,
    /// the event clock time, and a COUNT — never any text from a session.
    static func messageBody(kind: LidGuardMessageKind, clockTime: String) -> String {
        switch kind {
        case .lidAlert(let busySessionCount):
            return "NapCat: this Mac started going to sleep at \(clockTime) while "
                + taskPhrase(busySessionCount)
                + " still running, and Stay Awake is off."
        case .test:
            return "NapCat test message (\(clockTime)). Messages automation works — "
                + "this is what you'll get if your Mac sleeps mid-task."
        }
    }

    /// Count → phrase. A non-positive count cannot happen through the gate
    /// (it requires a task in flight) but degrades to the indefinite form
    /// rather than printing "0 Claude Code tasks".
    static func taskPhrase(_ count: Int) -> String {
        switch count {
        case ..<1: return "a Claude Code task was"
        case 1: return "1 Claude Code task was"
        default: return "\(count) Claude Code tasks were"
        }
    }

    // MARK: Send-outcome classification (mirrors the P2 sudo-stderr classifier)

    /// AppleEvent error numbers osascript reports on stderr.
    static let errAEEventNotPermittedStatus: Int32 = -1743
    static let errAEEventWouldRequireUserConsentStatus: Int32 = -1744
    /// AppleEvent timeout — what an UNANSWERED TCC prompt looks like from here.
    static let errAETimeoutStatus: Int32 = -1712
    /// The target application is not running.
    static let procNotFoundStatus: Int32 = -600

    /// Pure classification of one osascript run (fixture-tested):
    /// - the child had not exited when the budget expired (`exitStatus == nil`)
    ///   → `timedOutUnconfirmed`
    /// - exit 0 → `handedToMessages` (NOT "sent": the AppleEvent was accepted,
    ///   IDS transmit is asynchronous and may complete on wake)
    /// - stderr naming -1743 / errAEEventNotPermitted, or -1712 (an AE timeout
    ///   is an unanswered Automation prompt) → `permissionDenied`
    /// - anything else → `sendFailed`
    static func classifySend(exitStatus: Int32?, stderr: String) -> MessageSendOutcome {
        guard let exitStatus else { return .timedOutUnconfirmed }
        if exitStatus == 0 { return .handedToMessages }
        let denialNeedles = [
            "\(errAEEventNotPermittedStatus)",
            "errAEEventNotPermitted",
            "\(errAETimeoutStatus)",
        ]
        if denialNeedles.contains(where: { stderr.contains($0) }) { return .permissionDenied }
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .sendFailed(detail.isEmpty ? "the send helper exited \(exitStatus)" : detail)
    }

    /// Splits a send outcome for logging into a log-safe public CATEGORY and an
    /// optional free-form detail. Only `.sendFailed` carries a detail, and that
    /// detail is raw osascript stderr — which can echo the recipient (the
    /// user's own phone number / Apple ID). The category is safe to log at
    /// `privacy: .public`; the detail must ONLY ever be logged at
    /// `privacy: .private`, so the recipient never lands in a `.public`
    /// unified-log line (captured by sysdiagnose).
    static func outcomeLogFields(_ outcome: MessageSendOutcome) -> (publicCategory: String, privateDetail: String?) {
        switch outcome {
        case .handedToMessages: return ("handedToMessages", nil)
        case .permissionDenied: return ("permissionDenied", nil)
        case .timedOutUnconfirmed: return ("timedOutUnconfirmed", nil)
        case .sendFailed(let detail): return ("sendFailed", detail)
        }
    }

    // MARK: Automation permission mapping

    /// `AEDeterminePermissionToAutomateTarget` status → state. `procNotFound`
    /// means Messages is not running, which tells us NOTHING about the grant —
    /// it must never render as ready or denied.
    static func automationPermission(fromStatus status: Int32) -> AutomationPermission {
        switch status {
        case 0: return .granted
        case errAEEventNotPermittedStatus: return .denied
        case errAEEventWouldRequireUserConsentStatus: return .wouldRequireConsent
        case procNotFoundStatus: return .targetNotRunning
        default: return .unknown(status)
        }
    }
}
