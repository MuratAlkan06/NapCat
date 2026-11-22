// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCatWire

/// F4 slice S1: the channel server's wire (`ApprovalChannel`) and its version
/// stamp. The stamp follows the busy hook's precedent: one Swift constant, one
/// stamp line in the design doc, byte-matched here.
struct ApprovalChannelTests {
    // MARK: - The version stamp (Swift ↔ design doc parity)

    static let designDocURL = LidGuardStructureTests.repoRoot().appendingPathComponent("design/remote-approvals.md")

    /// Exactly one stamp line, reading exactly `<prefix><expected>`.
    static func versionStampFailures(_ doc: String, expected: Int) -> [String] {
        let prefix = ApprovalChannel.serverVersionStampPrefix
        let lines = doc.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let stamps = lines.filter { $0.contains(prefix) }
        guard stamps.count == 1, let stamp = stamps.first else {
            return ["exactly one stamp line in the design doc — found \(stamps.count)"]
        }
        return stamp == prefix + "\(expected)" ? [] : ["the stamp line reads '\(stamp)', expected '\(prefix)\(expected)'"]
    }

    @Test func theServerVersionStampMatchesTheDesignDoc() throws {
        let doc = try String(contentsOf: Self.designDocURL, encoding: .utf8)
        let failures = Self.versionStampFailures(doc, expected: ApprovalChannel.serverVersion)
        #expect(failures.isEmpty, "\(failures)")
        #expect(ApprovalChannel.serverVersion == 1, "the contract value of this slice")
        #expect(ApprovalChannel.serverVersionStampPrefix == "napcat-channel-version: ")
    }

    /// Canaries: a drift on either side, a duplicate or a dropped stamp fail.
    @Test func theStampParityCatchesADriftOnEitherSide() throws {
        let doc = try String(contentsOf: Self.designDocURL, encoding: .utf8)
        let expected = ApprovalChannel.serverVersion
        let stamp = ApprovalChannel.serverVersionStampPrefix + "\(expected)"
        try #require(Self.versionStampFailures(doc, expected: expected).isEmpty, "canary baseline must be clean")
        #expect(!Self.versionStampFailures(doc, expected: expected + 1).isEmpty, "Swift bumped, doc not")
        let mutants: [(String, String)] = [
            ("doc bumped, Swift not", doc.replacingOccurrences(of: stamp, with: ApprovalChannel.serverVersionStampPrefix + "\(expected + 1)")),
            ("stamp dropped", doc.replacingOccurrences(of: stamp, with: "")),
            ("duplicate stamp", doc + "\n" + stamp + "\n"),
        ]
        for (name, mutant) in mutants {
            #expect(mutant != doc, "canary setup '\(name)'")
            #expect(!Self.versionStampFailures(mutant, expected: expected).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    /// Claude Code sees the same version as the server's `serverInfo.version`.
    @Test func theServerReportsItsVersionInTheHandshake() throws {
        let line = ApprovalChannel.initializeResult(id: .number("1"), requestedVersion: "2025-06-18")
        let members = try #require(ApprovalPreview.parseObject(line))
        guard case .object(let result)? = members.first(where: { $0.key == "result" })?.value,
              case .object(let info)? = result.first(where: { $0.key == "serverInfo" })?.value else {
            Issue.record("no serverInfo in \(line)")
            return
        }
        #expect(info.first { $0.key == "version" }?.value == .string("\(ApprovalChannel.serverVersion)"))
        #expect(info.first { $0.key == "name" }?.value == .string(ApprovalChannel.serverName))
    }
}
