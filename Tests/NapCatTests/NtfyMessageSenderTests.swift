// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// The ntfy publish request, verified WITHOUT any network I/O: every test here
/// calls the pure `makeRequest` builder or inspects the session configuration.
/// Nothing in this file resolves a hostname, opens a socket, or resumes a task.
struct NtfyMessageSenderTests {
    static let destination = NtfyDestination(server: "https://ntfy.sh", topic: "napcat-lid-8f3k2p")

    // MARK: - URL

    @Test func theUrlIsTheServerPlusTheTopicAndNothingElse() throws {
        let request = try #require(NtfyMessageSender.makeRequest(destination: Self.destination, body: "x"))
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
        let request = try #require(NtfyMessageSender.makeRequest(destination: destination, body: "x"))
        #expect(request.url?.absoluteString == "https://ntfy.example.com:8443/napcat_x-1")
    }

    /// Every topic the validator accepts must still produce exactly one path
    /// component — that is the whole point of the grammar.
    @Test(arguments: [
        "a", "0", "A-Z_az-09", "napcat", String(repeating: "z", count: 64),
    ])
    func everyAcceptedTopicIsASinglePathComponent(topic: String) throws {
        let destination = try #require(LidGuardPolicy.destination(server: "https://ntfy.sh", topic: topic))
        let url = try #require(NtfyMessageSender.makeRequest(destination: destination, body: "x")?.url)
        #expect(url.pathComponents == ["/", topic])
        #expect(url.host == "ntfy.sh")
    }

    // MARK: - Method, headers, body

    @Test func theRequestIsAPostWithTheExactNtfyHeaders() throws {
        let request = try #require(NtfyMessageSender.makeRequest(destination: Self.destination, body: "hello"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Title") == "NapCat")
        #expect(request.value(forHTTPHeaderField: "Priority") == "high")
        #expect(request.value(forHTTPHeaderField: "Tags") == "zzz,warning")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "text/plain; charset=utf-8")
        #expect(request.timeoutInterval == LidGuardTuning.requestTimeout)
    }

    /// HTTP header values must be ASCII (ntfy would otherwise need RFC 2047
    /// encoding), so the fixed header values are locked to ASCII here.
    @Test func theFixedHeaderValuesAreAscii() {
        for value in [
            LidGuardTuning.ntfyTitleValue,
            LidGuardTuning.ntfyPriorityValue,
            LidGuardTuning.ntfyTagsValue,
            LidGuardTuning.ntfyContentTypeValue,
            LidGuardTuning.ntfyTitleHeader,
            LidGuardTuning.ntfyPriorityHeader,
            LidGuardTuning.ntfyTagsHeader,
        ] {
            let isASCII = value.unicodeScalars.allSatisfy { $0.isASCII }
            #expect(isASCII, "'\(value)' must be ASCII")
            #expect(!value.isEmpty)
        }
        #expect(LidGuardTuning.ntfyTagsValue == "zzz,warning")
        #expect(LidGuardTuning.ntfyPriorityValue == "high")
    }

    /// The body is the message, verbatim, UTF-8 encoded — no JSON wrapper, no
    /// escaping, nothing prepended.
    @Test func theBodyIsTheMessageVerbatimAsUtf8() throws {
        let body = LidGuardPolicy.messageBody(kind: .lidAlert(busySessionCount: 2), clockTime: "22:49")
        let request = try #require(NtfyMessageSender.makeRequest(destination: Self.destination, body: body))
        let data = try #require(request.httpBody)
        #expect(data == Data(body.utf8))
        #expect(String(data: data, encoding: .utf8) == body)
        #expect(!body.hasPrefix("{"), "a JSON body would need a topic field; we publish plain text")
    }

    /// The lid-alert and test bodies both round-trip (the test body carries a
    /// non-ASCII em dash, which is fine in a UTF-8 BODY but never in a header).
    @Test func bothMessageKindsRoundTripThroughTheBody() throws {
        for kind in [LidGuardMessageKind.lidAlert(busySessionCount: 1), .test] {
            let body = LidGuardPolicy.messageBody(kind: kind, clockTime: "09:05")
            let request = try #require(NtfyMessageSender.makeRequest(destination: Self.destination, body: body))
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
        #expect(NtfyMessageSender.makeRequest(destination: destination, body: "x") == nil,
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
        #expect(NtfyMessageSender.makeRequest(destination: destination, body: "x") == nil,
                "\(destination.server)/\(destination.topic) must never produce a request")
    }

    /// The postcondition stated positively: when a request IS built, it points
    /// at the configured origin and exactly one path segment — the topic.
    @Test(arguments: ["https://ntfy.sh", "https://ntfy.example.com:8443", "https://192.168.1.10:8443"])
    func everyBuiltRequestHitsTheConfiguredOriginAndOnlyTheTopic(server: String) throws {
        let destination = try #require(LidGuardPolicy.destination(server: server, topic: "napcat-x_1"))
        let url = try #require(NtfyMessageSender.makeRequest(destination: destination, body: "x")?.url)
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
    /// rather than crashing or silently doing nothing. No task is created, so
    /// no network I/O happens here.
    @Test func aFailedConstructionIsReportedAsASendFailure() {
        let sender = NtfyMessageSender()
        let box = OutcomeBox()
        sender.send(
            .test,
            to: NtfyDestination(server: "not a url", topic: "napcat"),
            at: Date(timeIntervalSince1970: 0)
        ) { box.set($0) }
        #expect(box.value == .sendFailed("the ntfy server address is not usable"))
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
    /// The delegate is driven directly here: no task is ever resumed, so this
    /// opens no socket and resolves no hostname.
    @Test func theSessionRefusesEveryRedirect() throws {
        let session = NtfyMessageSender.makeSession()
        defer { session.invalidateAndCancel() }
        let delegate = try #require(session.delegate as? NtfyRedirectRefuser,
                                    "the publish session must refuse redirects")

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
    /// itself waiting for a network that will not exist until the Mac wakes.
    @Test func theSessionIsEphemeralAndNeverWaitsForConnectivity() {
        let session = NtfyMessageSender.makeSession()
        defer { session.invalidateAndCancel() }
        let configuration = session.configuration
        #expect(!configuration.waitsForConnectivity, "a parked request is worse than a fast failure")
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.timeoutIntervalForRequest == LidGuardTuning.requestTimeout)
        #expect(configuration.timeoutIntervalForResource == LidGuardTuning.requestTimeout)
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
