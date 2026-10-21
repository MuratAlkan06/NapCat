import Foundation

/// Tunables for the Track B lid guard (slice B2, ntfy delivery since B4).
/// These are CODE CONSTANTS, not UserDefaults keys — PLAN.md §11 gains exactly
/// four persisted lid-guard keys (enable / topic / server / primed-at) plus,
/// since Track C, ONE finish-alert toggle (`claudeFinishAlertEnabled`), which
/// reuses that same destination and priming; nothing else.
enum LidGuardTuning {
    /// How long the WillSleep handler may hold the power-change acknowledgment
    /// while the alert POST is handed to URLSession (user-chosen 2026-08-24,
    /// unchanged by the channel swap).
    ///
    /// HONEST LIMIT: 1.5 s buys the request a chance to leave the Mac. Whether
    /// the ntfy server actually answered before the machine went down is not
    /// knowable here — an unanswered request is reported as
    /// `timedOutUnconfirmed`, never "sent".
    static let ackHoldBudget: TimeInterval = 1.5

    /// Unconditional force-ack ceiling. An unacknowledged power notification
    /// delays the sleep for the OS cap (~30 s), so we ack far below it no
    /// matter what the send path does.
    static let forceAckCeiling: TimeInterval = 20

    /// Minimum WALL-CLOCK gap between two alerts. Must be evaluated on a clock
    /// that advances across sleep (see `LidGuardPolicy.cooldownExpired`);
    /// generous enough that dark wakes / Power Nap cannot double-notify.
    static let cooldownSeconds: TimeInterval = 15 * 60

    /// Hard budget for collecting the fire-gate snapshot. The Claude detection
    /// readers are main-actor isolated, so the sleep handler hops to the main
    /// queue; if that hop does not return inside this budget we skip (never
    /// fire blind) and acknowledge the power change.
    static let snapshotBudget: TimeInterval = 0.5

    /// URLSession request/resource timeout for one publish. It is deliberately
    /// far longer than `ackHoldBudget`: the sleep hold is what buys the request
    /// its transmission window, and a request still running when the Mac goes
    /// down finishes (or fails) on wake rather than being abandoned.
    static let requestTimeout: TimeInterval = 10

    // MARK: ntfy protocol constants

    /// Default public instance. The server is user-overridable so a
    /// self-hosted ntfy works, but it must always be an https origin.
    static let defaultNtfyServer = "https://ntfy.sh"

    /// ntfy topic grammar: 1–64 characters from `[A-Za-z0-9_-]`.
    /// THE TOPIC NAME IS THE ONLY PASSWORD on a public ntfy feed — anyone who
    /// knows it can read and post to it. It is therefore treated as a secret
    /// everywhere: never logged, never echoed into a menu caption, never
    /// interpolated into anything but the request URL.
    static let maxTopicLength = 64

    /// Upper bound on a stored server origin (scheme + max DNS name + port);
    /// longer input is rejected rather than truncated.
    static let maxServerLength = 300

    /// Fixed publish headers. ASCII only — HTTP header values must be, and
    /// ntfy would otherwise need RFC 2047 encoding. Title and Content-Type are
    /// the same for every message; Priority and Tags are PER KIND and chosen
    /// only by `LidGuardPolicy.ntfyHeaders(for:)` from the constants below.
    static let ntfyTitleHeader = "Title"
    static let ntfyTitleValue = "NapCat"
    static let ntfyPriorityHeader = "Priority"
    /// `urgent` = ntfy priority 5 (alias `max`). ntfy iOS v1.8.0 delivers
    /// priority-5 messages as iOS CRITICAL ALERTS that bypass silent mode and
    /// Do Not Disturb — the user's phone is permanently on silent, so the lid
    /// alert needs p5 to be heard at all the moment that app version ships.
    /// On Android (and on iOS before 1.8.0) it only means a longer vibration
    /// burst plus a pop-over. Was `high` (p4) until curation round 1,
    /// 2026-10-18 (PLAN.md decision log). The LID constants: the lid alert
    /// and the test message (which proves exactly that delivery) use them.
    static let ntfyPriorityValue = "urgent"
    static let ntfyTagsHeader = "Tags"
    static let ntfyTagsValue = "zzz,warning"
    /// Track C session alerts. `high` = ntfy priority 4: a long vibration
    /// burst + pop-over, deliberately BELOW the lid alert's critical-alert p5 —
    /// a finished or waiting Claude session is news, not an emergency.
    static let finishPriorityValue = "high"
    static let finishTagsValue = "white_check_mark"
    static let attentionPriorityValue = "high"
    static let attentionTagsValue = "raised_hand"
    static let ntfyContentTypeHeader = "Content-Type"
    static let ntfyContentTypeValue = "text/plain; charset=utf-8"
}

// MARK: - Destination

/// A VALIDATED ntfy destination: an https origin plus a topic that matches the
/// ntfy grammar. The sender builds its URL only from these two fields, so no
/// unvalidated user text can ever reach a URL.
///
/// Build it exclusively through `LidGuardPolicy.destination(server:topic:)` —
/// `LidGuardStructureTests` lints that no other source file constructs one.
struct NtfyDestination: Equatable, Sendable {
    /// Normalized origin: `https://host[:port]`, never a trailing slash.
    let server: String
    /// Normalized topic — a SECRET (see `LidGuardTuning.maxTopicLength`).
    let topic: String
}

// MARK: - Config validation

/// Result of validating the user-entered ntfy topic. `invalid` keeps the
/// feature inert with an inline caption — no send path is reachable and nothing
/// crashes.
enum TopicValidation: Equatable, Sendable {
    /// Trimmed and grammar-checked, safe to use as the single URL path segment.
    case valid(String)
    /// Nothing entered yet.
    case empty
    /// Empty after trimming is `.empty`; this is "entered, but unusable":
    /// too long, or containing anything outside `[A-Za-z0-9_-]`.
    case invalid
}

/// Result of validating the user-entered ntfy server.
enum ServerValidation: Equatable, Sendable {
    /// Normalized `https://host[:port]` — no trailing slash, no path.
    case valid(String)
    /// Nothing entered — the caller falls back to
    /// `LidGuardTuning.defaultNtfyServer`.
    case empty
    /// Not an https origin, or it carries a path / query / fragment /
    /// credentials, or its host is not a plain `[A-Za-z0-9._-]` name (see
    /// `LidGuardPolicy.isUsableServerHost` — that rule is what stops a
    /// percent-encoded host from smuggling any of the above back in).
    case invalid
}

// MARK: - Arming

/// Whether the lid guard is armed, and if not, what is missing. The IOKit
/// sleep notification is registered ONLY in `.armed` — the OFF states have
/// zero sleep-path footprint.
enum LidGuardArmingState: Equatable, Sendable {
    /// Feature toggle is off.
    case off
    /// Enabled but no usable topic (or an unusable server) stored.
    case needsTopic
    /// Enabled with a destination, but the config-time test send has never
    /// succeeded — arming REQUIRES it so the user proves the topic is
    /// subscribed on their phone before the lid-close message depends on it.
    case needsTestSend
    /// Enabled ∧ destination valid ∧ primed.
    case armed
}

// MARK: - Fire gate

/// Everything the fire gate reads about the world, sampled FRESH at WillSleep.
struct LidGuardSnapshot: Equatable, Sendable {
    let enabled: Bool
    /// Validated destination; nil exactly when `topicValid` is false.
    let destination: NtfyDestination?
    /// Topic AND server both usable.
    let topicValid: Bool
    let primed: Bool
    /// OBSERVED `pmset -g` SleepDisabled mirror. `nil` = unreadable, which
    /// satisfies "≠ true" and therefore FIRES (deliberate fail-toward-notify).
    let stayAwakeObserved: Bool?
    let taskInFlight: Bool
    let busySessionCount: Int
}

enum LidGuardSkipReason: String, Equatable, Sendable {
    case disabled
    case invalidTopic
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

/// The messages NapCat can ever send: exactly four closed kinds. There is
/// deliberately no free-text case: every body is built by
/// `LidGuardPolicy.messageBody` from a fixed template plus, at most, the event
/// clock time and Int COUNTS / MINUTES, so nothing from a Claude session,
/// transcript, prompt, or working directory is reachable. Every associated
/// value is an `Int` (or `Int?`) — `LidGuardPolicyTests` locks that.
enum LidGuardMessageKind: Equatable, Sendable {
    /// Track B: the Mac started sleeping mid-task (lid lane).
    case lidAlert(busySessionCount: Int)
    /// The config-time priming send (lid lane).
    case test
    /// Track C: `folded` sessions' work fully ended (main turn AND background
    /// subagents) inside one batch window; `minutes` is the run length when
    /// exactly one finished and it is known, `stillWorking` the sessions
    /// still busy (session lane).
    case sessionFinished(minutes: Int?, folded: Int, stillWorking: Int)
    /// Track C waiting buzz: a session stopped to ask for approval/input
    /// `minutes` into its run (session lane).
    case needsAttention(minutes: Int?, stillWorking: Int)
}

/// The two per-kind ntfy headers. Both values are FIXED ASCII constants from
/// `LidGuardTuning` — never derived from any input.
struct NtfyHeaders: Equatable, Sendable {
    let priority: String
    let tags: String
}

/// Independent single-flight lanes in `NtfyMessageSender` (risk F2). A Track C
/// session alert may hold its lane for up to `LidGuardTuning.requestTimeout`;
/// it must NEVER cause the WillSleep lid publish to be refused, so the lid
/// alert (and the test send that primes it) get a lane of their own.
enum NtfySendLane: CaseIterable, Sendable {
    case lid
    case session
}

/// Outcome of one publish attempt. `accepted` deliberately does NOT claim the
/// phone got it — ntfy has the message (and caches it 12 h), but the push to
/// the device is asynchronous.
enum MessageSendOutcome: Equatable, Sendable {
    /// HTTP 2xx: the ntfy server took the message.
    case accepted
    /// The server answered with a non-2xx status (bad topic, auth required on
    /// a self-hosted instance, rate limit…). The status code is NOT a secret.
    case rejected(Int)
    /// The request reported no usable answer — timed out, connection lost, or
    /// the response could not be read: we do not know whether it left. Never
    /// retried (a retry could duplicate a message ntfy already has).
    case timedOutUnconfirmed
    /// The publish provably never left the Mac: a pre-connect transport failure
    /// (`LidGuardPolicy.preConnectTransportErrorCodes`) or an inline refusal by
    /// the sender. The detail comes from a FIXED vocabulary
    /// (`LidGuardPolicy.transportErrorName`) so it can never echo the URL and
    /// therefore never the topic.
    case sendFailed(String)
}

/// Pure Track B / B2 decision logic: arming, the fire gate, topic/server
/// validation, the app-generated message bodies (Track C kinds included), the
/// per-kind headers and send lanes, the send-outcome classifier, and the
/// debug-sim wiring predicate. No I/O, no subprocess, no syscalls —
/// `LidGuardStructureTests` keeps `URLSession`, `URLRequest`, `Process`, and
/// `IORegisterForSystemPower` out of this file. Table-tested like
/// `HysteresisEngine`.
enum LidGuardPolicy {
    // MARK: Wiring predicate (ADR §8 mirror, same shape as B1's)

    /// In debugBattery mode the ENTIRE B2 subsystem is structurally absent: no
    /// IOKit power registration, no sender, no network — ever.
    static func lidGuardMayBeConstructed(debugBattery: Bool) -> Bool {
        !debugBattery
    }

    // MARK: Topic validation

    /// Trim, then apply the ntfy grammar `^[A-Za-z0-9_-]{1,64}$` exactly.
    /// Rejecting `/`, `.`, `?`, `#`, whitespace and every non-ASCII scalar is
    /// what makes the topic safe to append as the single URL path segment: a
    /// value that passes here cannot introduce another path component, a query,
    /// or a fragment.
    static func validateTopic(_ raw: String) -> TopicValidation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.unicodeScalars.count > LidGuardTuning.maxTopicLength { return .invalid }
        guard trimmed.unicodeScalars.allSatisfy(isTopicScalar) else { return .invalid }
        return .valid(trimmed)
    }

    /// `A–Z a–z 0–9 _ -` and nothing else.
    private static func isTopicScalar(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x41 && scalar.value <= 0x5A)      // A–Z
            || (scalar.value >= 0x61 && scalar.value <= 0x7A) // a–z
            || (scalar.value >= 0x30 && scalar.value <= 0x39) // 0–9
            || scalar.value == 0x5F                            // _
            || scalar.value == 0x2D                            // -
    }

    /// Convenience: the normalized topic, or nil when it is unusable.
    static func normalizedTopic(_ raw: String) -> String? {
        if case .valid(let topic) = validateTopic(raw) { return topic }
        return nil
    }

    // MARK: Server validation

    /// An https ORIGIN and nothing more. A path, query, fragment, or embedded
    /// credentials are rejected rather than silently dropped, because the topic
    /// is the only path segment the sender appends — accepting a server path
    /// would move the message to a different topic than the one the user
    /// configured. Plain `http` is rejected outright: the topic travels in the
    /// URL and is a password.
    ///
    /// PERCENT-ENCODING RULE (security review 2026-09-09): the normalized origin
    /// is reassembled from `percentEncodedHost`, NOT from `host`. `host` is
    /// percent-DECODED, so `https://evil.com%2Fntfy.sh` used to parse as a
    /// clean, path-free origin whose decoded host (`evil.com/ntfy.sh`) smuggled
    /// a path back into the reassembled string — and the same trick moved the
    /// topic into a query (`%3F`), a fragment (`%23`), a traversal
    /// (`%2F..%2F`), or past the credentials check (`%2540`, a double-encoded
    /// `@`). Reassembling from the UNdecoded host keeps the guards below and the
    /// produced string in the same alphabet, and `isUsableServerHost` then
    /// closes every escape hatch: `%` cannot appear in a host at all.
    ///
    /// NOTHING IS DROPPED SILENTLY (I-2, review closure pass 2026-09-09): the
    /// origin we return must account for the ENTIRE authority that was typed.
    /// `URLComponents.port` is an `Int?` and reports nil for a port it could not
    /// parse as well as for one that is absent, so `https://ntfy.sh:9999…9`
    /// (out of `Int` range) used to validate as a bare `https://ntfy.sh` — the
    /// port quietly gone and the message published to 443 instead. Comparing
    /// the reassembled origin against the components' own authority string
    /// closes that without special-casing overflow: anything the reassembly
    /// fails to reproduce is `.invalid`, which the user sees, rather than a
    /// truncation they do not. (A bare trailing `:` carries no port and is
    /// still fine; the comparison is case-insensitive so an uppercase scheme
    /// keeps working.)
    static func validateServer(_ raw: String) -> ServerValidation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.unicodeScalars.count > LidGuardTuning.maxServerLength { return .invalid }
        // Any interior whitespace or control scalar (including U+2028/U+2029,
        // which survive the trim) makes this unusable as a URL.
        guard !trimmed.unicodeScalars.contains(where: isUnsafeScalar) else { return .invalid }
        guard let components = URLComponents(string: trimmed) else { return .invalid }
        guard components.scheme?.lowercased() == "https" else { return .invalid }
        guard let host = components.percentEncodedHost, isUsableServerHost(host) else { return .invalid }
        guard components.user == nil, components.password == nil else { return .invalid }
        guard components.query == nil, components.fragment == nil else { return .invalid }
        guard components.path.isEmpty || components.path == "/" else { return .invalid }
        let origin = components.port.map { "https://\(host):\($0)" } ?? "https://\(host)"
        var authority = components
        authority.path = ""
        authority.query = nil
        authority.fragment = nil
        guard authority.string?.lowercased() == origin.lowercased() else { return .invalid }
        return .valid(origin)
    }

    /// Whether a host can be concatenated into `https://<host>[:port]/<topic>`
    /// without changing the SHAPE of the resulting URL. Applied to the
    /// percent-ENCODED host, and re-applied by the sender as defense in depth.
    ///
    /// ALLOWLIST, not a denylist: `A–Z a–z 0–9 . - _` only. That covers every
    /// DNS name and IPv4 literal, and structurally excludes `/ ? # @ % [ ] :`
    /// and `\` — the characters that could smuggle a path, query, fragment,
    /// credentials, or a further percent-escape into the origin.
    ///
    /// DELIBERATE EXCLUSIONS (documented choices, not oversights):
    /// - **Bracketed IPv6 literals are NOT supported.** `[`/`]` are rejected, so
    ///   `https://[::1]` is `.invalid`. An ntfy instance reachable only by IPv6
    ///   literal is far outside this feature's use, and allowing brackets would
    ///   mean carrying a second origin grammar through every guard below.
    /// - **Internationalized (IDN) hostnames are not supported, in either
    ///   form.** Foundation applies UTS-46 host mapping BEFORE we see anything,
    ///   so the alphabet meets an already-mapped host and the outcome splits
    ///   three ways (measured, not assumed — corrected in the 2026-09-09 review
    ///   closure pass, where this comment previously over-claimed):
    ///   1. A label that stays non-ASCII after mapping comes back from
    ///      `percentEncodedHost` as `%XX` escapes (`ntfy.exämple.com` →
    ///      `ntfy.ex%C3%A4mple.com`) and is REJECTED — `%` is not a host
    ///      character here. `xn--…` is decoded back to Unicode first, so the
    ///      punycode spelling lands in the same place.
    ///   2. A mapping that would produce a URL delimiter (`／` U+FF0F, `＃`
    ///      U+FF03) makes `URLComponents(string:)` itself fail — REJECTED
    ///      before the alphabet is consulted.
    ///   3. But a lookalike that maps ONTO this alphabet is ACCEPTED and
    ///      silently normalized to its ASCII form: `ntfy．sh` (U+FF0E),
    ///      `nt\u{AD}fy.sh` (soft hyphen), `ⓒntfy.sh`, `ＮＴＦＹ.ＳＨ` all
    ///      arrive as plain ASCII. That is Foundation's normalization, not a
    ///      hole: the mapped host is the one a browser would resolve too, it is
    ///      the form we store and show back in the editor, and re-validating it
    ///      is idempotent (the mapped form maps to itself), so the two layers
    ///      cannot disagree about it. A user who pastes a homograph therefore
    ///      sees the real ASCII host it became.
    ///   Case 1 was never really usable anyway: `URL(string:)` rewrites a
    ///   Unicode host to punycode, which the sender's byte-identical round-trip
    ///   check already refused, so the send failed with the config still
    ///   reading "valid". Rejecting here just moves that failure to where the
    ///   user can see it. Workaround: an ASCII host name or an IP address.
    static func isUsableServerHost(_ host: String) -> Bool {
        !host.isEmpty && host.unicodeScalars.allSatisfy(isServerHostScalar)
    }

    /// `A–Z a–z 0–9 . - _` and nothing else.
    private static func isServerHostScalar(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x41 && scalar.value <= 0x5A)      // A–Z
            || (scalar.value >= 0x61 && scalar.value <= 0x7A) // a–z
            || (scalar.value >= 0x30 && scalar.value <= 0x39) // 0–9
            || scalar.value == 0x2E                            // .
            || scalar.value == 0x2D                            // -
            || scalar.value == 0x5F                            // _
    }

    /// C0/C1 control characters, DEL, the Unicode line/paragraph separators,
    /// and any space — the class that could smuggle a newline into a log line
    /// or split a URL.
    private static func isUnsafeScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value <= 0x20 || scalar.value == 0x7F
            || (scalar.value >= 0x80 && scalar.value <= 0x9F)
            || scalar.value == 0x2028 || scalar.value == 0x2029
    }

    /// The stored server, or the default when nothing usable is stored. Empty
    /// means "the user never changed it", which is the public instance.
    static func normalizedServer(_ raw: String) -> String? {
        switch validateServer(raw) {
        case .valid(let server): return server
        case .empty: return LidGuardTuning.defaultNtfyServer
        case .invalid: return nil
        }
    }

    /// The ONLY constructor of a `NtfyDestination`. Both halves must validate,
    /// so an unvalidated string can never reach the request builder.
    static func destination(server: String, topic: String) -> NtfyDestination? {
        guard let server = normalizedServer(server), let topic = normalizedTopic(topic) else { return nil }
        return NtfyDestination(server: server, topic: topic)
    }

    // MARK: Arming

    /// Armed iff enabled ∧ destination valid ∧ primed. Precedence of the "not
    /// armed" reasons is off → needsTopic → needsTestSend, so the menu caption
    /// always names the NEXT thing the user has to do.
    static func armingState(
        enabled: Bool,
        server: String,
        topic: String,
        primedAt: Double
    ) -> LidGuardArmingState {
        guard enabled else { return .off }
        guard destination(server: server, topic: topic) != nil else { return .needsTopic }
        guard primedAt > 0 else { return .needsTestSend }
        return .armed
    }

    // MARK: Fire gate (pure, table-tested)

    /// `fire iff enabled ∧ topicValid ∧ primed ∧ stayAwakeObserved ≠ true
    /// ∧ taskInFlight ∧ cooldownExpired ∧ ¬sendInFlight`.
    ///
    /// The checks run in that order so the logged skip reason names the FIRST
    /// unmet condition. Note `stayAwakeObserved == nil` (pmset unreadable) does
    /// NOT block: unknown fails toward notifying.
    static func decide(_ inputs: LidGuardGateInputs) -> LidGuardGateDecision {
        let snapshot = inputs.snapshot
        guard snapshot.enabled else { return .skip(.disabled) }
        guard snapshot.topicValid, snapshot.destination != nil else { return .skip(.invalidTopic) }
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
    /// the conservative direction: never double-notify.
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
    /// the event clock time, and Int COUNTS / MINUTES — never any text from a
    /// session. The Track C kinds carry counts + minutes only (no clock time):
    /// - `sessionFinished`, one session: "A Claude session finished after
    ///   42 min — 1 still working" (the "after N min" part only when known);
    /// - `sessionFinished`, folded ≥ 2: "3 Claude sessions finished — none
    ///   still working" (minutes deliberately omitted — they differ per session);
    /// - `needsAttention`: "Claude is waiting for your approval — 12 min in"
    ///   (+ " — 1 other still working" / " — N others still working").
    static func messageBody(kind: LidGuardMessageKind, clockTime: String) -> String {
        switch kind {
        case .lidAlert(let busySessionCount):
            return "NapCat: this Mac started going to sleep at \(clockTime) while "
                + taskPhrase(busySessionCount)
                + " still running, and Stay Awake is off."
        case .test:
            return "NapCat test message (\(clockTime)). ntfy push works — "
                + "this is how the lid-close and session alerts will reach you."
        case .sessionFinished(let minutes, let folded, let stillWorking):
            if folded >= 2 {
                return "\(folded) Claude sessions finished — " + stillWorkingPhrase(stillWorking)
            }
            let after = knownMinutes(minutes).map { " after \($0) min" } ?? ""
            return "A Claude session finished" + after + " — " + stillWorkingPhrase(stillWorking)
        case .needsAttention(let minutes, let stillWorking):
            let elapsed = knownMinutes(minutes).map { " — \($0) min in" } ?? ""
            let others: String
            switch stillWorking {
            case ..<1: others = ""
            case 1: others = " — 1 other still working"
            default: others = " — \(stillWorking) others still working"
            }
            return "Claude is waiting for your approval" + elapsed + others
        }
    }

    /// Minutes worth printing. Non-positive minutes render exactly like
    /// unknown ones (defensive — the caller passes nil under a minute), so a
    /// body can never read "after 0 min" or "-3 min in".
    static func knownMinutes(_ minutes: Int?) -> Int? {
        guard let minutes, minutes > 0 else { return nil }
        return minutes
    }

    /// Still-busy count → phrase. A negative count cannot happen but degrades
    /// to "none" rather than printing "-1 still working".
    static func stillWorkingPhrase(_ count: Int) -> String {
        switch count {
        case ..<1: return "none still working"
        case 1: return "1 still working"
        default: return "\(count) still working"
        }
    }

    // MARK: Per-kind headers and send lanes (pure, table-tested)

    /// Priority + Tags for one kind — the ONLY place they are chosen. The lid
    /// alert and the test message keep the B2 values byte-for-byte.
    static func ntfyHeaders(for kind: LidGuardMessageKind) -> NtfyHeaders {
        switch kind {
        case .lidAlert, .test:
            return NtfyHeaders(priority: LidGuardTuning.ntfyPriorityValue, tags: LidGuardTuning.ntfyTagsValue)
        case .sessionFinished:
            return NtfyHeaders(priority: LidGuardTuning.finishPriorityValue, tags: LidGuardTuning.finishTagsValue)
        case .needsAttention:
            return NtfyHeaders(priority: LidGuardTuning.attentionPriorityValue, tags: LidGuardTuning.attentionTagsValue)
        }
    }

    /// Which single-flight lane a kind travels in. The test send shares the
    /// LID lane on purpose: it primes exactly that delivery path, and the B2
    /// single-flight between it and the lid alert is unchanged.
    static func lane(for kind: LidGuardMessageKind) -> NtfySendLane {
        switch kind {
        case .lidAlert, .test: return .lid
        case .sessionFinished, .needsAttention: return .session
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

    /// Transport failures that leave the outcome genuinely UNKNOWN — the
    /// request may well have left the Mac before it went down. Anything here
    /// must never be reported as a failure the user should act on.
    static let unconfirmedTransportErrorCodes: Set<Int> = [
        URLError.timedOut.rawValue,
        URLError.cancelled.rawValue,
        URLError.networkConnectionLost.rawValue,
    ]

    /// ALLOW-LIST (security review M1, 2026-10-21): the transport failures that
    /// are raised BEFORE the request body is sent — no network, no DNS answer,
    /// no TCP connection, a failed TLS handshake / certificate check, or an
    /// address URLSession would not even try. Only these are `sendFailed`,
    /// the outcome that provably sent nothing and is therefore safe to retry.
    /// Everything else — including codes raised while READING a response the
    /// server may already have acted on (badServerResponse, zeroByteResource,
    /// cannotDecode*, cannotParseResponse, dataLengthExceedsMaximum,
    /// requestBodyStreamExhausted) and any code not listed here — is
    /// `timedOutUnconfirmed`: an unknown phase fails toward NO retry.
    static let preConnectTransportErrorCodes: Set<Int> = [
        URLError.notConnectedToInternet.rawValue,
        URLError.cannotFindHost.rawValue,
        URLError.dnsLookupFailed.rawValue,
        URLError.cannotConnectToHost.rawValue,
        URLError.internationalRoamingOff.rawValue,
        URLError.callIsActive.rawValue,
        URLError.dataNotAllowed.rawValue,
        URLError.appTransportSecurityRequiresSecureConnection.rawValue,
        URLError.secureConnectionFailed.rawValue,
        URLError.serverCertificateUntrusted.rawValue,
        URLError.serverCertificateHasBadDate.rawValue,
        URLError.serverCertificateNotYetValid.rawValue,
        URLError.serverCertificateHasUnknownRoot.rawValue,
        URLError.clientCertificateRejected.rawValue,
        URLError.clientCertificateRequired.rawValue,
        URLError.badURL.rawValue,
        URLError.unsupportedURL.rawValue,
    ]

    /// Pure classification of one ntfy publish (fixture-tested):
    /// - an "unknown outcome" transport code → `timedOutUnconfirmed`
    /// - a PRE-CONNECT transport code (`preConnectTransportErrorCodes`) →
    ///   `sendFailed` with a FIXED-VOCABULARY detail (never the URL, hence
    ///   never the topic) — the only transport outcome that is retried
    /// - ANY OTHER transport code → `timedOutUnconfirmed` (the phase is unknown
    ///   or post-send: the request may well have landed)
    /// - no transport error and no HTTP response → `timedOutUnconfirmed`
    /// - HTTP 2xx → `accepted` (NOT "delivered": ntfy has it, the push to the
    ///   phone is asynchronous)
    /// - any other status → `rejected(status)`
    static func classifySend(statusCode: Int?, transportErrorCode: Int?) -> MessageSendOutcome {
        if let transportErrorCode {
            if unconfirmedTransportErrorCodes.contains(transportErrorCode) { return .timedOutUnconfirmed }
            if preConnectTransportErrorCodes.contains(transportErrorCode) {
                return .sendFailed(transportErrorName(transportErrorCode))
            }
            return .timedOutUnconfirmed
        }
        guard let statusCode else { return .timedOutUnconfirmed }
        if (200..<300).contains(statusCode) { return .accepted }
        return .rejected(statusCode)
    }

    /// URLError code → a fixed, SECRET-FREE sentence. Deliberately not
    /// `error.localizedDescription`: that string can carry the failing URL, and
    /// the URL contains the topic (which is the password). Every
    /// `preConnectTransportErrorCodes` member has a sentence of its own.
    static func transportErrorName(_ code: Int) -> String {
        switch code {
        case URLError.notConnectedToInternet.rawValue,
             URLError.internationalRoamingOff.rawValue,
             URLError.callIsActive.rawValue,
             URLError.dataNotAllowed.rawValue:
            return "this Mac had no internet connection"
        case URLError.cannotFindHost.rawValue, URLError.dnsLookupFailed.rawValue:
            return "the ntfy server name could not be resolved"
        case URLError.cannotConnectToHost.rawValue:
            return "the ntfy server refused the connection"
        case URLError.secureConnectionFailed.rawValue,
             URLError.appTransportSecurityRequiresSecureConnection.rawValue:
            return "the secure connection to the ntfy server failed"
        case URLError.serverCertificateUntrusted.rawValue,
             URLError.serverCertificateHasBadDate.rawValue,
             URLError.serverCertificateNotYetValid.rawValue,
             URLError.serverCertificateHasUnknownRoot.rawValue:
            return "the ntfy server certificate was not trusted"
        case URLError.clientCertificateRejected.rawValue, URLError.clientCertificateRequired.rawValue:
            return "the ntfy server asked for a client certificate"
        case URLError.badURL.rawValue, URLError.unsupportedURL.rawValue:
            return "the ntfy server address is not usable"
        default:
            return "the request failed (network error \(code))"
        }
    }

    /// Splits a send outcome for logging into a log-safe public CATEGORY and an
    /// optional free-form detail. The detail is drawn from
    /// `transportErrorName`'s fixed vocabulary, but it stays `.private` in the
    /// unified log anyway — defense in depth, and the same discipline the
    /// iMessage recipient needed before the channel swap. HTTP status codes are
    /// not secrets, so `rejected` folds its code into the public category.
    static func outcomeLogFields(_ outcome: MessageSendOutcome) -> (publicCategory: String, privateDetail: String?) {
        switch outcome {
        case .accepted: return ("accepted", nil)
        case .rejected(let status): return ("rejected(HTTP \(status))", nil)
        case .timedOutUnconfirmed: return ("timedOutUnconfirmed", nil)
        case .sendFailed(let detail): return ("sendFailed", detail)
        }
    }
}
