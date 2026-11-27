// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Writing a hook child's stdin (#119). The child can be gone before the
/// write lands: the kill switch exits before reading stdin, the capture's
/// `head -c` stops at the cap, and on a loaded machine any child can exit
/// first. A write to a pipe nobody reads raises SIGPIPE, whose default action
/// killed the whole test runner (signal 13). So both suites below ignore
/// SIGPIPE and write with the THROWING API, tolerating the EPIPE that follows:
/// what the child did is what each test then checks.
///
/// SIG_IGN is PROCESS-GLOBAL: once the first of these suites starts, every
/// suite in this test runner sees SIGPIPE ignored, not just these two. That
/// is safe here: the runner is this one test target's own process; no test
/// asserts the default disposition; and Foundation's `Process` restores the
/// default dispositions in every child it spawns, so a hook's own pipelines
/// still die of SIGPIPE as they would under Claude Code. A write elsewhere
/// in the runner to a closed pipe now fails with EPIPE instead of killing it.
enum HookChildStdin {
    /// Evaluated once, when a suite below is first instantiated.
    static let ignoreSIGPIPE: Void = { _ = signal(SIGPIPE, SIG_IGN) }()

    /// Writes `data` to a child's stdin. EPIPE (the child already exited, or
    /// stopped reading) is not an error; any other write error is thrown.
    static func write(_ data: Data, to handle: FileHandle) throws {
        do {
            try handle.write(contentsOf: data)
        } catch where isBrokenPipe(error) {
            // The child is gone; its exit is what the test checks.
        }
    }

    /// Whether `error` is EPIPE, bare or wrapped: Foundation reports it as a
    /// Cocoa write error whose underlying error is POSIX EPIPE.
    static func isBrokenPipe(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return error.code == Int(EPIPE) }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isBrokenPipe) ?? false
    }
}

/// The companion hook is the one place a bug could break the user's Claude
/// Code UX, so it is guarded three ways: a STRUCTURAL LINT (canary-proven),
/// a BEHAVIORAL run against the shipped script, and a PARITY byte-match of the
/// shell constants against the Swift source of truth (the watchdog byte-match
/// precedent applied to Track B).
@MainActor
struct ClaudeBusyHookScriptTests {
    /// SIGPIPE ignored before any test here writes a hook's stdin (#119;
    /// process-global — see `HookChildStdin`).
    init() { _ = HookChildStdin.ignoreSIGPIPE }

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
        // 6. The DISABLED kill switch is checked before ANY write op — a
        //    deletion (`rm -f`) and the sweep call (which deletes stale
        //    markers AND stale temp files) count as writes too.
        let firstGuard = codeLines.firstIndex(where: { $0.contains("-e \"$DISABLED_FLAG\"") })
        let firstWrite = codeLines.firstIndex(where: {
            $0.contains("mkdir") || $0.hasPrefix("mv ") || $0.contains("printf 'v1")
                || $0.contains("rm -f") || $0.contains("sweep_markers \"")
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

    /// Canary (H4): the sweep deletes files, so it must stay behind the kill
    /// switch — a sweep call (or any `rm -f`) hoisted above the DISABLED
    /// check MUST be caught.
    @Test func hookLintCatchesASweepOrDeleteBeforeTheKillSwitch() throws {
        let original = try Self.read(Self.hookScriptURL)
        let guardLine = #"if [ -e "$DISABLED_FLAG" ]; then"#
        #expect(original.contains(guardLine), "canary setup: the kill-switch line must exist")
        for hoisted in [#"sweep_markers "$(date +%s)""#, #"rm -f "$STATE_DIR/.payload.x""#] {
            let mutant = original.replacingOccurrences(of: guardLine, with: hoisted + "\n" + guardLine)
            #expect(mutant != original)
            #expect(Self.hookLintFailures(mutant).contains(where: { $0.contains("DISABLED checked after a write op") }),
                    "'\(hoisted)' above the kill switch must fail the lint")
        }
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
        runScript(scriptURL, bytes: Data(json.utf8), home: home)
    }

    /// `runScript` with raw stdin bytes (a payload that is not valid UTF-8),
    /// and optionally more environment variables than HOME and PATH.
    private func runScript(_ scriptURL: URL, bytes: Data, home: URL,
                           extraEnvironment: [String: String] = [:]) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            .merging(extraEnvironment) { current, _ in current }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try? process.run()
        do {
            try HookChildStdin.write(bytes, to: stdin.fileHandleForWriting)
        } catch {
            Issue.record("writing the hook's stdin failed: \(error)")
        }
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

    /// `withHome` for a throwing body (same temp HOME discipline).
    private func withThrowingHome(_ body: (URL) throws -> Void) throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("napcat-b1-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
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
            let pattern = "^v1 ts=[0-9]+ event=UserPromptSubmit pid=[0-9]+ src=unknown ep=[1-9][0-9]*\n$"
            #expect(contents.range(of: pattern, options: .regularExpression) != nil,
                    "marker content \(String(reflecting: contents)) must match the v1 grammar with src=unknown")
            // Hook v7: a marker set with none before starts a NEW episode, so
            // its episode start is this write's own ts.
            let parsed = ClaudeActivityPolicy.parseMarker(contents)
            #expect(parsed != nil && parsed?.ep == parsed.map { String($0.ts) },
                    "a new episode's ep is the write's ts, got \(String(reflecting: contents))")
        }
    }

    /// Every reconcile event clears a marker once nothing keeps it. B-2:
    /// `SubagentStop` clears only a POST-STOP marker (a foreground subagent
    /// ending mid-turn KEEPS it — the phase table below), so its marker is
    /// first moved past the main turn's Stop (kept by a running task).
    @Test func everyClearEventRemovesTheMarker() {
        #expect(ClaudeBusyConstants.clearEvents.contains("SubagentStop"), "vacuity: all five reconcile events")
        for clearEvent in ClaudeBusyConstants.clearEvents {
            withHome { home in
                let session = "cafe0001-0002-4abc-8def-000000000002"
                _ = runHook(json: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(session)"}"#, home: home)
                let marker = markerDir(home).appendingPathComponent(session)
                #expect(waitForFile(marker, present: true), "\(clearEvent): setup marker must exist")
                if clearEvent == "SubagentStop" {
                    _ = runHook(json: eventJSON("Stop", session, backgroundTasks: Self.runningTask), home: home)
                    #expect(waitForMarkerEvent(marker, event: "Stop").contains("event=Stop "), "setup: post-Stop marker")
                }

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

    /// A `background_tasks` value holding one running subagent.
    static let runningTask = #"[{"id":"a","type":"subagent","status":"running"}]"#

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
            let pattern = "^v1 ts=[0-9]+ event=Stop pid=[0-9]+ src=unknown ep=[1-9][0-9]*\n$"
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

    /// SubagentStop (newly registered in B3) reconciles the same way once the
    /// main turn has ended (B-2: post-Stop — the in-flight keep is in the
    /// phase table): a subagent finishing while others still run keeps the
    /// session busy; the last one finishing clears it.
    @Test func subagentStopReconcilesOnRemainingBackgroundTasks() {
        withHome { home in
            let session = "b3000003-0013-4abc-8def-000000000013"
            primeMarker(session, home: home)
            let marker = markerDir(home).appendingPathComponent(session)
            // The main turn ends while background work runs → post-Stop keep.
            _ = runHook(json: eventJSON("Stop", session, backgroundTasks: Self.runningTask), home: home)
            #expect(waitForMarkerEvent(marker, event: "Stop").contains("event=Stop "), "setup: post-Stop marker")
            // One subagent finished, another still running → KEEP.
            let stillRunning = #"[{"id":"b","type":"subagent","status":"running"}]"#
            _ = runHook(json: eventJSON("SubagentStop", session, backgroundTasks: stillRunning), home: home)
            #expect(waitForMarkerEvent(marker, event: "SubagentStop").contains("event=SubagentStop "),
                    "SubagentStop with a still-running peer KEEPS the marker")
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

    // MARK: - C1: Notification-type discrimination (keep-on-wait / keep-on-resume / clear)

    /// A Notification payload for `session`. `notificationType` is the RAW JSON
    /// literal for the `notification_type` field (e.g. `quoted("idle_prompt")`,
    /// `"123"`), or nil to omit the field; `backgroundTasks` likewise.
    private func notificationJSON(_ session: String, notificationType: String?, backgroundTasks: String? = nil) -> String {
        var fields = [#""hook_event_name":"Notification""#, #""session_id":"\#(session)""#]
        if let notificationType { fields.append(#""notification_type":\#(notificationType)"#) }
        if let backgroundTasks { fields.append(#""background_tasks":\#(backgroundTasks)"#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// `s` as a JSON string literal (callers pass only plain ASCII).
    private func quoted(_ s: String) -> String { "\"\(s)\"" }

    private func hookLog(_ home: URL) -> String {
        let url = markerDir(home).appendingPathComponent(ClaudeBusyConstants.logFileName)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Every WAITING type keeps the marker, rewritten with the synthetic
    /// `waiting` token in the unchanged v1 grammar (and readable by the Swift
    /// parser), and hook.log records reason=waiting-on-user.
    @Test func waitingNotificationTypesKeepTheMarkerAsWaiting() {
        let token = ClaudeBusyConstants.waitingEventToken
        for notificationType in ClaudeBusyConstants.waitingNotificationTypes {
            withHome { home in
                let session = "c1000001-0021-4abc-8def-000000000021"
                primeMarker(session, home: home)
                let result = runHook(json: notificationJSON(session, notificationType: quoted(notificationType)), home: home)
                #expect(result.exitCode == 0, "\(notificationType): exit 0")
                #expect(result.stdout.isEmpty, "\(notificationType): stdout must stay empty")
                let marker = markerDir(home).appendingPathComponent(session)
                let contents = waitForMarkerEvent(marker, event: token)
                let pattern = "^v1 ts=[0-9]+ event=\(token) pid=[0-9]+ src=unknown ep=[1-9][0-9]*\n$"
                #expect(contents.range(of: pattern, options: .regularExpression) != nil,
                        "\(notificationType): kept marker \(String(reflecting: contents)) must record event=\(token)")
                #expect(ClaudeActivityPolicy.parseMarker(contents)?.event == token,
                        "\(notificationType): the Swift reader must parse the waiting marker")
                #expect(hookLog(home).contains(
                    "keep session=\(session) event=Notification type=\(notificationType) phase=inflight reason=waiting-on-user pid="),
                        "\(notificationType): hook.log must record the waiting keep")
            }
        }
    }

    /// Every RESUME type keeps the marker with the REAL event name (work
    /// continues — not a wait) and logs reason=work-continues.
    @Test func resumeNotificationTypesKeepTheMarkerWithTheRealEvent() {
        for notificationType in ClaudeBusyConstants.resumeNotificationTypes {
            withHome { home in
                let session = "c1000002-0022-4abc-8def-000000000022"
                primeMarker(session, home: home)
                let result = runHook(json: notificationJSON(session, notificationType: quoted(notificationType)), home: home)
                #expect(result.exitCode == 0, "\(notificationType): exit 0")
                #expect(result.stdout.isEmpty, "\(notificationType): stdout must stay empty")
                let marker = markerDir(home).appendingPathComponent(session)
                let contents = waitForMarkerEvent(marker, event: "Notification")
                let pattern = "^v1 ts=[0-9]+ event=Notification pid=[0-9]+ src=unknown ep=[1-9][0-9]*\n$"
                #expect(contents.range(of: pattern, options: .regularExpression) != nil,
                        "\(notificationType): kept marker \(String(reflecting: contents)) must record event=Notification")
                #expect(hookLog(home).contains(
                    "keep session=\(session) event=Notification type=\(notificationType) phase=inflight reason=work-continues pid="),
                        "\(notificationType): hook.log must record the resume keep")
            }
        }
    }

    /// The documented CLEAR types, and every unknown / missing / non-string
    /// type, fall through to the original behavior: the marker is CLEARED and
    /// hook.log names the (validated) type, `?` when no string type exists.
    @Test func clearAndUnrecognizedNotificationTypesClearTheMarker() {
        let cap = String(repeating: "q", count: 32)  // longest well-formed type
        var cases: [(json: String?, logged: String)] = ClaudeBusyConstants.clearNotificationTypes.map {
            (json: Optional(quoted($0)), logged: $0)
        }
        cases += [
            (json: quoted("foo"), logged: "foo"),                    // unknown, well-formed
            (json: quoted(cap), logged: cap),                        // unknown, at the 32-char cap
            (json: nil, logged: "?"),                                // field absent
            (json: "123", logged: "?"),                              // number
            (json: "true", logged: "?"),                             // bool
            // S4: a JSON null now passes the stdin gate (`-convert json`,
            // not xml1) and reads as absent.
            (json: "null", logged: "?"),                             // null
            (json: #"{"permission_prompt":1}"#, logged: "?"),        // dict (raw form would print its KEY)
            (json: #"["permission_prompt"]"#, logged: "?"),          // array
            (json: quoted(""), logged: "invalid"),                   // empty string fails {1,32}
        ]
        for (json, logged) in cases {
            withHome { home in
                let session = "c1000003-0023-4abc-8def-000000000023"
                primeMarker(session, home: home)
                let label = json ?? "absent"
                let result = runHook(json: notificationJSON(session, notificationType: json), home: home)
                #expect(result.exitCode == 0, "exit 0 on \(label)")
                #expect(result.stdout.isEmpty, "stdout empty on \(label)")
                #expect(waitForFile(markerDir(home).appendingPathComponent(session), present: false),
                        "notification_type \(label) must CLEAR the marker")
                #expect(hookLog(home).contains("clear session=\(session) event=Notification type=\(logged) phase=inflight\n"),
                        "notification_type \(label) must be logged as type=\(logged)")
            }
        }
    }

    /// A string type failing the strict whole-string check (newline, CR,
    /// uppercase, a non-[a-z_] char, over 32 chars) is treated as unknown: the
    /// marker CLEARS, hook.log says `type=invalid`, and the raw value NEVER
    /// reaches the log (log-forgery guard). The trailing-newline case proves a
    /// newline in the value cannot be stripped into a valid waiting type.
    @Test func malformedNotificationTypeIsLoggedAsInvalidAndNeverEchoed() {
        let long = String(repeating: "q", count: 41)
        let overCap = String(repeating: "q", count: 33)
        let cases: [(json: String, raw: String)] = [
            (#""permission\nprompt""#, "prompt"),             // interior newline
            (#""permission_prompt\n""#, "permission_prompt"),  // trailing newline
            (#""permission_prompt\r""#, "permission_prompt"),  // trailing CR
            (#""x\nkeep session=forged""#, "forged"),          // forged log line
            (quoted("Permission_Prompt"), "Permission_Prompt"), // uppercase
            (quoted("permission-prompt"), "permission-prompt"), // char outside [a-z_]
            (quoted(long), long),                               // 41 chars
            (quoted(overCap), overCap),                         // one past the 32 cap
            // H2 — bash 3.2 drops NUL inside $(…): without the NUL mapping
            // these would collapse into the WAITING type permission_prompt.
            (#""permission\u0000_prompt""#, "_prompt"),        // interior NUL
            (#""permission_prompt\u0000""#, "permission_prompt"), // trailing NUL
            (#""\u0000permission_prompt""#, "permission_prompt"), // leading NUL
        ]
        for (json, raw) in cases {
            withHome { home in
                let session = "c1000004-0024-4abc-8def-000000000024"
                primeMarker(session, home: home)
                let result = runHook(json: notificationJSON(session, notificationType: json), home: home)
                #expect(result.exitCode == 0, "exit 0 on \(json)")
                #expect(result.stdout.isEmpty, "stdout empty on \(json)")
                #expect(waitForFile(markerDir(home).appendingPathComponent(session), present: false),
                        "malformed type \(json) must CLEAR the marker")
                let log = hookLog(home)
                #expect(log.contains("clear session=\(session) event=Notification type=invalid phase=inflight\n"),
                        "malformed type \(json) must be logged as type=invalid")
                #expect(!log.contains(raw), "the raw value of \(json) must never reach hook.log")
                #expect(log.split(separator: "\n").count == 2,
                        "exactly the set + clear lines — no injected line (\(json))")
            }
        }
    }

    /// H2 contrast: the SAME bytes minus the NUL still keep the marker as
    /// waiting — the NUL mapping rejects only the poisoned value.
    @Test func aNulBytePoisonsOnlyItsOwnNotificationType() {
        let token = ClaudeBusyConstants.waitingEventToken
        withHome { home in
            let session = "c1000008-0028-4abc-8def-000000000028"
            primeMarker(session, home: home)
            let marker = markerDir(home).appendingPathComponent(session)
            _ = runHook(json: notificationJSON(session, notificationType: #""permission\u0000_prompt""#), home: home)
            #expect(waitForFile(marker, present: false), "the NUL-poisoned type must CLEAR the marker")
            #expect(hookLog(home).contains("clear session=\(session) event=Notification type=invalid phase=inflight\n"))

            primeMarker(session, home: home)
            _ = runHook(json: notificationJSON(session, notificationType: quoted("permission_prompt")), home: home)
            #expect(waitForMarkerEvent(marker, event: token).contains("event=\(token) "),
                    "the clean permission_prompt must still KEEP the marker as waiting")
        }
    }

    /// Whether this machine's plutil accepts a JSON document carrying the
    /// JSON `escape` (a `\u0000`, or a lone surrogate) under the hook's own
    /// gate command. macOS 15's accepts `\u0000`; newer releases reject the
    /// whole document ("Unsupported escaped (unicode) null"), and Tahoe's
    /// rejects a lone surrogate the same way.
    private func plutilAcceptsEscape(_ escape: String, home: URL) throws -> Bool {
        let probe = home.appendingPathComponent("escape-probe.json")
        try Data(#"{"k":"a\#(escape)b"}"#.utf8).write(to: probe)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        process.arguments = ["-convert", "json", "-o", "/dev/null", probe.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Canary (H2, hook v6): strip BOTH NUL mappings — the `\u0000` escape
    /// rewrite on the stdin capture and the `tr` on the extracted type — and
    /// the poisoned value is no longer rejected as `invalid`. What happens
    /// instead depends on this OS's plutil, probed at runtime: if it accepts
    /// the escape, bash 3.2 drops the NUL and the type collapses into a forged
    /// `waiting` keep; if it rejects it, the whole event is dropped at the
    /// stdin gate (`stdin-not-json`, the marker left as it was). Either way
    /// the NUL rows above have teeth on this OS.
    @Test func nulMappingCanary() throws {
        let original = try Self.read(Self.hookScriptURL)
        let trMapping = " | LC_ALL=C /usr/bin/tr '\\000' '#'"
        let escapeMappedCapture = "  head -c \"$MAX_STDIN\" | LC_ALL=C /usr/bin/sed "
        var lines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let captures = lines.indices.filter { lines[$0].hasPrefix(escapeMappedCapture) }
        try #require(captures.count == 1, "canary setup: exactly one escape-mapping stdin capture must exist")
        lines[captures[0]] = "  head -c \"$MAX_STDIN\" >\"$payload\" 2>/dev/null"  // the pre-v6 capture
        let mutant = lines.joined(separator: "\n").replacingOccurrences(of: trMapping, with: "")
        #expect(original.contains(trMapping), "canary setup: the tr NUL mapping must exist to be removed")
        #expect(!mutant.contains(trMapping) && !mutant.contains(escapeMappedCapture),
                "canary setup: both mappings must be gone from the mutant")

        try withThrowingHome { home in
            let session = "c1000009-0029-4abc-8def-000000000029"
            let mutantURL = home.appendingPathComponent("mutant-busy-hook.sh")
            try mutant.write(to: mutantURL, atomically: true, encoding: .utf8)
            _ = runScript(mutantURL, json: promptJSON(session), home: home)
            let marker = markerDir(home).appendingPathComponent(session)
            #expect(waitForFile(marker, present: true), "canary setup: marker must be set first")

            let poisoned = notificationJSON(session, notificationType: #""permission\u0000_prompt""#)
            _ = runScript(mutantURL, json: poisoned, home: home)
            if try plutilAcceptsEscape(#"\u0000"#, home: home) {
                let token = ClaudeBusyConstants.waitingEventToken
                #expect(waitForMarkerEvent(marker, event: token).contains("event=\(token) "),
                        "plutil accepts the escape: without the mappings the poisoned type must pass as waiting")
            } else {
                let log = hookLog(home)
                #expect(log.hasSuffix(" ignore reason=stdin-not-json\n"),
                        "plutil rejects the escape: without the mappings the event must be dropped, got \(String(reflecting: log))")
                #expect(!log.contains("clear session=") && FileManager.default.fileExists(atPath: marker.path),
                        "the dropped event must leave the marker untouched")
            }
        }
    }

    // MARK: - H3: the event name is validated before it can reach hook.log

    /// A hook_event_name failing the whole-string `^[A-Za-z]{1,32}$` check
    /// (newline, CR, digit, space, over 32 chars) is logged on BOTH ignore
    /// paths as `event=invalid` — the raw text never reaches hook.log, and a
    /// forged second line cannot be injected.
    @Test func malformedEventNameIsLoggedAsInvalidAndNeverEchoed() {
        let valid = "e3000001-0031-4abc-8def-000000000031"
        let cases: [(event: String, raw: String, session: String, reason: String)] = [
            (#""Foo\nclear session=forged event=Stop""#, "forged", valid, "unhandled-event"),
            (#""Foo\nclear session=forged event=Stop""#, "forged", "not-a-session", "bad-session"),
            (#""Foo\r""#, "Foo", valid, "unhandled-event"),
            (#""Foo1""#, "Foo1", valid, "unhandled-event"),
            (#""Foo Bar""#, "Foo Bar", "not-a-session", "bad-session"),
            (quoted(String(repeating: "A", count: 33)), String(repeating: "A", count: 33), valid, "unhandled-event"),
        ]
        for (event, raw, session, reason) in cases {
            withHome { home in
                let json = #"{"hook_event_name":\#(event),"session_id":"\#(session)"}"#
                let result = runHook(json: json, home: home)
                #expect(result.exitCode == 0, "exit 0 on \(event)")
                #expect(result.stdout.isEmpty, "stdout empty on \(event)")
                let log = hookLog(home)
                let lines = log.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
                #expect(lines.count == 1, "exactly one log line for \(event), got \(String(reflecting: log))")
                #expect(log.hasSuffix(" ignore reason=\(reason) event=invalid\n"),
                        "\(event) must be logged as event=invalid, got \(String(reflecting: log))")
                #expect(!log.contains(raw), "the raw event name of \(event) must never reach hook.log")
                #expect(sessionShapedFiles(in: markerDir(home)).isEmpty, "an ignored event writes no marker")
            }
        }
    }

    /// The well-formed cases still log the name: an unknown plain-letters
    /// event (`Foo`) on both ignore paths, and `?` when the field is absent.
    @Test func wellFormedUnknownEventNamesAreStillLogged() {
        let valid = "e3000002-0032-4abc-8def-000000000032"
        let cases: [(json: String, expected: String)] = [
            (#"{"hook_event_name":"Foo","session_id":"\#(valid)"}"#, " ignore reason=unhandled-event event=Foo\n"),
            (#"{"hook_event_name":"Foo","session_id":"bad"}"#, " ignore reason=bad-session event=Foo\n"),
            (#"{"session_id":"\#(valid)"}"#, " ignore reason=unhandled-event event=?\n"),
        ]
        for (json, expected) in cases {
            withHome { home in
                #expect(runHook(json: json, home: home).exitCode == 0)
                let log = hookLog(home)
                #expect(log.hasSuffix(expected), "\(json) must log '\(expected)', got \(String(reflecting: log))")
                #expect(log.split(separator: "\n").count == 1)
            }
        }
    }

    /// Canary (H3): log the raw event again and the forged line lands in
    /// hook.log — proves the event=invalid rows have teeth.
    @Test func rawEventLoggingCanary() throws {
        let original = try Self.read(Self.hookScriptURL)
        let mutant = original.replacingOccurrences(of: "event=$logevent", with: "event=${event:-?}")
        #expect(mutant != original, "canary setup: the validated event field must exist to be reverted")
        withHome { home in
            let mutantURL = home.appendingPathComponent("mutant-busy-hook.sh")
            try? mutant.write(to: mutantURL, atomically: true, encoding: .utf8)
            let json = #"{"hook_event_name":"Foo\nclear session=forged event=Stop","session_id":"e3000003-0033-4abc-8def-000000000033"}"#
            _ = runScript(mutantURL, json: json, home: home)
            let log = hookLog(home)
            #expect(log.contains("forged") && log.split(separator: "\n").count == 2,
                    "the raw-logging mutant must inject the forged line, got \(String(reflecting: log))")
        }
    }

    /// Precedence: a WAITING type wins over a running background task — the
    /// session is blocked on the user, which is what the waiting token says.
    @Test func waitingTypeWinsOverARunningBackgroundTask() {
        withHome { home in
            let session = "c1000005-0025-4abc-8def-000000000025"
            primeMarker(session, home: home)
            let tasks = #"[{"id":"a","type":"subagent","status":"running"}]"#
            let json = notificationJSON(session, notificationType: quoted("permission_prompt"), backgroundTasks: tasks)
            #expect(runHook(json: json, home: home).exitCode == 0)
            let marker = markerDir(home).appendingPathComponent(session)
            let contents = waitForMarkerEvent(marker, event: ClaudeBusyConstants.waitingEventToken)
            #expect(contents.contains("event=\(ClaudeBusyConstants.waitingEventToken) "),
                    "waiting must win over a running background task, got \(String(reflecting: contents))")
            let log = hookLog(home)
            #expect(log.contains("type=permission_prompt phase=inflight reason=waiting-on-user"))
            #expect(!log.contains("reason=background-task-running"))
        }
    }

    /// B3 is unchanged under C1: a CLEAR-class type with a running background
    /// task still KEEPS the marker with the real event name. Non-Notification
    /// log lines carry no `type=` field (byte-identical to pre-C1).
    @Test func clearClassTypeWithARunningBackgroundTaskKeepsViaB3() {
        withHome { home in
            let session = "c1000006-0026-4abc-8def-000000000026"
            primeMarker(session, home: home)
            let tasks = #"[{"id":"a","type":"subagent","status":"running"}]"#
            let json = notificationJSON(session, notificationType: quoted("idle_prompt"), backgroundTasks: tasks)
            #expect(runHook(json: json, home: home).exitCode == 0)
            let marker = markerDir(home).appendingPathComponent(session)
            let contents = waitForMarkerEvent(marker, event: "Notification")
            let pattern = "^v1 ts=[0-9]+ event=Notification pid=[0-9]+ src=unknown ep=[1-9][0-9]*\n$"
            #expect(contents.range(of: pattern, options: .regularExpression) != nil,
                    "idle_prompt + running task must KEEP with event=Notification, got \(String(reflecting: contents))")
            #expect(hookLog(home).contains(
                "keep session=\(session) event=Notification type=idle_prompt phase=inflight reason=background-task-running pid="))

            // The turn really ends: a plain Stop clears, logged exactly as before C1.
            _ = runHook(json: eventJSON("Stop", session), home: home)
            #expect(waitForFile(marker, present: false), "Stop with nothing running CLEARS")
            #expect(hookLog(home).contains("clear session=\(session) event=Stop\n"),
                    "non-Notification log lines carry no type= field")
        }
    }

    /// Canary: prove the waiting keep has teeth. Neuter the waiting branch and
    /// run the permission-prompt scenario against the mutant — the marker MUST
    /// be lost (it falls through to clear).
    @Test func keepOnWaitingNotificationCanary() throws {
        let original = try Self.read(Self.hookScriptURL)
        let mutant = original.replacingOccurrences(
            of: #"if [ "$tclass" = waiting ]; then"#,
            with: "if false; then")
        #expect(mutant != original, "canary setup: the waiting keep guard must exist to be neutered")

        withHome { home in
            let session = "c1000007-0027-4abc-8def-000000000027"
            let mutantURL = home.appendingPathComponent("mutant-busy-hook.sh")
            try? mutant.write(to: mutantURL, atomically: true, encoding: .utf8)

            _ = runScript(mutantURL, json: promptJSON(session), home: home)
            let marker = markerDir(home).appendingPathComponent(session)
            #expect(waitForFile(marker, present: true), "canary setup: marker must be set first")

            _ = runScript(mutantURL, json: notificationJSON(session, notificationType: quoted("permission_prompt")), home: home)
            #expect(waitForFile(marker, present: false),
                    "mutant that drops the waiting keep must CLEAR the marker (so the waiting test has teeth)")
        }
    }

    // MARK: - S4: the stdin gate is JSON validity, not plist convertibility

    /// `plutil -convert xml1` rejects any JSON `null` (plist has no null), so
    /// one nullable field in a Claude Code payload used to drop the whole
    /// event. The gate is `-convert json` now: a Stop carrying `"foo": null`
    /// (and a null inside background_tasks) still CLEARS the marker.
    @Test func aNullValuedFieldNoLongerDropsTheEvent() {
        withHome { home in
            let session = "5a000001-0071-4abc-8def-000000000071"
            primeMarker(session, home: home)
            let json = #"{"hook_event_name":"Stop","session_id":"\#(session)","foo":null,"#
                + #""background_tasks":[{"id":"a","status":"completed","note":null}]}"#
            let result = runHook(json: json, home: home)
            #expect(result.exitCode == 0 && result.stdout.isEmpty)
            #expect(waitForFile(markerDir(home).appendingPathComponent(session), present: false),
                    "a Stop with a null-valued field must still CLEAR the marker")
            let log = hookLog(home)
            #expect(log.hasSuffix(" clear session=\(session) event=Stop\n"), "\(String(reflecting: log))")
            #expect(!log.contains("stdin-not-json"))
        }
    }

    /// Hook v6: newer plutil rejects a whole document carrying a `\u0000`
    /// escape, so a NUL in a field the hook does not read used to drop a
    /// Stop at the gate and leave the marker stuck. The escape is mapped
    /// before the gate now: the Stop still CLEARS, logged exactly as a clean
    /// one — for a top-level field and for one nested in a background task.
    /// (Hook v8 reads the final message only on a Stop kept for background
    /// work; these Stops keep nothing, so it stays unread here.)
    @Test func aNullEscapeInAnUnreadFieldNoLongerDropsTheEvent() {
        let extras = [
            #""last_assistant_message":"bin\u0000dump""#,
            #""background_tasks":[{"id":"a","status":"completed","note":"x\u0000y"}]"#,
        ]
        for extra in extras {
            withHome { home in
                let session = "5a000004-0074-4abc-8def-000000000074"
                primeMarker(session, home: home)
                let json = #"{"hook_event_name":"Stop","session_id":"\#(session)",\#(extra)}"#
                let result = runHook(json: json, home: home)
                #expect(result.exitCode == 0 && result.stdout.isEmpty, "\(extra)")
                #expect(waitForFile(markerDir(home).appendingPathComponent(session), present: false),
                        "a Stop with a null escape in \(extra) must still CLEAR the marker")
                let log = hookLog(home)
                #expect(log.hasSuffix(" clear session=\(session) event=Stop\n"), "\(String(reflecting: log))")
                #expect(!log.contains("stdin-not-json"), "\(extra) must pass the stdin gate")
                #expect(payloadTempFiles(in: markerDir(home)).isEmpty, "the payload is removed")
            }
        }
    }

    /// Hook v6: Tahoe's plutil also rejects a whole document carrying a LONE
    /// surrogate escape (JSON.stringify emits one when a string is cut
    /// mid-emoji), so such a Stop used to be dropped at the gate and leave the
    /// marker stuck. Every surrogate escape is mapped to U+FFFD before the
    /// gate now, so the payload passes it whatever this OS's plutil makes of
    /// lone surrogates (no probe needed): the Stop CLEARS, logged exactly as a
    /// clean one — for a lone high and a lone low surrogate, top-level and
    /// nested, and for a valid pair (mapped too, by design). (As above, the
    /// final message stays unread on these Stops.)
    @Test func aSurrogateEscapeInAnUnreadFieldNoLongerDropsTheEvent() {
        let pair = "\\ud83d\\ude00"  // a VALID pair (U+1F600), as its two JSON escapes
        let extras = [
            #""last_assistant_message":"cut \ud83d""#,
            #""background_tasks":[{"id":"a","status":"completed","note":"\ude00 tail"}]"#,
            #""last_assistant_message":"ok \#(pair)""#,
        ]
        for extra in extras {
            withHome { home in
                let session = "5a000005-0075-4abc-8def-000000000075"
                primeMarker(session, home: home)
                let json = #"{"hook_event_name":"Stop","session_id":"\#(session)",\#(extra)}"#
                let result = runHook(json: json, home: home)
                #expect(result.exitCode == 0 && result.stdout.isEmpty, "\(extra)")
                #expect(waitForFile(markerDir(home).appendingPathComponent(session), present: false),
                        "a Stop with a surrogate escape in \(extra) must still CLEAR the marker")
                let log = hookLog(home)
                #expect(log.hasSuffix(" clear session=\(session) event=Stop\n"), "\(String(reflecting: log))")
                #expect(!log.contains("stdin-not-json"), "\(extra) must pass the stdin gate")
                #expect(payloadTempFiles(in: markerDir(home)).isEmpty, "the payload is removed")
            }
        }
    }

    /// Canary (hook v6): strip ONLY the surrogate mapping and replay the
    /// lone-surrogate Stop. Where plutil rejects a lone surrogate (probed at
    /// runtime — Tahoe does) the event is dropped at the gate and the marker
    /// is left stuck, so the row above has teeth there; a plutil that accepts
    /// one never had the defect, and the Stop still clears.
    @Test func surrogateMappingCanary() throws {
        let original = try Self.read(Self.hookScriptURL)
        let surrogateMapping = #" -e 's/\\u[dD][89a-fA-F][0-9a-fA-F]{2}/\\ufffd/g'"#
        let mutant = original.replacingOccurrences(of: surrogateMapping, with: "")
        #expect(mutant != original, "canary setup: the surrogate mapping must exist to be removed")
        #expect(mutant.contains(#"/usr/bin/sed -E -e 's/\\u0000/\\u0023/g' >"$payload""#),
                "canary setup: the NUL mapping must stay in the mutant")

        try withThrowingHome { home in
            let session = "5a000007-0077-4abc-8def-000000000077"
            let mutantURL = home.appendingPathComponent("mutant-busy-hook.sh")
            try mutant.write(to: mutantURL, atomically: true, encoding: .utf8)
            _ = runScript(mutantURL, json: promptJSON(session), home: home)
            let marker = markerDir(home).appendingPathComponent(session)
            #expect(waitForFile(marker, present: true), "canary setup: marker must be set first")

            let json = #"{"hook_event_name":"Stop","session_id":"\#(session)","last_assistant_message":"cut \ud83d"}"#
            _ = runScript(mutantURL, json: json, home: home)
            let log = hookLog(home)
            if try plutilAcceptsEscape(#"\ud83d"#, home: home) {
                #expect(waitForFile(marker, present: false) && log.hasSuffix(" clear session=\(session) event=Stop\n"),
                        "plutil accepts a lone surrogate: the Stop must still clear, got \(String(reflecting: log))")
            } else {
                #expect(log.hasSuffix(" ignore reason=stdin-not-json\n"),
                        "plutil rejects a lone surrogate: without the mapping the Stop must be dropped, got \(String(reflecting: log))")
                #expect(FileManager.default.fileExists(atPath: marker.path), "the dropped Stop leaves the marker stuck")
            }
        }
    }

    /// Runs the SHIPPED stdin-capture line, verbatim (with the script's own
    /// MAX_STDIN line), on `json`; returns the mapped payload's byte count
    /// and the decoded text of its `k` field (nil when plutil cannot read it).
    private func runShippedCapture(_ json: String, home: URL) throws -> (bytes: Int, text: String?) {
        let lines = try Self.read(Self.hookScriptURL).split(separator: "\n").map(String.init)
        let cap = try #require(lines.first { $0.hasPrefix("MAX_STDIN=") })
        let capture = try #require(lines.first { $0.hasPrefix("  head -c \"$MAX_STDIN\"") })
        let payload = home.appendingPathComponent("mapped-payload.json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", cap + "\n" + capture]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "payload": payload.path]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try HookChildStdin.write(Data(json.utf8), to: stdin.fileHandleForWriting)
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        let bytes = try Data(contentsOf: payload).count

        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        extract.arguments = ["-extract", "k", "raw", "-o", "-", payload.path]
        let out = Pipe()
        extract.standardOutput = out
        extract.standardError = FileHandle.nullDevice
        try extract.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        extract.waitUntilExit()
        guard extract.terminationStatus == 0, var text = String(data: data, encoding: .utf8) else { return (bytes, nil) }
        if text.hasSuffix("\n") { text.removeLast() }
        return (bytes, text)
    }

    /// The capture's mapping, row by row, through the shipped line: the
    /// decoded text afterwards, and a payload exactly as long as the input
    /// (every rewrite is six characters for six, so the cap still holds). An
    /// escaped backslash before `u0000` / `ud83d` makes it TEXT, which is
    /// rewritten harmlessly; `\\\u0000` is a backslash plus `#`; the surrogate
    /// range matches either hex case and stops exactly at D800 and DFFF.
    @Test func theStdinCaptureMapsNulAndSurrogateEscapesInPlace() throws {
        let pair = "\\ud83d\\ude00"   // a valid pair (U+1F600)
        let edges = "\\uD7FF\\uE000"  // the code points either side of the surrogate range
        let rows: [(json: String, text: String)] = [
            (#"{"k":"a\u0000b"}"#, "a#b"),
            (#"{"k":"\\u0000"}"#, "\\u0023"),              // escaped backslash + text
            (#"{"k":"\\\u0000"}"#, "\\#"),                 // escaped backslash, then a NUL escape
            (#"{"k":"cut \ud83d"}"#, "cut \u{FFFD}"),      // lone high surrogate
            (#"{"k":"\udc00x"}"#, "\u{FFFD}x"),            // lone low surrogate
            (#"{"k":"\uDbFf"}"#, "\u{FFFD}"),              // mixed-case hex
            (#"{"k":"\#(pair)"}"#, "\u{FFFD}\u{FFFD}"),    // a valid pair is mapped too
            (#"{"k":"\\ud83d"}"#, "\\ufffd"),              // escaped backslash + text
            (#"{"k":"\#(edges)"}"#, "\u{D7FF}\u{E000}"),   // outside the range: untouched
        ]
        try withThrowingHome { home in
            for (json, text) in rows {
                let mapped = try runShippedCapture(json, home: home)
                #expect(mapped.text == text,
                        "\(json) must read back as \(String(reflecting: text)), got \(String(reflecting: mapped.text))")
                #expect(mapped.bytes == json.utf8.count, "\(json): the rewrite must be length-preserving")
            }
        }
    }

    /// A `\u0000` escape in a field the hook DOES read becomes `#`, which its
    /// strict checks reject — so a NUL that bash 3.2 would drop inside $(…)
    /// can never splice a valid value together: "St\u0000op" is logged as
    /// `unhandled-event event=invalid`, a session id with a NUL inside is a
    /// `bad-session`, and the marker a forged Stop would clear survives both.
    @Test func aNulEscapeCannotForgeTheEventNameOrTheSession() {
        let session = "5a000006-0076-4abc-8def-000000000076"
        let nul = #"\u0000"#
        let poisonedSession = String(session.prefix(24)) + nul + String(session.dropFirst(24))
        let cases: [(json: String, expected: String)] = [
            (#"{"hook_event_name":"St\#(nul)op","session_id":"\#(session)"}"#,
             " ignore reason=unhandled-event event=invalid\n"),
            (#"{"hook_event_name":"Stop","session_id":"\#(poisonedSession)"}"#,
             " ignore reason=bad-session event=Stop\n"),
        ]
        for (json, expected) in cases {
            withHome { home in
                primeMarker(session, home: home)
                let result = runHook(json: json, home: home)
                #expect(result.exitCode == 0 && result.stdout.isEmpty, "\(json)")
                let log = hookLog(home)
                #expect(log.hasSuffix(expected), "\(json) must log '\(expected)', got \(String(reflecting: log))")
                #expect(!log.contains("clear session="), "\(json) must never pass as a Stop")
                #expect(FileManager.default.fileExists(atPath: markerDir(home).appendingPathComponent(session).path),
                        "\(json): the marker a forged Stop would clear must survive")
            }
        }
    }

    /// …and the gate still rejects real garbage, logged as before.
    @Test func realGarbageStillFailsTheStdinGate() {
        let garbage = ["not json at all", "", #"{"hook_event_name":"Stop","session_id":"5a000002"#, "null", "{,}"]
        for bad in garbage {
            withHome { home in
                let result = runHook(json: bad, home: home)
                #expect(result.exitCode == 0 && result.stdout.isEmpty, "\(String(reflecting: bad))")
                let log = hookLog(home)
                #expect(log.hasSuffix(" ignore reason=stdin-not-json\n") && log.split(separator: "\n").count == 1,
                        "\(String(reflecting: bad)) must be rejected at the gate, got \(String(reflecting: log))")
                #expect(sessionShapedFiles(in: markerDir(home)).isEmpty)
                #expect(payloadTempFiles(in: markerDir(home)).isEmpty, "the payload is removed on the reject path")
            }
        }
    }

    /// Canary: the old xml1 gate drops the null-carrying Stop (the marker
    /// survives, the log says stdin-not-json) — proves the S4 test has teeth.
    @Test func xml1GateCanaryDropsANullPayload() throws {
        let original = try Self.read(Self.hookScriptURL)
        let mutant = original.replacingOccurrences(of: "plutil -convert json -o /dev/null",
                                                   with: "plutil -convert xml1 -o /dev/null")
        #expect(mutant != original, "canary setup: the json gate must exist")
        withHome { home in
            let session = "5a000003-0073-4abc-8def-000000000073"
            let mutantURL = home.appendingPathComponent("mutant-busy-hook.sh")
            try? mutant.write(to: mutantURL, atomically: true, encoding: .utf8)
            _ = runScript(mutantURL, json: promptJSON(session), home: home)
            let marker = markerDir(home).appendingPathComponent(session)
            #expect(waitForFile(marker, present: true), "canary setup: marker must be set first")
            _ = runScript(mutantURL, json: #"{"hook_event_name":"Stop","session_id":"\#(session)","foo":null}"#,
                          home: home)
            Thread.sleep(forTimeInterval: 0.1)
            #expect(FileManager.default.fileExists(atPath: marker.path), "the xml1 gate drops the event")
            #expect(hookLog(home).hasSuffix(" ignore reason=stdin-not-json\n"))
        }
    }

    // MARK: - S5: hook.log rotation

    private func logURL(_ home: URL) -> URL {
        markerDir(home).appendingPathComponent(ClaudeBusyConstants.logFileName)
    }

    /// A hook.log larger than 1 MiB is moved to hook.log.1 (replacing the old
    /// generation) BEFORE the next append, so the new line starts a fresh log.
    @Test func anOversizedHookLogIsRotatedBeforeTheAppend() throws {
        try withThrowingHome { home in
            try FileManager.default.createDirectory(at: markerDir(home), withIntermediateDirectories: true)
            let line = "planted line\n"
            let planted = String(repeating: line, count: 1_048_576 / line.utf8.count + 1)
            #expect(planted.utf8.count > 1_048_576, "setup: just over 1 MiB")
            try planted.write(to: logURL(home), atomically: true, encoding: .utf8)
            let rotated = markerDir(home).appendingPathComponent(ClaudeBusyConstants.logFileName + ".1")
            try "an older generation\n".write(to: rotated, atomically: true, encoding: .utf8)

            let result = runHook(json: #"{"hook_event_name":"Foo","session_id":"5b000001-0081-4abc-8def-000000000081"}"#,
                                 home: home)
            #expect(result.exitCode == 0 && result.stdout.isEmpty)
            #expect((try? String(contentsOf: rotated, encoding: .utf8)) == planted,
                    "the oversized log becomes hook.log.1 (one generation, replaced)")
            let fresh = hookLog(home)
            #expect(fresh.split(separator: "\n").count == 1 && fresh.hasSuffix(" ignore reason=unhandled-event event=Foo\n"),
                    "the new line starts a fresh hook.log, got \(String(reflecting: fresh.prefix(200)))")
        }
    }

    /// Exactly 1 MiB is not "larger than": no rotation, the line is appended.
    @Test func aHookLogAtTheCapIsNotRotated() throws {
        try withThrowingHome { home in
            try FileManager.default.createDirectory(at: markerDir(home), withIntermediateDirectories: true)
            let planted = String(repeating: "z", count: 1_048_575) + "\n"
            try planted.write(to: logURL(home), atomically: true, encoding: .utf8)
            _ = runHook(json: #"{"hook_event_name":"Foo","session_id":"5b000002-0082-4abc-8def-000000000082"}"#,
                        home: home)
            #expect(!FileManager.default.fileExists(
                atPath: markerDir(home).appendingPathComponent(ClaudeBusyConstants.logFileName + ".1").path))
            let log = hookLog(home)
            #expect(log.hasPrefix(planted) && log.hasSuffix(" ignore reason=unhandled-event event=Foo\n"))
        }
    }

    // MARK: - S6: the payload temp file is removed on signals too

    /// Pure lint (reusable for canaries): inside main(), right after the
    /// payload mktemp and BEFORE stdin is read, an EXIT trap removes the
    /// payload and a TERM/INT trap removes it AND exits 0 (a trapped signal
    /// would otherwise resume the script); every explicit payload removal is
    /// immediately followed by clearing the traps.
    static func payloadTrapFailures(_ script: String) -> [String] {
        let body = functionBody("main", in: script)
        guard let mktemp = body.firstIndex(where: { $0.hasPrefix("payload=$(mktemp ") }),
              let read = body.firstIndex(where: { $0.hasPrefix(#"head -c "$MAX_STDIN""#) }) else {
            return ["main() must create the payload with mktemp and read stdin with head -c (lint would be vacuous)"]
        }
        var failures: [String] = []
        for trap in [#"trap 'rm -f "$payload" 2>/dev/null' EXIT"#,
                     #"trap 'rm -f "$payload" 2>/dev/null; exit 0' TERM INT"#] {
            guard let index = body.firstIndex(of: trap) else {
                failures.append("missing `\(trap)`")
                continue
            }
            if !(mktemp < index && index < read) {
                failures.append("`\(trap)` must sit between the payload mktemp and the stdin read")
            }
        }
        let removals = body.indices.filter { body[$0] == #"rm -f "$payload" 2>/dev/null"# }
        if removals.count != 2 { failures.append("expected the two explicit payload removals, found \(removals.count)") }
        for index in removals where index + 1 >= body.count || body[index + 1] != "trap - EXIT TERM INT" {
            failures.append("an explicit payload removal is not followed by `trap - EXIT TERM INT`")
        }
        return failures
    }

    @Test func thePayloadTrapIsSetRightAfterTheMktemp() throws {
        let failures = Self.payloadTrapFailures(try Self.read(Self.hookScriptURL))
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func payloadTrapLintCatchesMutants() throws {
        let original = try Self.read(Self.hookScriptURL)
        try #require(Self.payloadTrapFailures(original).isEmpty, "canary baseline must be clean")
        let exitTrap = "  trap 'rm -f \"$payload\" 2>/dev/null' EXIT\n"
        // The stdin read is whatever capture pipeline the script ships (hook
        // v6 pipes it through the `\u0000` escape mapping), taken verbatim.
        let read = String(try #require(original.split(separator: "\n").first {
            $0.hasPrefix("  head -c \"$MAX_STDIN\"")
        })) + "\n"
        let mutants: [(String, (String) -> String)] = [
            ("EXIT trap dropped", { $0.replacingOccurrences(of: exitTrap, with: "") }),
            ("TERM trap resumes instead of exiting", {
                $0.replacingOccurrences(of: "2>/dev/null; exit 0' TERM INT", with: "2>/dev/null' TERM INT")
            }),
            ("trap set after the stdin read", {
                $0.replacingOccurrences(of: exitTrap, with: "").replacingOccurrences(of: read, with: read + exitTrap)
            }),
            ("traps never cleared", { $0.replacingOccurrences(of: "  trap - EXIT TERM INT\n", with: "") }),
        ]
        for (name, transform) in mutants {
            let mutant = transform(original)
            #expect(mutant != original, "canary setup '\(name)'")
            #expect(!Self.payloadTrapFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    private func payloadTempFiles(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(".payload.") }
    }

    // The SIGTERM-in-the-payload-window runs live in
    // `ClaudeBusyHookSignalWindowTests` (end of this file), off the main actor.

    // MARK: - S7: the version stamp (shell ↔ Swift parity) + the installer

    /// Pure parity check (reusable for canaries): exactly one stamp line, it
    /// is LINE 2, it reads `expected`, it ends within the first
    /// `installedHookReadBytes` bytes, and the app's own parser reads that
    /// value back from those bytes.
    static func versionStampFailures(_ script: String, expected: Int) -> [String] {
        var failures: [String] = []
        let prefix = ClaudeBusyConstants.hookVersionStampPrefix
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let stamps = lines.indices.filter { lines[$0].hasPrefix(prefix) }
        if stamps != [1] { failures.append("exactly one stamp line, on line 2 — found at lines \(stamps.map { $0 + 1 })") }
        if lines.count > 1, lines[1] != prefix + "\(expected)" {
            failures.append("line 2 must be '\(prefix)\(expected)', got '\(lines[1])'")
        }
        let cap = ClaudeBusyConstants.installedHookReadBytes
        let stampEnd = lines.prefix(2).joined(separator: "\n").utf8.count + 1
        if stampEnd > cap { failures.append("the stamp line ends past the first \(cap) bytes") }
        let bytes = Array(script.utf8)
        let parsed = MarkerDirectoryStore.parseHookVersionStamp(Array(bytes.prefix(cap)), truncated: bytes.count > cap)
        if parsed != expected { failures.append("the app reads \(String(describing: parsed)), expected \(expected)") }
        return failures
    }

    @Test func hookVersionStampMatchesSwiftConstant() throws {
        let script = try Self.read(Self.hookScriptURL)
        #expect(Self.versionStampFailures(script, expected: ClaudeBusyConstants.hookVersion).isEmpty,
                "\(Self.versionStampFailures(script, expected: ClaudeBusyConstants.hookVersion))")
        // 5 → 6: a `\u0000` escape on stdin is mapped before the plutil gate.
        // 6 → 7: the marker carries the episode start (`ep=`, sixth field).
        // 7 → 8: a Stop kept for background work logs whether the final
        // message asks (one closed word in hook.log; the marker unchanged).
        #expect(ClaudeBusyConstants.hookVersion == 8, "the contract value of this hook version")
        #expect(ClaudeBusyConstants.hookVersionStampPrefix == "# napcat-hook-version: ")
    }

    /// Canaries: a drift on either side, a duplicate stamp, a stamp moved off
    /// line 2 or past the first KiB, or a dropped stamp all fail.
    @Test func versionStampParityCatchesADriftOnEitherSide() throws {
        let script = try Self.read(Self.hookScriptURL)
        let expected = ClaudeBusyConstants.hookVersion
        let stamp = ClaudeBusyConstants.hookVersionStampPrefix + "\(expected)\n"
        try #require(Self.versionStampFailures(script, expected: expected).isEmpty, "canary baseline must be clean")
        #expect(!Self.versionStampFailures(script, expected: expected + 1).isEmpty, "Swift bumped, shell not")
        let mutants: [(String, String)] = [
            ("shell bumped, Swift not", script.replacingOccurrences(of: stamp, with: ClaudeBusyConstants.hookVersionStampPrefix + "\(expected + 1)\n")),
            ("stamp dropped", script.replacingOccurrences(of: stamp, with: "")),
            ("duplicate stamp", script.replacingOccurrences(of: "\numask 077\n", with: "\n" + stamp + "umask 077\n")),
            ("stamp past the first KiB", script.replacingOccurrences(of: stamp, with: "")
                .replacingOccurrences(of: "\numask 077\n", with: "\n" + stamp + "umask 077\n")),
        ]
        for (name, mutant) in mutants {
            #expect(mutant != script, "canary setup '\(name)'")
            #expect(!Self.versionStampFailures(mutant, expected: expected).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    /// The installer prints the version it installs, read from the installed
    /// copy's stamp with this exact command — run here (sed only, never the
    /// installer) against the shipped hook, it yields the Swift constant.
    @Test func theInstallerPrintsTheVersionItInstalls() throws {
        let installer = try Self.read(Self.installerURL)
        let extraction = #"HOOK_VERSION="$(/usr/bin/sed -n 's/^# napcat-hook-version: \([0-9][0-9]*\)$/\1/p' "$HOOK_DEST" | /usr/bin/head -n 1)""#
        let lines = installer.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.contains(extraction), "the installer must read the stamp from the installed copy")
        #expect(lines.contains(#"echo "installed: $HOOK_DEST (755, hook version ${HOOK_VERSION:-unknown})""#),
                "the installer must print the version it installed")
        let extract = try #require(lines.firstIndex(of: extraction))
        let install = try #require(lines.firstIndex { $0.hasPrefix(#"if ! /usr/bin/install -m 755 "$SRC" "$HOOK_DEST""#) })
        #expect(install < extract, "the stamp is read from the copy just installed")

        let sed = Process()
        sed.executableURL = URL(fileURLWithPath: "/usr/bin/sed")
        sed.arguments = ["-n", #"s/^# napcat-hook-version: \([0-9][0-9]*\)$/\1/p"#, Self.hookScriptURL.path]
        let out = Pipe()
        sed.standardOutput = out
        try sed.run()
        let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        sed.waitUntilExit()
        #expect(printed == "\(ClaudeBusyConstants.hookVersion)\n", "the installer would print \(String(reflecting: printed))")
    }

    /// Hook v7: an app build older than this hook cannot read its markers,
    /// so the installer prints ONE static reminder to relaunch NapCat before
    /// the new session — read here, never by running the installer. Its exit
    /// codes stay as they were: `exit 1` on the error paths, `exit 0` last.
    @Test func theInstallerRemindsToRelaunchNapCatBeforeANewSession() throws {
        let installer = try Self.read(Self.installerURL)
        let reminder = #"echo "Reminder: relaunch NapCat from this checkout before starting a new Claude session, so the app matches this hook's marker format.""#
        let lines = installer.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.filter { $0 == reminder }.count == 1, "exactly one reminder line, verbatim")
        #expect(lines.filter { $0.contains("Reminder:") }.count == 1, "no second reminder")
        #expect(!reminder.contains("$") && !reminder.contains("`"), "static text: nothing is expanded")
        let code = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        #expect(code.last == "exit 0", "the success path still ends in exit 0")
        let exits = code.compactMap { line -> String? in
            guard let range = line.range(of: "exit [0-9]+", options: .regularExpression) else { return nil }
            return String(line[range])
        }
        #expect(Set(exits) == ["exit 0", "exit 1"] && exits.filter { $0 == "exit 0" }.count == 1,
                "exit codes unchanged, got \(exits)")
        let reminderIndex = try #require(code.firstIndex(of: reminder))
        let newSessionNote = try #require(code.firstIndex { $0.hasPrefix(#"echo "NOTE: hooks load at session start"#) })
        #expect(reminderIndex < newSessionNote, "the relaunch reminder comes before the new-session note")
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

    /// Plants `name` in `dir` with `contents`, backdated by `age` seconds
    /// (0 = fresh). Returns its URL.
    @discardableResult
    private func plant(_ name: String, in dir: URL, age: Double, contents: String = "x") -> URL {
        let url = dir.appendingPathComponent(name)
        try? contents.write(to: url, atomically: false, encoding: .utf8)
        if age > 0 {
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)],
                                                   ofItemAtPath: url.path)
        }
        return url
    }

    /// H4: a run killed at Claude's 5 s timeout leaves `.payload.*` /
    /// `.marker.*` behind. The next run removes those older than 60 s; a fresh
    /// one (a concurrent run's) stays, and the sweep never touches hook.log, a
    /// foreign dotfile, or a session marker inside the 12 h cap.
    @Test func sweepRemovesStaleTempFilesKeepsFreshAndForeignFiles() {
        withHome { home in
            let dir = markerDir(home)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let twoMinutes = 120.0
            let stalePayload = plant(".payload.abc123", in: dir, age: twoMinutes)
            let staleMarkerTemp = plant(".marker.def456", in: dir, age: twoMinutes)
            let freshPayload = plant(".payload.fresh", in: dir, age: 0)
            let foreignDotfile = plant(".other.abc123", in: dir, age: twoMinutes)
            let log = plant(ClaudeBusyConstants.logFileName, in: dir, age: twoMinutes, contents: "planted line\n")
            let youngMarker = plant("44440000-0007-4abc-8def-000000000007", in: dir, age: twoMinutes,
                                    contents: "v1 ts=1 event=UserPromptSubmit pid=1 src=unknown\n")

            // Any invocation sweeps; an unrelated session leaves the others be.
            let result = runHook(json: #"{"hook_event_name":"Stop","session_id":"55550000-0008-4abc-8def-000000000008"}"#,
                                 home: home)
            #expect(result.exitCode == 0)

            let fm = FileManager.default
            #expect(!fm.fileExists(atPath: stalePayload.path), "a .payload.* older than 60 s is swept")
            #expect(!fm.fileExists(atPath: staleMarkerTemp.path), "a .marker.* older than 60 s is swept")
            #expect(fm.fileExists(atPath: freshPayload.path), "a fresh temp file (a live run's) is kept")
            #expect(fm.fileExists(atPath: foreignDotfile.path), "only .payload.* / .marker.* are temp files")
            #expect(fm.fileExists(atPath: youngMarker.path), "a session marker inside the 12 h cap is kept")
            #expect(hookLog(home).hasPrefix("planted line\n"), "hook.log is appended to, never swept")
            #expect(fm.fileExists(atPath: log.path))
        }
    }

    /// H4: the DISABLED kill switch still short-circuits BEFORE the sweep —
    /// a paused hook deletes nothing, not even stale temp files or a marker
    /// past the 12 h cap (lint order is locked by rule 6 of hookLintFailures).
    @Test func disabledFlagShortCircuitsBeforeTheSweep() {
        withHome { home in
            let dir = markerDir(home)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let old = Double(ClaudeBusyConstants.freshnessCapSeconds) + 3600
            let flag = plant(ClaudeBusyConstants.disabledFlagName, in: dir, age: 120, contents: "")
            let stalePayload = plant(".payload.abc123", in: dir, age: 120)
            let staleMarkerTemp = plant(".marker.def456", in: dir, age: 120)
            let staleMarker = plant("66660000-0009-4abc-8def-000000000009", in: dir, age: old,
                                    contents: "v1 ts=1 event=UserPromptSubmit pid=1 src=unknown\n")

            let result = runHook(json: #"{"hook_event_name":"Stop","session_id":"77770000-0010-4abc-8def-000000000010"}"#,
                                 home: home)
            #expect(result.exitCode == 0)
            Thread.sleep(forTimeInterval: 0.1)

            let fm = FileManager.default
            for url in [flag, stalePayload, staleMarkerTemp, staleMarker] {
                #expect(fm.fileExists(atPath: url.path), "\(url.lastPathComponent) must survive a paused run")
            }
            #expect(!fm.fileExists(atPath: dir.appendingPathComponent(ClaudeBusyConstants.logFileName).path),
                    "a paused hook does not even log")
        }
    }

    // MARK: - Parity: shell constants ↔ Swift source of truth (byte-match)

    @Test func hookScriptMatchesSwiftConstants() throws {
        let script = try Self.read(Self.hookScriptURL)
        // Marker dir path.
        #expect(script.contains(ClaudeBusyConstants.markerDirRelativePath))
        // Session-id regex (verbatim).
        #expect(script.contains(ClaudeBusyConstants.sessionIDRegex))
        // Marker grammar: version + each token prefix, and the full printf
        // (hook v7: the five required tokens, then the optional `ep=`).
        #expect(script.contains("v1 ts=%s event=%s pid=%s src=%s ep=%s"))
        #expect(script.contains(ClaudeBusyConstants.markerVersion))
        for prefix in ClaudeBusyConstants.markerTokenPrefixes + [ClaudeBusyConstants.markerOptionalTokenPrefix] {
            #expect(script.contains(prefix), "grammar token '\(prefix)' missing from the shell script")
        }
        #expect(Self.episodeFieldParityFailures(script).isEmpty, "\(Self.episodeFieldParityFailures(script))")
        // The six registered event names.
        for event in ClaudeBusyConstants.allEvents {
            #expect(script.contains(event), "event '\(event)' missing from the shell script")
        }
        // 12h cap.
        #expect(script.contains("CAP=\(ClaudeBusyConstants.freshnessCapSeconds)"))
    }

    /// Hook v7 parity (pure, reusable for canaries) for the SIXTH field: the
    /// marker is written by ONE printf whose format is the version tag, the
    /// four required tokens, then the optional episode-start token — each
    /// `%s`, built here from the Swift constants; the shell's strict `ep`
    /// check bounds the value at `maxDigits` digits with no leading zero; its
    /// full-line read ends in the optional token (no seventh field); and the
    /// writer carries a value that passed that read over, else anchors at the
    /// write's own ts.
    static func episodeFieldParityFailures(
        _ script: String,
        optional: String = ClaudeBusyConstants.markerOptionalTokenPrefix,
        maxDigits: Int = ClaudeBusyConstants.episodeStartMaxDigits
    ) -> [String] {
        var failures: [String] = []
        let codeLines = script.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let tokens = ClaudeBusyConstants.markerTokenPrefixes + [optional]
        let format = ([ClaudeBusyConstants.markerVersion] + tokens.map { $0 + "%s" }).joined(separator: " ") + "\\n"
        let writers = codeLines.filter { $0.hasPrefix("printf 'v1") }
        if writers.count != 1 { failures.append("exactly one marker printf, found \(writers.count)") }
        if !writers.allSatisfy({ $0.hasPrefix("printf '\(format)' ") }) {
            failures.append("the marker printf must be '\(format)', got \(writers)")
        }
        let epRegex = "^[1-9][0-9]{0,\(maxDigits - 1)}$"
        if !codeLines.contains("EP_RE='\(epRegex)'") {
            failures.append("the shell ep check must be EP_RE='\(epRegex)'")
        }
        let lineRegex = "^v1 ts=[0-9]+ event=[^ ]+ pid=[0-9]+ src=[^ ]+ \(optional)([^ ]+)$"
        if !codeLines.contains("EP_MARKER_RE='\(lineRegex)'") {
            failures.append("the shell ep read must be EP_MARKER_RE='\(lineRegex)'")
        }
        let writer = functionBody("write_marker", in: script)
        for line in [#"ep=$(marker_episode "$1")"#, #"[ -n "$ep" ] || ep=$2"#] where !writer.contains(line) {
            failures.append("write_marker must contain '\(line)'")
        }
        let probe = functionBody("marker_episode", in: script)
        for line in [#"[ -f "$1" ] || return 0"#,
                     #"line=$(head -c 256 "$1" 2>/dev/null | LC_ALL=C /usr/bin/tr '\000' '#')"#,
                     #"[[ $line =~ $EP_MARKER_RE ]] || return 0"#,
                     #"[[ $ep =~ $EP_RE ]] || return 0"#] where !probe.contains(line) {
            failures.append("marker_episode must contain '\(line)'")
        }
        return failures
    }

    /// Canaries: drop the sixth field from the printf, loosen or widen the
    /// shell's ep check, let its read accept a seventh field, skip the
    /// validation, or make the writer always re-anchor — or drift a Swift
    /// constant — and the parity lint fails.
    @Test func episodeFieldParityCatchesADriftOnEitherSide() throws {
        let script = try Self.read(Self.hookScriptURL)
        try #require(Self.episodeFieldParityFailures(script).isEmpty, "canary baseline must be clean")
        let shellMutants: [(String, String, String)] = [
            ("printf drops ep", #" src=%s ep=%s\n' "$2" "$3" "$PPID" "$4" "$ep""#, #" src=%s\n' "$2" "$3" "$PPID" "$4""#),
            ("ep check loosened", "EP_RE='^[1-9][0-9]{0,9}$'", "EP_RE='^[0-9]+$'"),
            ("ep check widened", "EP_RE='^[1-9][0-9]{0,9}$'", "EP_RE='^[1-9][0-9]{0,10}$'"),
            ("ep read accepts a seventh field", #"src=[^ ]+ ep=([^ ]+)$'"#, #"src=[^ ]+ ep=([^ ]+)( |$)'"#),
            ("probe validation dropped", #"[[ $ep =~ $EP_RE ]] || return 0"#, ":"),
            ("writer never carries ep over", #"ep=$(marker_episode "$1")"#, #"ep="""#),
            ("writer never falls back", #"[ -n "$ep" ] || ep=$2"#, ":"),
        ]
        for (name, target, replacement) in shellMutants {
            let mutant = script.replacingOccurrences(of: target, with: replacement)
            #expect(mutant != script, "canary setup '\(name)'")
            #expect(!Self.episodeFieldParityFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        #expect(!Self.episodeFieldParityFailures(script, optional: "episode=").isEmpty, "Swift prefix drift")
        #expect(!Self.episodeFieldParityFailures(script, maxDigits: 11).isEmpty, "Swift digit bound drift")
    }

    /// The quoted names on `line`, in order (`"Stop": [ …` ⇒ ["Stop", …]).
    private static func quotedNames(_ line: Substring) -> [String] {
        line.split(separator: "\"", omittingEmptySubsequences: false).enumerated()
            .filter { $0.offset % 2 == 1 }.map { String($0.element) }
    }

    /// Event-set parity (B3, amended by B-2): SubagentStop is a registered
    /// reconcile event and — since B-2 — a member of `ClaudeBusyConstants.
    /// clearEvents` / `allEvents`. The registration list is set-matched
    /// EXACTLY (nothing missing, nothing extra) against the installer's
    /// printed entries, the uninstaller's removal list, and the README's
    /// hand-paste block, so none drifts out of sync with the Swift constants.
    @Test func subagentStopIsWiredAcrossHookAndInstallers() throws {
        let hook = try Self.read(Self.hookScriptURL)
        let installer = try Self.read(Self.installerURL)
        let uninstaller = try Self.read(Self.uninstallerURL)
        let readme = try Self.read(Self.repoRoot().appendingPathComponent("README.md"))
        let registered = Set(ClaudeBusyConstants.allEvents)

        #expect(ClaudeBusyConstants.allEvents.count == 6 && registered.count == 6, "six distinct registered events")
        #expect(ClaudeBusyConstants.clearEvents.contains("SubagentStop"), "SubagentStop is a reconcile event")
        #expect(hook.contains("SubagentStop"), "the hook must handle SubagentStop")

        let installerEntries = installer.split(separator: "\n").filter { $0.contains("$EXEC_CMD ]") }
            .compactMap { Self.quotedNames($0).first }
        #expect(installerEntries.count == 6 && Set(installerEntries) == registered,
                "installer registrations \(installerEntries) must be exactly \(registered.sorted())")

        let removal = try #require(uninstaller.split(separator: "\n").first { $0.contains("\"UserPromptSubmit\",") },
                                   "the uninstaller's removal list")
        #expect(Self.quotedNames(removal).count == 6 && Set(Self.quotedNames(removal)) == registered,
                "uninstaller removal list \(Self.quotedNames(removal)) must be exactly \(registered.sorted())")

        let readmeEntries = readme.split(separator: "\n")
            .filter { $0.hasPrefix("\"") && $0.contains(ClaudeBusyConstants.installedHookRelativePath) }
            .compactMap { Self.quotedNames($0).first }
        #expect(readmeEntries.count == 6 && Set(readmeEntries) == registered,
                "README registrations \(readmeEntries) must be exactly \(registered.sorted())")

        // PreToolUse carries no background_tasks, so it is deliberately NOT wired.
        #expect(!hook.contains("PreToolUse"), "PreToolUse must not be handled (no background_tasks signal)")
        #expect(!installer.contains("PreToolUse"), "PreToolUse must not be registered")
    }

    /// C1 parity: the shell's two KEEP case patterns byte-match the Swift
    /// waiting / resume lists (same members, same order, nothing extra — a
    /// clear type may never appear in a keep pattern), the synthetic waiting
    /// token byte-matches `WAITING_EVENT`, and every listed type can actually
    /// pass the shell's strict type check (else its branch would be dead code).
    @Test func notificationTypeClassesMatchSwiftConstants() throws {
        let script = try Self.read(Self.hookScriptURL)
        let codeLines = script.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let waiting = ClaudeBusyConstants.waitingNotificationTypes
        let resume = ClaudeBusyConstants.resumeNotificationTypes
        let clear = ClaudeBusyConstants.clearNotificationTypes
        let documented = waiting + resume + clear

        // Synthetic token + strict type check, verbatim.
        let token = ClaudeBusyConstants.waitingEventToken
        #expect(codeLines.contains("WAITING_EVENT=\(token)"), "WAITING_EVENT must byte-match waitingEventToken")
        let typeRegex = "^[a-z_]{1,32}$"
        #expect(codeLines.contains("NTYPE_RE='\(typeRegex)'"), "the strict type check must be ^[a-z_]{1,32}$")

        // Every case-pattern line naming a documented type, in file order.
        let casePatterns = codeLines.filter { line in
            line.hasSuffix(")") && documented.contains(where: { line.contains($0) })
        }
        #expect(casePatterns == [waiting.joined(separator: "|") + ")", resume.joined(separator: "|") + ")"],
                "shell keep patterns \(casePatterns) must byte-match the Swift waiting/resume lists")

        // The three classes are disjoint, and each type is reachable.
        #expect(Set(documented).count == documented.count, "a type may belong to one class only")
        for type in documented {
            #expect(type.range(of: typeRegex, options: .regularExpression) != nil,
                    "'\(type)' can never pass the shell's type check")
        }

        // The token is not a real hook event and parses as a marker event.
        #expect(!ClaudeBusyConstants.allEvents.contains(token),
                "the synthetic token must not collide with a real hook event name")
        #expect(ClaudeActivityPolicy.parseMarker("v1 ts=1 event=\(token) pid=1 src=unknown\n")?.event == token)
    }

    // MARK: - B-2: phase parity (shell lists ↔ Swift constants, byte-match)

    /// The body lines of the shell function `name` (from `name() {` to the
    /// first line that is exactly `}`), comment-free and trimmed.
    static func functionBody(_ name: String, in script: String) -> [String] {
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(of: "\(name)() {") else { return [] }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex(of: "}") ?? rest.endIndex
        return rest[..<end].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Pure parity check (reusable for canaries): `marker_phase`'s case
    /// patterns are EXACTLY the in-flight list, then the post-Stop list, then
    /// the `*)` default — same members, same order, nothing extra; the
    /// synthetic token byte-matches `WAITING_AFTER_STOP_EVENT`; the token
    /// check is `^[A-Za-z-]{1,32}$` and every phase / waiting token passes it;
    /// the two lists are disjoint and each holds its waiting token.
    static func phaseParityFailures(_ script: String, inFlight: [String], postStop: [String],
                                    waitingAfterStop: String) -> [String] {
        var failures: [String] = []
        let codeLines = script.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if !codeLines.contains("WAITING_AFTER_STOP_EVENT=\(waitingAfterStop)") {
            failures.append("WAITING_AFTER_STOP_EVENT must byte-match waitingAfterStopEventToken")
        }
        let tokenRegex = "^[A-Za-z-]{1,32}$"
        if !codeLines.contains("TOKEN_RE='\(tokenRegex)'") {
            failures.append("the marker-token check must be \(tokenRegex)")
        }
        let body = functionBody("marker_phase", in: script)
        if !body.contains(#"line=$(head -c 256 "$1" 2>/dev/null | LC_ALL=C /usr/bin/tr '\000' '#')"#) {
            failures.append("marker_phase must read at most 256 bytes with NULs mapped")
        }
        let patterns = body.filter { $0.hasSuffix(")") && !$0.contains("$") }
        let expected = [inFlight.joined(separator: "|") + ")", postStop.joined(separator: "|") + ")", "*)"]
        if patterns != expected {
            failures.append("marker_phase patterns \(patterns) must byte-match \(expected)")
        }
        let waiting = ClaudeBusyConstants.waitingEventToken
        for token in inFlight + postStop + [waitingAfterStop, waiting]
        where token.range(of: tokenRegex, options: .regularExpression) == nil {
            failures.append("'\(token)' can never pass the marker-token check")
        }
        if !Set(inFlight).isDisjoint(with: postStop) { failures.append("a token may belong to one phase only") }
        if !inFlight.contains(waiting) { failures.append("'\(waiting)' must be IN-FLIGHT") }
        if !postStop.contains(waitingAfterStop) { failures.append("'\(waitingAfterStop)' must be POST-STOP") }
        return failures
    }

    @Test func phaseTokenListsMatchSwiftConstants() throws {
        let script = try Self.read(Self.hookScriptURL)
        let failures = Self.phaseParityFailures(script, inFlight: ClaudeBusyConstants.inFlightEventTokens,
                                                postStop: ClaudeBusyConstants.postStopEventTokens,
                                                waitingAfterStop: ClaudeBusyConstants.waitingAfterStopEventToken)
        #expect(failures.isEmpty, "\(failures)")
        // Vacuity: the probe really exists, and the contract values hold.
        #expect(Self.functionBody("marker_phase", in: script).count >= 10)
        #expect(ClaudeBusyConstants.waitingAfterStopEventToken == "waiting-after-stop")
        #expect(ClaudeBusyConstants.inFlightEventTokens == ["UserPromptSubmit", "Notification", "waiting"])
        #expect(ClaudeBusyConstants.postStopEventTokens
                == ["Stop", "StopFailure", "SessionEnd", "SubagentStop", "waiting-after-stop"])
        // The synthetic token is no real hook event and parses as a marker event.
        let token = ClaudeBusyConstants.waitingAfterStopEventToken
        #expect(!ClaudeBusyConstants.allEvents.contains(token))
        #expect(ClaudeActivityPolicy.parseMarker("v1 ts=1 event=\(token) pid=1 src=unknown\n")?.event == token)
    }

    /// Canaries: drop `waiting-after-stop` from EITHER side (the shell case
    /// pattern, the shell token variable, or the Swift list) — or reorder a
    /// list — and the parity lint fails.
    @Test func phaseParityCatchesADriftOnEitherSide() throws {
        let script = try Self.read(Self.hookScriptURL)
        let inFlight = ClaudeBusyConstants.inFlightEventTokens
        let postStop = ClaudeBusyConstants.postStopEventTokens
        let token = ClaudeBusyConstants.waitingAfterStopEventToken
        try #require(Self.phaseParityFailures(script, inFlight: inFlight, postStop: postStop,
                                              waitingAfterStop: token).isEmpty, "canary baseline must be clean")

        let shellMutants: [(String, String, String)] = [
            ("shell case pattern", "SubagentStop|waiting-after-stop)", "SubagentStop)"),
            ("shell token variable", "WAITING_AFTER_STOP_EVENT=waiting-after-stop", "WAITING_AFTER_STOP_EVENT=waiting"),
            ("shell extra in-flight token", "Notification|waiting)", "Notification|waiting|Stop)"),
            ("shell token regex", "TOKEN_RE='^[A-Za-z-]{1,32}$'", "TOKEN_RE='^[A-Za-z]{1,32}$'"),
            ("shell unbounded read", "head -c 256 \"$1\"", "cat \"$1\""),
            ("shell SessionEnd dropped (S11)", "StopFailure|SessionEnd|SubagentStop", "StopFailure|SubagentStop"),
        ]
        for (name, target, replacement) in shellMutants {
            let mutant = script.replacingOccurrences(of: target, with: replacement)
            #expect(mutant != script, "canary setup '\(name)'")
            #expect(!Self.phaseParityFailures(mutant, inFlight: inFlight, postStop: postStop,
                                              waitingAfterStop: token).isEmpty, "canary '\(name)' was NOT caught")
        }
        let swiftMutants: [(String, [String], [String])] = [
            ("Swift post-Stop list", inFlight, postStop.filter { $0 != token }),
            ("Swift in-flight list", inFlight.filter { $0 != "Notification" }, postStop),
            ("Swift list order", inFlight, Array(postStop.reversed())),
            ("Swift SessionEnd dropped (S11)", inFlight, postStop.filter { $0 != "SessionEnd" }),
        ]
        for (name, mutantInFlight, mutantPostStop) in swiftMutants {
            #expect(!Self.phaseParityFailures(script, inFlight: mutantInFlight, postStop: mutantPostStop,
                                              waitingAfterStop: token).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - B-2: the phase-aware reconcile table, through the shipped script

    enum PhaseEvent: String, CaseIterable, Sendable {
        case subagentStop = "SubagentStop"
        case permissionPrompt = "permission_prompt"            // WAITING class
        case quotaAutoResumeFired = "quota_auto_resume_fired"  // RESUME class
        case idlePrompt = "idle_prompt"                        // CLEAR class
    }

    enum PhaseVerdict: Equatable, Sendable {
        case keep(String)   // reason=
        case clear
        case ignore         // reason=no-marker
        /// Hook v5 — reason=poststop-clear-notification: the post-Stop marker
        /// is left BYTE-IDENTICAL (no rewrite, no clear).
        case spare
    }

    struct PhaseRow: CustomTestStringConvertible, Sendable {
        let id: String
        /// The marker's event token before the event; nil = no marker.
        let prior: String?
        let event: PhaseEvent
        let bg: Bool
        /// The marker's event token after the event; nil = no marker.
        let result: String?
        let verdict: PhaseVerdict
        var testDescription: String {
            "\(id): \(prior ?? "absent") + \(event.rawValue) bg=\(bg ? "yes" : "no") → \(result ?? "absent")"
        }
    }

    /// The frozen phase of each prior token (absent ⇒ none).
    nonisolated static func phase(of prior: String?) -> String {
        guard let prior else { return "none" }
        if ClaudeBusyConstants.inFlightEventTokens.contains(prior) { return "inflight" }
        if ClaudeBusyConstants.postStopEventTokens.contains(prior) { return "poststop" }
        return "none"
    }

    nonisolated static let wait = "waiting-on-user", resume = "work-continues", bgKeep = "background-task-running",
               midTurn = "main-turn-in-flight"

    /// (prior token) × (event) × (background task running), 8 × 4 × 2 = 64
    /// rows — the frozen B-2 rules, written out (never computed). S11 added
    /// the `SessionEnd` prior (POST-STOP, rows E1–E8). Hook v5 changed the
    /// four POST-STOP `idle_prompt` + no-task rows (S7, E7, A7, P7) from
    /// clear to SPARE: a Notification carries no `background_tasks`, so it
    /// can never prove the background work that kept the marker has ended.
    nonisolated static let phaseRows: [PhaseRow] = {
        let was = "waiting-after-stop"
        typealias E = PhaseEvent
        func rows(_ prefix: String, _ prior: String?, _ cells: [(E, Bool, String?, PhaseVerdict)]) -> [PhaseRow] {
            cells.enumerated().map { index, cell in
                PhaseRow(id: "\(prefix)\(index + 1)", prior: prior, event: cell.0, bg: cell.1,
                         result: cell.2, verdict: cell.3)
            }
        }
        var all: [PhaseRow] = []
        // Phase none: no marker.
        all += rows("N", nil, [
            (.subagentStop, false, nil, .ignore),
            (.subagentStop, true, "SubagentStop", .keep(bgKeep)),
            (.permissionPrompt, false, "waiting", .keep(wait)),
            (.permissionPrompt, true, "waiting", .keep(wait)),
            (.quotaAutoResumeFired, false, "Notification", .keep(resume)),
            (.quotaAutoResumeFired, true, "Notification", .keep(resume)),
            (.idlePrompt, false, nil, .clear),
            (.idlePrompt, true, "Stop", .keep(bgKeep)),
        ])
        // Phase IN-FLIGHT.
        all += rows("U", "UserPromptSubmit", [
            (.subagentStop, false, "Notification", .keep(midTurn)),
            (.subagentStop, true, "Notification", .keep(midTurn)),
            (.permissionPrompt, false, "waiting", .keep(wait)),
            (.permissionPrompt, true, "waiting", .keep(wait)),
            (.quotaAutoResumeFired, false, "Notification", .keep(resume)),
            (.quotaAutoResumeFired, true, "Notification", .keep(resume)),
            (.idlePrompt, false, nil, .clear),
            (.idlePrompt, true, "Notification", .keep(bgKeep)),
        ])
        all += rows("K", "Notification", [
            (.subagentStop, false, "Notification", .keep(midTurn)),
            (.subagentStop, true, "Notification", .keep(midTurn)),
            (.permissionPrompt, false, "waiting", .keep(wait)),
            (.permissionPrompt, true, "waiting", .keep(wait)),
            (.quotaAutoResumeFired, false, "Notification", .keep(resume)),
            (.quotaAutoResumeFired, true, "Notification", .keep(resume)),
            (.idlePrompt, false, nil, .clear),
            (.idlePrompt, true, "Notification", .keep(bgKeep)),
        ])
        all += rows("W", "waiting", [
            (.subagentStop, false, "Notification", .keep(midTurn)),
            (.subagentStop, true, "Notification", .keep(midTurn)),
            (.permissionPrompt, false, "waiting", .keep(wait)),
            (.permissionPrompt, true, "waiting", .keep(wait)),
            (.quotaAutoResumeFired, false, "Notification", .keep(resume)),
            (.quotaAutoResumeFired, true, "Notification", .keep(resume)),
            (.idlePrompt, false, nil, .clear),
            (.idlePrompt, true, "Notification", .keep(bgKeep)),
        ])
        // Phase POST-STOP.
        all += rows("S", "Stop", [
            (.subagentStop, false, nil, .clear),
            (.subagentStop, true, "SubagentStop", .keep(bgKeep)),
            (.permissionPrompt, false, was, .keep(wait)),
            (.permissionPrompt, true, was, .keep(wait)),
            (.quotaAutoResumeFired, false, "Stop", .keep(resume)),
            (.quotaAutoResumeFired, true, "Stop", .keep(resume)),
            (.idlePrompt, false, "Stop", .spare),
            (.idlePrompt, true, "Stop", .keep(bgKeep)),
        ])
        // S11: a SessionEnd marker exists only while background work outlived
        // the session — POST-STOP, so the last subagent ending CLEARS it.
        all += rows("E", "SessionEnd", [
            (.subagentStop, false, nil, .clear),
            (.subagentStop, true, "SubagentStop", .keep(bgKeep)),
            (.permissionPrompt, false, was, .keep(wait)),
            (.permissionPrompt, true, was, .keep(wait)),
            (.quotaAutoResumeFired, false, "Stop", .keep(resume)),
            (.quotaAutoResumeFired, true, "Stop", .keep(resume)),
            (.idlePrompt, false, "SessionEnd", .spare),
            (.idlePrompt, true, "Stop", .keep(bgKeep)),
        ])
        all += rows("A", "SubagentStop", [
            (.subagentStop, false, nil, .clear),
            (.subagentStop, true, "SubagentStop", .keep(bgKeep)),
            (.permissionPrompt, false, was, .keep(wait)),
            (.permissionPrompt, true, was, .keep(wait)),
            (.quotaAutoResumeFired, false, "Stop", .keep(resume)),
            (.quotaAutoResumeFired, true, "Stop", .keep(resume)),
            (.idlePrompt, false, "SubagentStop", .spare),
            (.idlePrompt, true, "Stop", .keep(bgKeep)),
        ])
        all += rows("P", was, [
            (.subagentStop, false, nil, .clear),
            (.subagentStop, true, "SubagentStop", .keep(bgKeep)),
            (.permissionPrompt, false, was, .keep(wait)),
            (.permissionPrompt, true, was, .keep(wait)),
            (.quotaAutoResumeFired, false, "Stop", .keep(resume)),
            (.quotaAutoResumeFired, true, "Stop", .keep(resume)),
            (.idlePrompt, false, was, .spare),
            (.idlePrompt, true, "Stop", .keep(bgKeep)),
        ])
        return all
    }()

    @Test func phaseRowsCoverTheWholeGrid() {
        #expect(Self.phaseRows.count == 64, "vacuity guard — 8 priors × 4 events × 2 bg states")
        #expect(Set(Self.phaseRows.map(\.id)).count == 64)
        let priors = Set(Self.phaseRows.map { $0.prior ?? "absent" })
        #expect(priors == ["absent", "UserPromptSubmit", "Notification", "waiting", "Stop", "SessionEnd",
                           "SubagentStop", "waiting-after-stop"], "the grid's eight prior states")
        // Every listed phase token is a prior in the grid (except StopFailure,
        // which `stopFailureAndSessionEndArePostStop` pins).
        let listed = Set(ClaudeBusyConstants.inFlightEventTokens + ClaudeBusyConstants.postStopEventTokens)
        #expect(listed.subtracting(priors) == ["StopFailure"])
    }

    /// `StopFailure` is POST-STOP like `Stop`, and — S11 — so is `SessionEnd`
    /// (written only when background work outlives the session): before
    /// S11 it was unlisted, read as phase "none", and the last subagent
    /// ending left a stuck "running" marker behind. Now SubagentStop(bg=no)
    /// after SessionEnd CLEARS it.
    @Test func stopFailureAndSessionEndArePostStop() {
        withHome { home in
            let session = "b2f00004-0060-4abc-8def-000000000060"
            let marker = markerDir(home).appendingPathComponent(session)
            for prior in ["StopFailure", "SessionEnd"] {
                plantMarker(prior, at: marker)
                _ = runHook(json: eventJSON("SubagentStop", session, backgroundTasks: Self.doneTask), home: home)
                #expect(waitForFile(marker, present: false), "a post-\(prior) SubagentStop(bg=no) clears")
                #expect(hookLog(home).hasSuffix(" clear session=\(session) event=SubagentStop phase=poststop\n"),
                        "\(prior): \(String(reflecting: hookLog(home)))")
            }
        }
    }

    /// End to end: Stop with a running background task, then the session
    /// ends while it still runs (marker rewritten as `SessionEnd`), then the
    /// last subagent finishes ⇒ CLEARED, not a no-op.
    @Test func sessionEndWithBackgroundWorkThenTheLastSubagentClears() {
        withHome { home in
            let session = "b2f00005-0061-4abc-8def-000000000061"
            primeMarker(session, home: home)
            let marker = markerDir(home).appendingPathComponent(session)
            _ = runHook(json: eventJSON("Stop", session, backgroundTasks: Self.runningTask), home: home)
            #expect(waitForMarkerEvent(marker, event: "Stop").contains("event=Stop "))
            _ = runHook(json: eventJSON("SessionEnd", session, backgroundTasks: Self.runningTask), home: home)
            #expect(waitForMarkerEvent(marker, event: "SessionEnd").contains("event=SessionEnd "))
            _ = runHook(json: eventJSON("SubagentStop", session, backgroundTasks: Self.doneTask), home: home)
            #expect(waitForFile(marker, present: false), "the last subagent ending after SessionEnd CLEARS")
            #expect(hookLog(home).hasSuffix(" clear session=\(session) event=SubagentStop phase=poststop\n"))
        }
    }

    /// The marker line planted as the prior state: a distinctive `pid` /
    /// `src` so a rewrite by the hook (`src=unknown`) is told apart from it.
    private func plantMarker(_ token: String, at url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let now = Int(Date().timeIntervalSince1970)
        try? "v1 ts=\(now) event=\(token) pid=999999 src=planted\n".write(to: url, atomically: true, encoding: .utf8)
    }

    /// Polls until the marker holds a hook-written (`src=unknown`, hook v7
    /// `ep=` last) line with `event=<token>`; returns the last content seen.
    private func waitForRewrite(_ url: URL, event token: String, timeout: Double = 3) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let c = try? String(contentsOf: url, encoding: .utf8),
               c.contains("event=\(token) "),
               c.range(of: " src=unknown ep=[0-9]+\n$", options: .regularExpression) != nil { return c }
            Thread.sleep(forTimeInterval: 0.03)
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func phaseEventJSON(_ event: PhaseEvent, _ session: String, bg: Bool) -> String {
        let tasks = bg ? Self.runningTask : #"[{"id":"a","type":"subagent","status":"completed"}]"#
        switch event {
        case .subagentStop: return eventJSON("SubagentStop", session, backgroundTasks: tasks)
        default: return notificationJSON(session, notificationType: quoted(event.rawValue), backgroundTasks: tasks)
        }
    }

    @Test(arguments: phaseRows)
    func phaseAwareReconcileTable(_ row: PhaseRow) {
        withHome { home in
            let session = "b2000001-0041-4abc-8def-000000000041"
            let marker = markerDir(home).appendingPathComponent(session)
            if let prior = row.prior { plantMarker(prior, at: marker) }
            let planted = FileManager.default.contents(atPath: marker.path)
            let result = runHook(json: phaseEventJSON(row.event, session, bg: row.bg), home: home)
            #expect(result.exitCode == 0)
            #expect(result.stdout.isEmpty)

            if row.verdict == .spare {
                #expect(planted != nil && row.result == row.prior, "row setup: a spared marker must exist")
                Thread.sleep(forTimeInterval: 0.15)
                #expect(FileManager.default.contents(atPath: marker.path) == planted,
                        "the post-Stop marker must be left byte-identical (no rewrite, no clear)")
            } else if let expected = row.result {
                let contents = waitForRewrite(marker, event: expected)
                let pattern = "^v1 ts=[0-9]+ event=\(expected) pid=[0-9]+ src=unknown ep=[1-9][0-9]*\n$"
                #expect(contents.range(of: pattern, options: .regularExpression) != nil,
                        "marker \(String(reflecting: contents)) must be rewritten as event=\(expected)")
                #expect(ClaudeActivityPolicy.parseMarker(contents)?.event == expected, "the Swift reader parses it")
            } else {
                #expect(waitForFile(marker, present: false), "no marker may remain")
                Thread.sleep(forTimeInterval: 0.1)
                #expect(!FileManager.default.fileExists(atPath: marker.path), "and none appears later")
            }

            let phase = Self.phase(of: row.prior)
            let name = row.event == .subagentStop ? "SubagentStop" : "Notification"
            let type = row.event == .subagentStop ? "" : " type=\(row.event.rawValue)"
            let log = hookLog(home)
            switch row.verdict {
            case .keep(let reason):
                #expect(log.contains("keep session=\(session) event=\(name)\(type) phase=\(phase) reason=\(reason) pid="),
                        "log \(String(reflecting: log))")
            case .clear:
                #expect(log.hasSuffix(" clear session=\(session) event=\(name)\(type) phase=\(phase)\n"),
                        "log \(String(reflecting: log))")
            case .ignore:
                #expect(log.hasSuffix(" ignore reason=no-marker event=SubagentStop phase=none\n"),
                        "log \(String(reflecting: log))")
            case .spare:
                #expect(log.contains(
                    " ignore reason=poststop-clear-notification session=\(session) type=\(row.event.rawValue) pid="),
                        "log \(String(reflecting: log))")
                #expect(log.hasSuffix(" src=unknown\n"), "log \(String(reflecting: log))")
            }
            #expect(log.split(separator: "\n").count == 1, "exactly one log line per run")
        }
    }

    // MARK: B-2 canonical scenarios (sequences through the shipped script)

    private static let doneTask = #"[{"id":"a","type":"subagent","status":"completed"}]"#

    /// (a) A foreground subagent finishing mid-turn never clears the running
    /// turn: UPS → SubagentStop(bg=no) ⇒ the marker is KEPT as Notification.
    @Test func scenarioA_foregroundSubagentStopMidTurnKeepsTheMarker() {
        withHome { home in
            let session = "b2a00001-0051-4abc-8def-000000000051"
            primeMarker(session, home: home)
            let marker = markerDir(home).appendingPathComponent(session)
            _ = runHook(json: eventJSON("SubagentStop", session, backgroundTasks: Self.doneTask), home: home)
            let contents = waitForMarkerEvent(marker, event: "Notification")
            #expect(contents.contains("event=Notification "), "kept, got \(String(reflecting: contents))")
            #expect(hookLog(home).contains("keep session=\(session) event=SubagentStop phase=inflight reason=main-turn-in-flight pid="))
        }
    }

    /// (b) UPS → waiting → SubagentStop(bg=no) ⇒ `Notification`: the waiting
    /// episode ends, so a later wait in the SAME turn notifies again (the
    /// policy fed the hook's own tokens buzzes twice).
    @Test func scenarioB_subagentStopEndsTheWaitingEpisodeSoALaterWaitBuzzesAgain() {
        withHome { home in
            let session = "b2b00001-0052-4abc-8def-000000000052"
            primeMarker(session, home: home)
            let marker = markerDir(home).appendingPathComponent(session)
            let steps: [(json: String, token: String)] = [
                (notificationJSON(session, notificationType: quoted("permission_prompt")), "waiting"),
                (eventJSON("SubagentStop", session, backgroundTasks: Self.doneTask), "Notification"),
                (notificationJSON(session, notificationType: quoted("permission_prompt")), "waiting"),
            ]
            var tokens: [String] = []
            for step in steps {
                _ = runHook(json: step.json, home: home)
                let contents = waitForMarkerEvent(marker, event: step.token)
                tokens.append(ClaudeActivityPolicy.parseMarker(contents)?.event ?? "?")
            }
            #expect(tokens == ["waiting", "Notification", "waiting"])

            // Those exact tokens through the app policy: two separate buzzes.
            let t = 1_800_000_000
            var tracked = FinishAlertPolicy.baseline(current: [], now: t)
            var buzzes = 0
            for (index, token) in ([ClaudeBusyConstants.setEvent] + tokens).enumerated() {
                let ts = t + index * 120
                let observation = FinishAlertPolicy.observe(
                    previous: tracked,
                    current: [IdentifiedBusyMarker(sessionID: session,
                                                   marker: BusyMarker(ts: ts, event: token, pid: 1, src: "unknown"))],
                    now: ts + 1)
                buzzes += observation.events.filter { if case .waiting = $0 { return true } else { return false } }.count
                tracked = observation.tracked
            }
            #expect(buzzes == 2, "the second wait of the turn buzzes again")
        }
    }

    /// (c) Stop(bg=yes) → permission_prompt ⇒ `waiting-after-stop`; then the
    /// background subagent ends — SubagentStop(bg=no) ⇒ CLEARED.
    @Test func scenarioC_waitAfterStopThenTheLastSubagentEndsClears() {
        withHome { home in
            let session = "b2c00001-0053-4abc-8def-000000000053"
            primeMarker(session, home: home)
            let marker = markerDir(home).appendingPathComponent(session)
            _ = runHook(json: eventJSON("Stop", session, backgroundTasks: Self.runningTask), home: home)
            #expect(waitForMarkerEvent(marker, event: "Stop").contains("event=Stop "))
            _ = runHook(json: notificationJSON(session, notificationType: quoted("permission_prompt")), home: home)
            let afterStop = ClaudeBusyConstants.waitingAfterStopEventToken
            #expect(waitForMarkerEvent(marker, event: afterStop).contains("event=\(afterStop) "))
            #expect(hookLog(home).contains("type=permission_prompt phase=poststop reason=waiting-on-user"))
            _ = runHook(json: eventJSON("SubagentStop", session, backgroundTasks: Self.doneTask), home: home)
            #expect(waitForFile(marker, present: false), "the last subagent ending after Stop CLEARS")
            #expect(hookLog(home).hasSuffix(" clear session=\(session) event=SubagentStop phase=poststop\n"))
        }
    }

    /// (d) B3 unchanged after Stop: Stop(bg=yes) → SubagentStop(bg=yes) keeps,
    /// SubagentStop(bg=no) clears.
    @Test func scenarioD_postStopSubagentStopsAreB3Unchanged() {
        withHome { home in
            let session = "b2d00001-0054-4abc-8def-000000000054"
            primeMarker(session, home: home)
            let marker = markerDir(home).appendingPathComponent(session)
            _ = runHook(json: eventJSON("Stop", session, backgroundTasks: Self.runningTask), home: home)
            #expect(waitForMarkerEvent(marker, event: "Stop").contains("event=Stop "))
            _ = runHook(json: eventJSON("SubagentStop", session, backgroundTasks: Self.runningTask), home: home)
            #expect(waitForMarkerEvent(marker, event: "SubagentStop").contains("event=SubagentStop "))
            _ = runHook(json: eventJSON("SubagentStop", session, backgroundTasks: Self.doneTask), home: home)
            #expect(waitForFile(marker, present: false), "the last subagent ending CLEARS")
        }
    }

    /// (e) No marker: SubagentStop(bg=no) creates nothing and logs why.
    @Test func scenarioE_subagentStopWithoutAMarkerCreatesNothing() {
        withHome { home in
            let session = "b2e00001-0055-4abc-8def-000000000055"
            let result = runHook(json: eventJSON("SubagentStop", session, backgroundTasks: Self.doneTask), home: home)
            #expect(result.exitCode == 0 && result.stdout.isEmpty)
            Thread.sleep(forTimeInterval: 0.15)
            #expect(sessionShapedFiles(in: markerDir(home)).isEmpty, "nothing is created")
            #expect(hookLog(home).hasSuffix(" ignore reason=no-marker event=SubagentStop phase=none\n"))
        }
    }

    /// (f) Hook v5 — the live bug: Stop(bg=yes) keeps the marker, then an
    /// `idle_prompt` Notification arrives while the background subagent still
    /// works. A Notification payload carries NO `background_tasks`, so it must
    /// not clear the post-Stop marker — neither as `Stop` nor as
    /// `waiting-after-stop`. Only the last SubagentStop(bg=no) clears it.
    @Test func scenarioF_postStopIdleNotificationNeverClearsTheMarker() {
        withHome { home in
            let session = "b2f00006-0062-4abc-8def-000000000062"
            primeMarker(session, home: home)
            let marker = markerDir(home).appendingPathComponent(session)
            _ = runHook(json: eventJSON("Stop", session, backgroundTasks: Self.runningTask), home: home)
            #expect(waitForMarkerEvent(marker, event: "Stop").contains("event=Stop "))

            for token in ["Stop", ClaudeBusyConstants.waitingAfterStopEventToken] {
                if token != "Stop" {
                    _ = runHook(json: notificationJSON(session, notificationType: quoted("permission_prompt")), home: home)
                    #expect(waitForMarkerEvent(marker, event: token).contains("event=\(token) "))
                }
                let before = FileManager.default.contents(atPath: marker.path)
                let result = runHook(json: notificationJSON(session, notificationType: quoted("idle_prompt")), home: home)
                #expect(result.exitCode == 0 && result.stdout.isEmpty)
                Thread.sleep(forTimeInterval: 0.15)
                #expect(before != nil && FileManager.default.contents(atPath: marker.path) == before,
                        "\(token): an idle Notification after Stop leaves the marker untouched")
                let lastLine = hookLog(home).split(separator: "\n").last.map(String.init) ?? ""
                #expect(lastLine.contains(
                    " ignore reason=poststop-clear-notification session=\(session) type=idle_prompt pid=")
                        && lastLine.hasSuffix(" src=unknown"), "\(token): \(String(reflecting: lastLine))")
            }

            _ = runHook(json: eventJSON("SubagentStop", session, backgroundTasks: Self.doneTask), home: home)
            #expect(waitForFile(marker, present: false), "the last subagent ending still CLEARS")
            #expect(hookLog(home).hasSuffix(" clear session=\(session) event=SubagentStop phase=poststop\n"))
        }
    }

    /// Canary: neuter the hook v5 guard and scenario (f) breaks — the idle
    /// Notification after Stop falls through to the clear (the live bug).
    @Test func postStopNotificationGuardCanary() throws {
        let original = try Self.read(Self.hookScriptURL)
        let mutant = original.replacingOccurrences(
            of: #"elif [ "$event" = Notification ] && [ "$phase" = poststop ]; then"#,
            with: "elif false; then")
        #expect(mutant != original, "canary setup: the post-Stop Notification guard must exist to be neutered")
        withHome { home in
            let session = "b2f00007-0063-4abc-8def-000000000063"
            let mutantURL = home.appendingPathComponent("mutant-busy-hook.sh")
            try? mutant.write(to: mutantURL, atomically: true, encoding: .utf8)
            let marker = markerDir(home).appendingPathComponent(session)
            plantMarker("Stop", at: marker)
            _ = runScript(mutantURL, json: notificationJSON(session, notificationType: quoted("idle_prompt")), home: home)
            #expect(waitForFile(marker, present: false),
                    "without the guard the post-Stop marker is CLEARED (so scenario (f) has teeth)")
        }
    }

    /// Canary: drop `waiting-after-stop` from the shell's POST-STOP pattern and
    /// scenario (c) breaks — the post-Stop wait reads as phase "none", so the
    /// last subagent ending leaves the marker standing (a stuck "running").
    @Test func phaseListCanaryBreaksScenarioC() throws {
        let original = try Self.read(Self.hookScriptURL)
        let mutant = original.replacingOccurrences(of: "SubagentStop|waiting-after-stop)", with: "SubagentStop)")
        #expect(mutant != original, "canary setup: the post-Stop pattern must exist")
        withHome { home in
            let session = "b2c00002-0056-4abc-8def-000000000056"
            let mutantURL = home.appendingPathComponent("mutant-busy-hook.sh")
            try? mutant.write(to: mutantURL, atomically: true, encoding: .utf8)
            let marker = markerDir(home).appendingPathComponent(session)
            plantMarker(ClaudeBusyConstants.waitingAfterStopEventToken, at: marker)
            _ = runScript(mutantURL, json: eventJSON("SubagentStop", session, backgroundTasks: Self.doneTask), home: home)
            Thread.sleep(forTimeInterval: 0.15)
            #expect(FileManager.default.fileExists(atPath: marker.path),
                    "without the token in the list the marker is NOT cleared (so scenario (c) has teeth)")
            #expect(hookLog(home).contains("phase=none"))
        }
    }

    // MARK: B-2: the phase probe never trusts the marker

    /// A marker the hook did not write — garbage, an oversized or forged
    /// token, a NUL- or CR-spliced token, a wrong version — reads as phase
    /// "none": the probe never echoes it, and SubagentStop(bg=no) leaves it
    /// alone (no clear, no rewrite).
    @Test func unparseableMarkersReadAsPhaseNone() {
        let cases: [(name: String, bytes: [UInt8])] = [
            ("garbage", Array("not a marker\n".utf8)),
            ("wrong version", Array("v2 ts=1 event=Stop pid=1 src=x\n".utf8)),
            ("missing ts", Array("v1 event=Stop pid=1 src=x\n".utf8)),
            ("33-char token", Array("v1 ts=1 event=\(String(repeating: "S", count: 33)) pid=1 src=x\n".utf8)),
            ("digit in token", Array("v1 ts=1 event=Stop2 pid=1 src=x\n".utf8)),
            ("NUL-spliced token", Array("v1 ts=1 event=Sto".utf8) + [0] + Array("p pid=1 src=x\n".utf8)),
            ("CR in token", Array("v1 ts=1 event=Stop\r pid=1 src=x\n".utf8)),
            ("token on line two", Array("v1 ts=1\nevent=Stop pid=1 src=x\n".utf8)),
            ("empty", []),
        ]
        for (name, bytes) in cases {
            withHome { home in
                let session = "b2f00001-0057-4abc-8def-000000000057"
                let marker = markerDir(home).appendingPathComponent(session)
                try? FileManager.default.createDirectory(at: markerDir(home), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: marker.path, contents: Data(bytes))
                let result = runHook(json: eventJSON("SubagentStop", session, backgroundTasks: Self.doneTask), home: home)
                #expect(result.exitCode == 0 && result.stdout.isEmpty, "\(name)")
                Thread.sleep(forTimeInterval: 0.1)
                #expect(FileManager.default.contents(atPath: marker.path) == Data(bytes), "\(name): left untouched")
                #expect(hookLog(home).hasSuffix(" ignore reason=no-marker event=SubagentStop phase=none\n"),
                        "\(name): \(String(reflecting: hookLog(home)))")
            }
        }
    }

    /// A marker longer than the 256-byte read whose token sits past it reads
    /// as "none"; one whose token sits inside it is still read.
    @Test func thePhaseProbeReadsOnlyTheFirst256Bytes() {
        withHome { home in
            let session = "b2f00002-0058-4abc-8def-000000000058"
            let marker = markerDir(home).appendingPathComponent(session)
            try? FileManager.default.createDirectory(at: markerDir(home), withIntermediateDirectories: true)
            let pad = String(repeating: "0", count: 300)
            try? "v1 ts=\(pad) event=Stop pid=1 src=x\n".write(to: marker, atomically: true, encoding: .utf8)
            _ = runHook(json: eventJSON("SubagentStop", session, backgroundTasks: Self.doneTask), home: home)
            #expect(hookLog(home).hasSuffix(" ignore reason=no-marker event=SubagentStop phase=none\n"))

            try? "v1 ts=1 event=Stop pid=1 src=\(pad)\n".write(to: marker, atomically: true, encoding: .utf8)
            _ = runHook(json: eventJSON("SubagentStop", session, backgroundTasks: Self.doneTask), home: home)
            #expect(waitForFile(marker, present: false), "a token inside the first 256 bytes is read (post-Stop ⇒ clear)")
        }
    }

    /// UX safety: a FIFO planted under the marker's name must never block the
    /// hook (opening a FIFO for reading waits for a writer). The probe reads
    /// regular files only, so the run returns at once with phase "none".
    @Test func aFifoAtTheMarkerPathNeverBlocksTheHook() {
        withHome { home in
            let session = "b2f00003-0059-4abc-8def-000000000059"
            let marker = markerDir(home).appendingPathComponent(session)
            try? FileManager.default.createDirectory(at: markerDir(home), withIntermediateDirectories: true)
            #expect(mkfifo(marker.path, 0o600) == 0, "setup: FIFO created")
            // Belt and braces: if a regression ever blocks on the FIFO, open
            // it for writing (non-blocking) so the reader gets EOF and the
            // test fails instead of hanging.
            let unblocker = DispatchWorkItem {
                let fd = open(marker.path, O_WRONLY | O_NONBLOCK)
                if fd >= 0 { close(fd) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: unblocker)
            let started = Date()
            let result = runHook(json: eventJSON("SubagentStop", session, backgroundTasks: Self.doneTask), home: home)
            let elapsed = Date().timeIntervalSince(started)
            unblocker.cancel()
            #expect(result.exitCode == 0)
            #expect(elapsed < 3, "the hook must return at once, took \(elapsed) s")
            #expect(hookLog(home).hasSuffix(" ignore reason=no-marker event=SubagentStop phase=none\n"))
        }
    }

    // MARK: - Hook v7: the episode-start field (`ep=`), through the shipped script

    /// Plants `bytes` as the marker at `url` (the prior state of a run).
    private func plantBytes(_ bytes: [UInt8], at url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
    }

    /// A planted v7-shaped marker line: `src=planted`, so a hook rewrite
    /// (`src=unknown`) is told apart from it.
    private func plantedLine(_ token: String, ts: Int, ep: String) -> [UInt8] {
        Array("v1 ts=\(ts) event=\(token) pid=999999 src=planted ep=\(ep)\n".utf8)
    }

    /// Every in-episode rewrite — waiting, a mid-turn SubagentStop, a kept
    /// Stop, waiting after Stop, a resume, a post-Stop SubagentStop keep, and
    /// a UserPromptSubmit while the marker persists — carries the episode
    /// start over unchanged; only `ts` (and the token) move. The Swift reader
    /// sees the same value at every step.
    @Test func inEpisodeRewritesCarryTheEpisodeStartOver() {
        withHome { home in
            let session = "e7000001-0071-4abc-8def-000000000071"
            let marker = markerDir(home).appendingPathComponent(session)
            let start = Int(Date().timeIntervalSince1970) - 600
            plantBytes(plantedLine("UserPromptSubmit", ts: start, ep: String(start)), at: marker)
            let steps: [(json: String, token: String)] = [
                (notificationJSON(session, notificationType: quoted("permission_prompt")), "waiting"),
                (eventJSON("SubagentStop", session, backgroundTasks: Self.doneTask), "Notification"),
                (eventJSON("Stop", session, backgroundTasks: Self.runningTask), "Stop"),
                (notificationJSON(session, notificationType: quoted("permission_prompt")),
                 ClaudeBusyConstants.waitingAfterStopEventToken),
                (notificationJSON(session, notificationType: quoted("quota_auto_resume_fired")), "Stop"),
                (eventJSON("SubagentStop", session, backgroundTasks: Self.runningTask), "SubagentStop"),
                (promptJSON(session), "UserPromptSubmit"),
            ]
            for step in steps {
                #expect(runHook(json: step.json, home: home).exitCode == 0)
                let contents = waitForRewrite(marker, event: step.token)
                let parsed = ClaudeActivityPolicy.parseMarker(contents)
                #expect(parsed?.event == step.token, "\(step.token): rewritten, got \(String(reflecting: contents))")
                #expect(parsed?.ep == String(start), "\(step.token): the episode start is carried over")
                #expect((parsed?.ts ?? 0) > start, "\(step.token): only ts moves")
                #expect(contents.utf8.count < 256, "a marker line stays far below every read cap")
            }
        }
    }

    /// A prior marker WITHOUT a usable episode start — a v6 line, an empty,
    /// non-digit, zero, leading-zero, signed or over-long value, a seventh
    /// field, the value on line two, a missing field, a NUL inside it — never
    /// lends its value: the rewrite anchors a FRESH episode at its own ts.
    @Test func anUnusableEpisodeStartIsReplacedByAFreshAnchor() {
        let old = Int(Date().timeIntervalSince1970) - 600
        let head = "v1 ts=\(old) event=UserPromptSubmit pid=999999 src=planted"
        let cases: [(name: String, bytes: [UInt8])] = [
            ("v6 marker without ep", Array("\(head)\n".utf8)),
            ("empty ep", Array("\(head) ep=\n".utf8)),
            ("letters", Array("\(head) ep=abc\n".utf8)),
            ("zero", Array("\(head) ep=0\n".utf8)),
            ("leading zero", Array("\(head) ep=0123456789\n".utf8)),
            ("eleven digits", Array("\(head) ep=12345678901\n".utf8)),
            ("signed", Array("\(head) ep=-\(old)\n".utf8)),
            ("a seventh field", Array("\(head) ep=\(old) extra=1\n".utf8)),
            ("ep on line two", Array("\(head)\nep=\(old)\n".utf8)),
            ("missing pid", Array("v1 ts=\(old) event=UserPromptSubmit src=planted ep=\(old)\n".utf8)),
            ("NUL inside ep", Array("\(head) ep=17".utf8) + [0] + Array("00000000\n".utf8)),
        ]
        for (name, bytes) in cases {
            withHome { home in
                let session = "e7000002-0072-4abc-8def-000000000072"
                let marker = markerDir(home).appendingPathComponent(session)
                plantBytes(bytes, at: marker)
                let json = notificationJSON(session, notificationType: quoted("permission_prompt"))
                #expect(runHook(json: json, home: home).exitCode == 0, "\(name)")
                let contents = waitForRewrite(marker, event: ClaudeBusyConstants.waitingEventToken)
                let parsed = ClaudeActivityPolicy.parseMarker(contents)
                #expect(parsed != nil, "\(name): rewritten, got \(String(reflecting: contents))")
                #expect(parsed?.ep == parsed.map { String($0.ts) }, "\(name): a fresh anchor at the write's ts")
                #expect(parsed?.ep != String(old), "\(name): the unusable value is never carried over")
            }
        }
    }

    /// An episode ends when its marker is cleared; the next UserPromptSubmit
    /// starts a NEW one, anchored at its own ts — never the old start.
    @Test func aNewEpisodeAfterAClearAnchorsAfresh() {
        withHome { home in
            let session = "e7000003-0073-4abc-8def-000000000073"
            let marker = markerDir(home).appendingPathComponent(session)
            let start = Int(Date().timeIntervalSince1970) - 600
            plantBytes(plantedLine("UserPromptSubmit", ts: start, ep: String(start)), at: marker)
            _ = runHook(json: eventJSON("Stop", session, backgroundTasks: Self.doneTask), home: home)
            #expect(waitForFile(marker, present: false), "setup: Stop with nothing running clears")
            _ = runHook(json: promptJSON(session), home: home)
            let parsed = ClaudeActivityPolicy.parseMarker(waitForRewrite(marker, event: "UserPromptSubmit"))
            #expect(parsed?.ep == parsed.map { String($0.ts) }, "the new episode is anchored at its own ts")
            #expect(parsed?.ep != String(start))
        }
    }

    /// UX safety on the new read: a FIFO planted under the marker's name never
    /// blocks the backgrounded write (the probe reads regular files only); the
    /// write replaces it with a fresh-episode marker and the hook returns at once.
    @Test func aFifoAtTheMarkerPathNeverBlocksTheEpisodeRead() {
        withHome { home in
            let session = "e7000004-0074-4abc-8def-000000000074"
            let marker = markerDir(home).appendingPathComponent(session)
            try? FileManager.default.createDirectory(at: markerDir(home), withIntermediateDirectories: true)
            #expect(mkfifo(marker.path, 0o600) == 0, "setup: FIFO created")
            let unblocker = DispatchWorkItem {
                let fd = open(marker.path, O_WRONLY | O_NONBLOCK)
                if fd >= 0 { close(fd) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: unblocker)
            let started = Date()
            let result = runHook(json: promptJSON(session), home: home)
            #expect(result.exitCode == 0)
            #expect(Date().timeIntervalSince(started) < 3, "the hook must return at once")
            let contents = waitForRewrite(marker, event: "UserPromptSubmit")
            let elapsed = Date().timeIntervalSince(started)
            unblocker.cancel()
            let parsed = ClaudeActivityPolicy.parseMarker(contents)
            #expect(parsed?.ep == parsed.map { String($0.ts) }, "a fresh anchor, got \(String(reflecting: contents))")
            #expect(elapsed < 3, "the backgrounded write must not wait on the FIFO, took \(elapsed) s")
        }
    }

    /// Canary: make the writer ignore the current marker and the carry-over
    /// test breaks — the waiting rewrite re-anchors at its own ts.
    @Test func episodeCarryOverCanary() throws {
        let original = try Self.read(Self.hookScriptURL)
        let mutant = original.replacingOccurrences(of: #"ep=$(marker_episode "$1")"#, with: #"ep="""#)
        #expect(mutant != original, "canary setup: the carry-over read must exist to be removed")
        withHome { home in
            let session = "e7000005-0075-4abc-8def-000000000075"
            let mutantURL = home.appendingPathComponent("mutant-busy-hook.sh")
            try? mutant.write(to: mutantURL, atomically: true, encoding: .utf8)
            let marker = markerDir(home).appendingPathComponent(session)
            let start = Int(Date().timeIntervalSince1970) - 600
            plantBytes(plantedLine("UserPromptSubmit", ts: start, ep: String(start)), at: marker)
            _ = runScript(mutantURL, json: notificationJSON(session, notificationType: quoted("permission_prompt")),
                          home: home)
            let parsed = ClaudeActivityPolicy.parseMarker(waitForRewrite(marker, event: "waiting"))
            #expect(parsed != nil && parsed?.ep != String(start),
                    "without the carry-over read the episode start is lost (so the carry-over test has teeth)")
        }
    }

    // MARK: - Hook v8: the final-message check (silent — one closed word in hook.log)

    /// `text` as a JSON string literal, the way a payload carries it
    /// (JSONSerialization escapes it; non-ASCII stays UTF-8).
    nonisolated static func jsonString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8) else { return "null" }
        return String(array.dropFirst().dropLast())
    }

    /// A payload for `event` carrying `last_assistant_message` as the raw
    /// JSON literal `message` and `background_tasks` as raw JSON (nil omits
    /// a field), plus any `extra` raw fields.
    private func finalMessageJSON(_ event: String, _ session: String, message: String?,
                                  backgroundTasks: String?, extra: [String] = []) -> String {
        var fields = [#""hook_event_name":"\#(event)""#, #""session_id":"\#(session)""#] + extra
        if let backgroundTasks { fields.append(#""background_tasks":\#(backgroundTasks)"#) }
        if let message { fields.append(#""last_assistant_message":\#(message)"#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// hook.log's check lines.
    private func askCheckLines(_ home: URL) -> [String] {
        hookLog(home).split(separator: "\n").map(String.init).filter { $0.contains(" ask-check ") }
    }

    /// One whole check line, timestamp included: the log's own line style.
    private func isAskCheckLine(_ line: String, session: String, result: String) -> Bool {
        let pattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4} "
            + "ask-check session=\(session) result=\(result)$"
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    /// The checked path: a Stop with background work still running KEEPS the
    /// marker exactly as before (the same v1 grammar, the episode start
    /// carried over) and appends ONE check line right after its keep line.
    @Test func aStopKeptForBackgroundWorkLogsWhetherItsMessageAsks() {
        withHome { home in
            let session = "a8000001-0101-4abc-8def-000000000101"
            primeMarker(session, home: home)
            let marker = markerDir(home).appendingPathComponent(session)
            let primed = ClaudeActivityPolicy.parseMarker((try? String(contentsOf: marker, encoding: .utf8)) ?? "")
            let message = Self.jsonString("All three reviews are running.\n\nShall I merge the docs change now?")
            let result = runHook(json: finalMessageJSON("Stop", session, message: message,
                                                        backgroundTasks: Self.runningTask), home: home)
            #expect(result.exitCode == 0 && result.stdout.isEmpty)
            let contents = waitForMarkerEvent(marker, event: "Stop")
            let pattern = "^v1 ts=[0-9]+ event=Stop pid=[0-9]+ src=unknown ep=[1-9][0-9]*\n$"
            #expect(contents.range(of: pattern, options: .regularExpression) != nil,
                    "kept marker \(String(reflecting: contents)), in the unchanged grammar")
            #expect(primed?.ep != nil && ClaudeActivityPolicy.parseMarker(contents)?.ep == primed?.ep,
                    "the episode start is carried over, as before")
            let lines = hookLog(home).split(separator: "\n").map(String.init)
            #expect(lines.count == 3, "set, keep, check — got \(lines)")
            #expect(lines.count == 3
                        && lines[1].contains(" keep session=\(session) event=Stop reason=background-task-running pid=")
                        && lines[1].hasSuffix(" src=unknown"), "the keep line is unchanged: \(lines)")
            #expect(lines.count == 3 && isAskCheckLine(lines[2], session: session, result: "asks"), "\(lines)")
        }
    }

    /// The other words, and the escapes the stdin mapping rewrites: each run
    /// KEEPS the marker as before and logs exactly one check line — `no` for
    /// a string that does not ask (an empty one too), `absent` for no field
    /// or a JSON null, `unreadable` for a value that is not a string.
    @Test func theCheckHasOneWordForEveryShapeOfTheField() {
        let rows: [(message: String?, result: String)] = [
            (Self.jsonString("All three reviews are running; I will report back."), "no"),
            (Self.jsonString(""), "no"),
            (nil, "absent"),
            ("null", "absent"),
            ("42", "unreadable"),
            ("true", "unreadable"),
            (#"["Shall I merge it?"]"#, "unreadable"),
            (#"{"text":"Shall I merge it?"}"#, "unreadable"),
            // A NUL escape becomes `#` before the gate (hook v6): nothing is
            // spliced, and a `#` after the mark is not a closing character.
            (#""Ready to ship\u0000 it?""#, "asks"),
            (#""Ship it?\u0000""#, "no"),
            // A lone surrogate escape becomes U+FFFD before the gate.
            (#""Cut \ud83d here.\nShip it?""#, "asks"),
            (#""Ship it?\ud83d""#, "no"),
        ]
        for row in rows {
            withHome { home in
                let session = "a8000002-0102-4abc-8def-000000000102"
                primeMarker(session, home: home)
                let marker = markerDir(home).appendingPathComponent(session)
                let result = runHook(json: finalMessageJSON("Stop", session, message: row.message,
                                                            backgroundTasks: Self.runningTask), home: home)
                let label = row.message ?? "<no field>"
                #expect(result.exitCode == 0 && result.stdout.isEmpty, "\(label)")
                #expect(waitForMarkerEvent(marker, event: "Stop").contains("event=Stop "), "\(label): kept as before")
                let lines = hookLog(home).split(separator: "\n").map(String.init)
                #expect(lines.count == 3 && isAskCheckLine(lines[2], session: session, result: row.result),
                        "\(label) must log result=\(row.result), got \(lines)")
            }
        }
    }

    /// A payload the stdin gate refuses never reaches the check (invalid
    /// UTF-8 in the message; a message so long that the payload is cut at
    /// the 256 KiB cap): the event is ignored exactly as before, the marker
    /// is left byte-identical, and there is no check line. A message just
    /// under the cap is checked; the shell reads only its end.
    @Test func aPayloadTheGateRefusesIsIgnoredAsBeforeAndABigOneIsChecked() {
        let session = "a8000003-0103-4abc-8def-000000000103"
        func payload(_ message: Data) -> Data {
            var data = Data((#"{"hook_event_name":"Stop","session_id":"\#(session)","#
                + #""background_tasks":\#(Self.runningTask),"last_assistant_message":""#).utf8)
            data.append(message)
            data.append(Data(#""}"#.utf8))
            return data
        }
        let refused: [(name: String, bytes: Data)] = [
            ("invalid UTF-8", payload(Data("Shall I merge it".utf8) + Data([0xFF]) + Data("?".utf8))),
            ("cut at the cap", payload(Data((String(repeating: "y", count: 270_000) + "?").utf8))),
        ]
        for (name, bytes) in refused {
            withHome { home in
                primeMarker(session, home: home)
                let marker = markerDir(home).appendingPathComponent(session)
                let before = FileManager.default.contents(atPath: marker.path)
                let result = runScript(Self.hookScriptURL, bytes: bytes, home: home)
                #expect(result.exitCode == 0 && result.stdout.isEmpty, "\(name)")
                Thread.sleep(forTimeInterval: 0.15)
                #expect(before != nil && FileManager.default.contents(atPath: marker.path) == before,
                        "\(name): the marker is left as it was")
                let log = hookLog(home)
                #expect(log.hasSuffix(" ignore reason=stdin-not-json\n") && askCheckLines(home).isEmpty,
                        "\(name): \(String(reflecting: log))")
            }
        }
        withHome { home in
            let big = Self.jsonString(String(repeating: "y", count: 200_000) + "\nShall I continue?")
            let result = runHook(json: finalMessageJSON("Stop", session, message: big,
                                                        backgroundTasks: Self.runningTask), home: home)
            #expect(result.exitCode == 0 && result.stdout.isEmpty)
            let lines = askCheckLines(home)
            #expect(lines.count == 1 && isAskCheckLine(lines[0], session: session, result: "asks"), "\(lines)")
        }
    }

    /// What a run did to the marker.
    private enum MarkerOutcome { case rewritten(String), cleared, spared, absent }

    /// Only a Stop kept for background work is checked. The same asking
    /// message on every other path: each reconciles exactly as before, with
    /// its one usual log line, and no run writes a check line.
    @Test func onlyAStopKeptForBackgroundWorkIsChecked() {
        let session = "a8000004-0104-4abc-8def-000000000104"
        let asking = Self.jsonString("Shall I merge it?")
        let running = Self.runningTask, done = Self.doneTask
        func stopLike(_ event: String, _ tasks: String?) -> String {
            finalMessageJSON(event, session, message: asking, backgroundTasks: tasks)
        }
        func note(_ type: String, _ tasks: String?) -> String {
            finalMessageJSON("Notification", session, message: asking, backgroundTasks: tasks,
                             extra: [#""notification_type":"\#(type)""#])
        }
        let s = session
        let cases: [(name: String, prior: String?, json: String, outcome: MarkerOutcome, logged: String)] = [
            ("Stop, task finished", "UserPromptSubmit", stopLike("Stop", done), .cleared,
             " clear session=\(s) event=Stop"),
            ("Stop, no task", "UserPromptSubmit", stopLike("Stop", "[]"), .cleared, " clear session=\(s) event=Stop"),
            ("Stop, no task field", "UserPromptSubmit", stopLike("Stop", nil), .cleared,
             " clear session=\(s) event=Stop"),
            ("SubagentStop after Stop, task running", "Stop", stopLike("SubagentStop", running),
             .rewritten("SubagentStop"),
             " keep session=\(s) event=SubagentStop phase=poststop reason=background-task-running pid="),
            ("SubagentStop after Stop, last task", "Stop", stopLike("SubagentStop", done), .cleared,
             " clear session=\(s) event=SubagentStop phase=poststop"),
            ("SubagentStop mid-turn, task running", "UserPromptSubmit", stopLike("SubagentStop", running),
             .rewritten("Notification"),
             " keep session=\(s) event=SubagentStop phase=inflight reason=main-turn-in-flight pid="),
            ("SessionEnd, task running", "Stop", stopLike("SessionEnd", running), .rewritten("SessionEnd"),
             " keep session=\(s) event=SessionEnd reason=background-task-running pid="),
            ("StopFailure, task running", "UserPromptSubmit", stopLike("StopFailure", running),
             .rewritten("StopFailure"),
             " keep session=\(s) event=StopFailure reason=background-task-running pid="),
            ("idle_prompt mid-turn, task running", "UserPromptSubmit", note("idle_prompt", running),
             .rewritten("Notification"),
             " keep session=\(s) event=Notification type=idle_prompt phase=inflight reason=background-task-running pid="),
            ("permission_prompt after Stop", "Stop", note("permission_prompt", nil),
             .rewritten(ClaudeBusyConstants.waitingAfterStopEventToken),
             " keep session=\(s) event=Notification type=permission_prompt phase=poststop reason=waiting-on-user pid="),
            ("idle_prompt after Stop", "Stop", note("idle_prompt", nil), .spared,
             " ignore reason=poststop-clear-notification session=\(s) type=idle_prompt pid="),
            ("UserPromptSubmit", nil, stopLike("UserPromptSubmit", running), .rewritten("UserPromptSubmit"),
             " set session=\(s) pid="),
            ("Stop, task running, bad session", nil,
             finalMessageJSON("Stop", "not-a-session", message: asking, backgroundTasks: running), .absent,
             " ignore reason=bad-session event=Stop"),
        ]
        for c in cases {
            withHome { home in
                let marker = markerDir(home).appendingPathComponent(session)
                if let prior = c.prior { plantMarker(prior, at: marker) }
                let planted = FileManager.default.contents(atPath: marker.path)
                let result = runHook(json: c.json, home: home)
                #expect(result.exitCode == 0 && result.stdout.isEmpty, "\(c.name)")
                switch c.outcome {
                case .rewritten(let token):
                    #expect(waitForRewrite(marker, event: token).contains("event=\(token) "), "\(c.name): kept as before")
                case .cleared:
                    #expect(waitForFile(marker, present: false), "\(c.name): cleared as before")
                case .spared:
                    Thread.sleep(forTimeInterval: 0.15)
                    #expect(planted != nil && FileManager.default.contents(atPath: marker.path) == planted,
                            "\(c.name): left untouched as before")
                case .absent:
                    Thread.sleep(forTimeInterval: 0.15)
                    #expect(sessionShapedFiles(in: markerDir(home)).isEmpty, "\(c.name): no marker")
                }
                let lines = hookLog(home).split(separator: "\n").map(String.init)
                #expect(lines.count == 1 && lines[0].contains(c.logged), "\(c.name): its one usual line, got \(lines)")
                #expect(askCheckLines(home).isEmpty, "\(c.name): no check line")
            }
        }
    }

    /// Text no log line or marker can hold by chance: capital letters only,
    /// from a fixed seed (a log line never has eight capitals in a row).
    nonisolated static func distinctive(_ count: Int, seed: UInt32) -> String {
        var state = seed
        return String((0..<count).map { _ -> Character in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Character(UnicodeScalar(UInt8(65 + (state >> 24) % 26)))
        })
    }

    /// Every regular file under `root`, hidden ones included, with its bytes.
    private func everyFile(under root: URL) -> [(path: String, data: Data)] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        var files: [(path: String, data: Data)] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = FileManager.default.contents(atPath: url.path) else { continue }
            files.append((url.path, data))
        }
        return files
    }

    /// The path of every entry under `root` (files, folders, anything else;
    /// hidden ones included), relative to `root`.
    private func everyName(under root: URL) -> [String] {
        FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String } ?? []
    }

    /// Privacy: no byte of the final message is written anywhere. Distinctive
    /// messages (one that asks, one that does not, one far past the bound,
    /// one ending in a code block, one in multi-byte text) go through the
    /// checked path, then a SubagentStop and a plain end of turn with the
    /// same text; afterwards no file under the test HOME — hook.log, the
    /// markers, any temp file — holds a message or any 8-character piece of
    /// one, no file or folder NAME there holds such a piece, and no temp
    /// file is left.
    @Test func theFinalMessageIsNeverWrittenAnywhere() {
        let d = Self.distinctive
        let messages = [
            "QUOKKA \(d(24, 1)) MARMALADE, shall we vanquish the \(d(12, 2)) gizmo?",
            "\(d(40, 3)) obsidian lanterns hum at dusk.\n\(d(30, 4)).",
            d(1_500, 5) + "\n" + d(30, 6) + "?",
            "Run this one?\n```sh\n\(d(20, 7))\n```",
            "全部終わりましたか \(d(16, 8))？",
        ]
        withHome { home in
            for (index, text) in messages.enumerated() {
                let session = "a800000\(index)-0106-4abc-8def-000000000106"
                let message = Self.jsonString(text)
                let marker = markerDir(home).appendingPathComponent(session)
                primeMarker(session, home: home)
                _ = runHook(json: finalMessageJSON("Stop", session, message: message,
                                                   backgroundTasks: Self.runningTask), home: home)
                #expect(waitForMarkerEvent(marker, event: "Stop").contains("event=Stop "))
                _ = runHook(json: finalMessageJSON("SubagentStop", session, message: message,
                                                   backgroundTasks: Self.runningTask), home: home)
                #expect(waitForMarkerEvent(marker, event: "SubagentStop").contains("event=SubagentStop "))
                if index.isMultiple(of: 2) {
                    _ = runHook(json: finalMessageJSON("Stop", session, message: message,
                                                       backgroundTasks: Self.doneTask), home: home)
                    #expect(waitForFile(marker, present: false))
                }
            }
            Thread.sleep(forTimeInterval: 0.15)
            #expect(askCheckLines(home).count == messages.count, "non-vacuity: every checked Stop logged its word")
            let files = everyFile(under: home)
            #expect(files.contains { $0.path.hasSuffix("/" + ClaudeBusyConstants.logFileName) }, "the walk sees hook.log")
            let names = everyName(under: home)
            #expect(names.contains { $0.hasSuffix("/claude-busy/" + ClaudeBusyConstants.logFileName) },
                    "the name walk sees hook.log: \(names)")
            var leaks: [String] = []
            for text in messages {
                let characters = Array(text)
                for start in 0...(characters.count - 8) {
                    let piece = Data(String(characters[start..<(start + 8)]).utf8)
                    for file in files where file.data.range(of: piece) != nil {
                        leaks.append("\(String(reflecting: String(characters[start..<(start + 8)]))) in \(file.path)")
                    }
                    for name in names where Data(name.utf8).range(of: piece) != nil {
                        leaks.append("\(String(reflecting: String(characters[start..<(start + 8)]))) in the name \(name)")
                    }
                }
            }
            #expect(leaks.isEmpty, "message text written to disk: \(leaks.prefix(5))")
            let temp = ((try? FileManager.default.contentsOfDirectory(atPath: markerDir(home).path)) ?? [])
                .filter { $0.hasPrefix(".payload.") || $0.hasPrefix(".marker.") }
            #expect(temp.isEmpty, "no temp file is left: \(temp)")
        }
    }

    /// One row of the judgement table: a final message, through the shipped
    /// hook on a Stop kept for background work, and the word it must log.
    struct AskRow: CustomTestStringConvertible, Sendable {
        let id: String
        let note: String
        /// The `last_assistant_message` value, as a JSON literal.
        let message: String
        let result: String
        var testDescription: String { "\(id): \(note) → \(result)" }
    }

    /// The check's bounds, pinned to the script below.
    nonisolated static let askTailBytes = 400, askTailLines = 3

    /// The rule, row by row — including the bound (the last 400 bytes; a line
    /// counts by its end) and the known false positives and negatives the
    /// script's comment lists.
    nonisolated static let askRows: [AskRow] = {
        func row(_ id: String, _ note: String, _ text: String, _ result: String) -> AskRow {
            AskRow(id: id, note: note, message: jsonString(text), result: result)
        }
        func a(_ count: Int) -> String { String(repeating: "a", count: count) }
        let euros = String(repeating: "€", count: 200)  // 600 bytes: the cut lands inside a character
        return [
            row("asks-1", "a plain question", "Shall I go ahead?", "asks"),
            row("asks-2", "trailing spaces, a tab, a CR and blank lines", "Shall I go ahead?  \t\r\n\n \n", "asks"),
            row("asks-3", "a closing quote", #"He asked "is it done?""#, "asks"),
            row("asks-4", "a closing parenthesis", "(is that ok?)", "asks"),
            row("asks-5", "bold", "**Merge now?**", "asks"),
            row("asks-6", "italic, in a list item", "- _Ship it?_", "asks"),
            row("asks-7", "curly double quotes", "She said “ready?”", "asks"),
            row("asks-8", "a curly single quote", "It reads ’really?’", "asks"),
            row("asks-9", "a short sign-off after the question", "Which option do you want?\n\nThanks.", "asks"),
            row("asks-10", "two lines after the question", "Which one?\n1. A\n2. B", "asks"),
            row("asks-11", "the full-width question mark", "全部終わりましたか？", "asks"),
            row("asks-12", "full-width, in full-width parentheses", "（続けますか？）", "asks"),
            row("asks-13", "full-width, in corner brackets", "「進めますか？」", "asks"),
            row("asks-14", "a question above a closing code block", "Ready to run this?\n```sh\nmake test\n```", "asks"),
            row("asks-15", "a question above two code blocks", "Is this right?\n```\na\n```\n```\nb\n```", "asks"),
            row("no-1", "a statement", "All done.", "no"),
            row("no-2", "an empty message", "", "no"),
            row("no-3", "a question mid-line", "What next? Nothing, all done.", "no"),
            row("no-4", "the question only inside the closing code block", "Here it is:\n```swift\nlet x = a?\n```", "no"),
            row("no-5", "the question inside a tilde block", "Here:\n~~~\nwhy?\n~~~", "no"),
            row("no-6", "the question in an earlier code block", "a\n```\nb?\n```\n```\nc\n```", "no"),
            row("no-7", "nothing but a code block", "```\nonly code?\n```", "no"),
            row("no-8", "three lines after the question", "Which one?\n1. A\n2. B\n3. C", "no"),
            row("no-9", "the message is a result word itself", "asks", "no"),
            row("bound-1", "the mark is byte \(askTailBytes) from the end", "Shall I?\n" + a(askTailBytes - 2), "asks"),
            row("bound-2", "the mark is byte \(askTailBytes + 1) from the end", "Shall I?\n" + a(askTailBytes - 1), "no"),
            row("bound-3", "a full-width mark wholly inside the bound", "Proceed？\n" + a(askTailBytes - 4), "asks"),
            row("bound-4", "a full-width mark the bound cuts through", "Proceed？\n" + a(askTailBytes - 3), "no"),
            row("bound-5", "a question far past the bound",
                "Shall I continue?\n" + String(repeating: "x", count: 1_000), "no"),
            row("bound-6", "a long head, the question at the end",
                String(repeating: "y", count: 5_000) + "\nShall I go on?", "asks"),
            row("bound-7", "multi-byte text cut mid-character, then a question", euros + "\nContinuer ?", "asks"),
            row("bound-8", "multi-byte text cut mid-character, no question", euros + "\nContinuer.", "no"),
            row("bound-9", "a closing fence whose opening fence is past the bound",
                "Here:\n```\n" + String(repeating: "q?\n", count: 200) + "```", "no"),
            row("fp-1", "known false positive: a rhetorical question, then its answer",
                "Why did it fail?\nThe cache was stale.\nFixed.", "asks"),
            row("fp-2", "known false positive: a code span ending in ?", "The helper is `ready?`", "asks"),
            row("fp-3", "known false positive: a ? line inside a code block that is never closed",
                "Here is the log:\n```\nwhy did it fail?", "asks"),
            row("fp-4", "known false positive: a ? line between two ``` lines inside a ~~~ block",
                "Example:\n~~~\n```\nwhy?\n```\n~~~", "asks"),
            row("fn-1", "known false negative: (y/n) after the mark", "Want me to do it? (y/n)", "no"),
            row("fn-2", "known false negative: an emoji after the mark", "Ship it? 🚀", "no"),
            // Only ASCII whitespace is stripped, in any locale.
            row("fn-3", "known false negative: a no-break space after the mark", "Ready?\u{00A0}", "no"),
            row("fn-4", "known false negative: a ``` line inside a ~~~ block below the question",
                "Shall I run it?\n~~~\n```\n~~~", "no"),
            // "Shall I continue" in Arabic, ending in U+061F ARABIC QUESTION MARK.
            row("fn-5", "known false negative: the Arabic question mark",
                "\u{0647}\u{0644} \u{0623}\u{062A}\u{0627}\u{0628}\u{0639}\u{061F}", "no"),
        ]
    }()

    @Test(arguments: askRows)
    func theJudgementTable(_ row: AskRow) {
        withHome { home in
            let session = "a8000005-0105-4abc-8def-000000000105"
            let result = runHook(json: finalMessageJSON("Stop", session, message: row.message,
                                                        backgroundTasks: Self.runningTask), home: home)
            #expect(result.exitCode == 0 && result.stdout.isEmpty)
            let lines = askCheckLines(home)
            #expect(lines.count == 1 && isAskCheckLine(lines[0], session: session, result: row.result),
                    "\(row.id) must log result=\(row.result), got \(lines)")
        }
    }

    /// The judgement matches bytes whatever locale the hook inherits:
    /// `tail_asks` sets LC_ALL=C for itself, first thing. Three rows run
    /// through the hook in the bare environment (as the exec-form
    /// registration's `env -i` leaves it) and again with
    /// LC_ALL=en_US.UTF-8, and log the same word both times. In that UTF-8
    /// locale bash counts a no-break space as [[:space:]], so without the
    /// pin the no-break-space row (fn-3) would read `asks` there.
    @Test func theJudgementIsTheSameUnderAUTF8Locale() throws {
        let utf8 = ["LC_ALL": "en_US.UTF-8"]
        let body = Self.functionBody("tail_asks", in: try Self.read(Self.hookScriptURL))
        #expect(body.first == "local LC_ALL=C", "the pin is tail_asks' first line, got \(String(describing: body.first))")

        // Non-vacuity: bash really runs in a UTF-8 locale here, one in which
        // a no-break space is [[:space:]].
        let probe = Process(), output = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/bin/bash")
        probe.arguments = ["-c", #"case $'\xc2\xa0' in [[:space:]]) printf space ;; *) printf other ;; esac"#]
        probe.environment = ["PATH": "/usr/bin:/bin"].merging(utf8) { current, _ in current }
        probe.standardOutput = output
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        let seen = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        probe.waitUntilExit()
        #expect(seen == "space", "under \(utf8) bash must treat U+00A0 as [[:space:]], got \(String(describing: seen))")

        let ids = ["fn-3", "bound-7", "asks-12"]
        let rows = Self.askRows.filter { ids.contains($0.id) }
        try #require(rows.map(\.id) == ["asks-12", "bound-7", "fn-3"], "the rows exist")
        for row in rows {
            for environment in [[:], utf8] {
                withHome { home in
                    let session = "a8000007-0107-4abc-8def-000000000107"
                    let json = finalMessageJSON("Stop", session, message: row.message, backgroundTasks: Self.runningTask)
                    let result = runScript(Self.hookScriptURL, bytes: Data(json.utf8), home: home,
                                           extraEnvironment: environment)
                    #expect(result.exitCode == 0 && result.stdout.isEmpty)
                    let lines = askCheckLines(home)
                    #expect(lines.count == 1 && isAskCheckLine(lines[0], session: session, result: row.result),
                            "\(row.id) under \(environment) must log result=\(row.result), got \(lines)")
                }
            }
        }
    }

    @Test func theTableCoversBothWordsAndThePinnedBounds() throws {
        #expect(Self.askRows.count == 42 && Set(Self.askRows.map(\.id)).count == 42, "vacuity guard")
        #expect(Set(Self.askRows.map(\.result)) == ["asks", "no"])
        let lines = try Self.read(Self.hookScriptURL).split(separator: "\n").map(String.init)
        #expect(lines.filter { $0.hasPrefix("ASK_TAIL_BYTES=") } == ["ASK_TAIL_BYTES=\(Self.askTailBytes)"])
        #expect(lines.filter { $0.hasPrefix("ASK_TAIL_LINES=") } == ["ASK_TAIL_LINES=\(Self.askTailLines)"])
        #expect(Self.askTailBytes == 400 && Self.askTailLines == 3, "the contract values of this check")
    }

    /// Pure lint (reusable for canaries): where the final message may be
    /// read, and what may come of it.
    ///  1. The field is named on exactly two code lines, both in
    ///     `final_message_check`: the string extraction, piped straight into
    ///     the `tail -c` bound, and the type probe, whose output goes to
    ///     /dev/null. No code line names the transcript.
    ///  2. `final_message_check` is called once, from main(), on exactly the
    ///     Stop + background-work + valid-session guard line, inside the
    ///     payload window (after its mktemp, before its last removal); and
    ///     `asked` is set nowhere else but its reset.
    ///  3. `ask-check` is logged on exactly one code line: the closed-word
    ///     arm of `case "$asked" in`, inside the background-task keep branch.
    ///  4. An ALLOW list over the check's two functions, command
    ///     substitutions included (`allowListCheck`): every command is a
    ///     keyword or builtin from an explicit list, and only
    ///     `final_message_check` may also run `plutil -extract` with
    ///     exactly one `-o -`, `/usr/bin/tail -c N` and `/usr/bin/tr`, and
    ///     call `tail_asks`. No here-document or here-string, no redirect
    ///     but to /dev/null, no backtick, no word naming `BASH_REMATCH` or
    ///     holding `${!` (a regex capture, an indirect expansion), and no
    ///     word of those three commands expands a name taken to hold
    ///     message text: `$_`, `tail_asks`' arguments, and any name
    ///     assigned from one of those or from a read of the field. The
    ///     lint reads a body up to its first line that is exactly `}`, so
    ///     each function is defined exactly once (`definitionCount`) and
    ///     the `{` and `}` words of its body balance (`bracesBalance`):
    ///     the body read is the whole function.
    /// Limit: the allow list reads those two functions only. A copy of the
    /// payload or the message made by code outside them (in `main()`, say)
    /// to a place outside the test HOME is caught neither by this lint nor
    /// by the privacy sweep, which reads the test HOME only.
    static func finalMessageCheckFailures(_ script: String) -> [String] {
        let code = script.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let check = functionBody("final_message_check", in: script)
        let judge = functionBody("tail_asks", in: script)
        let main = functionBody("main", in: script)
        guard !check.isEmpty, !judge.isEmpty, !main.isEmpty else {
            return ["final_message_check, tail_asks and main must exist (lint would be vacuous)"]
        }
        var failures: [String] = []

        let extraction = #"t=$(set -o pipefail; plutil -extract last_assistant_message raw -expect string -o - "$1" 2>/dev/null | /usr/bin/tail -c "$((ASK_TAIL_BYTES + 1))" | LC_ALL=C /usr/bin/tr '\000' '#') || {"#
        let probe = #"if plutil -extract last_assistant_message raw -o - "$1" >/dev/null 2>&1; then"#
        let naming = code.filter { $0.contains("last_assistant_message") }
        if naming != [extraction, probe] {
            failures.append("the field must be named on the extraction and the probe line only, got \(naming)")
        }
        if !(check.contains(extraction) && check.contains(probe)) {
            failures.append("the extraction and the probe must sit in final_message_check")
        }
        if code.contains(where: { $0.contains("transcript") }) { failures.append("a code line names the transcript") }

        let guardLine = #"[ "$event" = Stop ] && [ "$bg_running" = yes ] && valid_session "$session" && asked=$(final_message_check "$payload")"#
        let calls = code.filter { $0.contains("final_message_check") && $0 != "final_message_check() {" }
        if calls != [guardLine] { failures.append("one call, on the Stop + background-work guard line; got \(calls)") }
        if let call = main.firstIndex(of: guardLine),
           let mktemp = main.firstIndex(where: { $0.hasPrefix("payload=$(mktemp ") }),
           let removal = main.lastIndex(of: #"rm -f "$payload" 2>/dev/null"#) {
            if !(mktemp < call && call < removal) { failures.append("the check must run inside the payload window") }
        } else {
            failures.append("the guard line, the payload's mktemp or its removal is missing from main")
        }
        let sets = code.filter { $0.contains("asked=") }
        if sets != [#"asked="""#, guardLine] { failures.append("asked is set by its reset and the guard only; got \(sets)") }

        let logLine = #"asks|no|absent|unreadable) log "ask-check session=$session result=$asked" ;;"#
        let logs = code.filter { $0.contains("ask-check") }
        if logs != [logLine] { failures.append("ask-check must be logged on the closed-word line only, got \(logs)") }
        if let keep = main.firstIndex(of: #"elif [ "$bg_running" = yes ]; then"#), let at = main.firstIndex(of: logLine) {
            let next = main[(keep + 1)...].firstIndex { $0.hasPrefix("elif ") || $0 == "else" } ?? main.endIndex
            if !(keep < at && at < next) { failures.append("the check line must sit in the background-task keep branch") }
            if at == 0 || main[at - 1] != #"case "$asked" in"# {
                failures.append(#"the check line must be the arm of `case "$asked" in`"#)
            }
        } else {
            failures.append("the keep branch or the check line is missing from main")
        }

        for (name, body) in [("final_message_check", check), ("tail_asks", judge)] {
            let defined = definitionCount(name, in: script)
            if defined != 1 { failures.append("\(name) must be defined exactly once, got \(defined) definitions") }
            if !bracesBalance(body.joined(separator: "\n")) {
                failures.append("the braces in \(name)'s body do not balance (the body read is not the whole function)")
            }
        }
        let tools = allowListCheck(check.joined(separator: "\n"), in: "final_message_check", mayRunTools: true,
                                   tainted: [])
        let judging = allowListCheck(judge.joined(separator: "\n"), in: "tail_asks", mayRunTools: false,
                                     tainted: ["1", "@", "*"])
        failures += tools.failures + judging.failures
        if Set(tools.ran) != ["plutil", "/usr/bin/tail", "/usr/bin/tr"] {
            failures.append("final_message_check must run plutil, /usr/bin/tail and /usr/bin/tr (lint would be vacuous), got \(tools.ran)")
        }
        return failures
    }

    // MARK: The allow list: a small reader of the shell this hook writes

    /// One token of `shellTokens`.
    enum ShellToken: Equatable, Sendable {
        case word(String)
        /// `;` `;;` `&` `&&` `|` `||` `(` `)`, or a newline.
        case separator(String)
        /// A redirection operator with its file descriptor, if any: `>`,
        /// `2>`, `2>&`, `>>`, `<`, `<<`, `<<<` and so on.
        case redirect(String)
    }

    nonisolated static func scalars(_ s: [Unicode.Scalar], _ from: Int, _ to: Int) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s[from..<min(to, s.count)])
        return String(view)
    }

    /// The index just past the quoted or substituted text starting at
    /// `start` (a `'`, `"` or backtick, or `$(` or `${`), skipping escapes,
    /// quotes and substitutions nested in it; nil when it is never closed.
    nonisolated static func skipGroup(_ s: [Unicode.Scalar], from start: Int) -> Int? {
        func at(_ k: Int) -> Unicode.Scalar? { k < s.count ? s[k] : nil }
        func opensGroup(_ k: Int) -> Bool {
            at(k) == "'" || at(k) == "\"" || at(k) == "`" || (at(k) == "$" && (at(k + 1) == "(" || at(k + 1) == "{"))
        }
        switch s[start] {
        case "'":
            var i = start + 1
            while let c = at(i), c != "'" { i += 1 }
            return at(i) == nil ? nil : i + 1
        case "`":
            var i = start + 1
            while let c = at(i), c != "`" { i += c == "\\" ? 2 : 1 }
            return at(i) == nil ? nil : i + 1
        case "\"":
            var i = start + 1
            while let c = at(i), c != "\"" {
                if c == "\\" {
                    i += 2
                } else if c != "'" && opensGroup(i) {
                    guard let end = skipGroup(s, from: i) else { return nil }
                    i = end
                } else {
                    i += 1
                }
            }
            return at(i) == nil ? nil : i + 1
        case "$" where at(start + 1) == "(" || at(start + 1) == "{":
            let open = s[start + 1], close: Unicode.Scalar = open == "(" ? ")" : "}"
            var depth = 1, i = start + 2
            while let c = at(i) {
                if c == "\\" { i += 2; continue }
                if opensGroup(i) {
                    guard let end = skipGroup(s, from: i) else { return nil }
                    i = end
                    continue
                }
                if c == open { depth += 1 }
                if c == close { depth -= 1; if depth == 0 { return i + 1 } }
                i += 1
            }
            return nil
        default:
            return start + 1
        }
    }

    /// Splits shell text into words, separators and redirections. Quoted
    /// text, escapes, `$(…)`, `$((…))`, `${…}` and backticks stay inside
    /// their word; a `#` starting a word starts a comment. Nil for text it
    /// cannot split (an unclosed quote or substitution).
    nonisolated static func shellTokens(_ text: String) -> [ShellToken]? {
        let s = Array(text.unicodeScalars)
        var tokens: [ShellToken] = [], word = "", i = 0
        func flush() { if !word.isEmpty { tokens.append(.word(word)); word = "" } }
        while i < s.count {
            let c = s[i]
            switch c {
            case " ", "\t":
                flush(); i += 1
            case "\n":
                flush(); tokens.append(.separator("\n")); i += 1
            case "#" where word.isEmpty:
                while i < s.count, s[i] != "\n" { i += 1 }
            case "\\":
                word += scalars(s, i, i + 2); i += 2
            case "'", "\"", "`", "$":
                guard let end = skipGroup(s, from: i) else { return nil }
                word += scalars(s, i, end); i = end
            case "<", ">":
                // A file descriptor number right before the operator is part of it.
                let descriptor = !word.isEmpty && word.allSatisfy { $0.isASCII && $0.isNumber }
                var op = descriptor ? word : ""
                if descriptor { word = "" } else { flush() }
                let ahead = scalars(s, i, i + 3)
                let ops = c == "<" ? ["<<<", "<<-", "<<", "<&", "<>", "<"] : [">>", ">&", ">|", ">"]
                let found = ops.first { ahead.hasPrefix($0) } ?? String(c)
                op += found
                i += found.unicodeScalars.count
                tokens.append(.redirect(op))
            case ";", "&", "|", "(", ")":
                flush()
                let pair = scalars(s, i, i + 2)
                if ["&&", "||", ";;"].contains(pair) {
                    tokens.append(.separator(pair)); i += 2
                } else if pair == "&>" {
                    tokens.append(.redirect(pair)); i += 2
                } else {
                    tokens.append(.separator(String(c))); i += 1
                }
            default:
                word.unicodeScalars.append(c); i += 1
            }
        }
        flush()
        return tokens
    }

    /// What `word` runs: the inner text of each `$(…)` in it (inside a
    /// `$((…))` the search goes on), and whether it holds a backtick
    /// substitution.
    nonisolated static func substitutions(in word: String) -> (inner: [String], backtick: Bool) {
        let s = Array(word.unicodeScalars)
        var inner: [String] = [], backtick = false, quoted = false, i = 0
        while i < s.count {
            let c = s[i]
            if c == "\\" {
                i += 2
            } else if c == "'" && !quoted {
                i = skipGroup(s, from: i) ?? s.count
            } else if c == "\"" {
                quoted.toggle(); i += 1
            } else if c == "`" {
                backtick = true; i += 1
            } else if c == "$", i + 1 < s.count, s[i + 1] == "(" {
                if i + 2 < s.count, s[i + 2] == "(" { i += 3; continue }
                let end = skipGroup(s, from: i) ?? s.count
                inner.append(scalars(s, i + 2, max(i + 2, end - 1)))
                i = end
            } else {
                i += 1
            }
        }
        return (inner, backtick)
    }

    /// Whether `word` expands one of `names`: `$n`, `${n…}`, `${#n}`, or,
    /// inside `$((…))`, the bare name.
    nonisolated static func expands(_ word: String, anyOf names: Set<String>) -> Bool {
        names.contains { name in
            let n = NSRegularExpression.escapedPattern(for: name)
            if word.range(of: #"\$\{?[#!]?"# + n + #"([^A-Za-z0-9_]|$)"#, options: .regularExpression) != nil {
                return true
            }
            return word.contains("$((") && name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
                && word.range(of: #"(^|[^A-Za-z0-9_$])"# + n + #"([^A-Za-z0-9_]|$)"#, options: .regularExpression) != nil
        }
    }

    /// The names `word` assigns: `name=…` (or `+=`) and every `${name:=…}`.
    nonisolated static func assignedNames(_ word: String) -> [String] {
        var names: [String] = []
        if let range = word.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\+?="#, options: .regularExpression) {
            names.append(String(word[range]).trimmingCharacters(in: CharacterSet(charactersIn: "+=")))
        }
        var rest = word[...]
        while let range = rest.range(of: #"\$\{[A-Za-z_][A-Za-z0-9_]*:?="#, options: .regularExpression) {
            names.append(String(rest[range].dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: ":=")))
            rest = rest[range.upperBound...]
        }
        return names
    }

    /// How many times `script` defines the shell function `name`: each
    /// `name()` (spaces allowed before and inside the parentheses) or
    /// `function name` on a code line, at its start or after any character
    /// that cannot be part of a name. Comment lines are skipped; a code line
    /// ending in a backslash is read with the next one, as bash reads it.
    nonisolated static func definitionCount(_ name: String, in script: String) -> Int {
        var code: [String] = [], joining = false
        for raw in script.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if joining {
                code[code.count - 1] = String(code[code.count - 1].dropLast()) + line
            } else if line.hasPrefix("#") {
                continue
            } else {
                code.append(line)
            }
            joining = code[code.count - 1].hasSuffix("\\")
        }
        let n = NSRegularExpression.escapedPattern(for: name)
        guard let definition = try? NSRegularExpression(
            pattern: #"(^|[^A-Za-z0-9_])(function[ \t]+"# + n + #"([^A-Za-z0-9_]|$)|"# + n + #"[ \t]*\([ \t]*\))"#)
        else { return 0 }
        return code.reduce(0) { $0 + definition.numberOfMatches(in: $1, range: NSRange($1.startIndex..., in: $1)) }
    }

    /// Whether the standalone `{` and `}` words of `text` pair up: never
    /// more `}` than `{` so far, and as many of each in all. Text it cannot
    /// split counts as balanced (`allowListCheck` reports it).
    nonisolated static func bracesBalance(_ text: String) -> Bool {
        var depth = 0
        for token in shellTokens(text) ?? [] {
            if token == .word("{") { depth += 1 }
            if token == .word("}") {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0
    }

    /// The allow-list rule (4. above) over `text`: a function body, or the
    /// inside of a command substitution in one. `tainted` names hold message
    /// text; so does `_` (`$_`, the last argument of the command before, can
    /// be a copy of it), and any name assigned from one of them or from a
    /// read of `last_assistant_message`. A word naming `BASH_REMATCH` or
    /// holding `${!` fails wherever it stands: a regex capture or an
    /// indirect expansion copies text without assigning it. Returns the
    /// failures and the external commands it saw, in order.
    nonisolated static func allowListCheck(_ text: String, in name: String, mayRunTools: Bool,
                                           tainted seeds: Set<String>) -> (failures: [String], ran: [String]) {
        guard let tokens = shellTokens(text) else {
            return (["\(name) cannot be read (an unclosed quote or substitution)"], [])
        }
        var failures: [String] = [], ran: [String] = []
        var tainted = seeds.union(["_"])
        let allWords = tokens.compactMap { token -> String? in
            if case .word(let w) = token { return w } else { return nil }
        }
        for w in allWords where w.contains("BASH_REMATCH") || w.contains("${!") {
            failures.append("a regex capture or indirect expansion in \(name): \(w)")
        }
        var grew = true
        while grew {
            grew = false
            for w in allWords where w.contains("last_assistant_message") || expands(w, anyOf: tainted) {
                for target in assignedNames(w) where !tainted.contains(target) {
                    tainted.insert(target); grew = true
                }
            }
        }
        let closedWords: Set<String> = ["asks", "no", "absent", "unreadable"]
        let leading: Set<String> = ["if", "then", "elif", "else", "while", "do", "{"]
        func isAssignment(_ w: String) -> Bool {
            w.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\+?="#, options: .regularExpression) != nil
        }
        func allowedAssignment(_ w: String) -> Bool {
            w == "LC_ALL=C" || w.range(of: #"^[a-z_][a-z0-9_]*\+?="#, options: .regularExpression) != nil
        }

        var caseArms: [Bool] = []  // one per open `case`: true while a pattern is due
        var words: [String] = [], redirects: [(op: String, target: String)] = []
        var pendingRedirect: String?, inTest = false

        func checkCommand(_ separator: String) {
            for w in words + redirects.map(\.target) {
                let found = substitutions(in: w)
                if found.backtick { failures.append("a backtick substitution in \(name): \(w)") }
                for inner in found.inner {
                    let nested = allowListCheck(inner, in: name, mayRunTools: mayRunTools, tainted: tainted)
                    failures += nested.failures
                    ran += nested.ran
                }
            }
            for r in redirects {
                if r.op.contains("<<") {
                    failures.append("a here-document or here-string in \(name): \(r.op)\(r.target)")
                } else if !(((r.op == ">" || r.op == "2>") && r.target == "/dev/null") || (r.op == "2>&" && r.target == "1")) {
                    failures.append("a redirect in \(name) that is not to /dev/null: \(r.op)\(r.target)")
                }
            }
            if let due = caseArms.last, due {
                // A pattern list (`a|b)`), or the `esac` that closes the case.
                if words == ["esac"] { caseArms.removeLast() } else if separator == ")" { caseArms[caseArms.count - 1] = false }
                return
            }
            var rest = words[...]
            while let first = rest.first, leading.contains(first) { rest = rest.dropFirst() }
            guard let first = rest.first else { return }
            if first == "case" {
                if rest.count != 3 || rest.last != "in" { failures.append("a case line that is not `case WORD in` in \(name)") }
                caseArms.append(true)
                return
            }
            if ["fi", "done", "esac", "}"].contains(first) {
                if first == "esac" && !caseArms.isEmpty { caseArms.removeLast() }
                return
            }
            var assignments: [String] = []
            while let w = rest.first, isAssignment(w) { assignments.append(w); rest = rest.dropFirst() }
            for a in assignments where !allowedAssignment(a) {
                failures.append("an assignment to \(a.prefix { $0 != "=" && $0 != "+" }) in \(name)")
            }
            guard let command = rest.first else { return }
            let args = Array(rest.dropFirst())
            switch command {
            case "[[", "[", ":", "return", "break", "continue":
                break
            case "local":
                for a in args where a.hasPrefix("-")
                    || !(isAssignment(a) ? allowedAssignment(a)
                         : a.range(of: "^[a-z_][a-z0-9_]*$", options: .regularExpression) != nil) {
                    failures.append("local \(a) in \(name): only lowercase names, or LC_ALL=C")
                }
            case "set":
                if args != ["-o", "pipefail"] { failures.append("set other than `set -o pipefail` in \(name): \(args)") }
            case "printf":
                if args.count != 1 || !closedWords.contains(args[0]) {
                    failures.append("a printf of anything but one closed word in \(name): printf \(args)")
                }
            case "tail_asks" where mayRunTools:
                break
            case "plutil" where mayRunTools, "/usr/bin/tail" where mayRunTools, "/usr/bin/tr" where mayRunTools:
                ran.append(command)
                for a in assignments where a != "LC_ALL=C" {
                    failures.append("a prefix assignment on \(command) in \(name): \(a)")
                }
                for w in assignments + args where expands(w, anyOf: tainted) {
                    failures.append("message text reaches \(command) in \(name): \(w)")
                }
                if command == "plutil", args.first != "-extract" {
                    failures.append("plutil other than `plutil -extract` in \(name): \(args)")
                }
                if command == "plutil", args.filter({ $0 == "-o" }).count != 1
                    || args.firstIndex(of: "-o").map({ $0 + 1 < args.count && args[$0 + 1] == "-" }) != true {
                    failures.append("plutil without exactly one `-o -` in \(name): \(args)")
                }
                if command == "/usr/bin/tail", args.count != 2 || args[0] != "-c" {
                    failures.append("tail other than `tail -c N` in \(name): \(args)")
                }
            default:
                failures.append("'\(command)' in \(name) is not on the allow list")
            }
        }

        for token in tokens {
            switch token {
            case .word(let w):
                if let op = pendingRedirect {
                    redirects.append((op, w)); pendingRedirect = nil
                    continue
                }
                if w == "[[" && words.allSatisfy({ leading.contains($0) }) { inTest = true }
                if w == "]]" { inTest = false }
                words.append(w)
            case .redirect(let op):
                if inTest { words.append(op); continue }
                if let op = pendingRedirect { failures.append("a redirect with no target in \(name): \(op)") }
                pendingRedirect = op
            case .separator(let separator):
                if inTest && separator != "\n" { words.append(separator); continue }
                if let op = pendingRedirect { failures.append("a redirect with no target in \(name): \(op)") }
                checkCommand(separator)
                if separator == ";;", !caseArms.isEmpty { caseArms[caseArms.count - 1] = true }
                words = []; redirects = []; pendingRedirect = nil; inTest = false
            }
        }
        if let op = pendingRedirect { failures.append("a redirect with no target in \(name): \(op)") }
        checkCommand("\n")
        return (failures, ran)
    }

    @Test func theFinalMessageIsReadAndLoggedOnlyWhereTheContractSays() throws {
        let failures = Self.finalMessageCheckFailures(try Self.read(Self.hookScriptURL))
        #expect(failures.isEmpty, "\(failures)")
    }

    /// Canaries: every rule of the lint above catches its mutant.
    @Test func finalMessageCheckLintCatchesMutants() throws {
        let original = try Self.read(Self.hookScriptURL)
        try #require(Self.finalMessageCheckFailures(original).isEmpty, "canary baseline must be clean")
        let guardLine = #"  [ "$event" = Stop ] && [ "$bg_running" = yes ] && valid_session "$session" && asked=$(final_message_check "$payload")"#
            + "\n"
        let block = "        case \"$asked\" in\n"
            + #"          asks|no|absent|unreadable) log "ask-check session=$session result=$asked" ;;"# + "\n"
            + "        esac\n"
        let clearLog = #"        log "clear session=$session event=$event$tinfo$pinfo""# + "\n"
        let payloadGone = "  trap - EXIT TERM INT\n\n  if ! valid_session"
        let judged = "  tail_asks \"$t\"\n"
        let mutants: [(String, (String) -> String)] = [
            ("checked on SubagentStop too", {
                $0.replacingOccurrences(of: #"&& [ "$bg_running" = yes ] && valid_session"#,
                                        with: #"|| [ "$event" = SubagentStop ] && [ "$bg_running" = yes ] && valid_session"#)
            }),
            ("checked with no background work", {
                $0.replacingOccurrences(of: #" && [ "$bg_running" = yes ] && valid_session"#, with: " && valid_session")
            }),
            ("checked after the payload is gone", {
                $0.replacingOccurrences(of: guardLine, with: "")
                    .replacingOccurrences(of: payloadGone, with: "  trap - EXIT TERM INT\n" + guardLine + "\n  if ! valid_session")
            }),
            ("a second read of the field", {
                $0.replacingOccurrences(of: guardLine, with: guardLine
                    + #"  plutil -extract last_assistant_message raw -o - "$payload" >/dev/null 2>&1"# + "\n")
            }),
            ("the transcript read", {
                $0.replacingOccurrences(of: guardLine, with: guardLine
                    + #"  plutil -extract transcript_path raw -o - "$payload" >/dev/null 2>&1"# + "\n")
            }),
            ("logged on a clear", {
                $0.replacingOccurrences(of: block, with: "").replacingOccurrences(of: clearLog, with: clearLog + block)
            }),
            ("any word logged", { $0.replacingOccurrences(of: "asks|no|absent|unreadable) log", with: "*) log") }),
            ("a snippet logged", { $0.replacingOccurrences(of: judged, with: judged + "  log \"ask-check tail=${t: -12}\"\n") }),
            ("the judgement prints the line", {
                $0.replacingOccurrences(of: "printf asks; return 0", with: #"printf 'asks %s' "$line"; return 0"#)
            }),
            ("the end written to a file", {
                $0.replacingOccurrences(of: judged, with: judged + "  printf '%s' \"$t\" >\"$STATE_DIR/.payload.tail\"\n")
            }),
            ("asked set elsewhere", { $0.replacingOccurrences(of: block, with: "        asked=$event\n" + block) }),
        ]
        for (name, transform) in mutants {
            let mutant = transform(original)
            #expect(mutant != original, "canary setup '\(name)'")
            #expect(!Self.finalMessageCheckFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    /// Canaries for the allow list (rule 4): each mutant must be caught BY
    /// that rule, with the failure it names. The first two are leaks a ban
    /// list let through: a copy of the whole payload out of the hook's
    /// folder, and message bytes in a file NAME. The last seven are leaks
    /// the allow list itself first let through: message bytes copied by a
    /// regex capture, an indirect expansion or `$_`, a file `plutil -create`
    /// writes despite `-o -`, a second definition (bash runs the last one,
    /// the lint reads the first), and a `}` at the start of a line that
    /// ends the body the lint reads while the function goes on.
    @Test func theAllowListCatchesWhatABanListMissed() throws {
        let original = try Self.read(Self.hookScriptURL)
        try #require(Self.finalMessageCheckFailures(original).isEmpty, "canary baseline must be clean")
        let declared = "final_message_check() {\n  local t\n"
        let judged = "  tail_asks \"$t\"\n"
        let judgeStart = "  local text=$1 line more=yes counted=0 code=no\n"
        func afterDeclared(_ line: String) -> (String) -> String {
            { $0.replacingOccurrences(of: declared, with: declared + line + "\n") }
        }
        func beforeJudged(_ line: String) -> (String) -> String {
            { $0.replacingOccurrences(of: judged, with: line + "\n" + judged) }
        }
        let mutants: [(name: String, transform: (String) -> String, caughtAs: String)] = [
            ("the payload copied out of the folder", afterDeclared(#"  /bin/cp "$1" /private/tmp/napcat-payload-copy"#),
             "'/bin/cp' in final_message_check is not on the allow list"),
            ("message bytes in a file name", beforeJudged(#"  /usr/bin/touch "$STATE_DIR/.n-${t: -8}""#),
             "'/usr/bin/touch' in final_message_check is not on the allow list"),
            ("a here-string", beforeJudged(#"  /usr/bin/tr -d x <<<"$t" >/dev/null"#),
             "a here-document or here-string in final_message_check"),
            ("a here-document", beforeJudged("  /usr/bin/tr -d x >/dev/null <<EOF\n$t\nEOF"),
             "a here-document or here-string in final_message_check"),
            ("the message on an external command's command line",
             beforeJudged(#"  plutil -extract "${t: -8}" raw -o - "$1" >/dev/null 2>&1"#),
             "message text reaches plutil in final_message_check"),
            ("the message through a copy", beforeJudged("  u=$t\n  /usr/bin/tr \"$u\" x >/dev/null"),
             "message text reaches /usr/bin/tr in final_message_check"),
            ("the message through a default", beforeJudged("  : \"${u:=$t}\"\n  /usr/bin/tr \"$u\" x >/dev/null"),
             "message text reaches /usr/bin/tr in final_message_check"),
            ("tail by its bare name", {
                $0.replacingOccurrences(of: "| /usr/bin/tail -c", with: "| tail -c")
            }, "'tail' in final_message_check is not on the allow list"),
            ("tail reading a file", {
                $0.replacingOccurrences(of: #"/usr/bin/tail -c "$((ASK_TAIL_BYTES + 1))""#,
                                        with: #"/usr/bin/tail -c "$((ASK_TAIL_BYTES + 1))" "$1""#)
            }, "tail other than `tail -c N` in final_message_check"),
            ("plutil writing a file", beforeJudged(#"  plutil -convert json -o "$STATE_DIR/.copy" "$1""#),
             "plutil without exactly one `-o -` in final_message_check"),
            ("a tool in the judgement", {
                $0.replacingOccurrences(of: judgeStart, with: judgeStart + "  /usr/bin/tr -d x >/dev/null\n")
            }, "'/usr/bin/tr' in tail_asks is not on the allow list"),
            ("a closed word redirected to a file", {
                $0.replacingOccurrences(of: "printf asks; return 0", with: #"printf asks >"$STATE_DIR/.asked"; return 0"#)
            }, "a redirect in tail_asks that is not to /dev/null"),
            ("an input redirect", beforeJudged(#"  /usr/bin/tr -d x <"$1" >/dev/null"#),
             "a redirect in final_message_check that is not to /dev/null"),
            ("a backtick substitution", beforeJudged("  : `/usr/bin/touch \"$STATE_DIR/.n\"`"),
             "a backtick substitution in final_message_check"),
            ("a tool inside a command substitution", beforeJudged(#"  : "$(/usr/bin/touch "$STATE_DIR/.n")""#),
             "'/usr/bin/touch' in final_message_check is not on the allow list"),
            ("eval", beforeJudged(#"  eval "$t""#), "'eval' in final_message_check is not on the allow list"),
            ("PATH reset", afterDeclared("  PATH=/private/tmp/napcat-bin:$PATH"),
             "an assignment to PATH in final_message_check"),
            ("an exported local", {
                $0.replacingOccurrences(of: declared, with: "final_message_check() {\n  local -x t\n")
            },
             "local -x in final_message_check"),
            ("allexport", afterDeclared("  set -a"), "set other than `set -o pipefail` in final_message_check"),
            ("a prefix assignment on a tool", {
                $0.replacingOccurrences(of: #"| /usr/bin/tail -c "$((ASK_TAIL_BYTES + 1))" | LC_ALL=C"#,
                                        with: #"| /usr/bin/tail -c "$((ASK_TAIL_BYTES + 1))" | LC_ALL=C TZ=x"#)
            }, "a prefix assignment on /usr/bin/tr in final_message_check"),
            ("message bytes in a file name through a regex capture",
             beforeJudged(#"  [[ $t =~ ([A-Z]{8}) ]] && plutil -create xml1 -o - "/private/tmp/napcat-x-${BASH_REMATCH[1]}" >/dev/null 2>&1"#),
             "a regex capture or indirect expansion in final_message_check"),
            ("message bytes in a file name through an indirect expansion",
             beforeJudged("  n=t\n  u=${!n}\n" + #"  plutil -create xml1 -o - "/private/tmp/napcat-x-${u: -8}" >/dev/null 2>&1"#),
             "a regex capture or indirect expansion in final_message_check"),
            ("the message through the last argument", beforeJudged("  : \"$t\"\n" + #"  /usr/bin/tr "${_: -8}" x >/dev/null"#),
             "message text reaches /usr/bin/tr in final_message_check"),
            ("plutil creating a file despite -o -",
             beforeJudged(#"  plutil -create xml1 -o - "/private/tmp/napcat-created" >/dev/null 2>&1"#),
             "plutil other than `plutil -extract` in final_message_check"),
            ("a second, leaky definition of the judgement", {
                $0.replacingOccurrences(of: "\nmain() {\n", with: "\ntail_asks() {\n"
                    + #"  printf '%s' "$1" >"/private/tmp/napcat-judged""# + "\n  printf no\n}\n\nmain() {\n")
            }, "tail_asks must be defined exactly once"),
            ("a second definition of the check, with the keyword", {
                $0.replacingOccurrences(of: "\nmain() {\n", with: "\n"
                    + #"function final_message_check { /bin/cp "$1" /private/tmp/napcat-payload-copy; }"# + "\n\nmain() {\n")
            }, "final_message_check must be defined exactly once"),
            ("a } at the start of a line ending the body read early", {
                $0.replacingOccurrences(of: judged, with: judged + "  { :\n}\n"
                    + #"  /bin/cp "$1" /private/tmp/napcat-payload-copy 2>/dev/null"# + "\n")
            }, "the braces in final_message_check's body do not balance"),
        ]
        for (name, transform, caughtAs) in mutants {
            let mutant = transform(original)
            #expect(mutant != original, "canary setup '\(name)'")
            let failures = Self.finalMessageCheckFailures(mutant)
            #expect(failures.contains { $0.hasPrefix(caughtAs) }, "canary '\(name)' was NOT caught as \(caughtAs): \(failures)")
        }
    }

    // MARK: - Installer registration is EXEC FORM only (no shell-form path)

    @Test func installerPrintsExecFormRegistration() throws {
        let installer = try Self.read(Self.installerURL)
        #expect(installer.contains("\"command\":\"/usr/bin/env\""), "exec form uses /usr/bin/env as the command")
        #expect(installer.contains("\"-i\""), "env -i strips BASH_ENV / BASH_FUNC_*")
        #expect(installer.contains("\"/bin/bash\""))
        #expect(installer.contains(ClaudeBusyConstants.installedHookRelativePath), "references the stable installed path")
        #expect(installer.contains("\"timeout\":5"))

        // C1: the Notification entry has NO matcher (the hook needs every type
        // to tell waiting-on-user apart from idle), and no printed registration
        // line carries one.
        #expect(installer.contains(#""Notification": [ { "hooks": [ $EXEC_CMD ] } ]"#),
                "the Notification entry is registered without a matcher")
        let registrationLines = installer.split(separator: "\n").filter { $0.contains("$EXEC_CMD ]") }
        #expect(registrationLines.count == 6, "six printed registrations, found \(registrationLines.count)")
        for line in registrationLines {
            #expect(!line.contains("matcher"), "printed registration must not carry a matcher: \(line)")
        }
        // ...and the UPDATE note tells earlier installs to drop the old matcher.
        #expect(installer.split(separator: "\n").contains(where: {
            $0.hasPrefix("echo") && $0.contains("REMOVE") && $0.contains("idle_prompt")
        }), "the installer must tell earlier installs to REMOVE the idle_prompt matcher")

        // NO shell-form: the ONLY "command" value is /usr/bin/env, and the
        // script path never appears as a command (only inside args).
        let commandOccurrences = installer.components(separatedBy: "\"command\":\"").count - 1
        #expect(commandOccurrences == 1, "exactly one command literal (the exec-form env), found \(commandOccurrences)")
        #expect(!installer.contains("\"command\":\"/bin/bash\""), "shell-form (bash as command) is forbidden")
        #expect(!installer.contains("\"command\":\"$HOOK_DEST\""), "bare-script-path command is forbidden")
    }

    /// The README registration the user pastes by hand must match the
    /// installer: its Notification entry has no matcher (with one, the C1
    /// waiting/resume branches would never receive their types).
    @Test func readmeNotificationRegistrationHasNoMatcher() throws {
        let readme = try Self.read(Self.repoRoot().appendingPathComponent("README.md"))
        let entries = readme.split(separator: "\n").filter { $0.hasPrefix("\"Notification\":") }
        #expect(entries.count == 1, "README documents exactly one Notification registration")
        for entry in entries {
            #expect(!entry.contains("matcher"), "README Notification registration must not carry a matcher")
            #expect(entry.contains(ClaudeBusyConstants.installedHookRelativePath))
        }
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

/// The SIGTERM-in-the-payload-window runs, kept OFF the main actor (#32): a
/// `.timeLimit` on a `@MainActor` test also counts the time the test waits for
/// the main actor, which on a loaded full run approaches the whole run's wall
/// time. Nothing here touches a main-actor type, so the limit measures the
/// hook run itself. The helpers are copies of `ClaudeBusyHookScriptTests`'
/// (whose statics are main-actor isolated there).
struct ClaudeBusyHookSignalWindowTests {
    /// SIGPIPE ignored before any test here writes a hook's stdin (#119;
    /// process-global — see `HookChildStdin`).
    init() { _ = HookChildStdin.ignoreSIGPIPE }

    private static var hookScriptURL: URL {
        URL(fileURLWithPath: #filePath)  // Tests/NapCatTests/<this file>
            .deletingLastPathComponent() // Tests/NapCatTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("scripts/claude-busy-hook.sh")
    }

    private static func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func markerDir(_ home: URL) -> URL {
        home.appendingPathComponent(ClaudeBusyConstants.markerDirRelativePath)
    }

    private func withHome(_ body: (URL) -> Void) {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("napcat-b1-hook-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        body(home)
    }

    private func hookLog(_ home: URL) -> String {
        let url = markerDir(home).appendingPathComponent(ClaudeBusyConstants.logFileName)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func payloadTempFiles(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(".payload.") }
    }

    /// Whether process `pid` has a direct child named `head` right now.
    private func hasHeadChild(_ pid: Int32) -> Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid), "head"]
        pgrep.standardOutput = FileHandle.nullDevice
        pgrep.standardError = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return false }
        pgrep.waitUntilExit()
        return pgrep.terminationReason == .exit && pgrep.terminationStatus == 0
    }

    /// Runs `scriptURL` with stdin left OPEN (so it blocks reading stdin with
    /// the payload temp file in place), sends SIGTERM once the payload exists
    /// AND the stdin `head` has started, then closes stdin. Returns the exit
    /// status, whether it was a signal death, and whether the payload was seen
    /// at all.
    ///
    /// Waiting for `head` closes the #29 race: the payload exists from its
    /// `mktemp`, but the traps are set a few lines later, and a TERM landing in
    /// between kills bash with the payload stranded. The stdin `head` starts
    /// only after the traps, so its presence proves they are installed; the
    /// no-traps mutant reaches `head` too, so the canary still runs.
    private func runTerminatedInPayloadWindow(_ scriptURL: URL, home: URL)
        -> (status: Int32, signalled: Bool, sawPayload: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, false, false) }
        do {
            try HookChildStdin.write(Data(#"{"hook_event_name":"Stop","#.utf8), to: stdin.fileHandleForWriting)
        } catch {
            Issue.record("writing the hook's stdin failed: \(error)")
        }
        let deadline = Date().addingTimeInterval(5)
        var sawPayload = false
        while Date() < deadline {
            if !payloadTempFiles(in: markerDir(home)).isEmpty { sawPayload = true; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let headDeadline = Date().addingTimeInterval(5)
        var sawHead = false
        while Date() < headDeadline {
            if hasHeadChild(process.processIdentifier) { sawHead = true; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if !sawHead {
            Issue.record("setup: the hook's stdin `head` never started within 5 s — a TERM now could land before the payload traps are set (#29)")
        }
        process.terminate()
        Thread.sleep(forTimeInterval: 0.2)   // let the signal land while stdin is still open
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return (process.terminationStatus, process.terminationReason == .uncaughtSignal, sawPayload)
    }

    /// A hook TERMed (Claude's timeout) while the payload temp file exists
    /// removes it and still exits 0 — it never resumes the run.
    @Test(.timeLimit(.minutes(1)))
    func aTermInThePayloadWindowRemovesThePayloadAndExitsZero() {
        withHome { home in
            let run = runTerminatedInPayloadWindow(Self.hookScriptURL, home: home)
            #expect(run.sawPayload, "setup: the payload temp file must have existed")
            #expect(!run.signalled && run.status == 0, "TERM must end the hook with exit 0, got \(run)")
            #expect(payloadTempFiles(in: markerDir(home)).isEmpty, "the trap removed the payload")
            #expect(hookLog(home).isEmpty, "the run ended in the trap — it never resumed")
        }
    }

    /// Canary: without the traps a TERM kills bash outright and strands the
    /// payload (only the 60 s sweep would reclaim it) — the test above has teeth.
    @Test(.timeLimit(.minutes(1)))
    func withoutTheTrapsATermStrandsThePayload() throws {
        let original = try Self.read(Self.hookScriptURL)
        let mutant = original
            .replacingOccurrences(of: "  trap 'rm -f \"$payload\" 2>/dev/null' EXIT\n", with: "")
            .replacingOccurrences(of: "  trap 'rm -f \"$payload\" 2>/dev/null; exit 0' TERM INT\n", with: "")
        #expect(mutant != original, "canary setup: the traps must exist")
        withHome { home in
            let mutantURL = home.appendingPathComponent("mutant-busy-hook.sh")
            try? mutant.write(to: mutantURL, atomically: true, encoding: .utf8)
            let run = runTerminatedInPayloadWindow(mutantURL, home: home)
            #expect(run.sawPayload)
            #expect(run.signalled, "without a trap the TERM kills bash")
            #expect(!payloadTempFiles(in: markerDir(home)).isEmpty, "and the payload is stranded")
        }
    }
}
