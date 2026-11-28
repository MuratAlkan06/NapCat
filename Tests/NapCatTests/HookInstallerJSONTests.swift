// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Audit F-7 (issue #103): the hook installer prints the exec-form
/// registrations (eight since hook v9) the user pastes into
/// ~/.claude/settings.json. It used to
/// splice $HOME into that JSON raw, so a quote or backslash in the path broke
/// — or added to — the pasted JSON. Now every path goes through the
/// installer's `json_string`.
///
/// The installer is never run (it installs into the real home). Its JSON
/// pieces — the escaper, the path variables, the command object and the
/// printed block — are extracted verbatim and run in a bare `bash -c` with
/// a synthetic HOME; the output must parse, and carry the paths byte for byte.
struct HookInstallerJSONTests {
    private static var installerURL: URL {
        LidGuardStructureTests.repoRoot().appendingPathComponent("scripts/install-claude-busy-hook.sh")
    }

    private static func lines() throws -> [String] {
        try String(contentsOf: installerURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Lines `from` (an exact line) through the first exact `through` line.
    private static func block(_ all: [String], from: String, through: String) throws -> [String] {
        let start = try #require(all.firstIndex(of: from), "'\(from)' not found in the installer")
        let end = try #require(all[start...].firstIndex(of: through), "'\(through)' not found after '\(from)'")
        return Array(all[start...end])
    }

    private static func line(_ all: [String], prefix: String) throws -> String {
        let matches = all.filter { $0.hasPrefix(prefix) }
        try #require(matches.count == 1, "expected one line starting '\(prefix)', found \(matches.count)")
        return matches[0]
    }

    /// The installer's own JSON-producing text, in order: the escaper, the
    /// two path variables, the guarded escaping + command object, then the
    /// printed registration block.
    private static func jsonSnippet() throws -> String {
        let all = try lines()
        let escaper = try block(all, from: "json_string() {", through: "}")
        let paths = [try line(all, prefix: "HOOK_DIR="), try line(all, prefix: "HOOK_DEST=")]
        let guarded = try block(all, from: #"if ! HOME_ARG_JSON="$(json_string "HOME=$HOME")" || ! HOOK_DEST_JSON="$(json_string "$HOOK_DEST")"; then"#,
                                through: "fi")
        let command = [try line(all, prefix: "EXEC_CMD=")]
        let printed = try block(all, from: "cat <<JSON", through: "JSON")
        return (escaper + paths + guarded + command + printed).joined(separator: "\n")
    }

    private struct Run { let status: Int32; let stdout: String }

    /// Runs in `directory` (a fresh temp dir), so a path that were ever
    /// EXECUTED instead of printed would leave its canary file there.
    private static func run(_ snippet: String, home: String, locale: String = "C",
                            in directory: URL = FileManager.default.temporaryDirectory) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.currentDirectoryURL = directory
        process.arguments = ["-c", snippet]
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin", "LC_ALL": locale]
        let out = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self))
    }

    /// The eight printed `"Event": [ … ],` lines as one JSON object.
    private static func registrations(_ printed: String) throws -> [String: Any] {
        let entries = printed.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("\"") && $0.contains("\"hooks\"") }
        try #require(entries.count == 8, "eight registrations expected, got \(entries.count)")
        let object = "{" + entries.map { $0.hasSuffix(",") ? String($0.dropLast()) : $0 }.joined(separator: ",") + "}"
        let parsed = try JSONSerialization.jsonObject(with: Data(object.utf8))
        return try #require(parsed as? [String: Any], "the printed registrations are not a JSON object")
    }

    private static func args(_ registrations: [String: Any], _ event: String) -> [String]? {
        let entry = (registrations[event] as? [[String: Any]])?.first
        let command = (entry?["hooks"] as? [[String: Any]])?.first
        guard command?["command"] as? String == "/usr/bin/env" else { return nil }
        return command?["args"] as? [String]
    }

    /// The entry's keys and its `matcher`, if any (hook v9: only the two
    /// question tool entries have one).
    private static func entryKeys(_ registrations: [String: Any], _ event: String) -> (keys: Set<String>, matcher: Any?) {
        let entries = registrations[event] as? [[String: Any]] ?? []
        let entry = entries.count == 1 ? entries[0] : [:]
        return (Set(entry.keys), entry["matcher"])
    }

    /// Homes with a quote, a backslash, both, a space, non-ASCII and a
    /// would-be command substitution: the printed JSON parses, all eight
    /// registrations carry exactly `-i`, `HOME=<home>`, `/bin/bash`,
    /// `<home>/.claude/hooks/napcat-busy-hook.sh` — and nothing was run.
    /// The two question tool entries alone carry `"matcher":
    /// "AskUserQuestion"`; the Notification entry has no matcher.
    @Test func thePrintedRegistrationsAreValidJSONForAnyHome() throws {
        let snippet = try Self.jsonSnippet()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("napcat-f7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let homes = ["/Users/plain", "/Users/o\"brien", "/Users/back\\slash", "/Users/both\\\"x\",\"y",
                     "/Users/with space", "/Users/ünïcödé", "/Users/$(touch napcat-f7-canary)", "/Users/`id`"]
        for locale in ["C", "en_US.UTF-8"] {
            for home in homes {
                let result = try Self.run(snippet, home: home, locale: locale, in: scratch)
                #expect(result.status == 0, "\(locale) \(home): status \(result.status)")
                let registrations = try Self.registrations(result.stdout)
                #expect(Set(registrations.keys) == Set(ClaudeBusyConstants.allEvents))
                for event in ClaudeBusyConstants.allEvents {
                    #expect(Self.args(registrations, event)
                            == ["-i", "HOME=" + home, "/bin/bash", home + "/" + ClaudeBusyConstants.installedHookRelativePath],
                            "\(locale) \(home): \(event) does not carry the paths byte for byte")
                    let entry = Self.entryKeys(registrations, event)
                    if ClaudeBusyConstants.questionToolEvents.contains(event) {
                        #expect(entry.keys == ["matcher", "hooks"]
                                && entry.matcher as? String == ClaudeBusyConstants.questionToolName,
                                "\(locale) \(home): \(event) must be matched to the question tool, got \(entry.keys)")
                    } else {
                        #expect(entry.keys == ["hooks"] && entry.matcher == nil,
                                "\(locale) \(home): \(event) must carry no matcher, got \(entry.keys)")
                    }
                }
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty,
                "a path was executed, not printed")
    }

    /// A home with a control character gets no registration at all — the
    /// installer refuses before printing (or installing) anything.
    @Test func aControlCharacterInHomeIsRefused() throws {
        let snippet = try Self.jsonSnippet()
        for home in ["/Users/new\nline", "/Users/tab\there", "/Users/cr\rhere", "/Users/del\u{7F}"] {
            let result = try Self.run(snippet, home: home)
            #expect(result.status == 1, "\(String(reflecting: home)) was not refused")
            #expect(!result.stdout.contains("\"hooks\""), "\(String(reflecting: home)): a registration was printed")
        }
    }

    /// Structure: the escaper runs before the first install step, the command
    /// object takes the escaped values only, and $HOME / $HOOK_DEST never
    /// appear raw inside it. Canary: the audited raw splice is caught.
    @Test func theCommandObjectSplicesOnlyEscapedValues() throws {
        let all = try Self.lines()
        let command = try Self.line(all, prefix: "EXEC_CMD=")
        #expect(Self.rawSpliceFailures(command).isEmpty, "\(Self.rawSpliceFailures(command))")
        let guarded = try #require(all.firstIndex { $0.hasPrefix("if ! HOME_ARG_JSON=") })
        let firstInstall = try #require(all.firstIndex { $0.hasPrefix("mkdir -p \"$HOOK_DIR\"") })
        #expect(guarded < firstInstall, "the paths must be escaped (and refused) before anything is installed")

        let audited = #"EXEC_CMD='{"type":"command","command":"/usr/bin/env","args":["-i","HOME='"$HOME"'","/bin/bash","'"$HOOK_DEST"'"],"timeout":5}'"#
        #expect(!Self.rawSpliceFailures(audited).isEmpty, "canary: the audited raw splice must be caught")
    }

    static func rawSpliceFailures(_ command: String) -> [String] {
        var failures: [String] = []
        for raw in [#"'"$HOME"'"#, #"'"$HOOK_DEST"'"#] where command.contains(raw) {
            failures.append("EXEC_CMD splices \(raw) into the JSON unescaped")
        }
        for escaped in [#"'"$HOME_ARG_JSON"'"#, #"'"$HOOK_DEST_JSON"'"#] where !command.contains(escaped) {
            failures.append("EXEC_CMD must splice \(escaped)")
        }
        return failures
    }
}
