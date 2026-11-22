// UPDATE CHECK (issue #111), part 1: the version grammar and its order.
// PURE — no imports, no I/O, no clock. Table-tested in UpdateVersionTests.

/// A NapCat release version: MAJOR.MINOR.PATCH, three non-negative numbers
/// and nothing else.
///
/// THE GRAMMAR IS STRICT, because a parsed tag is the ONLY response value
/// NapCat ever uses (the release page URL is built from it):
/// - a release TAG is `v` + three dot-separated ASCII decimal numbers — the
///   issue's `^v\d+\.\d+\.\d+$` with `\d` narrowed to `[0-9]` (a Unicode
///   digit such as `٣` never counts);
/// - no leading zeros (`v1.06.0` is not a tag NapCat cuts; SemVer §2 forbids
///   them), so a tag renders back byte-identically from its numbers;
/// - each number at most `maxDigits` digits (no overflow, no padding games);
/// - nothing before or after: a prerelease (`v1.7.0-beta.1`), a build suffix
///   (`v1.7.0+5`), whitespace or a fourth number is NOT a release.
///
/// The running app's `CFBundleShortVersionString` follows the same grammar
/// without the `v` (ScaffoldTests locks the plist to MAJOR.MINOR.PATCH).
struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    /// Upper bound on the digits of one number.
    static let maxDigits = 9

    /// A release tag (`v1.7.0`), or nil when it is anything else.
    init?(tag: String) {
        guard tag.hasPrefix("v") else { return nil }
        self.init(numbers: tag.dropFirst())
    }

    /// The running app's `CFBundleShortVersionString` (`1.6.0`), or nil.
    init?(bundleVersion: String) {
        self.init(numbers: Substring(bundleVersion))
    }

    private init?(numbers text: Substring) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= Self.maxDigits,
                  part.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }),
                  part == "0" || part.first != "0",
                  let value = Int(part) else { return nil }
            values.append(value)
        }
        major = values[0]
        minor = values[1]
        patch = values[2]
    }

    /// The tag this version is released under (`v1.7.0`).
    var tag: String { "v\(description)" }

    /// `1.7.0` — the bundle-version form.
    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

enum UpdateVersion {
    /// The release `tag` names when it is STRICTLY newer than `running`;
    /// nil when it is the same release, an older one, or either side does
    /// not parse. `tag` is `Any?` so a stored defaults value goes through
    /// the same gate as a fresh response: a stored tag is re-validated
    /// against the running version every time it is read, so once the app
    /// is upgraded to (or past) it, the "Update available" line disappears.
    static func newerRelease(tag: Any?, running: String) -> ReleaseVersion? {
        guard let running = ReleaseVersion(bundleVersion: running) else { return nil }
        return newerRelease(tag: tag, running: running)
    }

    static func newerRelease(tag: Any?, running: ReleaseVersion) -> ReleaseVersion? {
        guard let text = tag as? String, let release = ReleaseVersion(tag: text), release > running else { return nil }
        return release
    }
}
