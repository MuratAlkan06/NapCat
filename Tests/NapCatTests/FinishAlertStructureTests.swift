// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// FA-8 (policy half): the pure Track C finish-alert policy stays I/O-free —
/// no filesystem, dispatch sources/timers, network, subprocess, process or
/// IOKit power symbols, logging, clock/environment reads, or defaults — and
/// can never name the stored ntfy topic. Only `import Foundation` is allowed.
/// Canary-proven in-suite: every banned token injected into a copy of the
/// shipped file must trip the lint.
struct FinishAlertStructureTests {
    static let policyFile = "FinishAlertPolicy.swift"

    /// Banned in code (comments are stripped first — doc comments may NAME a
    /// boundary). Matched case-sensitively; the log-call tokens below are
    /// additionally matched case-INSENSITIVELY.
    static let bannedTokens = [
        "FileManager", "FileHandle", "DispatchSource", "DispatchQueue", "URLSession", "URLRequest",
        "Process(", "ProcessInfo", "proc_", "IOPM", "IORegisterForSystemPower", "Logger", "Timer",
        "UserDefaults", "NotificationCenter", "Date()", "lidGuardNtfyTopic", "storedTopic",
    ]

    /// Every lint failure for one policy-file text (empty = clean).
    static func lintFailures(_ source: String) -> [String] {
        var failures: [String] = []
        let code = LidGuardStructureTests.codeOnly(source)
        for token in bannedTokens where code.contains(token) {
            failures.append("'\(token)' in \(policyFile) — the finish-alert policy must stay I/O-free")
        }
        for token in LidGuardStructureTests.logCallTokens where code.lowercased().contains(token) {
            failures.append("log call '\(token)' in \(policyFile) — the policy never logs")
        }
        for line in code.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let words = trimmed.split(separator: " ")
            // `import X`, `@testable import X`, `@_exported import X`, `import struct X.Y` …
            guard let importIndex = words.firstIndex(of: "import"),
                  words[..<importIndex].allSatisfy({ $0.hasPrefix("@") }) else { continue }
            if trimmed != "import Foundation" {
                failures.append("'\(trimmed)' — the only import allowed in \(policyFile) is Foundation")
            }
        }
        return failures
    }

    static func shippedPolicy() throws -> String {
        try String(contentsOf: LidGuardStructureTests.sourcesDir().appendingPathComponent(policyFile),
                   encoding: .utf8)
    }

    @Test func shippedPolicyPassesTheLint() throws {
        let source = try Self.shippedPolicy()
        // Vacuity guard: the file must really be the policy.
        #expect(source.contains("enum FinishAlertPolicy"))
        #expect(source.contains("static func observe("))
        #expect(Self.lintFailures(source).isEmpty, "\(Self.lintFailures(source))")
    }

    /// Canary: every banned token, a log call, and a foreign import must trip
    /// the lock when injected into a copy of the shipped file; the same token
    /// inside a `//` comment must NOT (proves the comment strip is what lets
    /// doc comments name the boundary, not a blind spot).
    @Test func lintCatchesMutants() throws {
        let original = try Self.shippedPolicy()
        try #require(Self.lintFailures(original).isEmpty, "canary baseline must be clean")
        let anchor = "enum FinishAlertPolicy {"
        #expect(original.contains(anchor), "canary setup: anchor must exist")

        var mutants: [(String, String)] = Self.bannedTokens.map { token in
            ("banned token \(token)", "    static let canary = \(token)")
        }
        mutants += [
            ("logger call", "    static func canary() { alertLogger.notice(\"x\") }"),
            ("print call", "    static func canary() { print(\"x\") }"),
            ("NSLog call", "    static func canary() { NSLog(\"x\") }"),
            ("os_log call", "    static func canary() { os_log(\"x\") }"),
            ("defaults read", "    static let canary = UserDefaults.standard.string(forKey: \"x\")"),
            ("topic read", "    static let canary = DefaultsKeys.lidGuardNtfyTopic"),
            ("dispatch timer", "    static let canary = DispatchSource.makeTimerSource()"),
            ("wall clock read", "    static let canary = Date().timeIntervalSince1970"),
        ]
        for (name, line) in mutants {
            let mutant = original.replacingOccurrences(of: anchor, with: anchor + "\n" + line)
            #expect(mutant != original, "canary setup '\(name)'")
            #expect(!Self.lintFailures(mutant).isEmpty, "canary '\(name)' was NOT caught by the lint")
        }

        let importMutants = [
            ("second import", "import Foundation", "import Foundation\nimport Darwin"),
            ("IOKit import", "import Foundation", "import IOKit"),
            ("attributed import", "import Foundation", "import Foundation\n@preconcurrency import Dispatch"),
            ("scoped import", "import Foundation", "import Foundation\nimport class Foundation.FileManager"),
        ]
        for (name, target, replacement) in importMutants {
            let mutant = original.replacingOccurrences(of: target, with: replacement)
            #expect(mutant != original, "canary setup '\(name)'")
            #expect(!Self.lintFailures(mutant).isEmpty, "canary '\(name)' was NOT caught by the lint")
        }

        // Negative control: naming a banned symbol in a comment is allowed.
        let commented = original.replacingOccurrences(
            of: anchor, with: anchor + "\n    // never FileManager, Timer, Logger, UserDefaults, lidGuardNtfyTopic")
        #expect(commented != original)
        #expect(Self.lintFailures(commented).isEmpty, "a doc mention must not trip the lint")
    }
}
