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
                    "keep session=\(session) event=Notification type=\(notificationType) reason=waiting-on-user pid="),
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
                    "keep session=\(session) event=Notification type=\(notificationType) reason=work-continues pid="),
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
            // (A JSON null never reaches C1: plist has no null, so the whole
            // payload fails the pre-existing stdin JSON gate and is ignored.)
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
                #expect(hookLog(home).contains("clear session=\(session) event=Notification type=\(logged)\n"),
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
                #expect(log.contains("clear session=\(session) event=Notification type=invalid\n"),
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
            #expect(hookLog(home).contains("clear session=\(session) event=Notification type=invalid\n"))

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
            #expect(log.contains("type=permission_prompt reason=waiting-on-user"))
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
                "keep session=\(session) event=Notification type=idle_prompt reason=background-task-running pid="))

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
        #expect(!(ClaudeBusyConstants.allEvents + ["SubagentStop"]).contains(token),
                "the synthetic token must not collide with a real hook event name")
        #expect(ClaudeActivityPolicy.parseMarker("v1 ts=1 event=\(token) pid=1 src=unknown\n")?.event == token)
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
