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

    // MARK: - F-5 (issue #103): an explicit, pinned environment

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)  // Tests/NapCatTests/<this file>
            .deletingLastPathComponent() // Tests/NapCatTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    /// The watchdog gets exactly HOME and the pinned PATH — nothing inherited
    /// from the app (no BASH_ENV, no exported functions, no user PATH entry).
    @Test func theWatchdogGetsOnlyHomeAndThePinnedPath() {
        #expect(WatchdogController.pinnedPath == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(WatchdogController.watchdogEnvironment(home: "/Users/someone")
                == ["HOME": "/Users/someone", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
    }

    /// Lint: the spawn sets that environment before it runs, with the real
    /// home directory (the script's pidfile lives under it).
    @Test func theSpawnSetsTheEnvironmentBeforeItRuns() throws {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent("Sources/NapCat/WatchdogController.swift"),
                                encoding: .utf8)
        let assignment = try #require(source.range(of: "watchdog.environment = Self.watchdogEnvironment(home: NSHomeDirectory())"),
                                      "the watchdog's environment is no longer set explicitly")
        let run = try #require(source.range(of: "try watchdog.run()"))
        #expect(assignment.upperBound < run.lowerBound, "the environment must be set before the spawn")
        #expect(source.components(separatedBy: ".environment =").count - 1 == 1)
    }

    /// Every violation of the script's PATH pin; empty == locked. `set -u`
    /// first, then exactly the pin (byte-identical to the Swift constant),
    /// and PATH assigned nowhere else.
    static func scriptPathPinFailures(_ script: String) -> [String] {
        let code = script.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let pin = "PATH=\(WatchdogController.pinnedPath); export PATH"
        var failures: [String] = []
        if code.count < 2 || code[0] != "set -u" || code[1] != pin {
            failures.append("the script must open with `set -u` then exactly '\(pin)': \(code.prefix(2))")
        }
        let assignments = code.filter { $0.range(of: #"(^|[;&|\s])(export\s+)?PATH="#, options: .regularExpression) != nil }
        if assignments != [pin] {
            failures.append("PATH must be assigned exactly once, by the pin: \(assignments)")
        }
        return failures
    }

    @Test func theWatchdogScriptPinsPathBeforeItsFirstCommand() throws {
        let script = try String(contentsOf: Self.repoRoot.appendingPathComponent("Resources/napcat-watchdog.sh"), encoding: .utf8)
        #expect(Self.scriptPathPinFailures(script).isEmpty, "\(Self.scriptPathPinFailures(script))")

        let pin = "PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH"
        let mutants: [(String, (String) -> String)] = [
            ("pin dropped", { $0.replacingOccurrences(of: pin + "\n", with: "") }),
            ("user dir prepended", { $0.replacingOccurrences(of: "PATH=/usr/bin:", with: "PATH=$HOME/bin:/usr/bin:") }),
            ("inherited PATH appended", { $0.replacingOccurrences(of: "/sbin; export PATH", with: "/sbin:$PATH; export PATH") }),
            ("pin moved after the first command", {
                $0.replacingOccurrences(of: pin + "\n", with: "")
                    .replacingOccurrences(of: "APP_PID=\"${1:-}\"\n", with: "APP_PID=\"${1:-}\"\n" + pin + "\n")
            }),
            ("PATH reassigned later", { $0.replacingOccurrences(of: "rm -f \"$PIDFILE\"", with: "PATH=/tmp\nrm -f \"$PIDFILE\"") }),
        ]
        for (name, transform) in mutants {
            let mutant = transform(script)
            #expect(mutant != script, "canary setup '\(name)': target text must exist")
            #expect(!Self.scriptPathPinFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    /// Lint-style lock on the watchdog script's privileged surface
    /// (ADR §6b): every sudo invocation in Resources/napcat-watchdog.sh must
    /// byte-match one of the granted sudoers argv strings (PLAN.md §4, via
    /// PrivilegedCommand — PrivilegedCommandTests pins the enum to the §4
    /// literals, and SetupScriptTests parses scripts/setup.sh and locks its
    /// sudoers entries to the same enum), each revert command appears exactly
    /// once, and NO other sudo invocation exists in the script.
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
