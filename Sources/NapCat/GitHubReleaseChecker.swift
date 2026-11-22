import Foundation

// UPDATE CHECK (issue #111), part 3: the release response, read
// defensively. Everything here is PURE and fixture-tested
// (GitHubReleaseCheckerTests): nothing in this part opens a connection.

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

/// The update check's GitHub client (`GET /repos/…/releases/latest`).
///
/// RESPONSE DISCIPLINE: the ONLY value read from a response is the
/// top-level `tag_name`, and it is used only after it passes the strict
/// `ReleaseVersion(tag:)` grammar. No other field — `html_url`, asset URLs,
/// the release notes — is ever read, so no response text can reach a URL,
/// a log line or the UI.
struct GitHubReleaseChecker {
    /// A response body larger than this is a failure, never parsed. A real
    /// `releases/latest` answer is a few KiB.
    static let maxBodyBytes = 256 * 1024

    /// The one response field NapCat reads.
    static let tagField = "tag_name"

    /// The statuses that mean "go elsewhere". Redirects are never followed,
    /// so each of them ends the check.
    static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]

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
