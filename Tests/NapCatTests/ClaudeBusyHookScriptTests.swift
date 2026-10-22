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
            let pattern = "^v1 ts=[0-9]+ event=UserPromptSubmit pid=[0-9]+ src=unknown\n$"
            #expect(contents.range(of: pattern, options: .regularExpression) != nil,
                    "marker content \(String(reflecting: contents)) must match the v1 grammar with src=unknown")
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
                let pattern = "^v1 ts=[0-9]+ event=\(token) pid=[0-9]+ src=unknown\n$"
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
                let pattern = "^v1 ts=[0-9]+ event=Notification pid=[0-9]+ src=unknown\n$"
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

    /// Canary (H2): drop the NUL mapping and the poisoned value collapses into
    /// permission_prompt again — the marker is KEPT as waiting. Proves the
    /// NUL rows above have teeth (bash 3.2 really does drop the byte).
    @Test func nulMappingCanary() throws {
        let original = try Self.read(Self.hookScriptURL)
        let mapping = " | LC_ALL=C /usr/bin/tr '\\000' '#'"
        let mutant = original.replacingOccurrences(of: mapping, with: "")
        #expect(mutant != original, "canary setup: the NUL mapping must exist to be removed")

        withHome { home in
            let session = "c1000009-0029-4abc-8def-000000000029"
            let mutantURL = home.appendingPathComponent("mutant-busy-hook.sh")
            try? mutant.write(to: mutantURL, atomically: true, encoding: .utf8)
            _ = runScript(mutantURL, json: promptJSON(session), home: home)
            let marker = markerDir(home).appendingPathComponent(session)
            #expect(waitForFile(marker, present: true), "canary setup: marker must be set first")

            let poisoned = notificationJSON(session, notificationType: #""permission\u0000_prompt""#)
            _ = runScript(mutantURL, json: poisoned, home: home)
            let token = ClaudeBusyConstants.waitingEventToken
            #expect(waitForMarkerEvent(marker, event: token).contains("event=\(token) "),
                    "without the NUL mapping the poisoned type must pass as waiting (so the H2 rows have teeth)")
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
            let pattern = "^v1 ts=[0-9]+ event=Notification pid=[0-9]+ src=unknown\n$"
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
        let read = "  head -c \"$MAX_STDIN\" >\"$payload\" 2>/dev/null\n"
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

    /// Runs `scriptURL` with stdin left OPEN (so it blocks reading stdin with
    /// the payload temp file in place), sends SIGTERM once the payload exists,
    /// then closes stdin. Returns the exit status, whether it was a signal
    /// death, and whether the payload was seen at all.
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
        stdin.fileHandleForWriting.write(Data(#"{"hook_event_name":"Stop","#.utf8))
        let deadline = Date().addingTimeInterval(5)
        var sawPayload = false
        while Date() < deadline {
            if !payloadTempFiles(in: markerDir(home)).isEmpty { sawPayload = true; break }
            Thread.sleep(forTimeInterval: 0.02)
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
        #expect(ClaudeBusyConstants.hookVersion == 4, "the contract value of this slice")
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
        // Marker grammar: version + each token prefix, and the full printf.
        #expect(script.contains("v1 ts=%s event=%s pid=%s src=%s"))
        #expect(script.contains(ClaudeBusyConstants.markerVersion))
        for prefix in ClaudeBusyConstants.markerTokenPrefixes {
            #expect(script.contains(prefix), "grammar token '\(prefix)' missing from the shell script")
        }
        // The six registered event names.
        for event in ClaudeBusyConstants.allEvents {
            #expect(script.contains(event), "event '\(event)' missing from the shell script")
        }
        // 12h cap.
        #expect(script.contains("CAP=\(ClaudeBusyConstants.freshnessCapSeconds)"))
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
    /// the `SessionEnd` prior (POST-STOP, rows E1–E8).
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
            (.idlePrompt, false, nil, .clear),
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
            (.idlePrompt, false, nil, .clear),
            (.idlePrompt, true, "Stop", .keep(bgKeep)),
        ])
        all += rows("A", "SubagentStop", [
            (.subagentStop, false, nil, .clear),
            (.subagentStop, true, "SubagentStop", .keep(bgKeep)),
            (.permissionPrompt, false, was, .keep(wait)),
            (.permissionPrompt, true, was, .keep(wait)),
            (.quotaAutoResumeFired, false, "Stop", .keep(resume)),
            (.quotaAutoResumeFired, true, "Stop", .keep(resume)),
            (.idlePrompt, false, nil, .clear),
            (.idlePrompt, true, "Stop", .keep(bgKeep)),
        ])
        all += rows("P", was, [
            (.subagentStop, false, nil, .clear),
            (.subagentStop, true, "SubagentStop", .keep(bgKeep)),
            (.permissionPrompt, false, was, .keep(wait)),
            (.permissionPrompt, true, was, .keep(wait)),
            (.quotaAutoResumeFired, false, "Stop", .keep(resume)),
            (.quotaAutoResumeFired, true, "Stop", .keep(resume)),
            (.idlePrompt, false, nil, .clear),
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

    /// Polls until the marker holds a hook-written (`src=unknown`) line with
    /// `event=<token>`; returns the last content seen.
    private func waitForRewrite(_ url: URL, event token: String, timeout: Double = 3) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let c = try? String(contentsOf: url, encoding: .utf8),
               c.contains("event=\(token) "), c.hasSuffix(" src=unknown\n") { return c }
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
            let result = runHook(json: phaseEventJSON(row.event, session, bg: row.bg), home: home)
            #expect(result.exitCode == 0)
            #expect(result.stdout.isEmpty)

            if let expected = row.result {
                let contents = waitForRewrite(marker, event: expected)
                let pattern = "^v1 ts=[0-9]+ event=\(expected) pid=[0-9]+ src=unknown\n$"
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
