import Foundation
import os

/// SENDER FILE (structural-isolation boundary): the ONLY file in the B2
/// subsystem — and the only file anywhere in NapCat — that may name
/// `URLSession`/`URLRequest` or perform network I/O
/// (`LidGuardStructureTests` enforces both).
///
/// It publishes one message to ntfy:
///
///     POST <server>/<topic>
///     Title: NapCat
///     Priority: high
///     Tags: zzz,warning
///
///     <app-generated body>
///
/// SECRET HANDLING: the ntfy topic is the ONLY password on the feed, and it
/// travels inside the URL. So the URL is never logged, never surfaced in an
/// outcome detail, and the request is built ONLY from a `NtfyDestination`,
/// which `LidGuardPolicy.destination(server:topic:)` has already validated
/// against the ntfy grammar. No user string is ever interpolated into a URL
/// without passing that gate.
///
/// UNPRIVILEGED — no sudo, no PLAN §4 command, no subprocess, no TCC prompt.
final class NtfyMessageSender: MessageSender, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "lidguard")

    private let session: URLSession
    private let lock = NSLock()
    /// SINGLE FLIGHT. `generation` identifies the live request so a late
    /// completion from an older one cannot clear a newer one's claim. No strong
    /// reference to the task is needed (unlike the old `Process`): URLSession
    /// retains its tasks until they complete.
    private var sending = false
    private var generation: UInt64 = 0

    init(session: URLSession = NtfyMessageSender.makeSession()) {
        self.session = session
    }

    /// EPHEMERAL configuration: no disk cache, no cookies, no credential
    /// storage — a fire-and-forget publish leaves nothing behind. Connectivity
    /// waiting is explicitly OFF: as the Mac goes down we want a fast failure,
    /// not a request parked until some future network.
    ///
    /// REDIRECTS ARE REFUSED (`NtfyRedirectRefuser`): the URL carries the topic,
    /// which is the password, so following a 3xx would hand it to whatever host
    /// the server named. A redirected publish is a FAILED publish.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = LidGuardTuning.requestTimeout
        configuration.timeoutIntervalForResource = LidGuardTuning.requestTimeout
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration, delegate: NtfyRedirectRefuser(), delegateQueue: nil)
    }

    // MARK: - Request construction (pure — unit-tested without any network)

    /// Builds the publish request from a VALIDATED destination: the URL is
    /// `<server>/<topic>`, concatenated from the two already-normalized
    /// components and nothing else.
    ///
    /// The parsed URL must render back BYTE-IDENTICALLY to what we asked for:
    /// if Foundation had to percent-escape or otherwise rewrite anything, the
    /// components were not what the validator promised and we refuse rather
    /// than publish to a silently different address.
    ///
    /// Returns nil in that case — a state the validator should make
    /// unreachable, which is exactly why it is reported through the ordinary
    /// failure path instead of being force-unwrapped.
    ///
    /// POSTCONDITION (security review 2026-09-09, defense in depth): whatever
    /// the two stored strings are, the address we are about to POST to must
    /// parse back into EXACTLY the origin + one path segment we intended —
    /// `path == "/" + topic`, no query, no fragment, no credentials, and a host
    /// in the plain `[A-Za-z0-9._-]` alphabet. The validator is the first line
    /// of defense; this is the second, so a hand-edited defaults plist (or a
    /// future validator regression) cannot publish the topic — which is the
    /// password — to an address the user never configured. Everything is
    /// inspected in its UNdecoded form, because percent-decoding is precisely
    /// how the bypasses hid: `https://evil.com%2Fntfy.sh` has a clean-looking
    /// decoded host and a smuggled path.
    ///
    /// BOTH HALVES ARE RE-VALIDATED INDEPENDENTLY (L-1, review closure pass
    /// 2026-09-09). `path == "/" + topic` alone derives its expectation from the
    /// untrusted input, so it holds for a path-SHAPED topic (`../admin`,
    /// `a/b/c`, `v1/topic/publish`) just as happily as for a real one. The host
    /// half re-runs `isUsableServerHost`; the topic half therefore re-runs the
    /// ntfy grammar `^[A-Za-z0-9_-]{1,64}$` through the same pure validator the
    /// first layer uses. Only then does the path comparison mean what it says:
    /// one segment, and that segment is a well-formed topic.
    static func makeRequest(destination: NtfyDestination, body: String) -> URLRequest? {
        let address = "\(destination.server)/\(destination.topic)"
        guard let endpoint = URL(string: address), endpoint.absoluteString == address else { return nil }
        guard let parts = URLComponents(string: address) else { return nil }
        guard parts.scheme?.lowercased() == "https" else { return nil }
        guard let host = parts.percentEncodedHost, LidGuardPolicy.isUsableServerHost(host) else { return nil }
        guard parts.percentEncodedPath == "/\(destination.topic)" else { return nil }
        // …and the topic itself must still be a topic — not merely equal to
        // whatever the path turned out to be. `normalizedTopic` returns the
        // trimmed, grammar-checked value, so requiring it to come back
        // UNCHANGED also rejects anything the validator would have rewritten.
        guard LidGuardPolicy.normalizedTopic(destination.topic) == destination.topic else { return nil }
        guard parts.query == nil, parts.fragment == nil else { return nil }
        guard parts.user == nil, parts.password == nil else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = LidGuardTuning.requestTimeout
        request.httpBody = Data(body.utf8)
        request.setValue(LidGuardTuning.ntfyTitleValue, forHTTPHeaderField: LidGuardTuning.ntfyTitleHeader)
        request.setValue(LidGuardTuning.ntfyPriorityValue, forHTTPHeaderField: LidGuardTuning.ntfyPriorityHeader)
        request.setValue(LidGuardTuning.ntfyTagsValue, forHTTPHeaderField: LidGuardTuning.ntfyTagsHeader)
        request.setValue(LidGuardTuning.ntfyContentTypeValue, forHTTPHeaderField: LidGuardTuning.ntfyContentTypeHeader)
        return request
    }

    // MARK: - Send

    func send(
        _ kind: LidGuardMessageKind,
        to destination: NtfyDestination,
        at firedAt: Date,
        completion: @escaping @Sendable (MessageSendOutcome) -> Void
    ) {
        // The body is built HERE, from the closed kind + the event clock time.
        // No caller-supplied text exists anywhere on this path.
        let body = LidGuardPolicy.messageBody(kind: kind, clockTime: LidGuardPolicy.clockTime(firedAt))

        guard let request = Self.makeRequest(destination: destination, body: body) else {
            Self.logger.error("lid guard: the stored ntfy address could not be turned into a request")
            completion(.sendFailed("the ntfy server address is not usable"))
            return
        }

        // SINGLE-FLIGHT: never a second publish while one is alive.
        lock.lock()
        guard !sending else {
            lock.unlock()
            completion(.sendFailed("another message is still being sent"))
            return
        }
        sending = true
        generation &+= 1
        let claim = generation
        lock.unlock()

        // Fire and forget from the caller's perspective: `resume()` returns
        // immediately, so the WillSleep handler is never blocked by the network
        // — only by its own explicit `ackHoldBudget` wait.
        let task = session.dataTask(with: request) { [weak self] _, response, error in
            self?.clear(claim)
            let status = (response as? HTTPURLResponse)?.statusCode
            completion(LidGuardPolicy.classifySend(
                statusCode: status,
                transportErrorCode: Self.transportErrorCode(error)
            ))
        }
        task.resume()
    }

    /// Any error at all must produce a code, so an unexpected error domain is
    /// classified as a failure rather than falling through to the
    /// "no HTTP response" branch. The error's own message is deliberately
    /// discarded: `localizedDescription` can carry the failing URL, and the URL
    /// carries the topic.
    static func transportErrorCode(_ error: Error?) -> Int? {
        guard let error else { return nil }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain ? nsError.code : URLError.unknown.rawValue
    }

    /// Releases the single-flight claim ONLY when `claim` is still the live
    /// one. A late completion from a previous publish must never unlock a
    /// newer one.
    private func clear(_ claim: UInt64) {
        lock.lock()
        if generation == claim { sending = false }
        lock.unlock()
    }
}

/// Session delegate that refuses EVERY HTTP redirect (security review
/// 2026-09-09).
///
/// The publish URL is `<server>/<topic>`, and the topic is the only password on
/// the feed. Following a 3xx would republish it — headers, body and all — to
/// whatever host the response named: a compromised or hostile ntfy instance
/// could harvest the topic by answering `301 Location: https://attacker/…`,
/// and even an honest one could silently move traffic somewhere the user never
/// approved. Completing with `nil` refuses the redirect, so the task finishes
/// with the 3xx response itself, which `LidGuardPolicy.classifySend` reports as
/// `rejected(status)` — the user sees "refused by the server", never a silent
/// success at an address they did not choose.
///
/// Delegate methods for response/data delivery are bypassed by
/// completion-handler tasks, but this one is not: redirect handling is a
/// task-level delegate callback and is delivered for default and ephemeral
/// sessions.
final class NtfyRedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
