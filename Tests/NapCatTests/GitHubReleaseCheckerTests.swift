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
