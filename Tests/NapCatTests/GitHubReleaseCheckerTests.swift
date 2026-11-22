// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Issue #111, part 3: the release response, read defensively — fixtures
/// only, nothing here opens a connection. The status gate (a redirect or any
/// non-200 ends the check), the 256 KiB cap (checked before parsing), and the
/// parse itself: a JSON object whose top-level `tag_name` is a strict release
/// tag — and nothing else from the response is ever read.
struct GitHubReleaseCheckerTests {
    /// A trimmed but realistic `releases/latest` answer. Every other field
    /// points somewhere NapCat must never go, and the release notes even
    /// contain a decoy `"tag_name"`: only the top-level one may count.
    static let realisticRelease = #"""
        {
          "url": "https://api.github.com/repos/MuratAlkan06/NapCat/releases/1",
          "html_url": "https://attacker.example/NapCat/releases/tag/v9.9.9",
          "assets_url": "https://attacker.example/assets",
          "upload_url": "https://attacker.example/upload",
          "tarball_url": "https://attacker.example/tarball",
          "zipball_url": "https://attacker.example/zipball",
          "id": 1,
          "tag_name": "v1.7.0",
          "target_commitish": "main",
          "name": "v9.9.9 — not the tag",
          "draft": false,
          "prerelease": false,
          "assets": [{"browser_download_url": "https://attacker.example/NapCat-9.9.9.dmg", "tag_name": "v9.9.9"}],
          "body": "Release notes. {\"tag_name\": \"v9.9.9\"}"
        }
        """#

    static func data(_ text: String) -> Data { Data(text.utf8) }

    // MARK: The status gate (redirect fixtures)

    @Test(arguments: [301, 302, 303, 307, 308])
    func aRedirectEndsTheCheck(status: Int) {
        #expect(GitHubReleaseChecker.admit(statusCode: status, expectedLength: 100) == .redirected)
    }

    @Test(arguments: [
        (nil as Int?, ReleaseCheckFailure.transport),
        (304, .httpStatus(304)),
        (403, .httpStatus(403)),
        (404, .httpStatus(404)),
        (429, .httpStatus(429)),
        (500, .httpStatus(500)),
        (201, .httpStatus(201)),
        (204, .httpStatus(204)),
    ])
    func anythingButA200EndsTheCheck(status: Int?, failure: ReleaseCheckFailure) {
        #expect(GitHubReleaseChecker.admit(statusCode: status, expectedLength: -1) == failure)
    }

    @Test func aTwoHundredIsAdmittedUpToTheCap() {
        let cap = Int64(GitHubReleaseChecker.maxBodyBytes)
        #expect(GitHubReleaseChecker.maxBodyBytes == 262_144, "256 KiB")
        #expect(GitHubReleaseChecker.admit(statusCode: 200, expectedLength: -1) == nil, "unannounced: capped as it streams")
        #expect(GitHubReleaseChecker.admit(statusCode: 200, expectedLength: 0) == nil)
        #expect(GitHubReleaseChecker.admit(statusCode: 200, expectedLength: cap) == nil)
        #expect(GitHubReleaseChecker.admit(statusCode: 200, expectedLength: cap + 1) == .oversize)
        #expect(GitHubReleaseChecker.admit(statusCode: 200, expectedLength: .max) == .oversize)
    }

    // MARK: The parse

    @Test func aRealisticReleaseYieldsItsTopLevelTagOnly() throws {
        let outcome = GitHubReleaseChecker.parse(Self.data(Self.realisticRelease))
        #expect(outcome == .latest(try #require(ReleaseVersion(tag: "v1.7.0"))))
    }

    @Test(arguments: [
        ("empty", ""),
        ("not JSON", "not json"),
        ("an HTML error page", "<html><body>Bad gateway</body></html>"),
        ("truncated", #"{"tag_name": "v1.7.0""#),
        ("a top-level array", #"[{"tag_name": "v1.7.0"}]"#),
        ("a top-level string", #""v1.7.0""#),
        ("a top-level null", "null"),
        ("a top-level number", "170"),
        ("trailing junk", #"{"tag_name": "v1.7.0"} x"#),
    ])
    func malformedBodiesFail(name: String, body: String) {
        #expect(GitHubReleaseChecker.parse(Self.data(body)) == .failed(.malformed), "\(name)")
    }

    @Test func invalidUTF8IsMalformed() {
        #expect(GitHubReleaseChecker.parse(Data([0x7B, 0x22, 0xFF, 0xFE, 0x22, 0x3A, 0x31, 0x7D])) == .failed(.malformed))
    }

    @Test(arguments: [
        ("no tag at all", "{}"),
        ("only a name", #"{"name": "v1.7.0"}"#),
        ("null", #"{"tag_name": null}"#),
        ("a number", #"{"tag_name": 170}"#),
        ("an array", #"{"tag_name": ["v1.7.0"]}"#),
        ("an object", #"{"tag_name": {"v": "1.7.0"}}"#),
        ("nested only", #"{"release": {"tag_name": "v1.7.0"}}"#),
        ("a differently cased key", #"{"Tag_Name": "v1.7.0"}"#),
    ])
    func aMissingTagFails(name: String, body: String) {
        #expect(GitHubReleaseChecker.parse(Self.data(body)) == .failed(.missingTag), "\(name)")
    }

    @Test(arguments: ["v1.7.0-beta.1", "1.7.0", "v1.7", "v1.7.0 ", "latest", "", "v01.7.0",
                      "v1.7.0/../../evil", "https://attacker.example/v1.7.0"])
    func anUnusableTagFails(tag: String) throws {
        let body = String(data: try JSONSerialization.data(withJSONObject: ["tag_name": tag]), encoding: .utf8) ?? ""
        #expect(GitHubReleaseChecker.parse(Self.data(body)) == .failed(.unusableTag), "'\(tag)'")
    }

    /// JSON escapes decode before the grammar runs, so an escaped tag is the
    /// same tag — and an escaped junk tag is still junk.
    @Test func escapedTagsAreJudgedAfterDecoding() throws {
        #expect(GitHubReleaseChecker.parse(Self.data(#"{"tag_name": "v1.7.0"}"#))
                == .latest(try #require(ReleaseVersion(tag: "v1.7.0"))))
        #expect(GitHubReleaseChecker.parse(Self.data(#"{"tag_name": "v1.7.0\u0000"}"#)) == .failed(.unusableTag))
    }

    // MARK: The cap (oversize fixtures)

    /// A valid body padded to exactly the cap still parses; one byte more is
    /// a failure — decided before any JSON parsing.
    @Test func theCapIsCheckedBeforeParsing() throws {
        let cap = GitHubReleaseChecker.maxBodyBytes
        let head = #"{"tag_name": "v1.7.0", "pad": ""#
        let tail = #""}"#
        let exact = head + String(repeating: "x", count: cap - head.utf8.count - tail.utf8.count) + tail
        #expect(exact.utf8.count == cap)
        #expect(GitHubReleaseChecker.parse(Self.data(exact)) == .latest(try #require(ReleaseVersion(tag: "v1.7.0"))))
        let over = head + String(repeating: "x", count: cap - head.utf8.count - tail.utf8.count + 1) + tail
        #expect(GitHubReleaseChecker.parse(Self.data(over)) == .failed(.oversize))
        #expect(GitHubReleaseChecker.parse(Data(count: 4 * cap)) == .failed(.oversize), "not even inspected")
    }
}

/// Issue #111, part 4: the client — the one pinned, unauthenticated request,
/// the ephemeral redirect-refusing session, the header gate and the
/// streaming cap. The delegate is driven DIRECTLY (tasks minted from a
/// throwaway session are never resumed), and the end-to-end checks run on
/// `InMemoryGitHubProtocol`, installed only through the session's
/// `protocolClasses`: no test resolves a hostname or opens a socket.
@Suite(.serialized)
struct GitHubReleaseClientTests {
    static let running = ReleaseVersion(bundleVersion: "1.6.0")!
    static let endpoint = URL(string: "https://api.github.com/repos/MuratAlkan06/NapCat/releases/latest")!
    static let patience: TimeInterval = 5

    // MARK: The request

    @Test func theRequestIsTheOnePinnedUnauthenticatedGet() throws {
        let request = try #require(GitHubReleaseChecker.makeRequest(running: Self.running))
        #expect(request.url == Self.endpoint)
        #expect(request.url?.absoluteString == "https://api.github.com/repos/MuratAlkan06/NapCat/releases/latest")
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil && request.httpBodyStream == nil)
        #expect(request.allHTTPHeaderFields == ["User-Agent": "NapCat/1.6.0", "Accept": "application/vnd.github+json"],
                "exactly NapCat's two headers — got \(request.allHTTPHeaderFields ?? [:])")
        for header in ["Authorization", "Cookie", "Proxy-Authorization", "X-GitHub-Api-Version"] {
            #expect(request.value(forHTTPHeaderField: header) == nil, "\(header)")
        }
        #expect(request.timeoutInterval == 10)
        #expect(!request.httpShouldHandleCookies)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        // The User-Agent's version is the running one, rendered from its numbers.
        let twelve = try #require(ReleaseVersion(bundleVersion: "12.0.3"))
        let other = try #require(GitHubReleaseChecker.makeRequest(running: twelve))
        #expect(other.value(forHTTPHeaderField: "User-Agent") == "NapCat/12.0.3")
    }

    /// The page a manual check opens: the constant prefix plus the validated
    /// tag — the response's own `html_url` is never read.
    @Test func theReleasePageIsTheConstantPrefixPlusTheValidatedTag() throws {
        let version = try #require(ReleaseVersion(tag: "v1.7.0"))
        #expect(GitHubReleaseChecker.releasePageURL(for: version)?.absoluteString
                == "https://github.com/MuratAlkan06/NapCat/releases/tag/v1.7.0")
        #expect(GitHubReleaseChecker.releasePagePrefix == "https://github.com/MuratAlkan06/NapCat/releases/tag/")
        #expect(GitHubReleaseChecker.parse(Data(GitHubReleaseCheckerTests.realisticRelease.utf8)) == .latest(version),
                "the realistic fixture's attacker html_url changes nothing")
    }

    // MARK: The session

    @Test func theSessionIsEphemeralBoundedAndRefusesRedirects() throws {
        let fetch = GitHubReleaseFetch { _ in }
        let session = GitHubReleaseChecker.makeSession(delegate: fetch)
        defer { session.invalidateAndCancel() }
        let configuration = session.configuration
        #expect(!configuration.waitsForConnectivity, "offline is a fast failure")
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.timeoutIntervalForRequest == 10 && configuration.timeoutIntervalForResource == 10)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect((configuration.httpAdditionalHeaders ?? [:]).isEmpty, "no extra headers ride along")
        #expect(!(configuration.protocolClasses ?? []).contains { $0 == InMemoryGitHubProtocol.self },
                "production never swaps in the stub")
        let delegate = try #require(session.delegate as? GitHubReleaseFetch, "the session's delegate refuses redirects")
        #expect(delegate === fetch)

        // A redirect is answered with nil (refused), never followed. The task
        // is never resumed: nothing leaves the process.
        let task = session.dataTask(with: URLRequest(url: Self.endpoint))
        let redirect = try #require(HTTPURLResponse(url: Self.endpoint, statusCode: 302, httpVersion: "HTTP/1.1",
                                                    headerFields: ["Location": "https://attacker.example/x"]))
        let box = RedirectDecisionBox()
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: redirect,
                            newRequest: URLRequest(url: URL(string: "https://attacker.example/x")!)) {
            box.set($0)
        }
        #expect(box.decided && box.request == nil, "a redirect must be refused")
    }

    // MARK: The delegate, driven directly

    /// Mints task objects for the delegate calls; never resumed.
    static func mint() -> (URLSession, URLSessionDataTask) {
        let session = URLSession(configuration: .ephemeral)
        return (session, session.dataTask(with: URLRequest(url: endpoint)))
    }

    static func response(_ status: Int, url: URL = endpoint, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private let signal = DispatchSemaphore(value: 0)
        private var outcomes: [ReleaseCheckOutcome] = []
        func set(_ outcome: ReleaseCheckOutcome) {
            lock.lock()
            outcomes.append(outcome)
            lock.unlock()
            signal.signal()
        }
        func wait(_ seconds: TimeInterval) -> ReleaseCheckOutcome? {
            guard signal.wait(timeout: .now() + seconds) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return outcomes.first
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return outcomes.count
        }
    }

    final class DispositionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: URLSession.ResponseDisposition?
        func set(_ disposition: URLSession.ResponseDisposition) {
            lock.lock()
            value = disposition
            lock.unlock()
        }
        var disposition: URLSession.ResponseDisposition? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @Test(arguments: [
        ("a redirect", 302, endpoint, [:] as [String: String], ReleaseCheckFailure.redirected),
        ("a 404", 404, endpoint, [:], .httpStatus(404)),
        ("a 200 from another host", 200, URL(string: "https://attacker.example/releases/latest")!, [:], .redirected),
        ("a 200 over plain http", 200, URL(string: "http://api.github.com/repos/MuratAlkan06/NapCat/releases/latest")!,
         [:], .redirected),
        ("an announced oversize body", 200, endpoint, ["Content-Length": "262145"], .oversize),
    ])
    func theHeaderGateCancelsBeforeAnyBody(name: String, status: Int, url: URL, headers: [String: String],
                                           failure: ReleaseCheckFailure) {
        let (session, task) = Self.mint()
        defer { session.invalidateAndCancel() }
        let latch = Latch()
        let fetch = GitHubReleaseFetch { latch.set($0) }
        let box = DispositionBox()
        fetch.urlSession(session, dataTask: task, didReceive: Self.response(status, url: url, headers: headers)) {
            box.set($0)
        }
        #expect(box.disposition == .cancel, "\(name): the task is cancelled on the headers")
        fetch.urlSession(session, dataTask: task, didReceive: Data(#"{"tag_name": "v1.7.0"}"#.utf8))
        fetch.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        #expect(latch.wait(Self.patience) == .failed(failure), "\(name)")
    }

    /// An unannounced body past the cap: the buffer is dropped, the task is
    /// cancelled the moment it overflows, and the check fails — whatever
    /// arrives afterwards is never kept.
    @Test func theCapHoldsWhileTheBodyStreams() {
        let (session, task) = Self.mint()
        defer { session.invalidateAndCancel() }
        let latch = Latch()
        let fetch = GitHubReleaseFetch { latch.set($0) }
        let box = DispositionBox()
        fetch.urlSession(session, dataTask: task, didReceive: Self.response(200)) { box.set($0) }
        #expect(box.disposition == .allow)
        let chunk = Data(count: 200 * 1024)
        fetch.urlSession(session, dataTask: task, didReceive: chunk)
        #expect(task.state == .suspended, "under the cap: still reading")
        fetch.urlSession(session, dataTask: task, didReceive: chunk)
        #expect(task.state == .canceling || task.state == .completed, "over the cap: cancelled at once")
        fetch.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        #expect(latch.wait(Self.patience) == .failed(.oversize))
    }

    /// Exactly once, even if the system reports completion twice.
    @Test func theCompletionRunsExactlyOnce() throws {
        let (session, task) = Self.mint()
        defer { session.invalidateAndCancel() }
        let latch = Latch()
        let fetch = GitHubReleaseFetch { latch.set($0) }
        fetch.urlSession(session, dataTask: task, didReceive: Self.response(200)) { _ in }
        fetch.urlSession(session, dataTask: task, didReceive: Data(#"{"tag_name": "v1.7.0"}"#.utf8))
        fetch.urlSession(session, task: task, didCompleteWithError: nil)
        fetch.urlSession(session, task: task, didCompleteWithError: nil)
        #expect(latch.wait(Self.patience) == .latest(try #require(ReleaseVersion(tag: "v1.7.0"))))
        #expect(latch.count == 1)
    }

    @Test func aTransportErrorIsATransportFailure() {
        let (session, task) = Self.mint()
        defer { session.invalidateAndCancel() }
        let latch = Latch()
        let fetch = GitHubReleaseFetch { latch.set($0) }
        fetch.urlSession(session, task: task, didCompleteWithError: URLError(.notConnectedToInternet))
        #expect(latch.wait(Self.patience) == .failed(.transport))
    }

    // MARK: End to end, in memory

    static func check(_ script: InMemoryGitHubProtocol.Script) -> (ReleaseCheckOutcome?, [URLRequest]) {
        InMemoryGitHubProtocol.box.load(script)
        let latch = Latch()
        GitHubReleaseChecker(running: running, protocolClasses: [InMemoryGitHubProtocol.self])
            .fetchLatest { latch.set($0) }
        return (latch.wait(patience), InMemoryGitHubProtocol.box.seenRequests())
    }

    @Test func aReleaseArrivesThroughTheRealSessionPath() throws {
        let (outcome, seen) = Self.check(.init(status: 200, body: Data(GitHubReleaseCheckerTests.realisticRelease.utf8)))
        #expect(outcome == .latest(try #require(ReleaseVersion(tag: "v1.7.0"))))
        // What would have left the Mac: the pinned URL and NapCat's two
        // headers — no credential of any kind.
        let request = try #require(seen.first)
        #expect(seen.count == 1)
        #expect(request.url == Self.endpoint && request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "NapCat/1.6.0")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        for header in ["Authorization", "Cookie", "Proxy-Authorization"] {
            #expect(request.value(forHTTPHeaderField: header) == nil, "\(header)")
        }
    }

    @Test(arguments: [
        ("a redirect", InMemoryGitHubProtocol.Script(status: 302, headers: ["Location": "https://attacker.example/x"]),
         ReleaseCheckFailure.redirected),
        ("rate limited", .init(status: 403), .httpStatus(403)),
        ("no release yet", .init(status: 404), .httpStatus(404)),
        ("an oversize body", .init(status: 200, body: Data(count: 300 * 1024)), .oversize),
        ("a malformed body", .init(status: 200, body: Data("<html>oops</html>".utf8)), .malformed),
        ("no tag_name", .init(status: 200, body: Data(#"{"name": "v1.7.0"}"#.utf8)), .missingTag),
        ("a prerelease tag", .init(status: 200, body: Data(#"{"tag_name": "v1.7.0-rc.1"}"#.utf8)), .unusableTag),
        ("offline", .init(status: 0, failure: true), .transport),
    ])
    func everyFailureArrivesAsAFailure(name: String, script: InMemoryGitHubProtocol.Script,
                                       failure: ReleaseCheckFailure) {
        let (outcome, seen) = Self.check(script)
        #expect(outcome == .failed(failure), "\(name)")
        #expect(seen.count == 1, "\(name): one request, never a retry or a followed redirect")
    }
}

/// TEST-ONLY in-memory api.github.com. Installed ONLY through a session
/// configuration's `protocolClasses` (`GitHubReleaseChecker(running:
/// protocolClasses:)`) — never the process-global `registerClass`. `canInit`
/// claims every request and `startLoading` answers from the loaded script:
/// nothing ever reaches the network. The suite using it is serialized.
final class InMemoryGitHubProtocol: URLProtocol, @unchecked Sendable {
    struct Script: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
        var failure = false
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var script = Script(status: 500)
        private var seen: [URLRequest] = []
        func load(_ next: Script) {
            lock.lock()
            script = next
            seen = []
            lock.unlock()
        }
        func admit(_ request: URLRequest) -> Script {
            lock.lock()
            defer { lock.unlock() }
            seen.append(request)
            return script
        }
        func seenRequests() -> [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }
    }

    static let box = Box()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let script = Self.box.admit(request)
        guard !script.failure, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: script.status, httpVersion: "HTTP/1.1",
                                             headerFields: script.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !script.body.isEmpty { client?.urlProtocol(self, didLoad: script.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
