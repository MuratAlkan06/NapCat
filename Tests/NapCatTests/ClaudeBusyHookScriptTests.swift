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
        runScript(Self.hookScriptURL, json: json, home: home)
    }

    /// Runs an ARBITRARY hook script (the shipped one, or a mutated copy for a
    /// canary) under the same HOME/PATH discipline as `runHook`.
    private func runScript(_ scriptURL: URL, json: String, home: URL) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
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

    /// Polls a marker until its content records `event=<event>` and returns it.
    /// The keep path re-writes an ALREADY-PRESENT marker in the background, so
    /// `waitForFile(present:true)` alone can observe the pre-reconcile content.
    private func waitForMarkerEvent(_ url: URL, event: String, timeout: Double = 3) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let c = try? String(contentsOf: url, encoding: .utf8), c.contains("event=\(event) ") { return c }
            Thread.sleep(forTimeInterval: 0.03)
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
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

    // MARK: - B3: background_tasks reconcile on turn-ending / idle events

    /// A UserPromptSubmit payload for `session`.
    private func promptJSON(_ session: String) -> String {
        #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(session)"}"#
    }
    /// A reconcile-event payload with an optional raw `background_tasks` value
    /// (pass the JSON literal, e.g. `[{"status":"running"}]`, or nil to omit
    /// the field entirely — the pre-B3 shape).
    private func eventJSON(_ event: String, _ session: String, backgroundTasks: String? = nil) -> String {
        if let tasks = backgroundTasks {
            return #"{"hook_event_name":"\#(event)","session_id":"\#(session)","background_tasks":\#(tasks)}"#
        }
        return #"{"hook_event_name":"\#(event)","session_id":"\#(session)"}"#
    }

    /// Sets a marker for `session` and asserts it landed.
    private func primeMarker(_ session: String, home: URL) {
        _ = runHook(json: promptJSON(session), home: home)
        #expect(waitForFile(markerDir(home).appendingPathComponent(session), present: true),
                "setup: marker for \(session) must exist")
    }

    /// The dominant workflow bug B3 fixes: the main turn's Stop fires while a
    /// background subagent is still running. The marker must be KEPT.
    @Test func stopWithRunningBackgroundTaskKeepsTheMarker() {
        withHome { home in
            let session = "b3000001-0011-4abc-8def-000000000011"
            primeMarker(session, home: home)
            let tasks = #"[{"id":"a","type":"subagent","status":"running","agent_type":"security-dependency-reviewer"}]"#
            let result = runHook(json: eventJSON("Stop", session, backgroundTasks: tasks), home: home)
            #expect(result.exitCode == 0)
            #expect(result.stdout.isEmpty, "stdout must stay empty")
            let marker = markerDir(home).appendingPathComponent(session)
            // The keep path re-writes the marker in the background with the new
            // reconcile event — wait for that content, not just file presence.
            let contents = waitForMarkerEvent(marker, event: "Stop")
            #expect(FileManager.default.fileExists(atPath: marker.path),
                    "a running subagent must KEEP the marker on Stop")
            let pattern = "^v1 ts=[0-9]+ event=Stop pid=[0-9]+ src=unknown\n$"
            #expect(contents.range(of: pattern, options: .regularExpression) != nil,
                    "kept marker \(String(reflecting: contents)) records the reconcile event, same grammar")
        }
    }

    /// Non-running / empty / absent background_tasks preserve the original
    /// clear-on-Stop behavior.
    @Test func stopWithNoRunningBackgroundTaskClearsTheMarker() {
        let noneRunning: [String?] = [
            #"[{"id":"a","type":"subagent","status":"completed","agent_type":"foo"}]"#,  // all done
            "[]",                                                                        // empty
            nil,                                                                          // field absent
        ]
        for tasks in noneRunning {
            withHome { home in
                let session = "b3000002-0012-4abc-8def-000000000012"
                primeMarker(session, home: home)
                let result = runHook(json: eventJSON("Stop", session, backgroundTasks: tasks), home: home)
                #expect(result.exitCode == 0)
                #expect(waitForFile(markerDir(home).appendingPathComponent(session), present: false),
                        "no running subagent (\(tasks ?? "absent")) must CLEAR the marker")
            }
        }
    }

    /// SubagentStop (newly registered in B3) reconciles the same way: a subagent
    /// finishing while others still run keeps the session busy; the last one
    /// finishing clears it.
    @Test func subagentStopReconcilesOnRemainingBackgroundTasks() {
        withHome { home in
            let session = "b3000003-0013-4abc-8def-000000000013"
            primeMarker(session, home: home)
            // One subagent finished, another still running → KEEP.
            let stillRunning = #"[{"id":"b","type":"subagent","status":"running"}]"#
            _ = runHook(json: eventJSON("SubagentStop", session, backgroundTasks: stillRunning), home: home)
            let marker = markerDir(home).appendingPathComponent(session)
            #expect(waitForFile(marker, present: true), "SubagentStop with a still-running peer KEEPS the marker")
            // Last subagent finished → CLEAR.
            let allDone = #"[{"id":"b","type":"subagent","status":"completed"}]"#
            _ = runHook(json: eventJSON("SubagentStop", session, backgroundTasks: allDone), home: home)
            #expect(waitForFile(marker, present: false), "SubagentStop with none running CLEARS the marker")
        }
    }

    /// The `"status":"running"` match must be precise: valid-JSON background_tasks
    /// that merely CONTAIN "running" inside another token, or are the wrong shape
    /// entirely, must NOT be read as a running task — the marker CLEARS (fail
    /// toward the original behavior), exit 0, empty stdout.
    @Test func lookalikeBackgroundTasksNeverCountAsRunning() {
        let decoys: [String] = [
            #"[{"status":"not_running"},{"status":"running_slow"},{"agent_status":"running"}]"#, // lookalike tokens
            #""a-plain-running-string""#,                       // valid JSON, not an array
            "42",                                               // valid JSON, not an array
            #"[{"note":"the word running appears here"}]"#,     // "running" only inside a value
            #"[{"status":"completed"},{"status":"failed"},{"status":"queued"}]"#, // several, none running
        ]
        for tasks in decoys {
            withHome { home in
                let session = "b3000004-0014-4abc-8def-000000000014"
                primeMarker(session, home: home)
                let result = runHook(json: eventJSON("Stop", session, backgroundTasks: tasks), home: home)
                #expect(result.exitCode == 0, "exit 0 on \(String(reflecting: tasks))")
                #expect(result.stdout.isEmpty, "stdout empty on \(String(reflecting: tasks))")
                #expect(waitForFile(markerDir(home).appendingPathComponent(session), present: false),
                        "no exact running token in \(String(reflecting: tasks)) → CLEAR")
            }
        }
    }

    /// A background_tasks value that breaks the WHOLE payload's JSON (truncated /
    /// oversized-then-cut) must never crash the hook and must never be read as a
    /// running task. Invalid stdin is IGNORED at the JSON gate (pre-B3 behavior),
    /// so — with no prior marker — garbage can NEVER conjure a busy marker.
    @Test func brokenBackgroundTasksNeverCrashOrFalselyKeep() {
        withHome { home in
            let session = "b3000006-0016-4abc-8def-000000000016"
            let broken = #"{"hook_event_name":"Stop","session_id":"\#(session)","background_tasks":[{"status":"running"#
            let result = runHook(json: broken, home: home)
            #expect(result.exitCode == 0, "invalid stdin must still exit 0")
            #expect(result.stdout.isEmpty, "invalid stdin must stay silent")
            Thread.sleep(forTimeInterval: 0.1)
            #expect(sessionShapedFiles(in: markerDir(home)).isEmpty,
                    "a truncated background_tasks must never be read as running (no marker created)")
        }
    }

    /// Canary: prove the keep logic has teeth. Neuter the background-task guard
    /// so the reconcile branch ALWAYS clears, then run the exact
    /// "Stop with a running subagent" scenario against the mutant — the marker
    /// MUST be lost. If this ever passes without the guard, the keep behavior
    /// is untested.
    @Test func keepOnRunningBackgroundTaskCanary() throws {
        let original = try Self.read(Self.hookScriptURL)
        let mutant = original.replacingOccurrences(
            of: #"if [ "$bg_running" = yes ]; then"#,
            with: "if false; then")
        #expect(mutant != original, "canary setup: the background-task keep guard must exist to be neutered")

        withHome { home in
            let session = "b3000005-0015-4abc-8def-000000000015"
            let mutantURL = home.appendingPathComponent("mutant-busy-hook.sh")
            try? mutant.write(to: mutantURL, atomically: true, encoding: .utf8)

            _ = runScript(mutantURL, json: promptJSON(session), home: home)
            let marker = markerDir(home).appendingPathComponent(session)
            #expect(waitForFile(marker, present: true), "canary setup: marker must be set first")

            let tasks = #"[{"id":"a","type":"subagent","status":"running"}]"#
            _ = runScript(mutantURL, json: eventJSON("Stop", session, backgroundTasks: tasks), home: home)
            #expect(waitForFile(marker, present: false),
                    "mutant that drops the keep guard must CLEAR the marker (so the keep test has teeth)")
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

    /// B3 event-set parity: SubagentStop is a real event, handled by the hook
    /// and registered by the installer, but it is NOT one of ClaudeBusyConstants'
    /// original five (NapCat's Swift reader only reads markers, so it does not
    /// enumerate hook events). Assert the new event is wired consistently across
    /// the hook, installer, and uninstaller so none drifts out of sync.
    @Test func subagentStopIsWiredAcrossHookAndInstallers() throws {
        let hook = try Self.read(Self.hookScriptURL)
        let installer = try Self.read(Self.installerURL)
        let uninstaller = try Self.read(Self.uninstallerURL)

        #expect(hook.contains("SubagentStop"), "the hook must handle SubagentStop")
        #expect(installer.contains("\"SubagentStop\""), "the installer must print a SubagentStop registration")
        #expect(uninstaller.contains("SubagentStop"), "the uninstaller must list SubagentStop for removal")

        // The installer registers the full set: B1's five + SubagentStop.
        for event in ClaudeBusyConstants.allEvents + ["SubagentStop"] {
            #expect(installer.contains("\"\(event)\""), "installer missing registration for '\(event)'")
        }
        // PreToolUse carries no background_tasks, so it is deliberately NOT wired.
        #expect(!hook.contains("PreToolUse"), "PreToolUse must not be handled (no background_tasks signal)")
        #expect(!installer.contains("PreToolUse"), "PreToolUse must not be registered")
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
