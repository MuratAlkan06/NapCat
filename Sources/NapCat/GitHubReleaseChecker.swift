import Foundation

// UPDATE CHECK (issue #111): the GitHub release client.
//
// NETWORKING FILE (structural-isolation boundary): the THIRD and last of the
// sanctioned networking files — with NtfyMessageSender.swift and
// CloudKitMessageSender.swift, the only files that may name the URL Loading
// System (`LidGuardStructureTests.networkingFiles`). It makes ONE kind of
// request, unauthenticated and pinned (UpdateCheckStructureTests):
//
//     GET https://api.github.com/repos/MuratAlkan06/NapCat/releases/latest
//     User-Agent: NapCat/<running version>
//     Accept: application/vnd.github+json
//
// plus whatever standard headers macOS's HTTPS stack adds itself. No token,
// no Authorization, no cookies, no credentials — nothing here can carry one.
// The host literal appears exactly once in Sources (`apiHost`).
//
// The response half is PURE and fixture-tested (`admit`, `parse`); the
// session half is tested on an in-memory URLProtocol — no test opens a
// connection.

/// Why a check produced no release. A fixed vocabulary: no error message,
/// header or response text is ever carried out of this file.
enum ReleaseCheckFailure: Equatable, Sendable {
    /// No usable HTTP response (offline, timed out, cancelled, TLS failure).
    case transport
    /// A redirect: the check never follows one, so a 3xx is a failure.
    case redirected
    /// Any other status than 200.
    case httpStatus(Int)
    /// A body larger than `GitHubReleaseChecker.maxBodyBytes`.
    case oversize
    /// Not a JSON object.
    case malformed
    /// No string `tag_name` at the top level.
    case missingTag
    /// A `tag_name` that is not a strict release tag (a prerelease, junk).
    case unusableTag
}

/// What one check learned: the latest release, or why there is none.
enum ReleaseCheckOutcome: Equatable, Sendable {
    case latest(ReleaseVersion)
    case failed(ReleaseCheckFailure)
}

/// Something that can ask for the latest release. `GitHubReleaseChecker` in
/// production; tests hand the controller a scripted fake.
protocol ReleaseChecking: Sendable {
    /// Starts one check. `completion` runs exactly once, on any queue.
    func fetchLatest(completion: @escaping @Sendable (ReleaseCheckOutcome) -> Void)
}

/// The update check's GitHub client (`GET /repos/…/releases/latest`).
///
/// RESPONSE DISCIPLINE: the ONLY value read from a response is the
/// top-level `tag_name`, and it is used only after it passes the strict
/// `ReleaseVersion(tag:)` grammar. No other field — `html_url`, asset URLs,
/// the release notes — is ever read, so no response text can reach a URL,
/// a log line or the UI. The release page NapCat opens is built from
/// `releasePagePrefix` plus that validated tag (`releasePageURL(for:)`).
///
/// ONE SESSION PER CHECK, built by `makeSession`: ephemeral, redirect
/// refusing, 10 s for the whole exchange, never waiting for connectivity. It
/// is invalidated as soon as its one task completes, so nothing lingers
/// between the (at most daily) checks.
///
/// `@unchecked Sendable`: every stored property is an immutable `let`;
/// `protocolClasses` (a test seam, nil in production) is the only non-Sendable
/// one, and it is only ever read.
struct GitHubReleaseChecker: ReleaseChecking, @unchecked Sendable {
    /// THE pinned host — the one `api.github.com` literal in Sources.
    static let apiHost = "api.github.com"
    static let latestReleasePath = "/repos/MuratAlkan06/NapCat/releases/latest"
    /// The release page prefix; the validated tag completes it.
    static let releasePagePrefix = "https://github.com/MuratAlkan06/NapCat/releases/tag/"
    /// The whole exchange — connect, TLS, response, body — gets this long.
    static let requestTimeout: TimeInterval = 10
    static let acceptValue = "application/vnd.github+json"
    /// The User-Agent's product token; the running version follows the `/`.
    static let userAgentProduct = "NapCat"

    /// The running app's version: the User-Agent's only variable part.
    let running: ReleaseVersion
    /// TEST SEAM only: nil (production) leaves Foundation's own protocol
    /// list untouched; a test passes an in-memory `URLProtocol` stub here —
    /// never through the process-global `URLProtocol.registerClass`.
    private let protocolClasses: [AnyClass]?

    init(running: ReleaseVersion, protocolClasses: [AnyClass]? = nil) {
        self.running = running
        self.protocolClasses = protocolClasses
    }

    // MARK: Request construction (pure — unit-tested without any network)

    /// The one request: `GET https://api.github.com<latestReleasePath>`
    /// with EXACTLY two headers of NapCat's own — the User-Agent (product +
    /// the running version, rendered from its three numbers) and the Accept
    /// type — no body, no cookies, no cache.
    ///
    /// POSTCONDITION: the URL must render back byte-identically and be
    /// https on `apiHost`, or there is no request at all (a state the
    /// constants make unreachable, reported through the ordinary failure
    /// path rather than force-unwrapped).
    static func makeRequest(running: ReleaseVersion) -> URLRequest? {
        let address = "https://" + apiHost + latestReleasePath
        guard let url = URL(string: address), url.absoluteString == address,
              url.scheme == "https", url.host == apiHost, url.query == nil, url.user == nil else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.allHTTPHeaderFields = [
            "User-Agent": "\(userAgentProduct)/\(running)",
            "Accept": acceptValue,
        ]
        return request
    }

    /// The release page for a VALIDATED version: the constant prefix plus
    /// the tag its three numbers render to — never a response field.
    static func releasePageURL(for version: ReleaseVersion) -> URL? {
        let address = releasePagePrefix + version.tag
        guard let url = URL(string: address), url.absoluteString == address else { return nil }
        return url
    }

    /// EPHEMERAL configuration: no disk cache, no cookies, no credential
    /// storage, no extra headers — a check leaves nothing behind. Connectivity
    /// waiting is OFF: offline is a fast failure, retried by the cadence, not
    /// a request parked until some future network. Redirects are refused by
    /// the delegate (`GitHubReleaseFetch`), as on the ntfy sender.
    static func makeSession(delegate: GitHubReleaseFetch, protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    // MARK: Check

    func fetchLatest(completion: @escaping @Sendable (ReleaseCheckOutcome) -> Void) {
        guard let request = Self.makeRequest(running: running) else {
            completion(.failed(.transport))
            return
        }
        let fetch = GitHubReleaseFetch(completion: completion)
        Self.makeSession(delegate: fetch, protocolClasses: protocolClasses).dataTask(with: request).resume()
    }

    // MARK: Response (pure)
    /// A response body larger than this is a failure, never parsed. A real
    /// `releases/latest` answer is a few KiB.
    static let maxBodyBytes = 256 * 1024

    /// The one response field NapCat reads.
    static let tagField = "tag_name"

    /// The statuses that mean "go elsewhere". Redirects are never followed,
    /// so each of them ends the check.
    static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]

    /// The response gate for a live response: it must be HTTP, from
    /// `apiHost` (redirects are refused, so anything else came from
    /// somewhere NapCat never asked), then `admit(statusCode:expectedLength:)`.
    static func admit(_ response: URLResponse) -> ReleaseCheckFailure? {
        guard let http = response as? HTTPURLResponse else { return .transport }
        guard http.url?.scheme == "https", http.url?.host == apiHost else { return .redirected }
        return admit(statusCode: http.statusCode, expectedLength: http.expectedContentLength)
    }

    /// The response gate, applied as soon as the headers arrive: anything
    /// but a 200 ends the check, and so does an announced body over the cap
    /// (`expectedLength` is -1 when the length is not announced — the body
    /// is then capped as it streams). Nil = keep reading.
    static func admit(statusCode: Int?, expectedLength: Int64) -> ReleaseCheckFailure? {
        guard let statusCode else { return .transport }
        if redirectStatuses.contains(statusCode) { return .redirected }
        guard statusCode == 200 else { return .httpStatus(statusCode) }
        guard expectedLength <= Int64(maxBodyBytes) else { return .oversize }
        return nil
    }

    /// The body of an admitted response → the latest release. Oversize is
    /// checked BEFORE any parsing; then the body must be a JSON object whose
    /// top-level `tag_name` is a string that is a strict release tag.
    static func parse(_ data: Data) -> ReleaseCheckOutcome {
        guard data.count <= maxBodyBytes else { return .failed(.oversize) }
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any] else { return .failed(.malformed) }
        guard let tag = fields[tagField] as? String else { return .failed(.missingTag) }
        guard let release = ReleaseVersion(tag: tag) else { return .failed(.unusableTag) }
        return .latest(release)
    }
}

/// One check's session delegate (one per check, released with its session).
///
/// - REDIRECTS ARE REFUSED (as `NtfyRedirectRefuser` does for ntfy):
///   completing with nil delivers the 3xx itself, which the response gate
///   turns into `.redirected`. The check never lands anywhere but `apiHost`.
/// - THE GATE RUNS ON THE HEADERS: a non-200, a foreign host or an announced
///   oversize body cancels the task before any body is read.
/// - THE CAP HOLDS WHILE STREAMING: past `maxBodyBytes` the buffer is dropped
///   and the task cancelled, so an unannounced (or lying) body can never
///   grow past the cap in memory.
/// - `completion` runs exactly once, after which the session is invalidated
///   (which also releases this delegate).
///
/// No auth-challenge method is implemented: the system's default handling
/// (server-trust evaluation) applies, and no credential is ever supplied.
/// Callbacks arrive on the session's serial delegate queue; the lock makes
/// the state safe regardless.
final class GitHubReleaseFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (ReleaseCheckOutcome) -> Void)?
    private var body = Data()
    private var stopped: ReleaseCheckFailure?

    init(completion: @escaping @Sendable (ReleaseCheckOutcome) -> Void) {
        self.completion = completion
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let failure = GitHubReleaseChecker.admit(response)
        lock.lock()
        if stopped == nil { stopped = failure }
        lock.unlock()
        completionHandler(failure == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let overflow = stopped == nil && body.count + data.count > GitHubReleaseChecker.maxBodyBytes
        if overflow {
            stopped = .oversize
            body = Data()
        } else if stopped == nil {
            body.append(data)
        }
        lock.unlock()
        if overflow { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let outcome: ReleaseCheckOutcome
        if let stopped {
            outcome = .failed(stopped)
        } else if error != nil {
            outcome = .failed(.transport)
        } else {
            outcome = GitHubReleaseChecker.parse(body)
        }
        let deliver = completion
        completion = nil
        body = Data()
        lock.unlock()
        session.finishTasksAndInvalidate()
        deliver?(outcome)
    }
}
