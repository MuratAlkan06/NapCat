// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT-only toolchain does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Pure-logic tests for stale-watchdog detection (ADR §6 layer b).
/// Process liveness and command-line lookup are injected — no real process
/// is ever spawned or signaled, and no pidfile is touched.
struct WatchdogControllerTests {
    private static let watchdogCommand = "/bin/bash /Applications/NapCat.app/Contents/Resources/napcat-watchdog.sh 4242"

    @Test func missingPidfileMeansNothingToReap() {
        let pid = WatchdogController.stalePID(
            pidfileContents: nil,
            isProcessAlive: { _ in true },
            commandLine: { _ in Self.watchdogCommand }
        )
        #expect(pid == nil)
    }

    @Test func garbagePidfileMeansNothingToReap() {
        for contents in ["", "\n", "not-a-pid", "-7", "0"] {
            let pid = WatchdogController.stalePID(
                pidfileContents: contents,
                isProcessAlive: { _ in true },
                commandLine: { _ in Self.watchdogCommand }
            )
            #expect(pid == nil, "contents \(String(reflecting: contents)) must not reap")
        }
    }

    @Test func deadPidMeansNothingToReap() {
        let pid = WatchdogController.stalePID(
            pidfileContents: "1234\n",
            isProcessAlive: { _ in false },
            commandLine: { _ in Self.watchdogCommand }
        )
        #expect(pid == nil)
    }

    @Test func recycledPidWithUnrelatedCommandMeansNothingToReap() {
        // PID reuse: alive, but it's not our watchdog — must NOT be SIGTERMed.
        let pid = WatchdogController.stalePID(
            pidfileContents: "1234\n",
            isProcessAlive: { _ in true },
            commandLine: { _ in "/usr/sbin/cupsd -l" }
        )
        #expect(pid == nil)
    }

    @Test func alivePidWithVanishedCommandLineMeansNothingToReap() {
        // Raced: alive at kill -0 time, gone by ps time.
        let pid = WatchdogController.stalePID(
            pidfileContents: "1234\n",
            isProcessAlive: { _ in true },
            commandLine: { _ in nil }
        )
        #expect(pid == nil)
    }

    @Test func aliveMatchingWatchdogIsReaped() {
        let pid = WatchdogController.stalePID(
            pidfileContents: " 1234 \n",
            isProcessAlive: { queried in queried == 1234 },
            commandLine: { queried in queried == 1234 ? Self.watchdogCommand : nil }
        )
        #expect(pid == 1234)
    }

    /// The Swift-side pidfile path must byte-match PIDFILE in
    /// Resources/napcat-watchdog.sh ($HOME/Library/Application Support/
    /// NapCat/watchdog.pid) — both sides delete/inspect the same file.
    @Test func pidfilePathMatchesWatchdogScript() {
        #expect(
            WatchdogController.pidfileURL.path
                == NSHomeDirectory() + "/Library/Application Support/NapCat/watchdog.pid"
        )
    }

    /// Lint-style lock on the watchdog script's privileged surface
    /// (ADR §6b): every sudo invocation in Resources/napcat-watchdog.sh must
    /// byte-match one of the granted sudoers argv strings (PLAN.md §4, via
    /// PrivilegedCommand — the same source of truth PrivilegedCommandTests
    /// locks against setup.sh), each revert command appears exactly once,
    /// and NO other sudo invocation exists in the script.
    @Test func watchdogScriptSudoLinesByteMatchGrantedArgvStrings() throws {
        let scriptURL = URL(fileURLWithPath: #filePath)  // Tests/NapCatTests/<this file>
            .deletingLastPathComponent()                 // Tests/NapCatTests
            .deletingLastPathComponent()                 // Tests
            .deletingLastPathComponent()                 // repo root
            .appendingPathComponent("Resources/napcat-watchdog.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        // Guard against path drift making the test vacuous.
        try #require(script.contains("napcat-watchdog.sh <app-pid>"))

        // The complete revert set: stay-awake off + the three charging
        // re-enables (CHTE, with CH0B/CH0C as the fallback family).
        let expectedInvocations: [PrivilegedCommand] = [
            .stayAwakeOff, .chargingEnableCHTE, .chargingEnableCH0B, .chargingEnableCH0C,
        ]

        // Executable lines only — comments in the script legitimately
        // mention sudoers. Every line in this script is either a full-line
        // comment or plain code (no trailing comments, asserted below).
        let codeLines = script
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        for line in codeLines {
            #expect(!line.contains("#"),
                    "trailing comment would defeat this lint — split it out: \(line)")
        }

        for command in expectedInvocations {
            let sudoLine = command.sudoArgv.joined(separator: " ")
            #expect(codeLines.filter { $0.contains(sudoLine) }.count == 1,
                    "watchdog must invoke exactly once: \(sudoLine)")
        }

        let sudoLineCount = codeLines.filter { $0.contains("sudo") }.count
        #expect(sudoLineCount == expectedInvocations.count,
                "watchdog contains a sudo invocation beyond the granted revert set")
    }
}
