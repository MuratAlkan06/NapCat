// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// The ntfy publish request, verified WITHOUT any network I/O: every test here
/// calls the pure `makeRequest` builder or inspects the session configuration.
/// Nothing in this suite resolves a hostname, opens a socket, or resumes a
/// task. (The FA-2 lane tests below DO resume tasks — but only against the
/// in-memory `InMemoryNtfyProtocol`, never the network.)
struct NtfyMessageSenderTests {
    static let destination = NtfyDestination(server: "https://ntfy.sh", topic: "napcat-lid-8f3k2p")

    // MARK: - URL

    @Test func theUrlIsTheServerPlusTheTopicAndNothingElse() throws {
        let request = try #require(NtfyMessageSender.makeRequest(destination: Self.destination, kind: .test, body: "x"))
        let url = try #require(request.url)
        #expect(url.absoluteString == "https://ntfy.sh/napcat-lid-8f3k2p")
        #expect(url.scheme == "https")
        #expect(url.host == "ntfy.sh")
        #expect(url.path == "/napcat-lid-8f3k2p")
        #expect(url.query == nil)
        #expect(url.fragment == nil)
    }

    @Test func aCustomServerAndPortSurviveIntoTheUrl() throws {
        let destination = try #require(LidGuardPolicy.destination(
            server: "https://ntfy.example.com:8443/", topic: "napcat_x-1"))
        let request = try #require(NtfyMessageSender.makeRequest(destination: destination, kind: .test, body: "x"))
        #expect(request.url?.absoluteString == "https://ntfy.example.com:8443/napcat_x-1")
    }

    /// Every topic the validator accepts must still produce exactly one path
    /// component — that is the whole point of the grammar.
    @Test(arguments: [
        "a", "0", "A-Z_az-09", "napcat", String(repeating: "z", count: 64),
    ])
    func everyAcceptedTopicIsASinglePathComponent(topic: String) throws {
        let destination = try #require(LidGuardPolicy.destination(server: "https://ntfy.sh", topic: topic))
        let url = try #require(NtfyMessageSender.makeRequest(destination: destination, kind: .test, body: "x")?.url)
        #expect(url.pathComponents == ["/", topic])
        #expect(url.host == "ntfy.sh")
    }

    // MARK: - Method, headers, body

    /// Per kind (the literal table in `LidGuardPolicyTests.kindTable`): Title
    /// and Content-Type are fixed, Priority and Tags follow the kind. The lid
    /// alert and the test send keep the B2 `urgent` / `zzz,warning` exactly.
    @Test(arguments: LidGuardPolicyTests.kindTable)
    func theRequestIsAPostWithTheExactNtfyHeaders(row: LidGuardPolicyTests.KindTableRow) throws {
        let request = try #require(NtfyMessageSender.makeRequest(destination: Self.destination, kind: row.kind, body: "hello"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Title") == "NapCat")
        #expect(request.value(forHTTPHeaderField: "Priority") == row.priority)
        #expect(request.value(forHTTPHeaderField: "Tags") == row.tags)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "text/plain; charset=utf-8")
        #expect(request.timeoutInterval == LidGuardTuning.requestTimeout)
    }

    /// HTTP header values must be ASCII (ntfy would otherwise need RFC 2047
    /// encoding), so EVERY header name and value — the fixed pair and every
    /// per-kind Priority / Tags — is locked to ASCII here.
    @Test func theFixedHeaderValuesAreAscii() {
        let perKind = LidGuardPolicyTests.kindTable.flatMap { row -> [String] in
            let headers = LidGuardPolicy.ntfyHeaders(for: row.kind)
            return [headers.priority, headers.tags]
        }
        for value in [
            LidGuardTuning.ntfyTitleValue,
            LidGuardTuning.ntfyPriorityValue,
            LidGuardTuning.ntfyTagsValue,
            LidGuardTuning.finishPriorityValue,
            LidGuardTuning.finishTagsValue,
            LidGuardTuning.attentionPriorityValue,
            LidGuardTuning.attentionTagsValue,
            LidGuardTuning.ntfyContentTypeValue,
            LidGuardTuning.ntfyTitleHeader,
            LidGuardTuning.ntfyPriorityHeader,
            LidGuardTuning.ntfyTagsHeader,
            LidGuardTuning.ntfyContentTypeHeader,
        ] + perKind {
            let isASCII = value.unicodeScalars.allSatisfy { $0.isASCII }
            #expect(isASCII, "'\(value)' must be ASCII")
            #expect(!value.isEmpty)
            // No CR/LF: a header value must not be able to split a header.
            #expect(!value.unicodeScalars.contains { $0.value == 0x0A || $0.value == 0x0D })
        }
        #expect(LidGuardTuning.ntfyTagsValue == "zzz,warning")
        // p5 — the only level ntfy iOS 1.8.0 turns into a critical alert that
        // reaches a phone on silent (see LidGuardTuning.ntfyPriorityValue).
        #expect(LidGuardTuning.ntfyPriorityValue == "urgent")
        // Track C session alerts: p4, deliberately below the lid alert.
        #expect(LidGuardTuning.finishPriorityValue == "high")
        #expect(LidGuardTuning.finishTagsValue == "white_check_mark")
        #expect(LidGuardTuning.attentionPriorityValue == "high")
        #expect(LidGuardTuning.attentionTagsValue == "raised_hand")
    }

    /// The body is the message, verbatim, UTF-8 encoded — no JSON wrapper, no
    /// escaping, nothing prepended.
    @Test func theBodyIsTheMessageVerbatimAsUtf8() throws {
        let body = LidGuardPolicy.messageBody(kind: .lidAlert(busySessionCount: 2), clockTime: "22:49")
        let request = try #require(NtfyMessageSender.makeRequest(
            destination: Self.destination, kind: .lidAlert(busySessionCount: 2), body: body))
        let data = try #require(request.httpBody)
        #expect(data == Data(body.utf8))
        #expect(String(data: data, encoding: .utf8) == body)
        #expect(!body.hasPrefix("{"), "a JSON body would need a topic field; we publish plain text")
    }

    /// Every kind's body round-trips (the test and Track C bodies carry a
    /// non-ASCII em dash, which is fine in a UTF-8 BODY but never in a header).
    @Test func everyMessageKindRoundTripsThroughTheBody() throws {
        for kind in [LidGuardMessageKind.lidAlert(busySessionCount: 1), .test,
                     .sessionFinished(minutes: 42, folded: 1, stillWorking: 1),
                     .needsAttention(minutes: 12, stillWorking: 0)] {
            let body = LidGuardPolicy.messageBody(kind: kind, clockTime: "09:05")
            let request = try #require(NtfyMessageSender.makeRequest(destination: Self.destination, kind: kind, body: body))
            let data = try #require(request.httpBody)
            #expect(String(data: data, encoding: .utf8) == body)
        }
    }

    // MARK: - Construction failure path

    /// Validation should make this unreachable — which is exactly why the
    /// builder REPORTS it instead of force-unwrapping. A destination whose
    /// fields somehow bypassed the validator must produce nil, not a request to
    /// somewhere unexpected.
    @Test(arguments: [
        NtfyDestination(server: "not a url", topic: "napcat"),
        NtfyDestination(server: "", topic: "napcat"),
        NtfyDestination(server: "http://ntfy.sh", topic: "napcat"),
        NtfyDestination(server: "https://", topic: "napcat"),
        NtfyDestination(server: "ntfy.sh", topic: "napcat"),
        NtfyDestination(server: "https://ntfy.sh", topic: "with space"),
    ])
    func anUnvalidatedDestinationBuildsNoRequest(destination: NtfyDestination) {
        #expect(NtfyMessageSender.makeRequest(destination: destination, kind: .test, body: "x") == nil,
                "\(destination) must not produce a request")
    }

    /// DEFENSE IN DEPTH for H1 (security review 2026-09-09). Every server string
    /// below is exactly what the OLD validator produced as a "normalized
    /// origin" from a percent-encoded host — i.e. what a hand-edited defaults
    /// plist or a validator regression would hand the sender. The request
    /// builder must refuse all of them on its own, without relying on the
    /// validator having run: the URL carries the topic, which is the password.
    ///
    /// The TOPIC rows (L-1, review closure pass) cover the other half. The
    /// builder's `path == "/" + topic` check takes its expectation from the
    /// untrusted topic itself, so a path-shaped topic satisfies it trivially —
    /// only an independent re-run of the ntfy grammar refuses these.
    @Test(arguments: [
        // A smuggled path — the message would go to a different topic.
        NtfyDestination(server: "https://evil.com/ntfy.sh", topic: "napcat"),
        NtfyDestination(server: "https://ntfy.sh/path", topic: "napcat"),
        NtfyDestination(server: "https://ntfy.sh/../attacker.example", topic: "napcat"),
        // The topic ends up in a fragment (never transmitted) or a query.
        NtfyDestination(server: "https://ntfy.sh#x", topic: "napcat"),
        NtfyDestination(server: "https://ntfy.sh?", topic: "napcat"),
        // Credentials, plain and percent-encoded. The encoded form is the one
        // the old `user == nil` check could not see: it resolves to evil.com.
        NtfyDestination(server: "https://user@ntfy.sh", topic: "napcat"),
        NtfyDestination(server: "https://user:pw@ntfy.sh", topic: "napcat"),
        NtfyDestination(server: "https://ntfy.sh%40evil.com", topic: "napcat"),
        NtfyDestination(server: "https://ntfy.sh%2Fpath", topic: "napcat"),
        // Documented non-goal, refused here too.
        NtfyDestination(server: "https://[::1]", topic: "napcat"),
        // A trailing slash would double up into "//topic".
        NtfyDestination(server: "https://ntfy.sh/", topic: "napcat"),
        // TOPIC SIDE (L-1). A path-shaped topic satisfies `path == "/" + topic`
        // by construction, so each of these built a perfectly good request
        // before the topic was re-validated in its own right.
        NtfyDestination(server: "https://ntfy.sh", topic: "../admin"),
        NtfyDestination(server: "https://ntfy.sh", topic: "a/b/c"),
        NtfyDestination(server: "https://ntfy.sh", topic: "v1/topic/publish"),
        // …the empty topic publishes to the server ROOT, not to a feed.
        NtfyDestination(server: "https://ntfy.sh", topic: ""),
        // …past the grammar's 64-scalar ceiling: rejected, never truncated.
        NtfyDestination(server: "https://ntfy.sh", topic: String(repeating: "z", count: 65)),
        // …a percent escape in the topic is a second encoding layer the path
        // check cannot see through (`%2F` is a smuggled "/").
        NtfyDestination(server: "https://ntfy.sh", topic: "napcat%2Fadmin"),
        NtfyDestination(server: "https://ntfy.sh", topic: "%2E%2E%2Fadmin"),
    ])
    func aSmuggledOriginBuildsNoRequestEvenIfItBypassedTheValidator(destination: NtfyDestination) {
        #expect(NtfyMessageSender.makeRequest(destination: destination, kind: .test, body: "x") == nil,
                "\(destination.server)/\(destination.topic) must never produce a request")
    }

    /// The postcondition stated positively: when a request IS built, it points
    /// at the configured origin and exactly one path segment — the topic.
    @Test(arguments: ["https://ntfy.sh", "https://ntfy.example.com:8443", "https://192.168.1.10:8443"])
    func everyBuiltRequestHitsTheConfiguredOriginAndOnlyTheTopic(server: String) throws {
        let destination = try #require(LidGuardPolicy.destination(server: server, topic: "napcat-x_1"))
        let url = try #require(NtfyMessageSender.makeRequest(destination: destination, kind: .test, body: "x")?.url)
        #expect(url.absoluteString == "\(server)/napcat-x_1")
        #expect(url.path == "/napcat-x_1")
        #expect(url.pathComponents == ["/", "napcat-x_1"])
        #expect(url.query == nil)
        #expect(url.fragment == nil)
        #expect(url.user == nil)
        #expect(url.password == nil)
        #expect(LidGuardPolicy.isUsableServerHost(try #require(url.host)))
    }

    /// …and the sender surfaces that through the ordinary completion path
    /// rather than crashing or silently doing nothing — in EITHER lane. No task
    /// is created, so no network I/O happens here. Repeating the send proves a
    /// construction failure never takes (and so never wedges) a lane's claim:
    /// the second attempt is refused for the address, not as "still sending".
    @Test func aFailedConstructionIsReportedAsASendFailure() {
        let sender = NtfyMessageSender()
        defer { for each in NtfySendLane.allCases { sender.session(for: each).invalidateAndCancel() } }
        for kind in [LidGuardMessageKind.test, .sessionFinished(minutes: 42, folded: 1, stillWorking: 0)] {
            for _ in 0..<2 {
                let box = OutcomeBox()
                sender.send(
                    kind,
                    to: NtfyDestination(server: "not a url", topic: "napcat"),
                    at: Date(timeIntervalSince1970: 0)
                ) { box.set($0) }
                #expect(box.value == .sendFailed("the ntfy server address is not usable"), "\(kind)")
            }
        }
    }

    // MARK: - Transport-error mapping

    @Test func transportErrorCodeIsNilOnlyWhenThereIsNoError() {
        #expect(NtfyMessageSender.transportErrorCode(nil) == nil)
        let urlError = URLError(.timedOut)
        #expect(NtfyMessageSender.transportErrorCode(urlError) == URLError.timedOut.rawValue)
        // An error from another domain must still yield a code, so it is
        // classified as a failure instead of falling through to "no response".
        let foreign = NSError(domain: "com.example.other", code: 200)
        #expect(NtfyMessageSender.transportErrorCode(foreign) == URLError.unknown.rawValue)
    }

    // MARK: - Session configuration

    /// A 3xx must never be followed: the publish URL carries the topic, which
    /// is the only password on the feed, so a redirect would hand it to
    /// whatever host the response named. The session therefore carries a
    /// delegate that refuses every redirect, and the refused 3xx is classified
    /// as a rejection — a redirected publish is a FAILED publish.
    ///
    /// Checked on EVERY lane's session of a production-built sender (one
    /// URLSession per lane since Track C). The delegate is driven directly
    /// here: no task is ever resumed, so this opens no socket and resolves no
    /// hostname.
    @Test(arguments: NtfySendLane.allCases)
    func theSessionRefusesEveryRedirect(lane: NtfySendLane) throws {
        let sender = NtfyMessageSender()
        defer { for each in NtfySendLane.allCases { sender.session(for: each).invalidateAndCancel() } }
        let session = sender.session(for: lane)
        let delegate = try #require(session.delegate as? NtfyRedirectRefuser,
                                    "the \(lane) publish session must refuse redirects")

        let endpoint = try #require(URL(string: "https://ntfy.sh/napcat-x"))
        let task = session.dataTask(with: URLRequest(url: endpoint))
        let redirect = try #require(HTTPURLResponse(
            url: endpoint,
            statusCode: 301,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://attacker.example/napcat-x"]
        ))
        let proposed = URLRequest(url: try #require(URL(string: "https://attacker.example/napcat-x")))
        let box = RedirectDecisionBox()
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: redirect,
            newRequest: proposed
        ) { box.set($0) }

        #expect(box.decided, "the redirect must be answered, not left hanging")
        #expect(box.request == nil, "following it would republish the topic to another host")
        #expect(LidGuardPolicy.classifySend(statusCode: 301, transportErrorCode: nil) == .rejected(301))
    }

    /// A fire-and-forget publish must leave nothing behind and must never park
    /// itself waiting for a network that will not exist until the Mac wakes —
    /// on EVERY lane's session of a production-built sender.
    @Test(arguments: NtfySendLane.allCases)
    func theSessionIsEphemeralAndNeverWaitsForConnectivity(lane: NtfySendLane) {
        let sender = NtfyMessageSender()
        defer { for each in NtfySendLane.allCases { sender.session(for: each).invalidateAndCancel() } }
        let configuration = sender.session(for: lane).configuration
        #expect(!configuration.waitsForConnectivity, "a parked request is worse than a fast failure")
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.timeoutIntervalForRequest == LidGuardTuning.requestTimeout)
        #expect(configuration.timeoutIntervalForResource == LidGuardTuning.requestTimeout)
        #expect(configuration.httpMaximumConnectionsPerHost == 1)
        // Production never swaps in a stub protocol (that is a test seam).
        #expect(!(configuration.protocolClasses ?? []).contains { $0 == InMemoryNtfyProtocol.self })
    }

    /// F2, transport half: `httpMaximumConnectionsPerHost = 1` would queue the
    /// lid POST behind an in-flight session-alert POST at the CONNECTION level
    /// even with separate single-flight claims. So every lane owns a distinct
    /// URLSession — the lid lane's connection pool is never shared.
    @Test func everyLaneOwnsADistinctSession() {
        let sender = NtfyMessageSender()
        defer { for each in NtfySendLane.allCases { sender.session(for: each).invalidateAndCancel() } }
        let sessions = NtfySendLane.allCases.map { sender.session(for: $0) }
        #expect(sessions.count == 2)
        for (index, session) in sessions.enumerated() {
            for other in sessions[(index + 1)...] {
                #expect(session !== other, "two lanes must never share one URLSession")
            }
        }
        #expect(sender.session(for: .lid) !== sender.session(for: .session))
        // Stable: the same lane always maps to the same session.
        #expect(sender.session(for: .lid) === sender.session(for: .lid))
    }
}

// MARK: - FA-2: the lid publish is never starved by a session alert

/// FA-2 (PLAN.md Track C verification matrix) — exercises the REAL
/// `NtfyMessageSender.send` path end to end, but every lane's session is built
/// by the production `makeSession(protocolClasses:)` with ONE protocol class:
/// `InMemoryNtfyProtocol`, an in-memory ntfy that answers from memory. Nothing
/// resolves a hostname, opens a socket, or publishes; the fixture host is also
/// under the reserved `.invalid` TLD (RFC 2606) as defence in depth.
struct NtfySendLaneTests {
    static let stubServer = "https://napcat-fa2.invalid"
    static let firedAt = Date(timeIntervalSince1970: 1_700_000_000)
    /// Generous: every wait normally resolves in milliseconds.
    static let patience: TimeInterval = 10

    static func makeStubbedSender() -> NtfyMessageSender {
        NtfyMessageSender { _ in NtfyMessageSender.makeSession(protocolClasses: [InMemoryNtfyProtocol.self]) }
    }

    static func tearDown(_ sender: NtfyMessageSender, topic: String) {
        InMemoryNtfyProtocol.server.forget(topic: topic)
        for lane in NtfySendLane.allCases { sender.session(for: lane).invalidateAndCancel() }
    }

    /// THE F2 guarantee: with a `.sessionFinished` POST mid-flight (held open
    /// by the stub), a `.lidAlert` publish is NOT refused and completes
    /// `.accepted` — while the finish POST is still in flight.
    @Test func aLidAlertIsAcceptedWhileASessionFinishedPostIsInFlight() {
        let topic = "fa2-lid-not-starved"
        let destination = NtfyDestination(server: Self.stubServer, topic: topic)
        let held = InMemoryNtfyProtocol.server.script(topic: topic, holding: [.session])
        let sender = Self.makeStubbedSender()
        defer { Self.tearDown(sender, topic: topic) }
        #expect(sender.session(for: .session).configuration.httpMaximumConnectionsPerHost == 1,
                "the stubbed sessions keep the production configuration")

        let finish = OutcomeLatch()
        sender.send(.sessionFinished(minutes: 42, folded: 1, stillWorking: 0), to: destination,
                    at: Self.firedAt) { finish.set($0) }
        #expect(held.wait(timeout: .now() + Self.patience) == .success,
                "the finish POST must actually be in flight (held by the stub)")
        #expect(finish.value == nil, "the finish POST is still unanswered")

        let lid = OutcomeLatch()
        sender.send(.lidAlert(busySessionCount: 1), to: destination, at: Self.firedAt) { lid.set($0) }
        #expect(lid.value != .sendFailed("another message is still being sent"),
                "a busy SESSION lane must never refuse the lid publish")
        #expect(lid.wait(Self.patience) == .accepted, "the lid publish completes while the finish POST is held")
        #expect(finish.value == nil, "…and the finish POST was mid-flight the whole time")

        #expect(InMemoryNtfyProtocol.server.release(topic: topic) == 1)
        #expect(finish.wait(Self.patience) == .accepted)
        #expect(InMemoryNtfyProtocol.server.seenCount(topic: topic) == 2, "both POSTs reached the in-memory server")
    }

    /// The inverse: single flight still holds WITHIN the session lane. A second
    /// `.sessionFinished` (and a `.needsAttention`, same lane) is refused
    /// INLINE — before `send` returns — and never reaches the server. Once the
    /// held POST completes, the lane's claim is released.
    @Test func aSecondSessionAlertIsRefusedInlineWhileTheSessionLaneIsBusy() {
        let topic = "fa2-session-single-flight"
        let destination = NtfyDestination(server: Self.stubServer, topic: topic)
        let held = InMemoryNtfyProtocol.server.script(topic: topic, holding: [.session])
        let sender = Self.makeStubbedSender()
        defer { Self.tearDown(sender, topic: topic) }

        let first = OutcomeLatch()
        sender.send(.sessionFinished(minutes: 42, folded: 1, stillWorking: 1), to: destination,
                    at: Self.firedAt) { first.set($0) }
        #expect(held.wait(timeout: .now() + Self.patience) == .success)

        for kind in [LidGuardMessageKind.sessionFinished(minutes: 3, folded: 1, stillWorking: 0),
                     .needsAttention(minutes: 12, stillWorking: 0)] {
            let refused = OutcomeBox()
            sender.send(kind, to: destination, at: Self.firedAt) { refused.set($0) }
            #expect(refused.value == .sendFailed("another message is still being sent"),
                    "\(kind) must be refused inline while its own lane is busy")
        }
        #expect(InMemoryNtfyProtocol.server.seenCount(topic: topic) == 1, "refused sends never left the sender")

        #expect(InMemoryNtfyProtocol.server.release(topic: topic) == 1)
        #expect(first.wait(Self.patience) == .accepted)

        // The lane is free again once its live request completed.
        InMemoryNtfyProtocol.server.setHolding([], topic: topic)
        let again = OutcomeLatch()
        sender.send(.sessionFinished(minutes: 5, folded: 2, stillWorking: 0), to: destination,
                    at: Self.firedAt) { again.set($0) }
        #expect(again.wait(Self.patience) == .accepted)
    }

    /// Symmetric, and the B2 rule unchanged: the LID lane keeps its single
    /// flight between the lid alert and the test send, while a busy lid lane
    /// does not block a session alert either.
    @Test func theLidLaneKeepsItsOwnSingleFlightAndNeverBlocksTheSessionLane() {
        let topic = "fa2-lid-single-flight"
        let destination = NtfyDestination(server: Self.stubServer, topic: topic)
        let held = InMemoryNtfyProtocol.server.script(topic: topic, holding: [.lid])
        let sender = Self.makeStubbedSender()
        defer { Self.tearDown(sender, topic: topic) }

        let lid = OutcomeLatch()
        sender.send(.lidAlert(busySessionCount: 2), to: destination, at: Self.firedAt) { lid.set($0) }
        #expect(held.wait(timeout: .now() + Self.patience) == .success)

        let test = OutcomeBox()
        sender.send(.test, to: destination, at: Self.firedAt) { test.set($0) }
        #expect(test.value == .sendFailed("another message is still being sent"),
                "the test send shares the lid lane — refused inline, exactly as in B2")

        let finish = OutcomeLatch()
        sender.send(.needsAttention(minutes: 7, stillWorking: 1), to: destination, at: Self.firedAt) { finish.set($0) }
        #expect(finish.wait(Self.patience) == .accepted, "a busy lid lane never blocks a session alert")
        #expect(lid.value == nil)

        #expect(InMemoryNtfyProtocol.server.release(topic: topic) == 1)
        #expect(lid.wait(Self.patience) == .accepted)
    }
}

/// TEST-ONLY in-memory ntfy server. Installed ONLY through a session
/// configuration's `protocolClasses` (`NtfyMessageSender.makeSession(
/// protocolClasses:)`) — never the process-global `registerClass`, so no other
/// session in the test process is touched. `canInit` claims every request and
/// `startLoading` answers from memory: nothing ever reaches the network.
///
/// Scripts are keyed by TOPIC so parallel tests can share the class. A request
/// whose lane (read back from its Tags header) is in that topic's `holding`
/// set is HELD — left unanswered until `release(topic:)` — and every other
/// request is answered HTTP 200 at once.
final class InMemoryNtfyProtocol: URLProtocol, @unchecked Sendable {
    static let server = InMemoryNtfyServer()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// URLProtocol client callbacks belong on the thread (and run-loop modes)
    /// `startLoading` was called on; a HELD request is answered from the test
    /// thread, so it hops back there. Never block that thread: CFNetwork runs
    /// every custom protocol on it, the lid request included.
    private var clientThread: Thread?
    private var clientModes: [String] = [RunLoop.Mode.default.rawValue]

    override func startLoading() {
        clientThread = Thread.current
        if let mode = RunLoop.current.currentMode, mode != .default {
            clientModes.append(mode.rawValue)
        }
        if Self.server.admit(self) { respondAccepted() }
    }

    override func stopLoading() {}

    func releaseHeld() {
        guard let clientThread else { return }
        perform(#selector(respondAccepted), on: clientThread, with: nil, waitUntilDone: false, modes: clientModes)
    }

    @objc private func respondAccepted() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// The stub's per-topic script and bookkeeping.
final class InMemoryNtfyServer: @unchecked Sendable {
    private let lock = NSLock()
    private var holding: [String: Set<NtfySendLane>] = [:]
    private var held: [String: [InMemoryNtfyProtocol]] = [:]
    private var arrivals: [String: DispatchSemaphore] = [:]
    private var seen: [String: Int] = [:]

    /// Fresh script for `topic`. The returned semaphore is signalled once per
    /// request that gets HELD.
    func script(topic: String, holding lanes: Set<NtfySendLane>) -> DispatchSemaphore {
        let arrival = DispatchSemaphore(value: 0)
        lock.lock()
        holding[topic] = lanes
        held[topic] = []
        arrivals[topic] = arrival
        seen[topic] = 0
        lock.unlock()
        return arrival
    }

    func setHolding(_ lanes: Set<NtfySendLane>, topic: String) {
        lock.lock()
        holding[topic] = lanes
        lock.unlock()
    }

    /// True ⇒ answer now; false ⇒ the request is held.
    func admit(_ request: InMemoryNtfyProtocol) -> Bool {
        let topic = request.request.url?.lastPathComponent ?? ""
        let lane: NtfySendLane = request.request.value(forHTTPHeaderField: "Tags") == LidGuardTuning.ntfyTagsValue
            ? .lid : .session
        lock.lock()
        seen[topic, default: 0] += 1
        guard holding[topic]?.contains(lane) == true else {
            lock.unlock()
            return true
        }
        held[topic, default: []].append(request)
        let arrival = arrivals[topic]
        lock.unlock()
        arrival?.signal()
        return false
    }

    /// Answers every held request for `topic` (HTTP 200); returns how many.
    @discardableResult
    func release(topic: String) -> Int {
        lock.lock()
        let requests = held[topic] ?? []
        held[topic] = []
        lock.unlock()
        for request in requests { request.releaseHeld() }
        return requests.count
    }

    func seenCount(topic: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return seen[topic] ?? 0
    }

    /// Test teardown: answer anything still held, then drop the script.
    func forget(topic: String) {
        release(topic: topic)
        lock.lock()
        holding[topic] = nil
        held[topic] = nil
        arrivals[topic] = nil
        seen[topic] = nil
        lock.unlock()
    }
}

/// One-shot outcome sink that can also be WAITED on (asynchronous paths).
final class OutcomeLatch: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var outcome: MessageSendOutcome?

    func set(_ newValue: MessageSendOutcome) {
        lock.lock()
        outcome = newValue
        lock.unlock()
        signal.signal()
    }

    var value: MessageSendOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }

    /// The outcome, or nil when none arrived within `seconds`.
    func wait(_ seconds: TimeInterval) -> MessageSendOutcome? {
        guard signal.wait(timeout: .now() + seconds) == .success else { return nil }
        return value
    }
}

/// Captures the redirect delegate's answer (and whether it answered at all).
final class RedirectDecisionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var answered = false
    private var newRequest: URLRequest?

    func set(_ request: URLRequest?) {
        lock.lock()
        answered = true
        newRequest = request
        lock.unlock()
    }

    var decided: Bool {
        lock.lock()
        defer { lock.unlock() }
        return answered
    }

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return newRequest
    }
}

/// Thread-safe one-shot outcome sink for the synchronous failure paths.
final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: MessageSendOutcome?

    func set(_ newValue: MessageSendOutcome) {
        lock.lock()
        outcome = newValue
        lock.unlock()
    }

    var value: MessageSendOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }
}
