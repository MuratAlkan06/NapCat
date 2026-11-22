// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Issue #111, part 1: the release-version grammar and its order. A parsed
/// tag is the only response value the update check ever uses, so the
/// grammar is table-tested from both sides: what it accepts must render back
/// byte-identically, and every near miss (prerelease, padding, Unicode
/// digits, a fourth number, stray bytes) is refused.
struct UpdateVersionTests {
    // MARK: The tag grammar

    @Test(arguments: [
        ("v0.0.0", 0, 0, 0),
        ("v1.6.0", 1, 6, 0),
        ("v1.6.1", 1, 6, 1),
        ("v10.20.30", 10, 20, 30),
        ("v999999999.0.7", 999_999_999, 0, 7),
    ])
    func aStrictReleaseTagParsesAndRendersBack(tag: String, major: Int, minor: Int, patch: Int) throws {
        let version = try #require(ReleaseVersion(tag: tag))
        #expect(version.major == major && version.minor == minor && version.patch == patch)
        #expect(version.tag == tag, "a tag renders back byte-identically")
        #expect(version.description == String(tag.dropFirst()))
    }

    @Test(arguments: [
        "", "v", "1.6.0", "V1.6.0", "vv1.6.0", "v1.6", "v1", "v1.6.0.1", "v1..0", "v1.6.", "v.6.0",
        // Prereleases and build metadata are not releases.
        "v1.7.0-beta.1", "v1.7.0-rc1", "v1.7.0+5", "v1.7.0-",
        // Leading zeros, signs, padding.
        "v01.6.0", "v1.06.0", "v1.6.00", "v00.0.0", "v-1.6.0", "v+1.6.0",
        " v1.6.0", "v1.6.0 ", "v1.6.0\n", "v1. 6.0", "v1.6.0\u{0}",
        // Not ASCII digits.
        "v١.٦.٠", "v1.６.0", "v1.6.0\u{0301}", "v1.6.x",
        // Too long a number (10 digits).
        "v1000000000.0.0",
        // URL-shaped junk.
        "v1.6.0/../x", "v1.6.0?x", "v1.6.0#x", "../v1.6.0",
    ])
    func everythingElseIsRefused(tag: String) {
        #expect(ReleaseVersion(tag: tag) == nil, "'\(tag)' must not parse as a release")
    }

    /// The running app's CFBundleShortVersionString: the same grammar, no `v`.
    @Test func theBundleVersionIsTheSameGrammarWithoutTheV() throws {
        let running = try #require(ReleaseVersion(bundleVersion: "1.6.0"))
        #expect(running.major == 1 && running.minor == 6 && running.patch == 0)
        #expect(running.tag == "v1.6.0" && running.description == "1.6.0")
        for junk in ["v1.6.0", "1.6", "1.6.0-dev", "01.6.0", "", "1.6.0 "] {
            #expect(ReleaseVersion(bundleVersion: junk) == nil, "'\(junk)'")
        }
    }

    /// The shipped Info.plist version parses (else the update check would
    /// never be constructed).
    @Test func theShippedBundleVersionParses() throws {
        let url = LidGuardStructureTests.repoRoot().appendingPathComponent("Resources/Info.plist")
        let plist = try PropertyListSerialization.propertyList(from: try Data(contentsOf: url), format: nil)
        let version = try #require((plist as? [String: Any])?["CFBundleShortVersionString"] as? String)
        #expect(ReleaseVersion(bundleVersion: version) != nil, "'\(version)'")
    }

    /// The grammar file is PURE: no import at all, no I/O, no clock — so the
    /// gate on the one response value can be read in isolation.
    @Test func theGrammarFileIsPure() throws {
        let text = LidGuardStructureTests.codeOnly(try String(
            contentsOf: LidGuardStructureTests.sourcesDir().appendingPathComponent("UpdateVersion.swift"),
            encoding: .utf8))
        #expect(text.contains("struct ReleaseVersion"), "vacuity")
        for token in ["import ", "UserDefaults", "URLSession", "URLRequest", "URL(", "FileManager", "Date(",
                      "ProcessInfo", "Logger", "DispatchQueue", "Task", "NSRegularExpression"] {
            #expect(!text.contains(token), "'\(token)' in UpdateVersion.swift — the grammar stays pure")
        }
    }

    // MARK: The order

    @Test func versionsOrderNumericallyNotLexically() throws {
        let tags = ["v0.9.9", "v1.6.0", "v1.6.1", "v1.9.0", "v1.10.0", "v2.0.0", "v10.0.0"]
        let versions = try tags.map { try #require(ReleaseVersion(tag: $0)) }
        #expect(versions == versions.sorted(), "\(versions)")
        #expect(versions.shuffled().sorted() == versions)
        #expect(try #require(ReleaseVersion(tag: "v1.10.0")) > #require(ReleaseVersion(tag: "v1.9.9")))
    }

    /// The compare table the issue asks for — patch / minor / major newer,
    /// equal, lower, malformed, prerelease — against the running 1.6.0.
    @Test(arguments: [
        ("patch newer", "v1.6.1" as (any Sendable)?, "v1.6.1" as String?),
        ("minor newer", "v1.7.0", "v1.7.0"),
        ("major newer", "v2.0.0", "v2.0.0"),
        ("numeric, not lexical", "v1.10.0", "v1.10.0"),
        ("equal", "v1.6.0", nil),
        ("lower patch", "v1.5.9", nil),
        ("lower major", "v0.99.99", nil),
        ("malformed", "v1.7", nil),
        ("no v", "1.7.0", nil),
        ("prerelease of a newer version", "v1.7.0-beta.1", nil),
        ("prerelease of the same version", "v1.6.0-rc.1", nil),
        ("leading zero", "v1.07.0", nil),
        ("not a string", 170, nil),
        ("absent", nil, nil),
    ] as [(String, (any Sendable)?, String?)])
    func theCompareTable(name: String, tag: (any Sendable)?, expected: String?) {
        #expect(UpdateVersion.newerRelease(tag: tag, running: "1.6.0")?.tag == expected, "\(name)")
    }

    /// A running version that does not parse never claims an update.
    @Test func anUnparsableRunningVersionNeverClaimsAnUpdate() {
        for running in ["", "1.6", "1.6.0-dev", "v1.6.0"] {
            #expect(UpdateVersion.newerRelease(tag: "v9.0.0", running: running) == nil, "'\(running)'")
        }
    }

    /// Read-time re-validation: a tag stored while running 1.6.0 stops being
    /// "newer" once the app itself is 1.7.0 — or later — so the line goes.
    @Test func aStoredTagStopsBeingNewerAfterTheUpgrade() {
        let stored: (any Sendable)? = "v1.7.0"
        #expect(UpdateVersion.newerRelease(tag: stored, running: "1.6.0")?.tag == "v1.7.0")
        #expect(UpdateVersion.newerRelease(tag: stored, running: "1.7.0") == nil)
        #expect(UpdateVersion.newerRelease(tag: stored, running: "1.8.2") == nil)
    }
}
