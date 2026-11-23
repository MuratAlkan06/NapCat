// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing

/// F4 slice S2: structure locks the behaviour tests cannot prove by example.
/// (The armed-gated lock — the host and the probe only behind the toggle,
/// fail-dark — lives with the S1 locks it replaced, in
/// ApprovalChannelStructureTests.)
struct RemoteApprovalsStructureTests {
    typealias Sources = ApprovalChannelStructureTests.Sources

    // MARK: - The toggle's policy is pure by construction

    static let policyFile = "RemoteApprovalsPolicy.swift"
    /// I/O, clocks, logging and the feature's effectful types: the policy
    /// only ever returns effects for the controller to perform.
    static let bannedTokens = ["UserDefaults", "FileManager", "Logger", "os_log", "DispatchQueue", "DispatchSource",
                               "Date(", "clock_gettime", "Timer", "URLSession", "Process(", "ApprovalSeamHost",
                               "SeamListener", "ChannelPolicyProbe", "NSApp", "print("]

    static func purityFailures(_ source: String) -> [String] {
        let code = LidGuardStructureTests.codeOnly(source)
        var failures = bannedTokens.filter { code.contains($0) }.map { "'\($0)' in \(policyFile) — the policy stays I/O-free" }
        for line in code.split(separator: "\n") {
            let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard let index = words.firstIndex(of: "import"), words[..<index].allSatisfy({ $0.hasPrefix("@") }) else { continue }
            if words.joined(separator: " ") != "import NapCatWire" {
                failures.append("'\(line)' — the only import allowed in \(policyFile) is NapCatWire (for the finding)")
            }
        }
        return failures
    }

    @Test func thePolicyIsPure() throws {
        let source = try String(contentsOf: LidGuardStructureTests.sourcesDir().appendingPathComponent(Self.policyFile),
                                encoding: .utf8)
        #expect(source.contains("struct RemoteApprovalsState"), "vacuity: the file is the policy")
        #expect(Self.purityFailures(source).isEmpty, "\(Self.purityFailures(source))")
        for planted in ["import Foundation", "let d = UserDefaults.standard", "let q = DispatchQueue(label: \"x\")",
                        "let h = ApprovalSeamHost(socketPath: p)", "let f = ChannelPolicyProbe.probe()"] {
            #expect(!Self.purityFailures(source + "\n" + planted).isEmpty, "canary '\(planted)' was NOT caught")
        }
        #expect(Self.purityFailures(source + "\n// UserDefaults in a comment is fine").isEmpty)
    }

    // MARK: - The S2 tests touch nothing live

    /// The S2 test files that run anything (this file only reads sources).
    static let s2TestFiles = ["RemoteApprovalsPolicyTests.swift", "RemoteApprovalsControllerTests.swift"]

    /// S1's list, plus what S2 could reach: the toggle's production factory
    /// (it resolves the real socket path and reads the real defaults), the
    /// real keychain, and any defaults store at all.
    static let liveTokens = ApprovalChannelStructureTests.liveTokens
        // The keychain names are split so no test file spells them
        // (KeychainTopicStoreTests.noTestFileCanReachTheRealKeychain).
        + ["makeIfEnabled(", "login" + "Keychain", "Sec" + "Item", ".standard", "/Library/Application Support"]

    static func liveFailures(_ tests: Sources) -> [String] {
        tests.flatMap { name, text in
            liveTokens.filter { text.contains($0) }.map { "'\($0)' in \(name) — S2 tests touch nothing live" }
        }
    }

    @Test func theS2TestsTouchNothingLive() throws {
        let directory = LidGuardStructureTests.repoRoot().appendingPathComponent("Tests/NapCatTests")
        let tests: Sources = try Self.s2TestFiles.map {
            ($0, LidGuardStructureTests.codeOnly(try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)))
        }
        #expect(tests.allSatisfy { !$0.text.isEmpty }, "vacuity: every listed file was read")
        #expect(Self.liveFailures(tests).isEmpty, "\(Self.liveFailures(tests))")
        for planted in ["let c = RemoteApprovalsController.makeIfEnabled(debugBattery: false, lidGuard: l)",
                        "let d = UserDefaults.standard", "let k = KeychainTopicStore." + "login" + "Keychain",
                        "let p = Process()", "let f = ChannelPolicyProbe.probe()",
                        "let s = SeamPaths.socketPath(home: h)"] {
            let mutant = tests.map { $0.name == "RemoteApprovalsControllerTests.swift" ? ($0.name, $0.text + "\n" + planted) : $0 }
            #expect(!Self.liveFailures(mutant).isEmpty, "canary '\(planted)' was NOT caught")
        }
    }
}
