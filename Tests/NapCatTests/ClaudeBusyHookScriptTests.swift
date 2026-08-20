// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// The companion hook is the one place a bug could break the user's Claude
/// Code UX, so it is guarded three ways: a STRUCTURAL LINT (canary-proven),
/// a BEHAVIORAL run against the shipped script, and a PARITY byte-match of the
/// shell constants against the Swift source of truth (the watchdog byte-match
/// precedent applied to Track B).
@MainActor
struct ClaudeBusyHookScriptTests {
    // MARK: Paths

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)  // Tests/NapCatTests/<this file>
            .deletingLastPathComponent() // Tests/NapCatTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }
    private static var hookScriptURL: URL { repoRoot().appendingPathComponent("scripts/claude-busy-hook.sh") }
    private static var installerURL: URL { repoRoot().appendingPathComponent("scripts/install-claude-busy-hook.sh") }
    private static var uninstallerURL: URL { repoRoot().appendingPathComponent("scripts/uninstall-claude-busy-hook.sh") }

    private static func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    // MARK: - Structural hook lint (pure over script text — reusable for canaries)

    /// Returns the list of UX-safety violations; empty == safe. Kept pure so
    /// the same rules can be run against a mutated copy (canary).
    static func hookLintFailures(_ script: String) -> [String] {
        var failures: [String] = []
        let allLines = script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let codeLines = allLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        // 1. Ends in an unconditional `exit 0`.
        if codeLines.last != "exit 0" {
            failures.append("last code line is not 'exit 0' (got \(codeLines.last ?? "<none>"))")
        }
        // 2. Silences stdout before logic runs (code line, not a comment mention).
        if !codeLines.contains(where: { $0.contains("exec >/dev/null") }) {
            failures.append("stdout is not redirected to /dev/null")
        }
        // 3. Never enables errexit.
        if codeLines.contains(where: { $0.contains("set -e") }) {
            failures.append("uses 'set -e'")
        }
        // 4. No bare non-zero exit anywhere in executable code.
        for line in codeLines {
            var cursor = line.startIndex
            while let range = line.range(of: "exit[ \t]+[0-9]+", options: .regularExpression, range: cursor..<line.endIndex) {
                let match = String(line[range])
                let digits = match.drop(while: { !$0.isNumber })
                if digits != "0" { failures.append("bare non-zero exit: '\(match)'") }
                cursor = range.upperBound
            }
        }
        // 5. No network calls.
        for line in codeLines {
            for token in ["curl", "wget", "ssh", "telnet"] where line.contains(token) {
                failures.append("network token '\(token)'")
            }
            if line.range(of: "(^|[^A-Za-z])nc([^A-Za-z]|$)", options: .regularExpression) != nil {
                failures.append("network token 'nc'")
            }
        }
        // 6. The DISABLED kill switch is checked before ANY write op.
        let firstGuard = codeLines.firstIndex(where: { $0.contains("-e \"$DISABLED_FLAG\"") })
        let firstWrite = codeLines.firstIndex(where: {
            $0.contains("mkdir") || $0.hasPrefix("mv ") || $0.contains("printf 'v1")
        })
        if let guardIdx = firstGuard, let writeIdx = firstWrite {
            if guardIdx >= writeIdx { failures.append("DISABLED checked after a write op") }
        } else {
            failures.append("missing DISABLED guard or write op (lint would be vacuous)")
        }
        return failures
    }

    @Test func shippedHookPassesTheLint() throws {
        let failures = Self.hookLintFailures(try Self.read(Self.hookScriptURL))
        #expect(failures.isEmpty, "hook lint violations: \(failures)")
    }

    /// Canary: prove the lint has teeth — mutants that remove the forced exit
    /// 0 or the stdout redirect MUST be caught.
    @Test func hookLintCatchesRemovalOfForcedExitZero() throws {
        var mutant = try Self.read(Self.hookScriptURL)
        // Turn the trailing forced exit into a non-zero exit.
        #expect(mutant.hasSuffix("exit 0\n"))
        mutant.removeLast("exit 0\n".count)
        mutant += "exit 2\n"
        #expect(!Self.hookLintFailures(mutant).isEmpty, "removing forced exit 0 must fail the lint")
    }

    @Test func hookLintCatchesRemovalOfStdoutRedirect() throws {
        let original = try Self.read(Self.hookScriptURL)
        let mutant = original.replacingOccurrences(of: "exec >/dev/null 2>&1", with: ":")
        #expect(mutant != original, "canary setup: the redirect line must exist to be removed")
        #expect(Self.hookLintFailures(mutant).contains(where: { $0.contains("stdout") }),
                "removing the stdout redirect must fail the lint")
    }

    // MARK: - Behavioral run against the shipped script (no real Claude)

    private struct RunResult { let stdout: String; let exitCode: Int32 }

    /// Runs the shipped hook with a TEST-ONLY marker dir via HOME override —
    /// the same $HOME the production exec-form registration always supplies, so
    /// this seam cannot weaken production. SUPERCONDUCTOR_MANAGED_AGENT is
    /// deliberately absent, matching env -i, so `src` records `unknown`.
    private func runHook(json: String, home: URL) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.hookScriptURL.path]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try? process.run()
        stdin.fileHandleForWriting.write(Data(json.utf8))
        try? stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunResult(stdout: String(data: data, encoding: .utf8) ?? "", exitCode: process.terminationStatus)
    }

    private func markerDir(_ home: URL) -> URL {
        home.appendingPathComponent(ClaudeBusyConstants.markerDirRelativePath)
    }

    private func waitForFile(_ url: URL, present: Bool, timeout: Double = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) == present { return true }
            Thread.sleep(forTimeInterval: 0.03)
        }
        return FileManager.default.fileExists(atPath: url.path) == present
    }

    private func withHome(_ body: (URL) -> Void) {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("napcat-b1-hook-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        body(home)
    }

    private func sessionShapedFiles(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { ClaudeBusyConstants.isValidSessionID($0) }
    }

    @Test func userPromptSubmitWritesExactlyOneWellFormedMarker() {
        withHome { home in
            let session = "deadbeef-0001-4abc-8def-000000000001"
            let result = runHook(json: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(session)"}"#, home: home)
            #expect(result.exitCode == 0)
            let marker = markerDir(home).appendingPathComponent(session)
            #expect(waitForFile(marker, present: true), "the backgrounded marker write must land")
            #expect(sessionShapedFiles(in: markerDir(home)) == [session], "exactly one marker")

            let contents = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
            let pattern = "^v1 ts=[0-9]+ event=UserPromptSubmit pid=[0-9]+ src=unknown\n$"
            #expect(contents.range(of: pattern, options: .regularExpression) != nil,
                    "marker content \(String(reflecting: contents)) must match the v1 grammar with src=unknown")
        }
    }

    @Test func everyClearEventRemovesTheMarker() {
        for clearEvent in ClaudeBusyConstants.clearEvents {
            withHome { home in
                let session = "cafe0001-0002-4abc-8def-000000000002"
                _ = runHook(json: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(session)"}"#, home: home)
                let marker = markerDir(home).appendingPathComponent(session)
                #expect(waitForFile(marker, present: true), "\(clearEvent): setup marker must exist")

                let result = runHook(json: #"{"hook_event_name":"\#(clearEvent)","session_id":"\#(session)"}"#, home: home)
                #expect(result.exitCode == 0)
                #expect(waitForFile(marker, present: false), "\(clearEvent) must remove the marker")
            }
        }
    }

    @Test func garbageInputWritesNothingAndStaysSilent() {
        withHome { home in
            for bad in ["not json at all", #"{"no_event":true}"#, "", "[1,2,3]"] {
                let result = runHook(json: bad, home: home)
                #expect(result.exitCode == 0, "exit 0 on garbage: \(String(reflecting: bad))")
                #expect(result.stdout.isEmpty, "stdout must be empty (never reaches Claude)")
                Thread.sleep(forTimeInterval: 0.1)
                #expect(sessionShapedFiles(in: markerDir(home)).isEmpty, "no marker for: \(String(reflecting: bad))")
            }
        }
    }

    @Test func disabledFlagSuppressesAllWork() {
        withHome { home in
            let dir = markerDir(home)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: dir.appendingPathComponent(ClaudeBusyConstants.disabledFlagName).path, contents: Data())

            let session = "0000aaaa-0003-4abc-8def-000000000003"
            let result = runHook(json: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(session)"}"#, home: home)
            #expect(result.exitCode == 0)
            Thread.sleep(forTimeInterval: 0.15)
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(session).path),
                    "kill switch must prevent the marker write")
            // Layer 6 runs before logging too.
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(ClaudeBusyConstants.logFileName).path),
                    "paused hook does not even log")
        }
    }

    @Test func sweepRemovesStaleMarkersKeepsFreshAndForeignFiles() {
        withHome { home in
            let dir = markerDir(home)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let stale = dir.appendingPathComponent("11110000-0004-4abc-8def-000000000004")
            let fresh = dir.appendingPathComponent("22220000-0005-4abc-8def-000000000005")
            let foreign = dir.appendingPathComponent("keep-me.txt")
            let now = Int(Date().timeIntervalSince1970)
            try? "v1 ts=1 event=UserPromptSubmit pid=1 src=unknown\n".write(to: stale, atomically: true, encoding: .utf8)
            try? "v1 ts=\(now) event=UserPromptSubmit pid=1 src=unknown\n".write(to: fresh, atomically: true, encoding: .utf8)
            try? "not a marker".write(to: foreign, atomically: true, encoding: .utf8)
            // Backdate the stale marker and the foreign file well past the cap.
            let old = Date(timeIntervalSinceNow: -Double(ClaudeBusyConstants.freshnessCapSeconds) - 3600)
            try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: stale.path)
            try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: foreign.path)

            // Any invocation sweeps; use an unrelated session so fresh is untouched.
            _ = runHook(json: #"{"hook_event_name":"Stop","session_id":"33330000-0006-4abc-8def-000000000006"}"#, home: home)

            #expect(!FileManager.default.fileExists(atPath: stale.path), ">12h marker swept")
            #expect(FileManager.default.fileExists(atPath: fresh.path), "fresh marker kept")
            #expect(FileManager.default.fileExists(atPath: foreign.path), "non-marker file never deleted")
        }
    }

    // MARK: - Parity: shell constants ↔ Swift source of truth (byte-match)

    @Test func hookScriptMatchesSwiftConstants() throws {
        let script = try Self.read(Self.hookScriptURL)
        // Marker dir path.
        #expect(script.contains(ClaudeBusyConstants.markerDirRelativePath))
        // Session-id regex (verbatim).
        #expect(script.contains(ClaudeBusyConstants.sessionIDRegex))
        // Marker grammar: version + each token prefix, and the full printf.
        #expect(script.contains("v1 ts=%s event=%s pid=%s src=%s"))
        #expect(script.contains(ClaudeBusyConstants.markerVersion))
        for prefix in ClaudeBusyConstants.markerTokenPrefixes {
            #expect(script.contains(prefix), "grammar token '\(prefix)' missing from the shell script")
        }
        // The five event names.
        for event in ClaudeBusyConstants.allEvents {
            #expect(script.contains(event), "event '\(event)' missing from the shell script")
        }
        // 12h cap.
        #expect(script.contains("CAP=\(ClaudeBusyConstants.freshnessCapSeconds)"))
    }

    // MARK: - Installer registration is EXEC FORM only (no shell-form path)

    @Test func installerPrintsExecFormRegistration() throws {
        let installer = try Self.read(Self.installerURL)
        #expect(installer.contains("\"command\":\"/usr/bin/env\""), "exec form uses /usr/bin/env as the command")
        #expect(installer.contains("\"-i\""), "env -i strips BASH_ENV / BASH_FUNC_*")
        #expect(installer.contains("\"/bin/bash\""))
        #expect(installer.contains(ClaudeBusyConstants.installedHookRelativePath), "references the stable installed path")
        #expect(installer.contains("\"timeout\":5"))
        #expect(installer.contains("idle_prompt"), "the Notification entry adds matcher idle_prompt")

        // NO shell-form: the ONLY "command" value is /usr/bin/env, and the
        // script path never appears as a command (only inside args).
        let commandOccurrences = installer.components(separatedBy: "\"command\":\"").count - 1
        #expect(commandOccurrences == 1, "exactly one command literal (the exec-form env), found \(commandOccurrences)")
        #expect(!installer.contains("\"command\":\"/bin/bash\""), "shell-form (bash as command) is forbidden")
        #expect(!installer.contains("\"command\":\"$HOOK_DEST\""), "bare-script-path command is forbidden")
    }

    /// Neither installer nor uninstaller may EDIT settings.json (they only
    /// print). No code line both mentions settings.json and redirects to it.
    @Test func installersNeverWriteSettingsJson() throws {
        for url in [Self.installerURL, Self.uninstallerURL] {
            let text = try Self.read(url)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("#") { continue }
                if code.contains("settings.json") {
                    #expect(!code.contains(">"), "installer must not redirect to settings.json: \(code)")
                }
            }
        }
    }
}
