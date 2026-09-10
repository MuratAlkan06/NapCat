// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Pure Track B / B2 decision logic — the fire gate, the wall-clock cooldown,
/// ntfy topic/server validation, the app-generated message bodies, and the
/// send-outcome classifier. Table-driven like HysteresisEngineTests; nothing
/// here sends anything, opens a socket, or touches IOKit.
struct LidGuardPolicyTests {
    /// The destination every "valid config" row uses.
    static let sampleDestination = NtfyDestination(server: "https://ntfy.sh", topic: "napcat-test-topic")

    // MARK: - Fire gate

    /// One row of the gate table. The baseline is "everything is right, fire";
    /// each row flips exactly one condition unless noted.
    struct GateRow: Sendable {
        let id: String
        let enabled: Bool
        let topicValid: Bool
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
            topicValid: Bool = true,
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
            self.topicValid = topicValid
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
                    destination: topicValid ? LidGuardPolicyTests.sampleDestination : nil,
                    topicValid: topicValid,
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
        .init("G3 topic/server invalid", topicValid: false, expected: .skip(.invalidTopic)),
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
              enabled: false, topicValid: false, primed: false,
              stayAwakeObserved: true, taskInFlight: false, sendInFlight: true,
              expected: .skip(.disabled)),
        .init("G14 clock jumped backwards — hold the cooldown, never double-notify",
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
            .disabled, .invalidTopic, .notPrimed, .stayAwakeOn,
            .noTaskInFlight, .cooldown, .sendInFlight,
        ]
        #expect(reasons == all)
    }

    /// A snapshot that CLAIMS a valid topic but carries no destination must
    /// never fire — the controller would have nothing to publish to.
    @Test func aMissingDestinationNeverFiresEvenIfTheFlagSaysValid() {
        let inputs = LidGuardGateInputs(
            snapshot: LidGuardSnapshot(
                enabled: true,
                destination: nil,
                topicValid: true,
                primed: true,
                stayAwakeObserved: false,
                taskInFlight: true,
                busySessionCount: 1
            ),
            sendInFlight: false,
            lastFiredAt: nil,
            now: 1_000_000
        )
        #expect(LidGuardPolicy.decide(inputs) == .skip(.invalidTopic))
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

    /// The single tunable the design fixes by value — unchanged by the B4
    /// channel swap; the request timeout is deliberately far larger, because
    /// the sleep hold is a transmission window, not a deadline.
    @Test func ackHoldBudgetIsTheLockedValue() {
        #expect(LidGuardTuning.ackHoldBudget == 1.5)
        #expect(LidGuardTuning.forceAckCeiling < 30, "must never approach the OS ceiling")
        #expect(LidGuardTuning.ackHoldBudget < LidGuardTuning.forceAckCeiling)
        #expect(LidGuardTuning.requestTimeout > LidGuardTuning.ackHoldBudget)
    }

    // MARK: - Topic validation (ntfy grammar: ^[A-Za-z0-9_-]{1,64}$)

    @Test(arguments: [
        ("napcat-lid-8f3k2p", TopicValidation.valid("napcat-lid-8f3k2p")),
        ("  napcat_Lid_42  ", .valid("napcat_Lid_42")),
        ("A", .valid("A")),
        ("0", .valid("0")),
        (String(repeating: "a", count: 64), .valid(String(repeating: "a", count: 64))),
        ("", .empty),
        ("   ", .empty),
        ("\n", .empty),
        (String(repeating: "a", count: 65), .invalid),
        // A slash would add a second path segment — the whole reason for the
        // grammar.
        ("napcat/lid", .invalid),
        ("napcat.lid", .invalid),
        ("napcat?x=1", .invalid),
        ("napcat#frag", .invalid),
        ("nap cat", .invalid),
        ("napcat:8080", .invalid),
        ("napcat%2Flid", .invalid),
        ("nap\ncat", .invalid),
        ("nap\rcat", .invalid),
        ("nap\u{0000}cat", .invalid),
        ("nap\u{2028}cat", .invalid),
        ("nap\u{2029}cat", .invalid),
        ("napcät", .invalid),
        ("ナップキャット", .invalid),
        ("napcat🐱", .invalid),
    ])
    func topicValidationTable(raw: String, expected: TopicValidation) {
        #expect(LidGuardPolicy.validateTopic(raw) == expected)
    }

    @Test func topicLengthCapMatchesTheNtfyGrammar() {
        #expect(LidGuardTuning.maxTopicLength == 64)
    }

    // MARK: - Server validation (https origin only)

    @Test(arguments: [
        ("https://ntfy.sh", ServerValidation.valid("https://ntfy.sh")),
        ("  https://ntfy.sh  ", .valid("https://ntfy.sh")),
        // Trailing-slash normalization: the sender always appends "/<topic>".
        ("https://ntfy.sh/", .valid("https://ntfy.sh")),
        ("https://ntfy.example.com:8443", .valid("https://ntfy.example.com:8443")),
        ("https://ntfy.example.com:8443/", .valid("https://ntfy.example.com:8443")),
        ("", .empty),
        ("   ", .empty),
        // http is refused outright: the topic (a password) rides in the URL.
        ("http://ntfy.sh", .invalid),
        ("HTTP://ntfy.sh", .invalid),
        ("ftp://ntfy.sh", .invalid),
        ("ntfy.sh", .invalid),
        ("//ntfy.sh", .invalid),
        ("https://", .invalid),
        // A server PATH would silently move the message to another topic.
        ("https://ntfy.sh/mytopic", .invalid),
        ("https://ntfy.sh/a/b", .invalid),
        ("https://ntfy.sh?x=1", .invalid),
        ("https://ntfy.sh#frag", .invalid),
        ("https://user:pw@ntfy.sh", .invalid),
        ("https://nt fy.sh", .invalid),
        ("https://ntfy.sh\nX", .invalid),
        // An INTERIOR line/paragraph separator survives the trim; reject it.
        // (A trailing one is trimmed like any newline and is therefore fine.)
        ("https://ntfy\u{2028}.sh", .invalid),
        ("https://ntfy\u{2029}.sh", .invalid),
        ("https://ntfy.sh\u{2028}", .valid("https://ntfy.sh")),

        // SECURITY REGRESSION ROWS (H1, security review 2026-09-09).
        // `URLComponents.host` is percent-DECODED while the path/query/fragment/
        // user guards see the UNdecoded parse, so every row below used to be
        // accepted and normalized into an origin that smuggled the decoded
        // character back in. Each is proven to reach a DIFFERENT address than
        // the user configured — the topic is a password, so that is a
        // credential-disclosure bug, not a cosmetic one.
        //
        // …the decoded "/" adds a host, leaving the real server in the path:
        // normalized to "https://evil.com/ntfy.sh".
        ("https://evil.com%2Fntfy.sh", .invalid),
        // …the decoded "#" puts the topic in a FRAGMENT (never sent at all).
        ("https://ntfy.sh%23x", .invalid),
        // …the decoded "?" puts the topic in a QUERY.
        ("https://ntfy.sh%3F", .invalid),
        // …path traversal out of the intended origin.
        ("https://ntfy.sh%2F..%2Fattacker.example", .invalid),
        // …DOUBLE-encoded "@": the `user == nil` guard sees no credentials,
        // but the produced URL resolves to host "evil.com".
        ("https://ntfy.sh%2540evil.com", .invalid),
        ("https://ntfy.sh%40evil.com", .invalid),
        ("https://ntfy.sh%2Fpath", .invalid),
        ("https://ntfy.sh%2f..%2fattacker.example", .invalid),
        ("https://ntfy.sh%00", .invalid),
        ("https://ntfy.sh%5Cevil", .invalid),
        ("https://%2Fntfy.sh", .invalid),
        // A bare "%" is not a host character either.
        ("https://ntfy%sh", .invalid),
        // Bracketed IPv6 literals: a DOCUMENTED non-goal (see
        // `LidGuardPolicy.isUsableServerHost`), rejected rather than parsed.
        ("https://[::1]", .invalid),
        ("https://[::1]:8443", .invalid),
        // IDN, BOTH spellings: `percentEncodedHost` escapes non-ASCII, and
        // Foundation decodes an `xn--…` label back to Unicode before we see it,
        // so neither form is usable. They never worked — `URL(string:)` rewrote
        // the Unicode host to punycode, which the sender's byte-identical check
        // refused while the config still read "valid". Now the rejection is
        // visible to the user. (Workaround: an ASCII host name or an IP.)
        ("https://ntfy.exämple.com", .invalid),
        ("https://ntfy.xn--exmple-cua.com", .invalid),
        // A port `URLComponents` cannot parse is reported as NO port at all, so
        // these used to normalize to a bare "https://ntfy.sh" and publish to
        // 443 — a truncation, which this validator does not do (I-2, review
        // closure pass 2026-09-09).
        ("https://ntfy.sh:99999999999999999999", .invalid),
        ("https://ntfy.sh:9223372036854775808", .invalid),
        // …but a bare trailing colon carries no port to begin with.
        ("https://ntfy.sh:", .valid("https://ntfy.sh")),
        // Ordinary hosts with the remaining allowlisted characters still pass.
        ("https://ntfy-2.internal_host.example.com:8443",
         .valid("https://ntfy-2.internal_host.example.com:8443")),
        ("https://192.168.1.10:8443", .valid("https://192.168.1.10:8443")),
    ])
    func serverValidationTable(raw: String, expected: ServerValidation) {
        #expect(LidGuardPolicy.validateServer(raw) == expected)
    }

    /// H1 root cause, stated as a property rather than a fixture list: whatever
    /// the input, an ACCEPTED origin never contains a character that could
    /// change the shape of `<server>/<topic>` — no `%` (hence no second decode
    /// pass), no `/ ? # @ [ ]`, no whitespace.
    @Test func anAcceptedOriginCanCarryNoUrlStructureAtAll() {
        let hostile = [
            "https://evil.com%2Fntfy.sh", "https://ntfy.sh%23x", "https://ntfy.sh%3F",
            "https://ntfy.sh%2F..%2Fattacker.example", "https://ntfy.sh%2540evil.com",
            "https://ntfy.sh%40evil.com", "https://ntfy.sh%2Fpath", "https://[::1]",
            "https://ntfy.sh/topic", "https://ntfy.sh?x=1", "https://ntfy.sh#f",
            "https://user:pw@ntfy.sh", "https://ntfy.exämple.com",
            "https://ntfy.xn--exmple-cua.com",
        ]
        for raw in hostile {
            #expect(LidGuardPolicy.validateServer(raw) == .invalid, "\(raw) must not be accepted")
        }
        // And the general property over every row the table accepts.
        for (raw, expected) in Self.acceptedServerFixtures {
            guard case .valid(let origin) = LidGuardPolicy.validateServer(raw) else {
                Issue.record("\(raw) should be accepted")
                continue
            }
            #expect(origin == expected)
            #expect(origin.hasPrefix("https://"))
            let authority = origin.dropFirst("https://".count)
            for forbidden in ["%", "/", "?", "#", "@", "[", "]", " ", "\\"] {
                #expect(!authority.contains(forbidden),
                        "'\(forbidden)' survived into the normalized origin '\(origin)'")
            }
        }
    }

    static let acceptedServerFixtures: [(String, String)] = [
        ("https://ntfy.sh", "https://ntfy.sh"),
        ("https://ntfy.sh/", "https://ntfy.sh"),
        ("https://ntfy.example.com:8443", "https://ntfy.example.com:8443"),
        ("https://192.168.1.10:8443", "https://192.168.1.10:8443"),
        ("https://ntfy-2.internal_host.example.com:8443", "https://ntfy-2.internal_host.example.com:8443"),
    ]

    /// The host allowlist itself (used by BOTH layers: the validator and the
    /// sender's postcondition).
    @Test func theHostAllowlistAcceptsOnlyPlainNames() {
        for host in ["ntfy.sh", "a", "0", "A-Z_az-09", "ntfy.example.com", "192.168.1.10", "xn--exmple-cua.com"] {
            #expect(LidGuardPolicy.isUsableServerHost(host), "'\(host)' is an ordinary host name")
        }
        for host in ["", "ntfy.sh/x", "ntfy.sh?x", "ntfy.sh#x", "ntfy.sh@x", "ntfy.sh%2F",
                     "[::1]", "ntfy.sh:8443", "ntfy sh", "ntfy.exämple.com", "ntfy.sh\\x"] {
            #expect(!LidGuardPolicy.isUsableServerHost(host), "'\(host)' must be refused")
        }
    }

    @Test func anOverlongServerIsRejectedNotTruncated() {
        let long = "https://" + String(repeating: "a", count: LidGuardTuning.maxServerLength) + ".example.com"
        #expect(LidGuardPolicy.validateServer(long) == .invalid)
    }

    /// An unset server is the public instance, not an error.
    @Test func anEmptyServerFallsBackToThePublicInstance() {
        #expect(LidGuardPolicy.normalizedServer("") == LidGuardTuning.defaultNtfyServer)
        #expect(LidGuardPolicy.normalizedServer("   ") == LidGuardTuning.defaultNtfyServer)
        #expect(LidGuardPolicy.normalizedServer("http://ntfy.sh") == nil)
        #expect(LidGuardTuning.defaultNtfyServer == "https://ntfy.sh")
    }

    // MARK: - Destination (the only constructor)

    @Test func aDestinationNeedsBothHalvesToValidate() {
        #expect(LidGuardPolicy.destination(server: "https://ntfy.sh", topic: "napcat-x")
                == NtfyDestination(server: "https://ntfy.sh", topic: "napcat-x"))
        // Empty server ⇒ default; the topic still decides.
        #expect(LidGuardPolicy.destination(server: "", topic: "napcat-x")
                == NtfyDestination(server: "https://ntfy.sh", topic: "napcat-x"))
        #expect(LidGuardPolicy.destination(server: "https://ntfy.sh", topic: "") == nil)
        #expect(LidGuardPolicy.destination(server: "https://ntfy.sh", topic: "bad/topic") == nil)
        #expect(LidGuardPolicy.destination(server: "http://ntfy.sh", topic: "napcat-x") == nil)
        // Normalization is applied on the way in.
        #expect(LidGuardPolicy.destination(server: "https://ntfy.sh/", topic: "  napcat-x ")
                == NtfyDestination(server: "https://ntfy.sh", topic: "napcat-x"))
    }

    @Test func anUnusableTopicLeavesTheFeatureInert() {
        #expect(LidGuardPolicy.normalizedTopic("bad/topic") == nil)
        #expect(LidGuardPolicy.armingState(
            enabled: true, server: "https://ntfy.sh", topic: "bad/topic", primedAt: 1) == .needsTopic)
        // …and so does an unusable SERVER, even with a perfect topic.
        #expect(LidGuardPolicy.armingState(
            enabled: true, server: "http://ntfy.sh", topic: "napcat-x", primedAt: 1) == .needsTopic)
    }

    // MARK: - Arming

    /// One arming row. A struct rather than a 5-tuple so the table stays
    /// readable (and so the parameterization has a single argument type).
    struct ArmingRow: Sendable {
        let id: String
        let enabled: Bool
        let server: String
        let topic: String
        let primedAt: Double
        let expected: LidGuardArmingState

        init(
            _ id: String,
            enabled: Bool = true,
            server: String = "https://ntfy.sh",
            topic: String = "napcat-x",
            primedAt: Double = 1,
            expected: LidGuardArmingState
        ) {
            self.id = id
            self.enabled = enabled
            self.server = server
            self.topic = topic
            self.primedAt = primedAt
            self.expected = expected
        }
    }

    static let armingRows: [ArmingRow] = [
        .init("A1 switched off", enabled: false, expected: .off),
        .init("A2 no topic", topic: "", expected: .needsTopic),
        .init("A3 blank topic", topic: "   ", expected: .needsTopic),
        .init("A4 topic outside the grammar", topic: "bad topic", expected: .needsTopic),
        .init("A5 unusable server blocks arming too", server: "notaserver", expected: .needsTopic),
        .init("A6 never primed", primedAt: 0, expected: .needsTestSend),
        .init("A7 fully configured", expected: .armed),
        .init("A8 empty server means the public instance", server: "", expected: .armed),
    ]

    @Test(arguments: armingRows)
    func armingStateTable(row: ArmingRow) {
        #expect(LidGuardPolicy.armingState(
            enabled: row.enabled,
            server: row.server,
            topic: row.topic,
            primedAt: row.primedAt
        ) == row.expected, "\(row.id)")
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
    /// contain anything that could have come from a session. The B4 channel
    /// swap deliberately left this wording untouched.
    @Test(arguments: [0, 1, 2, 7])
    func lidAlertBodyIsTemplatePlusTimeAndCount(count: Int) {
        let body = LidGuardPolicy.messageBody(kind: .lidAlert(busySessionCount: count), clockTime: "22:49")
        #expect(body == "NapCat: this Mac started going to sleep at 22:49 while "
                + LidGuardPolicy.taskPhrase(count)
                + " still running, and Stay Awake is off.")
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

    @Test func testMessageBodyIsSelfExplainingAndNamesTheChannel() {
        let body = LidGuardPolicy.messageBody(kind: .test, clockTime: "09:05")
        #expect(body.contains("NapCat test message"))
        #expect(body.contains("09:05"))
        #expect(body.contains("ntfy"))
        #expect(!body.contains("Messages"), "no iMessage wording survives the channel swap")
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

    @Test(arguments: [200, 201, 202, 204, 299])
    func twoHundredsAreAcceptedNotDelivered(status: Int) {
        #expect(LidGuardPolicy.classifySend(statusCode: status, transportErrorCode: nil) == .accepted)
    }

    @Test(arguments: [400, 401, 403, 404, 413, 429, 500, 502, 503])
    func nonSuccessStatusesAreRejectedWithTheirCode(status: Int) {
        #expect(LidGuardPolicy.classifySend(statusCode: status, transportErrorCode: nil) == .rejected(status))
    }

    /// A transport error whose meaning is "we never learned the answer" must
    /// not be reported as a failure — the POST may well have left the Mac
    /// before it went down.
    @Test(arguments: [
        URLError.timedOut.rawValue,
        URLError.cancelled.rawValue,
        URLError.networkConnectionLost.rawValue,
    ])
    func unknownOutcomeTransportErrorsAreUnconfirmed(code: Int) {
        #expect(LidGuardPolicy.classifySend(statusCode: nil, transportErrorCode: code) == .timedOutUnconfirmed)
        // Even with a status on the response, "we did not get an answer" wins.
        #expect(LidGuardPolicy.classifySend(statusCode: 200, transportErrorCode: code) == .timedOutUnconfirmed)
    }

    @Test func otherTransportErrorsAreNamedFromAFixedVocabulary() {
        #expect(LidGuardPolicy.classifySend(
            statusCode: nil, transportErrorCode: URLError.notConnectedToInternet.rawValue)
            == .sendFailed("this Mac had no internet connection"))
        #expect(LidGuardPolicy.classifySend(
            statusCode: nil, transportErrorCode: URLError.cannotFindHost.rawValue)
            == .sendFailed("the ntfy server name could not be resolved"))
        #expect(LidGuardPolicy.classifySend(
            statusCode: nil, transportErrorCode: URLError.secureConnectionFailed.rawValue)
            == .sendFailed("the secure connection to the ntfy server failed"))
        #expect(LidGuardPolicy.classifySend(statusCode: nil, transportErrorCode: -424_242)
            == .sendFailed("the request failed (network error -424242)"))
    }

    @Test func noResponseAndNoErrorIsAFailureNotASuccess() {
        #expect(LidGuardPolicy.classifySend(statusCode: nil, transportErrorCode: nil)
                == .sendFailed("the server sent no HTTP response"))
    }

    /// SECURITY: the failure detail must be drawn from a fixed vocabulary, not
    /// from `error.localizedDescription`, because that string can carry the
    /// failing URL — and the URL contains the topic, which is the password.
    @Test func noClassifiedFailureDetailCanEverCarryAUrlOrTopic() {
        let codes = [-1, 0, -999, -1001, -1003, -1004, -1005, -1009, -1200, -1202, -424_242]
        for code in codes {
            let outcome = LidGuardPolicy.classifySend(statusCode: nil, transportErrorCode: code)
            guard case .sendFailed(let detail) = outcome else { continue }
            for forbidden in ["http", "://", "ntfy.sh/", "/napcat"] {
                #expect(!detail.lowercased().contains(forbidden),
                        "the detail for \(code) must never look like a URL: \(detail)")
            }
        }
        for code in codes {
            let name = LidGuardPolicy.transportErrorName(code)
            #expect(!name.contains("://"))
        }
    }

    // MARK: - Outcome log split (the topic must never reach a .public line)

    /// The free-form `sendFailed` detail is the only variable text a log line
    /// carries. The split locks it into the PRIVATE field while the public
    /// category stays free of it, so the logging path can route it through
    /// `privacy: .private`. HTTP status codes are not secrets and therefore may
    /// ride in the public category.
    @Test func outcomeLogSplitKeepsTheFreeFormDetailOutOfThePublicCategory() {
        for outcome in [MessageSendOutcome.accepted, .timedOutUnconfirmed, .rejected(403)] {
            let fields = LidGuardPolicy.outcomeLogFields(outcome)
            #expect(fields.privateDetail == nil, "\(outcome) carries no free-form detail")
            #expect(!fields.publicCategory.isEmpty)
        }
        #expect(LidGuardPolicy.outcomeLogFields(.rejected(403)).publicCategory == "rejected(HTTP 403)")
        let fields = LidGuardPolicy.outcomeLogFields(.sendFailed("the ntfy server refused the connection"))
        #expect(fields.publicCategory == "sendFailed")
        #expect(fields.privateDetail == "the ntfy server refused the connection")
        #expect(!fields.publicCategory.contains("ntfy server"))
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
