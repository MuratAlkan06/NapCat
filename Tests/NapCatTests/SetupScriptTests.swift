// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Locks the USER-RUN, root-run installer scripts to the app's closed
/// privileged surface (pre-publication security audit, findings F1 + F2,
/// 2026-10-19). Neither script is ever EXECUTED here — both are strictly
/// user-run, as root. Every rule is a pure lint over the script TEXT, read at
/// test time, so each one is canary-proven in-suite against mutated copies
/// (the ClaudeBusyHookScriptTests pattern).
///
/// F1 — PrivilegedCommandTests pins the enum to literals retyped in that test,
/// but nothing read scripts/setup.sh, the file that actually writes
/// /etc/sudoers.d/napcat: a PR could widen an entry to `smc -k * -w *` and the
/// suite stayed green. Now the sudoers heredoc and the failsafe LaunchAgent's
/// ProgramArguments are parsed out of the script and must byte-match
/// `PrivilegedCommand` (per architecture branch, no wildcards).
///
/// F2 — root must never write through a path the invoking user controls: the
/// symlink refusal and the `sudo -u` home writes in setup.sh (and the matching
/// guard in uninstall.sh) are lint-locked.
struct SetupScriptTests {
    // MARK: Paths + text helpers

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)  // Tests/NapCatTests/<this file>
            .deletingLastPathComponent() // Tests/NapCatTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }
    private static var setupURL: URL { repoRoot().appendingPathComponent("scripts/setup.sh") }
    private static var uninstallURL: URL { repoRoot().appendingPathComponent("scripts/uninstall.sh") }

    private static func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private static func lines(_ script: String) -> [String] {
        script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Executable lines: trimmed, non-blank, not a full-line shell comment.
    /// Heredoc bodies are included; no rule that uses this matches them.
    private static func codeLines(_ script: String) -> [String] {
        lines(script)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func matches(_ line: String, _ pattern: String) -> Bool {
        line.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - F1: the sudoers entries

    /// The exact user spec every entry carries: the invoking user, run as root
    /// ONLY, no password. Any other sudoers line in the heredoc is a failure.
    static let entryPrefix = "$TARGET_USER ALL=(root) NOPASSWD: "

    /// Granted on every Mac, Intel included: stay awake.
    static let everyMacCommands: Set<PrivilegedCommand> = [.stayAwakeOn, .stayAwakeOff]
    /// Granted only inside the `IS_ARM64` branch: charge limiting.
    static let appleSiliconOnlyCommands: Set<PrivilegedCommand> = [
        .chargingDisableCH0B, .chargingDisableCH0C, .chargingDisableCHTE,
        .chargingEnableCH0B, .chargingEnableCH0C, .chargingEnableCHTE,
    ]

    /// Sudoers wildcard, negation, list separator and the ALL alias, plus the
    /// glob/regex/escape/quote characters: any of them widens (or empties) an
    /// exact-argument entry, so none may appear in a granted command part.
    static let forbiddenCommandTokens = ["*", "ALL", "!", ",", "?", "[", "]", "\\", "^", "$", "\""]

    /// The only line outside the heredoc allowed to mention `NOPASSWD:` — the
    /// closing summary, which READS the installed file and writes nothing.
    static let sudoersSummaryLine = #"grep "^$TARGET_USER" "$SUDOERS_FILE" | sed -e "s/^$TARGET_USER ALL=(root) NOPASSWD: /    /""#

    /// What the sudoers block of a setup.sh text grants, per branch, plus
    /// every violation found while parsing it.
    struct SudoersGrant {
        var everyMac: [PrivilegedCommand] = []
        var appleSiliconOnly: [PrivilegedCommand] = []
        var blockLines: ClosedRange<Int>?
        var failures: [String] = []
    }

    static func parseSudoersGrant(_ script: String) -> SudoersGrant {
        var grant = SudoersGrant()
        let all = lines(script)
        let trimmed = all.map { $0.trimmingCharacters(in: .whitespaces) }

        // The ONE block that generates the sudoers file: `{ … } > "$TMP"`.
        guard let end = trimmed.firstIndex(of: #"} > "$TMP""#),
              let start = trimmed[..<end].lastIndex(of: "{") else {
            grant.failures.append(#"sudoers block `{ … } > "$TMP"` not found (the lock would be vacuous)"#)
            return grant
        }
        grant.blockLines = start...end

        let commandByLine = Dictionary(
            PrivilegedCommand.allCases.map { ($0.argv.joined(separator: " "), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var inHeredoc = false
        var inArm64 = false
        var sawArm64Branch = false
        for index in (start + 1)..<end {
            let raw = all[index]
            if inHeredoc {
                if raw == "EOF" { inHeredoc = false; continue }
                // The heredoc is UNQUOTED: a `$(…)` or backtick anywhere in it
                // (comments included) would run as root while the file is
                // generated. The one expansion allowed is the entry prefix.
                let afterUser = raw.hasPrefix("$TARGET_USER ") ? String(raw.dropFirst("$TARGET_USER".count)) : raw
                if afterUser.contains("$") || afterUser.contains("`") {
                    grant.failures.append("shell expansion in the sudoers heredoc: '\(raw)'")
                }
                if raw.hasSuffix("\\") {
                    grant.failures.append("line continuation in the sudoers heredoc: '\(raw)'")
                }
                // Blank lines and plain `# ` comments only. `#include`,
                // `#includedir` and `#<uid> …` are sudoers DIRECTIVES/RULES,
                // not comments — they fall through and fail as non-entries.
                if raw.isEmpty || raw.hasPrefix("# ") { continue }
                guard raw.hasPrefix(Self.entryPrefix) else {
                    grant.failures.append("not a canonical '\(Self.entryPrefix)<command>' entry: '\(raw)'")
                    continue
                }
                let command = String(raw.dropFirst(Self.entryPrefix.count))
                for part in command.split(separator: " ", omittingEmptySubsequences: false) {
                    for token in Self.forbiddenCommandTokens where part.contains(token) {
                        grant.failures.append("forbidden '\(token)' in granted command '\(command)'")
                    }
                }
                guard let granted = commandByLine[command] else {
                    grant.failures.append("granted command is not a PrivilegedCommand argv: '\(command)'")
                    continue
                }
                if inArm64 { grant.appleSiliconOnly.append(granted) } else { grant.everyMac.append(granted) }
                continue
            }
            // Outside a heredoc the block may hold only its known skeleton.
            switch trimmed[index] {
            case "cat <<EOF":
                inHeredoc = true
            case #"if [ "$IS_ARM64" = "1" ]; then"#:
                if inArm64 || sawArm64Branch { grant.failures.append("more than one IS_ARM64 branch in the sudoers block") }
                inArm64 = true
                sawArm64Branch = true
            case "fi":
                if !inArm64 { grant.failures.append("unbalanced 'fi' in the sudoers block") }
                inArm64 = false
            default:
                grant.failures.append("unexpected code in the sudoers block: '\(trimmed[index])'")
            }
        }
        if inHeredoc { grant.failures.append("unterminated heredoc in the sudoers block") }
        if !sawArm64Branch { grant.failures.append("no IS_ARM64 branch in the sudoers block (the per-arch lock would be vacuous)") }
        return grant
    }

    /// Every violation of the sudoers lock in a setup.sh text; empty == locked.
    static func sudoersLintFailures(_ script: String) -> [String] {
        let grant = parseSudoersGrant(script)
        var failures = grant.failures
        guard let block = grant.blockLines else { return failures }

        // Per architecture branch: exactly the expected set, no duplicates.
        if grant.everyMac.count != everyMacCommands.count || Set(grant.everyMac) != everyMacCommands {
            failures.append("every-Mac (Intel) entries \(grant.everyMac) != the \(everyMacCommands.count) stay-awake commands")
        }
        if grant.appleSiliconOnly.count != appleSiliconOnlyCommands.count
            || Set(grant.appleSiliconOnly) != appleSiliconOnlyCommands {
            failures.append("IS_ARM64 entries \(grant.appleSiliconOnly) != the \(appleSiliconOnlyCommands.count) charge-control commands")
        }

        let all = lines(script)
        for index in all.indices where !block.contains(index) {
            let line = all[index].trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            // No passwordless grant may be written from anywhere else.
            if line.contains("NOPASSWD:") && line != sudoersSummaryLine {
                failures.append("NOPASSWD: outside the sudoers heredoc: '\(line)'")
            }
        }
        let code = codeLines(script)
        // One sudoers destination, defined once…
        let sudoersPaths = code.filter { $0.contains("/etc/sudoers") }
        if sudoersPaths != [#"SUDOERS_FILE="/etc/sudoers.d/napcat""#] {
            failures.append("sudoers paths in code must be exactly the SUDOERS_FILE definition: \(sudoersPaths)")
        }
        // …installed from $TMP, which only the parsed block writes.
        let tmpWrites = code.filter { matches($0, #">>?[ \t]*"\$TMP""#) }
        if tmpWrites != [#"} > "$TMP""#] {
            failures.append(#"$TMP must be written only by the parsed block: "# + "\(tmpWrites)")
        }
        let sudoersInstalls = code.filter { $0.contains("install") && $0.contains(#""$SUDOERS_FILE""#) }
        if sudoersInstalls != [#"/usr/bin/install -m 0440 -o root -g wheel "$TMP" "$SUDOERS_FILE""#] {
            failures.append("the sudoers file must be installed from $TMP, 0440 root:wheel, once: \(sudoersInstalls)")
        }
        return failures
    }

    @Test func setupGrantsExactlyThePrivilegedCommandSetPerArchitecture() throws {
        let script = try Self.read(Self.setupURL)
        try #require(script.contains("USER-RUN ONLY, as root:   sudo ./scripts/setup.sh"))  // path-drift guard

        let failures = Self.sudoersLintFailures(script)
        #expect(failures.isEmpty, "setup.sh sudoers lock violations: \(failures)")

        // Intel: the two stay-awake entries only. Apple Silicon: those plus the
        // six charge-control entries — eight, the whole closed enum.
        let grant = Self.parseSudoersGrant(script)
        #expect(grant.everyMac.count == 2)
        #expect(grant.everyMac.count + grant.appleSiliconOnly.count == 8)
        #expect(Set(grant.everyMac + grant.appleSiliconOnly) == Set(PrivilegedCommand.allCases))

        // The partition this lock checks against must cover the enum exactly —
        // a new case fails here until it is deliberately placed in a branch.
        #expect(Self.everyMacCommands.isDisjoint(with: Self.appleSiliconOnlyCommands))
        #expect(Self.everyMacCommands.union(Self.appleSiliconOnlyCommands) == Set(PrivilegedCommand.allCases))

        // The granted argv strings themselves carry no sudoers wildcard.
        for command in PrivilegedCommand.allCases {
            for part in command.argv {
                for token in Self.forbiddenCommandTokens {
                    #expect(!part.contains(token), "\(command) argv part '\(part)' contains '\(token)'")
                }
            }
        }
    }

    /// Canary: every way of widening the grant must trip the lock — including
    /// the audit's own example, `smc -k * -w *`.
    @Test func sudoersLockCatchesWideningMutants() throws {
        let original = try Self.read(Self.setupURL)
        try #require(Self.sudoersLintFailures(original).isEmpty, "canary baseline must be clean")

        let pmsetOn = "NOPASSWD: /usr/bin/pmset -a disablesleep 1\n"
        let pmsetOff = "NOPASSWD: /usr/bin/pmset -a disablesleep 0\n"
        let ch0bDisable = "$TARGET_USER ALL=(root) NOPASSWD: /usr/local/napcat/smc -k CH0B -w 02\n"
        let mutants: [(String, String, String)] = [
            ("wildcard smc write (audit example)",
             "smc -k CHTE -w 00000000", "smc -k * -w *"),
            ("extra command appended to an entry",
             pmsetOn, "NOPASSWD: /usr/bin/pmset -a disablesleep 1, /bin/sh\n"),
            ("runas widened to ALL",
             "ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1", "ALL=(ALL) NOPASSWD: /usr/bin/pmset -a disablesleep 1"),
            ("blanket NOPASSWD: ALL rule added",
             pmsetOff, pmsetOff + "$TARGET_USER ALL=(root) NOPASSWD: ALL\n"),
            ("#includedir directive disguised as a comment",
             pmsetOff, pmsetOff + "#includedir /tmp/napcat\n"),
            ("#uid rule disguised as a comment",
             pmsetOff, pmsetOff + "#0 ALL=(ALL) NOPASSWD: ALL\n"),
            ("command substitution in a heredoc comment",
             "# Remove with: sudo ./scripts/uninstall.sh\n", "# Remove with: $(touch /tmp/napcat-pwn)\n"),
            ("negated (any-but) entry",
             "/usr/bin/pmset -a disablesleep 0\nEOF", "!/usr/bin/pmset -a disablesleep 0\nEOF"),
            ("duplicate entry",
             pmsetOn, pmsetOn + "$TARGET_USER ALL=(root) " + pmsetOn),
            ("charge-control entry moved into the Intel (every-Mac) branch",
             pmsetOff + "EOF", pmsetOff + ch0bDisable + "EOF"),
            ("NOPASSWD grant written outside the heredoc",
             #"if ! /usr/sbin/visudo -cf "$TMP"; then"#,
             #"echo "$TARGET_USER ALL=(root) NOPASSWD: /bin/sh" >> "$TMP""# + "\n" + #"if ! /usr/sbin/visudo -cf "$TMP"; then"#),
            ("second sudoers file",
             #"SMC_DIR="/usr/local/napcat""#, #"EXTRA_SUDOERS="/etc/sudoers.d/napcat-extra""# + "\n" + #"SMC_DIR="/usr/local/napcat""#),
        ]
        for (name, target, replacement) in mutants {
            let mutant = original.replacingOccurrences(of: target, with: replacement)
            #expect(mutant != original, "canary setup '\(name)': target text must exist")
            #expect(!Self.sudoersLintFailures(mutant).isEmpty, "canary '\(name)' was NOT caught by the sudoers lock")
        }

        // A MOVED entry (no duplicate; every line still a valid argv) passes
        // exact matching — pin that the per-branch rule is what catches it.
        let moved = original.replacingOccurrences(of: ch0bDisable, with: "")
            .replacingOccurrences(of: pmsetOff + "EOF", with: pmsetOff + ch0bDisable + "EOF")
        let movedFailures = Self.sudoersLintFailures(moved)
        #expect(movedFailures.contains { $0.contains("every-Mac") } && movedFailures.contains { $0.contains("IS_ARM64 entries") },
                "a charge-control entry moved to the Intel branch must fail the per-architecture rule: \(movedFailures)")
    }

    // MARK: - F1: the failsafe LaunchAgent

    static let agentHeredocOpener = #"cat > "$TMP_AGENT" <<EOF"#

    /// Every violation of the LaunchAgent lock in a setup.sh text; empty == locked.
    static func failsafeAgentLintFailures(_ script: String) -> [String] {
        var failures: [String] = []
        let all = lines(script)
        let openers = all.indices.filter { all[$0].trimmingCharacters(in: .whitespaces) == agentHeredocOpener }
        guard openers.count == 1, let open = openers.first,
              let close = all[(open + 1)...].firstIndex(of: "EOF") else {
            return ["exactly one `\(agentHeredocOpener)` … `EOF` heredoc expected (the lock would be vacuous)"]
        }
        let body = all[(open + 1)..<close]
        if body.contains(where: { $0.contains("$") || $0.contains("`") }) {
            failures.append("shell expansion inside the UNQUOTED agent heredoc (it would run as root at generation time)")
        }
        let data = Data(body.joined(separator: "\n").utf8)
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return failures + ["the agent heredoc is not a property-list dictionary"]
        }
        // No `Program`, no extra triggers or environment — just the one-shot.
        if Set(plist.keys) != ["Label", "ProgramArguments", "RunAtLoad"] {
            failures.append("agent keys \(plist.keys.sorted()) != exactly Label, ProgramArguments, RunAtLoad")
        }
        if plist["Label"] as? String != "com.napcat.failsafe" {
            failures.append("agent Label is not com.napcat.failsafe")
        }
        let arguments = plist["ProgramArguments"] as? [String]
        if arguments != PrivilegedCommand.stayAwakeOff.sudoArgv {
            failures.append("agent ProgramArguments \(arguments ?? []) != \(PrivilegedCommand.stayAwakeOff.sudoArgv)")
        }
        if plist["RunAtLoad"] as? Bool != true {
            failures.append("agent RunAtLoad is not true")
        }
        // The file installed is the file linted: only this heredoc writes it.
        let redirects = codeLines(script).filter { matches($0, #">>?[ \t]*"\$TMP_AGENT""#) }
        if redirects != [agentHeredocOpener] {
            failures.append(#"$TMP_AGENT must be written only by the linted heredoc: "# + "\(redirects)")
        }
        return failures
    }

    @Test func failsafeAgentRunsExactlyTheStayAwakeOffRevert() throws {
        let failures = Self.failsafeAgentLintFailures(try Self.read(Self.setupURL))
        #expect(failures.isEmpty, "setup.sh LaunchAgent lock violations: \(failures)")
        // Spelled out once: the agent's argv is the non-interactive revert.
        #expect(PrivilegedCommand.stayAwakeOff.sudoArgv
                == ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "0"])
    }

    /// Canary: the LaunchAgent lock must catch a changed revert, a dropped
    /// `-n`, an injected `Program`, shell expansion, and a second writer.
    @Test func failsafeAgentLockCatchesWideningMutants() throws {
        let original = try Self.read(Self.setupURL)
        try #require(Self.failsafeAgentLintFailures(original).isEmpty, "canary baseline must be clean")

        let mutants: [(String, String, String)] = [
            ("revert flipped to stay-awake ON at every login",
             "\t\t<string>0</string>\n", "\t\t<string>1</string>\n"),
            ("non-interactive -n dropped",
             "\t\t<string>-n</string>\n", ""),
            ("Program key injected",
             "<dict>\n", "<dict>\n\t<key>Program</key>\n\t<string>/bin/sh</string>\n"),
            ("command substitution in the plist heredoc",
             "<dict>\n", "<dict>\n<!-- $(id) -->\n"),
            ("second writer appends to the linted file",
             #"if ! /usr/bin/plutil -lint -s "$TMP_AGENT"; then"#,
             #"echo "<!-- -->" >> "$TMP_AGENT""# + "\n" + #"if ! /usr/bin/plutil -lint -s "$TMP_AGENT"; then"#),
        ]
        for (name, target, replacement) in mutants {
            let mutant = original.replacingOccurrences(of: target, with: replacement)
            #expect(mutant != original, "canary setup '\(name)': target text must exist")
            #expect(!Self.failsafeAgentLintFailures(mutant).isEmpty, "canary '\(name)' was NOT caught by the LaunchAgent lock")
        }
    }

    // MARK: - F2: root never writes through the user's home

    /// The prefix every write under the invoking user's home must carry.
    static let asUser = #"/usr/bin/sudo -u "$TARGET_USER" "#

    /// A line that creates, copies, moves, links, removes or re-owns a file.
    private static func mutatesFiles(_ line: String) -> Bool {
        matches(line, #"(^|[ /;&|(])(install|mkdir|cp|mv|ln|rm|tee|touch|ditto|chown|chgrp|chmod)( |$)"#)
            || matches(line, #">>?[ \t]*"?\$(TARGET_HOME|AGENT_DIR|AGENT_FILE|DEFAULTS_PLIST)"#)
    }

    /// User-facing messages name paths and fix-up commands; they write nothing.
    private static func isMessage(_ line: String) -> Bool {
        line.hasPrefix("echo ") || line.hasPrefix("FAILURES+=") || line.hasPrefix("REVERTED+=")
    }

    private static func touchesUserHome(_ line: String) -> Bool {
        ["$TARGET_HOME", "$AGENT_DIR", "$AGENT_FILE", "$DEFAULTS_PLIST"].contains { line.contains($0) }
    }

    /// Every F2 violation across both scripts; empty == locked.
    static func homeWriteLintFailures(setup: String, uninstall: String) -> [String] {
        var failures: [String] = []

        // --- setup.sh ---
        let code = codeLines(setup)
        // 1. The symlink refusal exists and really exits nonzero…
        if let start = code.firstIndex(of: "refuse_symlink() {"),
           let end = code[start...].firstIndex(of: "}") {
            let body = Array(code[start...end])
            if !body.contains(#"if [ -L "$1" ]; then"#) || !body.contains("exit 1") {
                failures.append("refuse_symlink must test `[ -L \"$1\" ]` and `exit 1`")
            }
        } else {
            failures.append("refuse_symlink() is missing from setup.sh")
        }
        // 2. …and is applied to ~/Library and ~/Library/LaunchAgents BEFORE the
        //    first write of any kind (temp files included).
        let firstWrite = code.firstIndex { !isMessage($0) && (mutatesFiles($0) || $0.contains("mktemp")) } ?? code.endIndex
        for path in [#""$TARGET_HOME/Library""#, #""$AGENT_DIR""#] {
            if let call = code.firstIndex(of: "refuse_symlink \(path)") {
                if call >= firstWrite {
                    failures.append("refuse_symlink \(path) runs after the first write ('\(code[firstWrite])')")
                }
            } else {
                failures.append("setup.sh never refuses a symlinked \(path)")
            }
        }
        // 3. Root never creates a file owned by the user on their behalf.
        for line in code where line.contains(#"-o "$TARGET_USER""#) {
            failures.append("root-run write chowned to the user: '\(line)'")
        }
        // 4. Every write under the user's home runs AS the user.
        for line in code where touchesUserHome(line) && !isMessage(line) && mutatesFiles(line) && !line.contains(asUser) {
            failures.append("setup.sh writes under the user's home as root: '\(line)'")
        }
        // Non-vacuity: the two LaunchAgent writes exist, as the user.
        if !code.contains(where: { $0.hasPrefix(asUser) && $0.contains("install -d") && $0.hasSuffix(#""$AGENT_DIR""#) }) {
            failures.append("setup.sh must create $AGENT_DIR via `sudo -u \"$TARGET_USER\" … install -d`")
        }
        if !code.contains(where: { $0.hasPrefix(asUser) && $0.contains("install") && $0.hasSuffix(#""$TMP_AGENT" "$AGENT_FILE""#) }) {
            failures.append("setup.sh must install the agent plist via `sudo -u \"$TARGET_USER\" … install`")
        }

        // --- uninstall.sh (error-collecting; same boundary) ---
        let uninstallCode = codeLines(uninstall)
        for line in uninstallCode where touchesUserHome(line) && !isMessage(line) && mutatesFiles(line) && !line.contains(asUser) {
            failures.append("uninstall.sh writes under the user's home as root: '\(line)'")
        }
        let agentRemoval = uninstallCode.firstIndex { $0.contains(asUser + #"/bin/rm -f "$AGENT_FILE""#) }
        let plistRemoval = uninstallCode.firstIndex { $0.contains(asUser + #"/bin/rm -f "$DEFAULTS_PLIST""#) }
        if agentRemoval == nil { failures.append("uninstall.sh must remove $AGENT_FILE as the user") }
        if plistRemoval == nil { failures.append("uninstall.sh must remove $DEFAULTS_PLIST as the user") }
        let guardLine = uninstallCode.firstIndex {
            $0.contains(#"[ -L "$TARGET_HOME/Library" ]"#) && $0.contains(#"[ -L "$AGENT_DIR" ]"#)
        }
        if let guardLine, let agentRemoval {
            if guardLine >= agentRemoval { failures.append("uninstall.sh checks for symlinks only after removing the agent") }
        } else {
            failures.append("uninstall.sh never refuses a symlinked ~/Library or ~/Library/LaunchAgents")
        }
        return failures
    }

    @Test func rootNeverWritesThroughTheUsersHome() throws {
        let failures = Self.homeWriteLintFailures(
            setup: try Self.read(Self.setupURL),
            uninstall: try Self.read(Self.uninstallURL)
        )
        #expect(failures.isEmpty, "F2 home-write lock violations: \(failures)")
    }

    /// Canary: reverting to the audited root-run write, dropping or neutering
    /// the symlink refusal, running it too late, or deleting as root in
    /// uninstall.sh must each trip the lock.
    @Test func homeWriteLockCatchesRegressionMutants() throws {
        let setup = try Self.read(Self.setupURL)
        let uninstall = try Self.read(Self.uninstallURL)
        try #require(Self.homeWriteLintFailures(setup: setup, uninstall: uninstall).isEmpty, "canary baseline must be clean")

        let libraryRefusal = #"refuse_symlink "$TARGET_HOME/Library""# + "\n"
        let firstTempFile = #"TMP="$(mktemp)""# + "\n"  // after the smc installs
        let setupMutants: [(String, (String) -> String)] = [
            ("audited root-run install -d -o USER restored", {
                $0.replacingOccurrences(
                    of: #"/usr/bin/sudo -u "$TARGET_USER" /usr/bin/install -d -m 755 -g "$TARGET_GROUP" "$AGENT_DIR""#,
                    with: #"/usr/bin/install -d -m 755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$AGENT_DIR""#)
            }),
            ("plist installed by root", {
                $0.replacingOccurrences(of: #"/usr/bin/sudo -u "$TARGET_USER" /usr/bin/install -m 0644"#,
                                        with: "/usr/bin/install -m 0644")
            }),
            ("LaunchAgents symlink refusal dropped", {
                $0.replacingOccurrences(of: #"refuse_symlink "$AGENT_DIR""# + "\n", with: "")
            }),
            ("symlink test neutered", {
                $0.replacingOccurrences(of: #"if [ -L "$1" ]; then"#, with: "if false; then")
            }),
            ("~/Library refusal moved after the first write", {
                $0.replacingOccurrences(of: libraryRefusal, with: "")
                    .replacingOccurrences(of: firstTempFile, with: libraryRefusal + firstTempFile)
            }),
        ]
        for (name, transform) in setupMutants {
            let mutant = transform(setup)
            #expect(mutant != setup, "canary setup '\(name)': target text must exist")
            #expect(!Self.homeWriteLintFailures(setup: mutant, uninstall: uninstall).isEmpty,
                    "canary '\(name)' was NOT caught by the F2 lock")
        }

        let uninstallMutants: [(String, String, String)] = [
            ("agent removed as root",
             #"/usr/bin/sudo -u "$TARGET_USER" /bin/rm -f "$AGENT_FILE""#, #"rm -f "$AGENT_FILE""#),
            ("defaults plist removed as root",
             #"/usr/bin/sudo -u "$TARGET_USER" /bin/rm -f "$DEFAULTS_PLIST""#, #"rm -f "$DEFAULTS_PLIST""#),
            ("symlink guard dropped",
             #"{ [ -L "$TARGET_HOME/Library" ] || [ -L "$AGENT_DIR" ]; }"#, "false"),
        ]
        for (name, target, replacement) in uninstallMutants {
            let mutant = uninstall.replacingOccurrences(of: target, with: replacement)
            #expect(mutant != uninstall, "canary setup '\(name)': target text must exist")
            #expect(!Self.homeWriteLintFailures(setup: setup, uninstall: mutant).isEmpty,
                    "canary '\(name)' was NOT caught by the F2 lock")
        }
    }
}
