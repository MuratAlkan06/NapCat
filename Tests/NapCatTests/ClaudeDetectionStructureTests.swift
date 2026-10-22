// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Structural isolation for Track B (mirrors DebugPowerSimulator's isolation
/// test): every process/IOKit syscall the detection stack uses is CONFINED to
/// the two designated reader files, and the whole subsystem is STRUCTURALLY
/// ABSENT in debugBattery mode (never constructed).
struct ClaudeDetectionStructureTests {
    private static func sourcesDir() -> URL {
        URL(fileURLWithPath: #filePath)      // Tests/NapCatTests/<this file>
            .deletingLastPathComponent()     // Tests/NapCatTests
            .deletingLastPathComponent()     // Tests
            .deletingLastPathComponent()     // repo root
            .appendingPathComponent("Sources/NapCat")
    }

    private static func swiftSources() throws -> [(name: String, text: String)] {
        let dir = sourcesDir()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
        return try names.map { ($0, codeOnly(try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8))) }
    }

    /// Strips `//`/`///` line comments so the confinement scan matches only
    /// executable code — doc comments legitimately NAME these symbols to
    /// document the boundary. (None of these files use `/* */` blocks, and no
    /// scanned code line contains `//` inside a string literal.)
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let range = line.range(of: "//") { return line[..<range.lowerBound] }
                return line
            }
            .joined(separator: "\n")
    }

    /// Each low-level symbol may appear ONLY in its allowed reader file(s).
    @Test func syscallsAreConfinedToReaderFiles() throws {
        let allowed: [String: Set<String>] = [
            "proc_listpids": ["ClaudeProcessProber.swift"],
            // B1.2: proc_pidpath is now the prober's best-effort SECONDARY only
            // (dropped from SleepAssertionReader); proc_pidinfo pbi_name is the
            // NAME-returning primary in BOTH readers.
            "proc_pidpath": ["ClaudeProcessProber.swift"],
            "proc_pidinfo": ["ClaudeProcessProber.swift", "SleepAssertionReader.swift"],
            "IOPMCopyAssertionsByProcess": ["SleepAssertionReader.swift"],
            // Track C: the finish-alert watcher is the READER file for its
            // own descriptor-level calls — the event-only open and the ONE
            // filesystem-object source (B1 amendment). Registered here rather
            // than widening any existing token's allowed set.
            "O_EVTONLY": ["MarkerDirectoryWatcher.swift"],
            "makeFileSystemObjectSource": ["MarkerDirectoryWatcher.swift"],
        ]
        let sources = try Self.swiftSources()
        for (token, allowedFiles) in allowed {
            for (name, text) in sources where text.contains(token) {
                #expect(allowedFiles.contains(name),
                        "'\(token)' leaked into \(name) — it must stay in \(allowedFiles.sorted())")
            }
            // Guard against a rename making the confinement vacuous: the token
            // must actually appear in at least one allowed file.
            let present = sources.contains { allowedFiles.contains($0.name) && $0.text.contains(token) }
            #expect(present, "'\(token)' not found in any allowed reader file — test would be vacuous")
        }
    }

    /// The pure decision/presentation/menu files must never reference a
    /// process/IOKit read symbol (belt-and-braces over the confinement above).
    @Test func nonReaderDetectionFilesAreSyscallFree() throws {
        let nonReaders = ["ClaudeActivityPolicy.swift", "ClaudeActivityController.swift",
                          "BusyMarkerStore.swift", "MenuStateModel.swift", "MenuPanelView.swift",
                          "MenuPanelVariants.swift", "FinishAlertPolicy.swift", "FinishAlertController.swift",
                          "MarkerDirectoryWatcher.swift"]
        let dir = Self.sourcesDir()
        for file in nonReaders {
            let text = Self.codeOnly(try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8))
            // "import IOKit" (not bare "IOKit" — the controller legitimately
            // names the IOKitSleepAssertionReader type it constructs).
            for token in ["proc_listpids", "proc_pidpath", "proc_pidinfo", "IOPMCopyAssertionsByProcess", "import IOKit"] {
                #expect(!text.contains(token), "'\(token)' must not appear in \(file)")
            }
        }
    }

    /// S7: the app's one read under ~/.claude — the installed hook copy's
    /// first KiB — is resolved in exactly one reader file. The constant may be
    /// DEFINED in ClaudeBusyConstants.swift; only BusyMarkerStore.swift may
    /// name it (or spell the path out).
    static let installedHookPathTokens = ["installedHookRelativePath", ".claude/hooks", "napcat-busy-hook"]

    static let installedHookPathDefinition =
        #"static let installedHookRelativePath = ".claude/hooks/napcat-busy-hook.sh""#

    static func installedHookPathFailures(_ sources: [(name: String, text: String)]) -> [String] {
        var failures: [String] = []
        for (name, text) in sources where name != "BusyMarkerStore.swift" {
            // The constants file is scanned with its ONE definition removed.
            let scanned = name == "ClaudeBusyConstants.swift"
                ? text.replacingOccurrences(of: installedHookPathDefinition, with: "") : text
            for token in installedHookPathTokens where scanned.contains(token) {
                failures.append("'\(token)' in \(name) — only BusyMarkerStore.swift may resolve the installed hook path")
            }
        }
        let constants = sources.first { $0.name == "ClaudeBusyConstants.swift" }?.text ?? ""
        let reader = sources.first { $0.name == "BusyMarkerStore.swift" }?.text ?? ""
        if constants.components(separatedBy: installedHookPathDefinition).count != 2
            || !reader.contains("ClaudeBusyConstants.installedHookRelativePath") {
            failures.append("the definition / the one reader of the installed hook path moved (lint would be vacuous)")
        }
        return failures
    }

    @Test func onlyTheStoreResolvesTheInstalledHookPath() throws {
        let sources = try Self.swiftSources()
        #expect(Self.installedHookPathFailures(sources).isEmpty, "\(Self.installedHookPathFailures(sources))")

        func mutate(_ name: String, _ code: String) -> [(name: String, text: String)] {
            sources.map { $0.name == name ? ($0.name, $0.text + "\n" + code) : $0 }
        }
        let canaries: [(String, [(name: String, text: String)])] = [
            ("menu reads the installed hook",
             mutate("MenuStateModel.swift", "let p = ClaudeBusyConstants.installedHookRelativePath")),
            ("controller spells the path out",
             mutate("ClaudeActivityController.swift", "let p = NSHomeDirectory() + \"/.claude/hooks/x\"")),
            ("finish alert names the hook file", mutate("FinishAlertController.swift", "let n = \"napcat-busy-hook.sh\"")),
            ("a second constant in the constants file",
             mutate("ClaudeBusyConstants.swift", "let q = installedHookRelativePath")),
        ]
        for (name, mutant) in canaries {
            #expect(!Self.installedHookPathFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    /// Debug-sim graph: in debugBattery mode the controller is never built, so
    /// no reader is constructed and no syscall path exists. Outside debug mode
    /// it IS built (construction alone does no I/O).
    @Test @MainActor func detectionControllerAbsentInDebugMode() {
        #expect(ClaudeActivityController.makeIfEnabled(debugBattery: true) == nil,
                "debugBattery mode must not construct the detection stack")
        #expect(ClaudeActivityController.makeIfEnabled(debugBattery: false) != nil,
                "outside debug mode the read-only detection stack is constructed")
    }
}
