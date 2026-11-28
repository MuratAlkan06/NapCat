// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat
@testable import NapCatWire

/// F4 slice S0: the Mac-side category gate (`ApprovalGate`). Table-driven
/// from both sides: every forbidden family and every row of every table is
/// exercised, the Bash grammar is run against a catalogue of shell bypass
/// classes (chaining, substitution, redirection, quoting, globbing, wrappers,
/// exec-capable options, encoding tricks), Bash forwards only an exact listed
/// command (slice S-GATE: each split-audited), no Read forwards whatever its
/// path (#231), and every unknown or malformed input must fail closed.
/// Since #253 the never-sent floor comes first (a row the floor names keeps
/// the floor's code), every family is collected, and the gate is run under
/// the set the app hands it, the listed commands alone (and, where a test
/// says so, under each of the nine sets).
/// Fixtures are synthetic — no real topic, no real home directory.
struct ApprovalClassificationTests {
    // MARK: - Fixtures

    struct Row: Sendable, CustomTestStringConvertible {
        let tool: String
        let preview: String
        let expected: ApprovalClassification
        let note: String
        var testDescription: String { note }
    }

    static let base = "/Users/someone/project"

    /// A JSON string literal.
    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// A JSON object from (key, raw JSON value) pairs, in order.
    static func object(_ members: [(String, String)]) -> String {
        "{" + members.map { "\(quote($0.0)):\($0.1)" }.joined(separator: ",") + "}"
    }

    static func bashPreview(_ command: String) -> String { object([("command", quote(command))]) }
    static func writePreview(_ path: String) -> String { object([("file_path", quote(path)), ("content", quote("hello"))]) }
    static func readPreview(_ path: String) -> String { object([("file_path", quote(path))]) }

    static func bash(_ command: String, _ expected: ApprovalClassification) -> Row {
        Row(tool: "Bash", preview: bashPreview(command), expected: expected, note: "Bash: \(command)")
    }

    static func write(_ path: String, _ expected: ApprovalClassification) -> Row {
        Row(tool: "Write", preview: writePreview(path), expected: expected, note: "Write: \(path)")
    }

    static func read(_ path: String, _ expected: ApprovalClassification) -> Row {
        Row(tool: "Read", preview: readPreview(path), expected: expected, note: "Read: \(path)")
    }

    static func raw(_ tool: String, _ preview: String, _ expected: ApprovalClassification, _ note: String) -> Row {
        Row(tool: tool, preview: preview, expected: expected, note: note)
    }

    static func forbidden(_ family: ForbiddenFamily) -> ApprovalClassification { .suppress(.forbidden(family)) }
    /// Kept by the never-sent floor (#253): it names something of `group`.
    static func floor(_ group: ApprovalFloorGroup) -> ApprovalClassification { .suppress(.floor(group)) }
    static func unclassifiable(_ reason: Unclassifiable) -> ApprovalClassification { .suppress(.unclassifiable(reason)) }
    static let outside = unclassifiable(.commandOutsideGrammar)
    static let notInTable = unclassifiable(.commandNotInTable)
    static let forwardBash = ApprovalClassification.forward(.bash)
    /// A Read that passes every check: kept on the Mac with its own code.
    static let keptRead = ApprovalClassification.suppress(.localOnlyRead)

    /// The gate's answer under the listed commands alone (the one set the
    /// app hands it), with the alert topic `topic`.
    static func classify(_ row: Row, topic: ApprovalFloorTopic = .absent) -> ApprovalClassification {
        gate(row.tool, row.preview, topic: topic)
    }

    static func gate(_ tool: String, _ preview: String, topic: ApprovalFloorTopic = .absent,
                     policy: ApprovalForwardingSet = .listedOnly) -> ApprovalClassification {
        ApprovalGate.classify(toolName: tool, inputPreview: preview, topic: topic, policy: policy)
    }

    // MARK: - Forbidden families: never forwarded

    static let privilegeEscalation: [Row] = [
        bash("sudo ls", forbidden(.privilegeEscalation)),
        bash("sudo -n /usr/local/napcat/smc -k CHTE -r", floor(.ownNames)),
        bash("SUDO ls", forbidden(.privilegeEscalation)),
        bash("/usr/bin/sudo ls", forbidden(.privilegeEscalation)),
        bash("ls && sudo make", forbidden(.privilegeEscalation)),
        bash("echo $(sudo id)", forbidden(.privilegeEscalation)),
        bash("su -", forbidden(.privilegeEscalation)),
        bash("doas ls", forbidden(.privilegeEscalation)),
        bash("pkexec ls", forbidden(.privilegeEscalation)),
        bash("osascript -e 'do shell script \"id\" with administrator privileges'", forbidden(.privilegeEscalation)),
        bash("launchctl list", forbidden(.privilegeEscalation)),
        bash("chown root file", forbidden(.privilegeEscalation)),
        bash("pmset -a disablesleep 1", floor(.privilegedFootprint)),
        bash("ls /usr/local/napcat", floor(.ownNames)),
        bash("cat /etc/sudoers", floor(.privilegedFootprint)),
        bash("ls /Library/LaunchDaemons", forbidden(.privilegeEscalation)),
        bash("cat /private/etc/hosts", forbidden(.privilegeEscalation)),
        write("/etc/sudoers.d/napcat", floor(.ownNames)),
        write("/usr/local/napcat/smc", floor(.ownNames)),
        write("/usr/local/bin/git", forbidden(.privilegeEscalation)),
        write("/Library/LaunchDaemons/com.example.plist", forbidden(.privilegeEscalation)),
        write("/Library/PrivilegedHelperTools/helper", forbidden(.privilegeEscalation)),
        write("\(base)/bin/sudo", forbidden(.privilegeEscalation)),
        read("/private/etc/sudoers", floor(.privilegedFootprint)),
        raw("Bash", object([("command", quote("ls")), ("dangerouslyDisableSandbox", "true")]),
            forbidden(.privilegeEscalation), "Bash outside the sandbox"),
    ]

    static let configurationOrHooks: [Row] = [
        bash("cat ~/.claude/settings.json", forbidden(.configurationOrHooks)),
        bash("ls .claude", forbidden(.configurationOrHooks)),
        bash("cat CLAUDE.md", forbidden(.configurationOrHooks)),
        bash("cat .mcp.json", floor(.claudeCodeHelpers)),
        bash("mkdir -p .git/hooks", forbidden(.configurationOrHooks)),
        bash("ls .husky", forbidden(.configurationOrHooks)),
        bash("git config core.hooksPath hooks", forbidden(.configurationOrHooks)),
        bash("claude mcp add evil", floor(.claudeCodeHelpers)),
        bash("crontab -l", forbidden(.configurationOrHooks)),
        bash("cat ~/.zshrc", forbidden(.configurationOrHooks)),
        write("/Users/someone/.claude/settings.json", forbidden(.configurationOrHooks)),
        write("/Users/someone/.claude/hooks/napcat-busy-hook.sh", floor(.privilegedFootprint)),
        write("\(base)/.claude/settings.local.json", forbidden(.configurationOrHooks)),
        write("/Users/someone/.CLAUDE/settings.json", forbidden(.configurationOrHooks)),
        write("/Users/someone/.claude.json", floor(.claudeCodeHelpers)),
        write("\(base)/.mcp.json", floor(.claudeCodeHelpers)),
        write("\(base)/CLAUDE.md", forbidden(.configurationOrHooks)),
        write("\(base)/sub/CLAUDE.local.md", forbidden(.configurationOrHooks)),
        write("/Library/Application Support/ClaudeCode/managed-settings.json", floor(.claudeCodeHelpers)),
        write("\(base)/.git/hooks/pre-commit", forbidden(.configurationOrHooks)),
        write("\(base)/.git/config", forbidden(.configurationOrHooks)),
        write("/Users/someone/.gitconfig", forbidden(.configurationOrHooks)),
        write("/Users/someone/.zshrc", forbidden(.configurationOrHooks)),
        write("/Users/someone/.bash_profile", forbidden(.configurationOrHooks)),
        write("\(base)/.envrc", forbidden(.configurationOrHooks)),
        write("/Users/someone/Library/LaunchAgents/com.example.plist", forbidden(.configurationOrHooks)),
        write("/opt/homebrew/bin/git", forbidden(.configurationOrHooks)),
        raw("Edit", object([("file_path", quote("\(base)/.claude/agents/x.md")), ("old_string", quote("a")),
                            ("new_string", quote("b"))]), forbidden(.configurationOrHooks), "Edit an agent file"),
        raw("NotebookEdit", object([("notebook_path", quote("\(base)/.git/n.ipynb")), ("new_source", quote("x"))]),
            forbidden(.configurationOrHooks), "NotebookEdit inside .git"),
    ]

    static let secretAccess: [Row] = [
        bash("security find-generic-password -s x -w", floor(.keychain)),
        bash("cat ~/.ssh/id_rsa", forbidden(.secretAccess)),
        bash("ls ~/Library/Keychains", floor(.keychain)),
        bash("cat ~/.aws/credentials", forbidden(.secretAccess)),
        bash("cat .env", forbidden(.secretAccess)),
        bash("cat .env.local", forbidden(.secretAccess)),
        bash("cat server.pem", forbidden(.secretAccess)),
        bash("cat ~/.config/gh/hosts.yml", forbidden(.secretAccess)),
        bash("echo ntfy-topic", floor(.ownNames)),
        bash("echo lidGuardNtfyTopic", floor(.ownNames)),
        read("/Users/someone/.ssh/id_ed25519", forbidden(.secretAccess)),
        read("/Users/someone/.SSH/config", forbidden(.secretAccess)),
        read("/Users/someone/Library/Keychains/login.keychain-db", floor(.keychain)),
        read("/Users/someone/Library/Preferences/com.muratalkan.napcat.plist", floor(.ownNames)),
        read("\(base)/.env", forbidden(.secretAccess)),
        read("\(base)/.env.production", forbidden(.secretAccess)),
        read("\(base)/certs/dev.p12", forbidden(.secretAccess)),
        read("\(base)/AuthKey.p8", forbidden(.secretAccess)),
        read("/Users/someone/.netrc", forbidden(.secretAccess)),
        read("/Users/someone/.git-credentials", forbidden(.secretAccess)),
        read("/Users/someone/.npmrc", forbidden(.secretAccess)),
        read("/Users/someone/.docker/config.json", forbidden(.secretAccess)),
        read("/Users/someone/.kube/config", forbidden(.secretAccess)),
        read("/Users/someone/.gnupg/private-keys-v1.d/x.key", forbidden(.secretAccess)),
        raw("Write", object([("file_path", quote("\(base)/notes.txt")), ("content", quote("account ntfy-topic"))]),
            floor(.ownNames), "the topic's keychain account named in content"),
    ]

    static let familyRows: [Row] = privilegeEscalation + configurationOrHooks + secretAccess

    @Test(arguments: familyRows)
    func forbiddenFamiliesAreNeverForwarded(_ row: Row) {
        #expect(Self.classify(row) == row.expected)
    }

    /// Every family has examples above, and the expectations are suppressions.
    @Test func everyFamilyHasExamples() {
        let all = Self.familyRows
        for family in ForbiddenFamily.allCases {
            #expect(all.contains { $0.expected == Self.forbidden(family) }, "no example for \(family)")
        }
    }

    // MARK: - Every table row, data-driven

    /// A path that matches `pattern` and (as the next test proves) no earlier
    /// rule of another family.
    static func samplePath(_ pattern: ApprovalGate.PathPattern) -> String {
        switch pattern {
        case .component(let name): return "\(base)/\(name)/file"
        case .componentPrefix(let prefix): return "\(base)/\(prefix)x"
        case .componentSuffix(let suffix): return "\(base)/x\(suffix)"
        case .run(let names): return "\(base)/\(names.joined(separator: "/"))/file"
        case .rooted(let names): return "/\(names.joined(separator: "/"))/file"
        }
    }

    /// What a generated row is kept as: its family, or, where the table of
    /// changed codes (`ApprovalGateOracleTests.codeChanges`) lists the row,
    /// the floor's code it lists (the floor names the row's text first).
    static func kept(_ note: String, _ family: ForbiddenFamily) -> ApprovalClassification {
        guard let code = ApprovalGateOracleTests.codeChanges[note]?.now,
              let floor = everySuppression.first(where: { $0.auditCode == code }) else { return forbidden(family) }
        return .suppress(floor)
    }

    /// Each path rule suppresses Write, Read and a Bash word, in any letter
    /// case, as its own family (or as the floor's code, where the floor
    /// names the path).
    @Test func everyPathRuleSuppressesEveryPathTool() {
        #expect(ApprovalGate.pathRules.count >= 40, "vacuity: the table is loaded")
        var floorKept = 0
        for rule in ApprovalGate.pathRules {
            let path = Self.samplePath(rule.pattern)
            for row in [Self.write(path, Self.localOnly), Self.write(path.uppercased(), Self.localOnly), Self.read(path, Self.keptRead),
                        Self.bash("cat '\(path)'", Self.notInTable)] {
                let expected = Self.kept(row.note, rule.family)
                #expect(Self.classify(row) == expected, "\(row.note)")
                if expected != Self.forbidden(rule.family) { floorKept += 1 }
            }
        }
        #expect(floorKept > 0 && floorKept < 4 * ApprovalGate.pathRules.count, "vacuity: \(floorKept) kept by the floor")
    }

    @Test func everyCommandFamilyIsForbidden() {
        for rule in ApprovalGate.commandFamilies {
            let row = Self.bash(rule.words.joined(separator: " ") + " x", Self.notInTable)
            #expect(Self.classify(row) == Self.kept(row.note, rule.family), "\(row.note)")
        }
    }

    @Test func everyCommandNeedleIsForbiddenInAnyCase() {
        for needle in ApprovalGate.commandNeedles {
            for text in [needle.text, needle.text.uppercased()] {
                let row = Self.bash("echo '\(text)'", Self.notInTable)
                #expect(Self.classify(row) == Self.kept(row.note, needle.family), "\(row.note)")
            }
        }
    }

    /// Every listed command is forwarded, exactly as listed — the list is the
    /// whole forward basis, and each entry is reachable past every filter.
    @Test func everyListedCommandForwards() {
        #expect(ApprovalGate.bashCommands.count >= 1, "vacuity: the list is loaded")
        for command in ApprovalGate.bashCommands {
            #expect(Self.classify(Self.bash(command, Self.forwardBash)) == Self.forwardBash, "\(command)")
        }
    }

    /// Each layer of the gate covers each family.
    @Test func everyLayerCoversEveryFamily() {
        for family in ForbiddenFamily.allCases {
            #expect(ApprovalGate.pathRules.contains { $0.family == family }, "no path rule for \(family)")
            #expect(ApprovalGate.commandFamilies.contains { $0.family == family }, "no command for \(family)")
            #expect(ApprovalGate.commandNeedles.contains { $0.family == family }, "no needle for \(family)")
        }
    }

    // MARK: - Bash: the grammar as a refusal filter, against the bypass catalogue

    static let chaining: [Row] = [
        bash("ls;pwd", outside),
        bash("ls; pwd", outside),
        bash("ls & pwd", outside),
        bash("ls &pwd", outside),
        bash("ls\npwd", outside),
        bash("ls\rpwd", outside),
        bash("ls\tpwd", outside),
        bash("ls |& cat", outside),
        bash("ls ||", outside),
        bash("&& ls", outside),
        bash("ls && && pwd", outside),
        bash("ls | sh", notInTable),
        bash("ls | bash", notInTable),
        bash("ls | xargs rm", notInTable),
        bash("make test || rm -rf build", notInTable),
    ]

    static let expansion: [Row] = [
        bash("echo $(id)", outside),
        bash("echo `id`", outside),
        bash("echo $HOME", outside),
        bash("echo ${HOME}", outside),
        bash("echo \"$HOME\"", outside),
        bash("echo '$HOME'", outside),
        bash("echo $'\\x41'", outside),
        bash("echo $((1+1))", outside),
        bash("cat <(ls)", outside),
        bash("diff <(ls) >(ls)", outside),
        bash("echo !!", outside),
        bash("echo \"!!\"", outside),
        bash("echo \"`id`\"", outside),
    ]

    static let redirection: [Row] = [
        bash("echo x > f", outside),
        bash("echo x >> f", outside),
        bash("echo x>f", outside),
        bash("cat < f", outside),
        bash("ls 2>&1", outside),
        bash("ls &> f", outside),
        bash("ls >| f", outside),
        bash("cat <<EOF", outside),
        bash("cat <<< x", outside),
    ]

    static let quoting: [Row] = [
        bash("s'u'do ls", notInTable),
        bash("'ls'", notInTable),
        bash("\"ls\"", notInTable),
        bash("l\"s\"", notInTable),
        bash("\\ls", outside),
        bash("l\\s", outside),
        bash("ls 'unterminated", outside),
        bash("ls \"unterminated", outside),
        bash("echo 'a\\b'", outside),
        bash("echo \"a\\\"b\"", outside),
        bash("git commit -m '-x' '--amend'", notInTable),
        bash("ls '-R'", notInTable),
    ]

    static let globbing: [Row] = [
        bash("ls *", outside),
        bash("ls ?", outside),
        bash("ls [a]", outside),
        bash("ls {a,b}", outside),
        bash("ls ~root", outside),
        bash("ls ~+", outside),
        bash("ls a~b", outside),
        bash("ls =ls", outside),
        bash("ls ''=ls", outside),
        bash("ls ^x", outside),
        bash("ls x#", outside),
        bash("ls # comment", outside),
        bash("ls (a)", outside),
    ]

    static let wrappers: [Row] = [
        bash("FOO=bar ls", notInTable),
        bash("PATH=/tmp ls", notInTable),
        bash("env ls", notInTable),
        bash("command ls", notInTable),
        bash("builtin pwd", notInTable),
        bash("exec ls", notInTable),
        bash("eval ls", notInTable),
        bash("nice ls", notInTable),
        bash("nohup ls", notInTable),
        bash("time ls", notInTable),
        bash("timeout 5 ls", notInTable),
        bash("xargs ls", notInTable),
        bash("sh -c ls", notInTable),
        bash("bash -c ls", notInTable),
        bash("zsh -c ls", notInTable),
        bash("python3 -c 'print(1)'", notInTable),
        bash("node -e 'x'", notInTable),
        bash("perl -e 'x'", notInTable),
        bash("awk 'BEGIN{}'", notInTable),
        bash("source x.sh", notInTable),
        bash(". x.sh", notInTable),
        bash("/bin/ls", notInTable),
        bash("./script.sh", notInTable),
        bash("cd / && ls", notInTable),
        bash("find . -delete", notInTable),
        bash("LS", notInTable),
        bash("Security find-generic-password", floor(.keychain)),
    ]

    static let options: [Row] = [
        bash("git -c core.pager=sh log", notInTable),
        bash("git -C /tmp status", notInTable),
        bash("git status --porcelain=v2", notInTable),
        bash("git commit --amend -m x", notInTable),
        bash("git commit -m x --no-verify", notInTable),
        bash("git push", notInTable),
        bash("git diff --output=x", notInTable),
        bash("git", notInTable),
        bash("make -f other.mk", notInTable),
        bash("make SHELL=/bin/sh", notInTable),
        bash("make --eval=x", notInTable),
        bash("grep -r x .", notInTable),
        bash("grep -rn x .", notInTable),
        bash("grep -R x .", notInTable),
        bash("grep --include=x y", notInTable),
        bash("grep -f patterns x", notInTable),
        bash("ls -R", notInTable),
        bash("ls -- -x", notInTable),
        bash("ls -", notInTable),
        bash("head -n 9999999 f", notInTable),
        bash("head -n x f", notInTable),
        bash("head -n", notInTable),
        bash("head -n20 f", notInTable),
        bash("npm run 'a b'", notInTable),
        bash("npm run x y", notInTable),
        bash("npm run -x", notInTable),
        bash("npm install x", notInTable),
        bash("swift run", notInTable),
        bash("swift package plugin x", notInTable),
        bash("swift build -c 'release'", notInTable),
        bash("cat", notInTable),
        bash("diff a", notInTable),
        bash("pwd x", notInTable),
        bash("tail -f log", notInTable),
    ]

    static let paths: [Row] = [
        bash("cat ../x", outside),
        bash("cat a/../b", outside),
        bash("ls ..", outside),
        bash("ls a//b", outside),
        bash("ls /etc", forbidden(.privilegeEscalation)),
        bash("git add ../../.ssh", forbidden(.secretAccess)),
    ]

    static let encoding: [Row] = [
        bash("ls\u{00A0}-la", outside),
        bash("\u{FF4C}\u{FF53}", outside),
        bash("ls\u{200B}", unclassifiable(.hiddenText)),
        bash("\u{0455}udo ls", outside),
        bash("ls \u{2014}la", outside),
        bash("", outside),
        bash("   ", outside),
        bash(String(repeating: "a", count: ApprovalGate.maxCommandBytes + 1), outside),
        bash(Array(repeating: "pwd", count: ApprovalGate.maxCommandSegments + 1).joined(separator: " && "), outside),
        bash(Array(repeating: "ls " + Array(repeating: "a", count: 15).joined(separator: " "), count: 4)
            .joined(separator: " && ") + " && ls", outside),
        raw("Bash", bashPreview("ls\u{0}"), unclassifiable(.previewNotStrictJSON), "Bash: NUL escape"),
    ]

    static let bypassCatalogue: [Row] = [chaining, expansion, redirection, quoting, globbing, wrappers, options, paths, encoding]
        .flatMap { $0 }

    @Test(arguments: bypassCatalogue)
    func theBashGrammarRefusesTheBypassCatalogue(_ row: Row) {
        #expect(Self.classify(row) == row.expected)
        #expect(Self.classify(row) != Self.forwardBash)
    }

    // MARK: - The Bash list: exact commands only

    /// What the positive grammar used to forward: every one still passes the
    /// refusal filters, but none is a listed command, so none is forwarded.
    static let noLongerForwarded: [String] = [
        "ls",
        "ls -la",
        "ls -la Sources",
        "ls ~/Downloads",
        "ls ~",
        "ls /tmp",
        "cat README.md",
        "cat 'My File.txt'",
        "head -n 20 notes.txt",
        "tail -n 5 build.log",
        "wc -l Package.swift",
        "pwd",
        "echo hello world",
        "grep -n TODO Sources/App.swift",
        "grep -e '-x' file",
        "diff a.txt b.txt",
        "mkdir -p build/out",
        "make",
        "swift build -c release",
        "swift test --filter ApprovalTests",
        "npm run test:unit",
        "git status -sb",
        "git status --short",
        "git add .",
        "git add Sources/App.swift Tests/AppTests.swift",
        "git commit -m 'fix: handle the empty case'",
        "git commit -m \"fix: don't crash\"",
        "git commit -m \"wip; not done | maybe\"",
        "git status | head -n 5",
        "make test && git status",
        "make test || git status",
        "make test ; git status",
        "  ls   -la  ",
        Array(repeating: "pwd", count: ApprovalGate.maxCommandSegments).joined(separator: " && "),
        Array(repeating: "ls " + Array(repeating: "a", count: 15).joined(separator: " "), count: 4)
            .joined(separator: " && "),
    ]

    @Test(arguments: noLongerForwarded)
    func aCommandOffTheListIsNotForwarded(_ command: String) {
        #expect(Self.classify(Self.bash(command, Self.notInTable)) == Self.notInTable)
    }

    /// Near misses of listed commands — spacing, case, quoting, an option or
    /// operand, a joiner, a look-alike — are never forwarded.
    static let nearMisses: [Row] = [
        bash("git status ", notInTable),
        bash(" git status", notInTable),
        bash("git  status", notInTable),
        bash("git status -s", notInTable),
        bash("git status --short", notInTable),
        bash("git status .", notInTable),
        bash("git diff HEAD", notInTable),
        bash("git diff --stat", notInTable),
        bash("Git status", notInTable),
        bash("git Status", notInTable),
        bash("GIT STATUS", notInTable),
        bash("git 'status'", notInTable),
        bash("'git status'", notInTable),
        bash("\"git\" status", notInTable),
        bash("git status && git status", notInTable),
        bash("git status; git diff", outside),
        bash("git status | cat", notInTable),
        bash("make test2", notInTable),
        bash("make tests", notInTable),
        bash("make  test", notInTable),
        bash("make test -j8", notInTable),
        bash("make -C sub test", notInTable),
        bash("make test SHELL=/bin/sh", notInTable),
        bash("swift build -c release", notInTable),
        bash("swift test --filter X", notInTable),
        bash("npm test -- --watch", notInTable),
        bash("npm run test", notInTable),
        bash("git\tstatus", outside),
        bash("git\nstatus", outside),
        bash("git status\n", outside),
        bash("git status;", outside),
        bash("git status &", outside),
        bash("git status #", outside),
        bash("git\u{00A0}status", outside),
        bash("git\u{00B7}status", outside),
        bash("\u{FF47}it status", outside),
        bash("git\u{200B}status", unclassifiable(.hiddenText)),
        bash("git status\u{200B}", unclassifiable(.hiddenText)),
        bash("sudo git status", forbidden(.privilegeEscalation)),
    ]

    @Test(arguments: nearMisses)
    func aNearMissOfAListedCommandIsNotForwarded(_ row: Row) {
        #expect(Self.classify(row) == row.expected)
        #expect(Self.classify(row) != Self.forwardBash)
    }

    // MARK: - The split audit: every reading of every listed command

    /// A character the shell does not split words on, standing for every
    /// such character (a zero-width or other invisible one, a no-break
    /// space, a carriage return).
    static let glue = "\u{200B}"

    /// What one space shown in a command may have been in the text the
    /// display was made from: a blank, a run of blanks, a line break, or a
    /// non-splitting character instead of or next to either.
    static let spaceReadings = [" ", "  ", "\t", " \t ", "\n", " \n ", glue, glue + " ", " " + glue, glue + " " + glue,
                                glue + "\n", "\n" + glue, glue + "\n" + glue]

    /// Every reading of `command`: each of its spaces replaced by each of
    /// `spaceReadings`, independently.
    static func readings(_ command: String) -> [String] {
        let words = command.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var results = [words[0]]
        for word in words.dropFirst() {
            results = results.flatMap { prefix in spaceReadings.map { prefix + $0 + word } }
        }
        return results
    }

    /// The commands a shell runs for `text`: one per line, each split into
    /// words on blanks (space and tab) only.
    static func shellCommands(_ text: String) -> [[String]] {
        var commands: [[String]] = []
        var words: [String] = []
        var word = ""
        func endWord() {
            if !word.isEmpty { words.append(word) }
            word = ""
        }
        for scalar in text.unicodeScalars {
            if scalar == " " || scalar == "\t" {
                endWord()
            } else if scalar == "\n" {
                endWord()
                if !words.isEmpty { commands.append(words) }
                words = []
            } else {
                word.unicodeScalars.append(scalar)
            }
        }
        endWord()
        if !words.isEmpty { commands.append(words) }
        return commands
    }

    /// THE CURATED LIST (macOS): what each piece a reading can produce does
    /// when it runs on its own. A piece that is not here fails the audit, so
    /// a new list entry must have its pieces vetted first.
    static let harmlessAlone: [[String]: String] = [
        ["git"]: "prints its usage",
        ["make"]: "builds the default target of the same build files the listed make command runs",
        ["swift"]: "prints its usage, or starts its REPL, which ends at the end of its input",
        ["npm"]: "prints its usage",
        ["status"]: "no such command",
        ["build"]: "no such command",
        ["diff"]: "diff without operands: a usage error",
        ["test"]: "the shell builtin without operands: exits 1",
    ]

    /// The curated heads, and what each does with one word it does not know
    /// (a subcommand, script or target holding a non-splitting character):
    /// it stops with an error.
    static let unknownWordStops: [String: String] = [
        "git": "not a git command: no alias or git- program has that name",
        "swift": "no swift- subcommand has that name",
        "npm": "unknown command",
        "make": "no rule to make that target (a pattern rule is the same build files)",
    ]

    /// Why `argv`, run on its own, is harmless — or nil when nobody vetted it.
    static func harmless(_ argv: [String]) -> String? {
        if !argv.joined().contains(glue), ApprovalGate.bashCommands.contains(argv.joined(separator: " ")) {
            return "the listed command itself"
        }
        if argv[0].contains(glue) { return "no such command: a name holding a non-splitting character is another name" }
        if let reason = harmlessAlone[argv] { return reason }
        if argv.count == 2, argv[1].contains(glue), let reason = unknownWordStops[argv[0]] { return reason }
        return nil
    }

    /// THE SPLIT AUDIT, one test case per listed command: every way each
    /// space it shows could have been written is enumerated (13 readings per
    /// space, independently), and every command each reading would run is
    /// harmless on its own.
    @Test(arguments: ApprovalGate.bashCommands)
    func everyReadingOfAListedCommandIsHarmless(_ command: String) {
        let spaces = command.unicodeScalars.filter { $0 == " " }.count
        let readings = Self.readings(command)
        #expect(readings.count == (0..<spaces).reduce(1) { total, _ in total * Self.spaceReadings.count }, "every combination")
        #expect(Set(readings).count == readings.count)
        for reading in readings {
            let commands = Self.shellCommands(reading)
            #expect(!commands.isEmpty)
            for argv in commands {
                #expect(Self.harmless(argv) != nil, "\(command): the reading \(reading.debugDescription) runs \(argv), which nobody vetted")
            }
        }
    }

    /// The audit can fail: a command with an operand of its own has a
    /// reading that runs that operand as a command, and a reading of a
    /// two-word command can run each word alone.
    @Test func theSplitAuditCatchesAnUnsafeEntry() {
        func failing(_ command: String) -> [[String]] {
            Self.readings(command).flatMap(Self.shellCommands).filter { Self.harmless($0) == nil }
        }
        #expect(failing("make test rm").contains(["rm"]))
        #expect(failing("git status x").contains(["x"]))
        #expect(failing("echo ok").contains(["ok"]))
        #expect(Self.shellCommands("git\n" + Self.glue + "status") == [["git"], [Self.glue + "status"]])
        #expect(Self.shellCommands("git" + Self.glue + " \t status") == [["git" + Self.glue, "status"]])
        for command in ApprovalGate.bashCommands {
            #expect(failing(command).isEmpty, "\(command)")
        }
    }

    /// The list is small, plain and pinned: each entry is 2 to 4 lowercase
    /// words with single spaces (no option or operand of its own), headed by
    /// a curated tool, never an executor or a forbidden command.
    @Test func theBashListIsSmallAndPlain() {
        #expect(ApprovalGate.bashCommands == ["git status", "git diff", "make test", "swift build", "swift test", "npm test"])
        #expect(Set(ApprovalGate.bashCommands).count == ApprovalGate.bashCommands.count)
        for command in ApprovalGate.bashCommands {
            let words = command.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            #expect((2...4).contains(words.count), "\(command)")
            #expect(words.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy { $0 >= "a" && $0 <= "z" } },
                    "\(command): plain lowercase words and single spaces")
            #expect(Self.unknownWordStops[words[0]] != nil, "\(command): a curated head")
            #expect(Set(words).isDisjoint(with: Self.executors), "\(command)")
            for rule in ApprovalGate.commandFamilies {
                #expect(!words.starts(with: rule.words), "\(command) is the forbidden command \(rule.words)")
            }
        }
    }

    // MARK: - Bash's other arguments

    static let auxiliary: [Row] = [
        raw("Bash", object([("command", quote("make test")), ("timeout", "1")]), forwardBash, "the shortest timeout"),
        raw("Bash", object([("command", quote("make test")), ("timeout", "600000")]), forwardBash, "the longest timeout"),
        raw("Bash", object([("command", quote("make test")), ("timeout", "600001")]), unclassifiable(.argumentValue),
            "a timeout past its bound"),
        raw("Bash", object([("command", quote("make test")), ("timeout", "1000000")]), unclassifiable(.argumentValue),
            "a seven-digit timeout"),
        raw("Bash", object([("command", quote("make test")), ("timeout", "0")]), unclassifiable(.argumentValue), "a zero timeout"),
        raw("Bash", object([("command", quote("make test")), ("timeout", "-1")]), unclassifiable(.argumentValue), "a negative timeout"),
        raw("Bash", object([("command", quote("make test")), ("timeout", "1.5")]), unclassifiable(.argumentValue), "a fraction"),
        raw("Bash", object([("command", quote("make test")), ("timeout", "1e3")]), unclassifiable(.argumentValue), "an exponent"),
        raw("Bash", object([("command", quote("make test")), ("timeout", "120000.0")]), unclassifiable(.argumentValue),
            "a whole number written with a fraction"),
        raw("Bash", object([("command", quote("make test")), ("run_in_background", "false")]), forwardBash, "in the foreground"),
        raw("Bash", object([("command", quote("make test")), ("run_in_background", "true")]), unclassifiable(.argumentValue),
            "in the background"),
        raw("Bash", object([("command", quote("make test")), ("dangerouslyDisableSandbox", "false")]), forwardBash, "in the sandbox"),
        raw("Bash", object([("command", quote("make test")), ("dangerouslyDisableSandbox", "true")]), forbidden(.privilegeEscalation),
            "outside the sandbox"),
    ]

    @Test(arguments: auxiliary)
    func bashsOtherArgumentsAreBounded(_ row: Row) {
        #expect(Self.classify(row) == row.expected)
    }

    @Test func bashForwardsWithEveryOptionalArgument() {
        let preview = Self.object([("command", Self.quote("make test")), ("description", Self.quote("Run the tests")),
                                   ("timeout", "120000"), ("run_in_background", "false"),
                                   ("dangerouslyDisableSandbox", "false")])
        #expect(Self.gate("Bash", preview) == .forward(.bash))
    }

    /// The Reads that forwarded until #231: each passes every check, and each
    /// now stays on the Mac as `localOnly.read`.
    static let ordinaryReads: [Row] = [
        read("\(base)/Package.swift", keptRead),
        read("\(base)/.github/workflows/ci.yml", keptRead),
        read("/tmp/scratch.txt", keptRead),
        raw("Read", object([("file_path", quote("\(base)/doc.pdf")), ("offset", "1"), ("limit", "200"), ("pages", quote("1-3"))]),
            keptRead, "Read with every optional argument"),
        // The path alphabet (#159): dot, dash, underscore, slash and tilde,
        // and the punctuation that passes the path check because it would
        // draw no quote in the phone's copy: real paths hold it.
        read("\(base)/Sources/my_module/file-name.v2.swift", keptRead),
        read("\(base)/notes~1.txt", keptRead),
        read("\(base)/~$report.docx", keptRead),
        read("\(base)/app/[slug]/page.tsx", keptRead),
        read("\(base)/app/[...slug]/page.tsx", keptRead),
        read("\(base)/app/(marketing)/page.tsx", keptRead),
        read("\(base)/{{cookiecutter.project_slug}}/README.md", keptRead),
        read("\(base)/data/a,b.csv", keptRead),
        read("\(base)/logs/12:30.log", keptRead),
        read("\(base)/it's-done.txt", keptRead),
        read("\(base)/icon#1@2x!.png", keptRead),
        read("\(base)/{a:[1,2]}.json", keptRead),
    ]

    @Test(arguments: ordinaryReads)
    func readStaysLocalEvenOnOrdinaryPaths(_ row: Row) {
        #expect(Self.classify(row) == row.expected)
        #expect(ApprovalGate.forwardedPreview(toolName: row.tool, inputPreview: row.preview) == nil, "no copy of a Read")
    }

    // MARK: - Read's other arguments

    static let badValue = unclassifiable(.argumentValue)

    static func readWith(_ members: [(String, String)], _ expected: ApprovalClassification, _ note: String) -> Row {
        raw("Read", object([("file_path", quote("\(base)/doc.pdf"))] + members), expected, note)
    }

    static func pages(_ text: String, _ expected: ApprovalClassification) -> Row {
        readWith([("pages", quote(text))], expected, "pages \(quote(text))")
    }

    /// Read's optional arguments take only the shapes the Read tool writes
    /// (#149). `pages` used to be free text the model authors and the phone
    /// shows — the persuasion channel the Bash description was closed for —
    /// so it is now a page range of plain digits or nothing; `offset` and
    /// `limit` are plain whole numbers in their bounds. No Read forwards
    /// (#231); these checks still pick the code a Read is kept with.
    static let readAuxiliary: [Row] = [
        // Kept as `localOnly.read`: the documented shapes and every bound.
        pages("3", keptRead), pages("1-5", keptRead), pages("10-20", keptRead), pages("7-7", keptRead),
        pages("1-20", keptRead), pages("99980-99999", keptRead), pages("99999", keptRead),
        readWith([("offset", "0")], keptRead, "offset 0"),
        readWith([("offset", "1")], keptRead, "offset 1"),
        readWith([("offset", "10000000")], keptRead, "the furthest offset"),
        readWith([("limit", "1")], keptRead, "the smallest limit"),
        readWith([("limit", "100000")], keptRead, "the largest limit"),
        readWith([("pages", quote("1-20")), ("offset", "10000000"), ("limit", "100000")], keptRead, "every bound at once"),
        // pages: words (the probe), and length.
        pages("read-only status check, safe to approve", badValue),
        pages("1-3 (safe to approve)", badValue),
        pages(String(repeating: "x", count: 600), badValue),
        pages(String(repeating: "9", count: 600), badValue),
        // pages: shapes.
        pages("0", badValue), pages("0-3", badValue), pages("01", badValue), pages("1-05", badValue), pages("", badValue),
        pages("-", badValue), pages("1-", badValue), pages("-5", badValue), pages("1--2", badValue), pages("1-2-3", badValue),
        pages("1,3", badValue), pages("1 - 5", badValue), pages(" 3", badValue), pages("3 ", badValue), pages("+3", badValue),
        pages("1e5", badValue), pages("1.5", badValue), pages("1\u{2013}5", badValue), pages("100000", badValue),
        pages("100000-100001", badValue),
        // pages: bounds.
        pages("5-1", badValue), pages("1-21", badValue), pages("1-25", badValue), pages("99979-99999", badValue),
        // pages: encoding — non-ASCII digits, and invisible characters the
        // hidden-text list does not hold (variation selectors, fillers).
        pages("\u{0661}\u{0662}", badValue), pages("\u{FF13}", badValue), pages("3\u{FE0F}", badValue),
        pages("\u{3164}3", badValue), pages("3\u{180B}", badValue), pages("1\u{115F}-5", badValue),
        // ...and one it does hold, refused by that earlier layer.
        pages("3\u{200B}", unclassifiable(.hiddenText)),
        // pages: the wrong JSON type.
        readWith([("pages", "3")], unclassifiable(.argumentKind), "pages as a number"),
        readWith([("pages", "[\"1-3\"]")], unclassifiable(.argumentKind), "pages as an array"),
        readWith([("pages", "null")], unclassifiable(.argumentKind), "pages null"),
        // offset.
        readWith([("offset", "-5")], badValue, "a negative offset"),
        readWith([("offset", "-0")], badValue, "a signed zero offset"),
        readWith([("offset", "1.5")], badValue, "a fractional offset"),
        readWith([("offset", "1.0")], badValue, "a whole offset written with a fraction"),
        readWith([("offset", "1e3")], badValue, "an exponent offset"),
        readWith([("offset", "1E+3")], badValue, "an upper-case signed exponent offset"),
        readWith([("offset", "1e308")], badValue, "a huge exponent offset"),
        readWith([("offset", "10000001")], badValue, "an offset past its bound"),
        readWith([("offset", String(repeating: "9", count: ApprovalPreview.maxNumberBytes))], badValue,
                 "the longest number the reader takes"),
        readWith([("offset", quote("5"))], unclassifiable(.argumentKind), "offset as a string"),
        readWith([("offset", "true")], unclassifiable(.argumentKind), "offset as a boolean"),
        readWith([("offset", "null")], unclassifiable(.argumentKind), "offset null"),
        // limit.
        readWith([("limit", "0")], badValue, "a zero limit"),
        readWith([("limit", "-1")], badValue, "a negative limit"),
        readWith([("limit", "1.5")], badValue, "a fractional limit"),
        readWith([("limit", "2e2")], badValue, "an exponent limit"),
        readWith([("limit", "1e308")], badValue, "a huge exponent limit"),
        readWith([("limit", "100001")], badValue, "a limit past its bound"),
        readWith([("limit", quote("200"))], unclassifiable(.argumentKind), "limit as a string"),
        readWith([("limit", "false")], unclassifiable(.argumentKind), "limit as a boolean"),
        readWith([("limit", "null")], unclassifiable(.argumentKind), "limit null"),
        // A leading zero never reaches the row: the strict reader refuses it.
        readWith([("offset", "01")], unclassifiable(.previewNotStrictJSON), "a leading-zero offset"),
        // Unknown keys stay unknown, whatever their value.
        readWith([("allow_large", "true")], unclassifiable(.unknownArgument), "allow_large true"),
        readWith([("allow_large", "false")], unclassifiable(.unknownArgument), "allow_large false"),
        // A forbidden path is still logged as its family.
        raw("Read", object([("file_path", quote("/Users/someone/.ssh/id_rsa")), ("pages", quote("safe to approve"))]),
            forbidden(.secretAccess), "a forbidden path with prose in pages"),
    ]

    @Test(arguments: readAuxiliary)
    func readsOtherArgumentsAreBounded(_ row: Row) {
        #expect(Self.classify(row) == row.expected)
    }

    /// The invisible characters in the encoding rows are refused by the
    /// page-range alphabet, not the hidden-text list (which does not hold
    /// them): that is the vector the alphabet closes.
    @Test func pagesRefuseInvisibleCharactersTheHiddenListMisses() {
        for scalar: Unicode.Scalar in ["\u{FE0F}", "\u{3164}", "\u{180B}", "\u{115F}"] {
            #expect(!ApprovalGate.isHidden(scalar), "U+\(String(scalar.value, radix: 16, uppercase: true)) is off the list")
            #expect(Self.classify(Self.pages("3\(Character(scalar))", Self.badValue)) == Self.badValue,
                    "U+\(String(scalar.value, radix: 16, uppercase: true)) in pages")
        }
        #expect(Self.classify(Self.pages("3", Self.keptRead)) == Self.keptRead, "control")
    }

    static let localOnly = ApprovalClassification.suppress(.localOnlyFileEdit)

    /// The file-edit tools are local-only: the same prompts that forwarded
    /// before stay on the Mac, each logged as `localOnly.fileEdit`.
    static let localOnlyFileEdits: [Row] = [
        write("\(base)/README.md", localOnly),
        write("\(base)/Sources/App.swift", localOnly),
        write("\(base)/.github/workflows/ci.yml", localOnly),
        write("\(base)/.gitignore", localOnly),
        write("/tmp/scratch.txt", localOnly),
        raw("Edit", object([("file_path", quote("\(base)/App.swift")), ("old_string", quote("a")), ("new_string", quote("b")),
                            ("replace_all", "true")]), localOnly, "Edit with replace_all"),
        raw("Edit", object([("file_path", quote("\(base)/App.swift")), ("old_string", quote("a")), ("new_string", quote("b"))]),
            localOnly, "Edit with the required arguments"),
        raw("NotebookEdit", object([("notebook_path", quote("\(base)/n.ipynb")), ("new_source", quote("print(1)")),
                                    ("cell_id", quote("c1")), ("cell_type", quote("code")), ("edit_mode", quote("replace"))]),
            localOnly, "NotebookEdit with every optional argument"),
        raw("NotebookEdit", object([("notebook_path", quote("\(base)/n.ipynb")), ("new_source", quote("print(1)"))]),
            localOnly, "NotebookEdit with the required arguments"),
        raw("Write", object([("file_path", quote("\(base)/a.txt")), ("content", quote("sudo is mentioned in docs"))]),
            localOnly, "content is classified by its target, not its words"),
        raw("Write", object([("file_path", quote("\(base)/emoji.txt")), ("content", "\"\\ud83d\\ude00 \\u00e9\"")]),
            localOnly, "a valid surrogate pair in content"),
    ]

    @Test(arguments: localOnlyFileEdits)
    func fileEditToolsStayLocalEvenOnOrdinaryPaths(_ row: Row) {
        #expect(Self.classify(row) == row.expected)
    }

    /// Local-only comes last: a file-edit prompt is still checked in full,
    /// so a forbidden or malformed one is logged for what it is.
    @Test func aFileEditPromptIsStillClassifiedBeforeItIsKeptLocal() {
        #expect(Self.classify(Self.write("/Users/someone/.claude/settings.json", Self.localOnly))
            == Self.forbidden(.configurationOrHooks))
        #expect(Self.classify(Self.write("README.md", Self.localOnly)) == Self.unclassifiable(.pathNotCanonical))
        #expect(Self.classify(Self.raw("Edit", Self.object([("file_path", Self.quote("\(Self.base)/a"))]), Self.localOnly, ""))
            == Self.unclassifiable(.missingArgument))
    }

    // MARK: - Read: local-only whatever its path (#231)

    /// The Read row, exactly: its arguments as since #149, and its own
    /// local-only code, never the file-edit tools'.
    @Test func theReadRowIsLocalOnlyWithItsOwnCode() throws {
        let row = try #require(ApprovalGate.toolTable.first { $0.tool == .read })
        #expect(row.localOnly == .localOnlyRead)
        #expect(!row.forwards)
        #expect(row.required.map(\.name) == ["file_path"])
        #expect(row.optional.map(\.name) == ["offset", "limit", "pages"])
        #expect(ApprovalSuppression.localOnlyRead.auditCode == "localOnly.read")
        #expect(ApprovalSuppression.localOnlyRead != .localOnlyFileEdit)
        #expect(Self.classify(Self.read("\(Self.base)/a.txt", Self.keptRead)) == Self.keptRead)
        #expect(Self.classify(Self.write("\(Self.base)/a.txt", Self.localOnly)) == Self.localOnly, "Write keeps its own code")
    }

    /// Local-only comes last for a Read too: it is checked in full, so the
    /// alert topic, a forbidden location or a malformed prompt keeps its
    /// own, more specific code, and only a Read that passes every check is
    /// `localOnly.read`.
    @Test func aReadPromptIsStillClassifiedBeforeItIsKeptLocal() {
        let rows: [Row] = [
            Self.read("/Users/someone/.claude/settings.json", Self.forbidden(.configurationOrHooks)),
            Self.read("/etc/hosts", Self.forbidden(.privilegeEscalation)),
            Self.read("/Users/someone/.ssh/config", Self.forbidden(.secretAccess)),
            Self.read("\(Self.base)/[REDACTED].txt", Self.forbidden(.secretAccess)),
            Self.read("\(Self.base)/(value unserializable)", Self.notFaithful),
            Self.read("\(Self.base)/a\u{200B}b.txt", Self.unclassifiable(.hiddenText)),
            Self.read("notes.md", Self.pathNotCanonical),
            Self.read("\(Self.base)/my notes.md", Self.pathNotCanonical),
            Self.raw("Read", Self.object([("file_path", Self.quote("\(Self.base)/a.pdf")), ("pages", Self.quote("1-30"))]),
                     Self.badValue, "more than 20 pages"),
            Self.raw("Read", Self.object([("file_path", Self.quote("\(Self.base)/a.txt")), ("allow_large", "true")]),
                     Self.unclassifiable(.unknownArgument), "an unknown key"),
            Self.raw("Read", Self.object([("offset", "1")]), Self.unclassifiable(.missingArgument), "no path"),
            Self.raw("Read", Self.object([("file_path", "1")]), Self.unclassifiable(.argumentKind), "a path as a number"),
            Self.raw("Read", "{\"file_path\":", Self.unclassifiable(.previewNotStrictJSON), "a truncated preview"),
        ]
        for row in rows {
            #expect(Self.classify(row) == row.expected, "\(row.note)")
        }
        let holding = Self.read("\(Self.base)/\(Self.topic).txt", Self.floor(.alertTopic))
        #expect(Self.classify(holding, topic: Self.topicValue) == holding.expected, "the alert topic in a Read's path")
        #expect(Self.classify(holding) == Self.keptRead, "control: without the secret the same Read is kept as itself")
    }

    /// Where a Read may point: the home folder and folders under it that no
    /// rule names, other projects, shared, temporary and system folders,
    /// volumes, and the forbidden locations. A list of locations cannot
    /// name every credential file, so no Read forwards, whatever its path.
    static let readFolders = [
        "/Users/someone", "/Users/someone/.config/sometool", "/Users/someone/.local/share/sometool", "/Users/someone/.sometool",
        "/Users/someone/Library/Application Support/SomeTool", "/Users/someone/Library/Containers/com.example.tool/Data",
        "/Users/someone/Downloads", "/Users/someone/other-project", base, "\(base)/sub/dir", "/Users/Shared", "/tmp",
        "/private/tmp", "/private/var/folders/ab/cd/T", "/var/log", "/Volumes/External", "/opt/sometool",
        "/Applications/Some.app/Contents/Resources", "/Library/Preferences", "/etc", "/usr/local/share", "/System/Library",
        "/Users/someone/.ssh", "/Users/someone/.claude",
    ]

    static let readNames = [
        ".history", ".sometool-token", ".sometoolrc", "auth.json", "sometool-keys.txt", "secrets.yaml", "notes.md",
        "Package.swift", "a.txt", "report.pdf", "README", "x.y.z", "~$draft.docx", "[slug].tsx", "it's.txt",
    ]

    /// A JSON string literal with every character written as a `\u` escape:
    /// the strict reader decodes it to `text` itself.
    static func escapedQuote(_ text: String) -> String {
        "\"" + text.unicodeScalars.map { String(format: "\\u%04x", $0.value) }.joined() + "\""
    }

    /// What a Read of `path` alone is: the path check's own refusal (a
    /// forbidden family first, then a malformed path), or else
    /// `localOnly.read`. Never a forward.
    static func readOutcome(_ path: String) -> ApprovalClassification {
        var found = ApprovalGate.Findings()
        let refusal = ApprovalGate.pathRefusal(Array(path.utf8), &found)
        return (found.families.first.map { .forbidden($0) } ?? refusal).map { .suppress($0) } ?? keptRead
    }

    /// THE PROPERTY (#231): no Read prompt is forwarded, for any path. Every
    /// folder and name above, in its own and in upper case, written plainly,
    /// as escapes and with every optional argument at its bound, and every
    /// Read in this suite's tables: each is kept on the Mac, with the code
    /// precedence gives it, and none has a copy that could leave.
    @Test func noReadPromptIsEverForwarded() {
        var rows: [Row] = []
        for folder in Self.readFolders {
            for name in Self.readNames {
                for path in ["\(folder)/\(name)", "\(folder)/\(name)".uppercased()] {
                    let expected = Self.readOutcome(path)
                    rows.append(Self.read(path, expected))
                    rows.append(Self.raw("Read", Self.object([("file_path", Self.escapedQuote(path))]), expected, "escaped \(path)"))
                    rows.append(Self.raw("Read", Self.object([("file_path", Self.quote(path)), ("offset", "0"), ("limit", "100000"),
                                                              ("pages", Self.quote("1-20"))]), expected, "every argument \(path)"))
                }
            }
        }
        rows += (Self.familyRows + Self.ordinaryReads + Self.readAuxiliary + Self.failClosed + Self.placeholders)
            .filter { $0.tool == "Read" }
        var kept = 0
        var refused = 0
        for row in rows {
            let found = Self.classify(row)
            if case .forward = found { Issue.record("a Read was forwarded: \(row.note)") }
            #expect(found == row.expected, "\(row.note)")
            #expect(ApprovalGate.forwardedPreview(toolName: row.tool, inputPreview: row.preview) == nil, "a copy of \(row.note)")
            if found == Self.keptRead { kept += 1 } else { refused += 1 }
        }
        #expect(kept >= 1_500 && refused >= 500, "vacuity: \(kept) kept as localOnly.read, \(refused) for a more specific reason")
    }

    /// What can leave the Mac at all, by enumeration: only the Bash row
    /// forwards, its one required argument is the command, every other row
    /// keeps its prompts with a code, each tool on an ordinary preview
    /// forwards only if it is Bash, and of every command this suite holds,
    /// the ones that forward are exactly the listed ones.
    @Test func theOnlyForwardsAreTheListedBashCommands() throws {
        for row in ApprovalGate.toolTable {
            if row.forwards {
                #expect(row.tool == .bash, "\(row.tool) forwards")
                #expect(row.required.map(\.name) == ["command"])
                guard case .command = try #require(row.required.first).kind else {
                    Issue.record("the forwarding row's basis is not the command")
                    continue
                }
            } else {
                #expect(row.localOnly != nil, "\(row.tool)")
            }
        }
        let ordinary: [ApprovalTool: String] = [
            .bash: Self.bashPreview("make test"), .write: Self.writePreview("\(Self.base)/a.txt"),
            .edit: Self.object([("file_path", Self.quote("\(Self.base)/a.txt")), ("old_string", Self.quote("a")),
                                ("new_string", Self.quote("b"))]),
            .notebookEdit: Self.object([("notebook_path", Self.quote("\(Self.base)/n.ipynb")), ("new_source", Self.quote("x"))]),
            .read: Self.readPreview("\(Self.base)/a.txt"),
        ]
        #expect(Set(ordinary.keys) == Set(ApprovalTool.allCases), "every tool")
        for tool in ApprovalTool.allCases {
            let found = Self.gate(tool.rawValue, try #require(ordinary[tool]))
            #expect((found == .forward(tool)) == (tool == .bash), "\(tool): \(found)")
            if case .forward(let forwarded) = found { #expect(forwarded == .bash) }
        }
        let fromRows: [String] = (Self.nearMisses + Self.bypassCatalogue + Self.familyRows + Self.auxiliary)
            .filter { $0.tool == "Bash" }.compactMap(Self.command)
        let corpus = ApprovalGate.bashCommands + Self.noLongerForwarded + fromRows
        #expect(corpus.count >= 200, "vacuity: \(corpus.count) commands")
        let forwarded = Set(corpus.filter { Self.classify(Self.bash($0, Self.forwardBash)) == Self.forwardBash })
        #expect(forwarded == Set(ApprovalGate.bashCommands))
    }

    /// A Bash row's command, as its preview holds it.
    static func command(_ row: Row) -> String? {
        guard let members = ApprovalPreview.parseObject(row.preview),
              case .string(let text)? = members.first(where: { $0.key == "command" })?.value else { return nil }
        return text
    }

    // MARK: - Fail-closed defaults

    static let failClosed: [Row] = [
        // Tool names: exact, case-sensitive, known.
        raw("WebFetch", object([("url", quote("https://example.com"))]), unclassifiable(.unknownTool), "unknown tool WebFetch"),
        raw("Glob", object([("pattern", quote("*"))]), unclassifiable(.unknownTool), "unknown tool Glob"),
        raw("Task", "{}", unclassifiable(.unknownTool), "unknown tool Task"),
        raw("bash", bashPreview("ls"), unclassifiable(.unknownTool), "lowercase bash"),
        raw("BASH", bashPreview("ls"), unclassifiable(.unknownTool), "uppercase BASH"),
        raw("Bash ", bashPreview("ls"), unclassifiable(.malformedToolName), "tool name with a space"),
        raw("", bashPreview("ls"), unclassifiable(.malformedToolName), "empty tool name"),
        raw("B\u{0430}sh", bashPreview("ls"), unclassifiable(.malformedToolName), "Cyrillic a in the tool name"),
        raw(String(repeating: "A", count: ApprovalGate.maxToolNameBytes + 1), "{}",
            unclassifiable(.malformedToolName), "tool name too long"),
        // MCP: local-only in the MVP, whatever the arguments (NapCat's own
        // connector is the floor's, #253).
        raw("mcp__github__create_issue", object([("title", quote("x"))]), .suppress(.localOnlyMCP), "an MCP tool"),
        raw("mcp__napcat__ping", "{}", floor(.ownNames), "an MCP tool with no arguments"),
        // The preview must be one strict JSON object.
        raw("Bash", "", unclassifiable(.previewNotStrictJSON), "empty preview"),
        raw("Bash", "ls -la", unclassifiable(.previewNotStrictJSON), "plain text preview"),
        raw("Bash", "[]", unclassifiable(.previewNotStrictJSON), "array preview"),
        raw("Bash", "\"ls\"", unclassifiable(.previewNotStrictJSON), "string preview"),
        raw("Bash", "{", unclassifiable(.previewNotStrictJSON), "truncated preview"),
        raw("Bash", "{\"command\":\"ls\"} x", unclassifiable(.previewNotStrictJSON), "trailing text"),
        raw("Bash", "{\"command\":\"ls\",}", unclassifiable(.previewNotStrictJSON), "trailing comma"),
        raw("Bash", "{\"command\":\"ls\",\"command\":\"rm -rf x\"}", unclassifiable(.previewNotStrictJSON), "duplicate key"),
        raw("Bash", "{'command':'ls'}", unclassifiable(.previewNotStrictJSON), "single-quoted JSON"),
        raw("Bash", "\u{FEFF}{\"command\":\"ls\"}", unclassifiable(.previewNotStrictJSON), "byte order mark"),
        raw("Bash", "{\"command\":\"ls\",\"timeout\":01}", unclassifiable(.previewNotStrictJSON), "leading zero"),
        raw("Bash", "{\"command\":\"ls\",\"timeout\":+1}", unclassifiable(.previewNotStrictJSON), "plus sign"),
        raw("Bash", "{\"command\":\"ls\",\"timeout\":1.}", unclassifiable(.previewNotStrictJSON), "bare fraction dot"),
        raw("Bash", "{\"command\":\"ls\",\"timeout\":NaN}", unclassifiable(.previewNotStrictJSON), "NaN"),
        raw("Bash", "{\"command\":\"l\\ud800s\"}", unclassifiable(.previewNotStrictJSON), "lone high surrogate"),
        raw("Bash", "{\"command\":\"l\\udc00s\"}", unclassifiable(.previewNotStrictJSON), "lone low surrogate"),
        raw("Bash", "{\"command\":\"ls\u{0A}\"}", unclassifiable(.previewNotStrictJSON), "raw newline in a string"),
        raw("Bash", "{\"command\":\"l\\qs\"}", unclassifiable(.previewNotStrictJSON), "unknown escape"),
        raw("Write", object([("file_path", quote("\(base)/big.txt")),
                             ("content", quote(String(repeating: "x", count: ApprovalGate.maxPreviewBytes)))]),
            unclassifiable(.previewTooLarge), "preview over the size cap"),
        // The argument set is exact and typed.
        raw("Bash", object([("command", quote("ls")), ("shell", quote("zsh"))]), unclassifiable(.unknownArgument), "unknown key"),
        raw("Bash", object([("comm\u{0430}nd", quote("ls"))]), unclassifiable(.unknownArgument), "look-alike key"),
        raw("Bash", object([("description", quote("list"))]), unclassifiable(.missingArgument), "no command"),
        raw("Write", object([("file_path", quote("\(base)/a"))]), unclassifiable(.missingArgument), "Write without content"),
        raw("Bash", object([("command", "[\"ls\"]")]), unclassifiable(.argumentKind), "command as an array"),
        raw("Bash", object([("command", "null")]), unclassifiable(.argumentKind), "command null"),
        raw("Bash", object([("command", quote("git status")), ("timeout", quote("5"))]), unclassifiable(.argumentKind),
            "timeout as a string"),
        raw("Bash", object([("command", quote("git status")), ("run_in_background", quote("true"))]),
            unclassifiable(.argumentKind), "boolean as a string"),
        raw("Bash", object([("command", quote("git status")), ("dangerouslyDisableSandbox", quote("false"))]),
            unclassifiable(.argumentKind), "sandbox flag as a string"),
        raw("Write", object([("file_path", "{\"p\":\"x\"}"), ("content", quote("x"))]), unclassifiable(.argumentKind), "path as an object"),
        // Paths: absolute and canonical.
        write("README.md", unclassifiable(.pathNotCanonical)),
        write("~/notes.txt", unclassifiable(.pathNotCanonical)),
        write("\(base)/../escape.txt", unclassifiable(.pathNotCanonical)),
        write("\(base)/./a.txt", unclassifiable(.pathNotCanonical)),
        write("\(base)//a.txt", unclassifiable(.pathNotCanonical)),
        write("\(base)/dir/", unclassifiable(.pathNotCanonical)),
        write("/", unclassifiable(.pathNotCanonical)),
        write("C:\\x.txt", unclassifiable(.pathNotCanonical)),
        write("\(base)/a\\b.txt", unclassifiable(.pathNotCanonical)),
        write("\(base)/na\u{00EF}ve.txt", unclassifiable(.pathNotCanonical)),
        write("\(base)/.cl\u{0430}ude/settings.json", unclassifiable(.pathNotCanonical)),
        write("\(base)/a\tb.txt", unclassifiable(.pathNotCanonical)),
        write("/" + String(repeating: "a", count: ApprovalGate.maxPathBytes), unclassifiable(.pathNotCanonical)),
        write("\(base)/My Notes/todo.txt", unclassifiable(.pathNotCanonical)),
        read("\(base)/My Notes/todo.txt", unclassifiable(.pathNotCanonical)),
        read("\(base)/a b.txt", unclassifiable(.pathNotCanonical)),
        read("\(base)/a ", unclassifiable(.pathNotCanonical)),
        read("\(base)/ a", unclassifiable(.pathNotCanonical)),
        read("\(base)/\u{00B7}", unclassifiable(.pathNotCanonical)),
        read("\(base)/a\u{00B7}b.txt", unclassifiable(.pathNotCanonical)),
        // A double quote (#159): it would draw a member boundary in the
        // phone's copy. Written plainly or as an escape, in Write too.
        read("\(base)/a\"b.txt", unclassifiable(.pathNotCanonical)),
        read("\(base)/a\",\"limit\":1", unclassifiable(.pathNotCanonical)),
        read("\(base)/a.txt\",\"file_path\":\"\(base)/b.txt", unclassifiable(.pathNotCanonical)),
        raw("Read", object([("file_path", "\"\(base)/a\\u0022b.txt\"")]), unclassifiable(.pathNotCanonical),
            "an escaped double quote in a path"),
        write("\(base)/a\"b.txt", unclassifiable(.pathNotCanonical)),
    ]

    @Test(arguments: failClosed)
    func unknownOrMalformedInputFailsClosed(_ row: Row) {
        #expect(Self.classify(row) == row.expected)
    }

    // MARK: - What the phone shows is what is approved

    /// A character that renders invisibly or reorders text, anywhere in the
    /// preview, refuses it: the phone could not show what would be approved.
    @Test func hiddenOrReorderingCharactersFailClosed() {
        let hidden: [Unicode.Scalar] = ["\u{0007}", "\u{001B}", "\u{007F}", "\u{0085}", "\u{00AD}", "\u{200B}", "\u{200D}",
                                        "\u{200E}", "\u{202E}", "\u{2066}", "\u{2069}", "\u{FEFF}", "\u{E0041}"]
        for scalar in hidden {
            let text = "a\(Character(scalar))b"
            let rows = [
                Self.raw("Write", Self.object([("file_path", Self.quote("\(Self.base)/a.swift")), ("content", Self.quote(text))]),
                         Self.unclassifiable(.hiddenText), "content"),
                Self.raw("Bash", Self.object([("command", Self.quote("ls")), ("description", Self.quote(text))]),
                         Self.unclassifiable(.hiddenText), "Bash description argument"),
                Self.raw("Write", Self.object([("file_path", Self.quote("\(Self.base)/a.swift")), ("content", Self.quote("x")),
                                               (text, Self.quote("x"))]), Self.unclassifiable(.hiddenText), "a key"),
            ]
            for row in rows {
                #expect(Self.classify(row) == row.expected, "U+\(String(scalar.value, radix: 16, uppercase: true)) in \(row.note)")
            }
        }
        let plain = Self.raw("Bash", Self.object([("command", Self.quote("git status")),
                                                  ("description", Self.quote("tab\tnewline\nwindows\r\nemoji \u{1F600} caf\u{00E9}"))]),
                             Self.forwardBash, "tab, newline, CR and ordinary Unicode")
        #expect(Self.classify(plain) == plain.expected)
    }

    // MARK: - Only a faithful preview is read

    static let notFaithful = unclassifiable(.previewNotFaithful)

    /// A preview holding one of the relay's placeholders — in any tool, in
    /// any string or key, written plainly or as escapes, in any letter case,
    /// even in a preview that does not parse — is refused for that reason,
    /// before any tool rule runs. The credential placeholder is secret access.
    static let placeholders: [Row] = [
        read("\(base)/x\u{22EF}y.txt", notFaithful),
        raw("Read", object([("file_path", "\"\(base)/x\\u22efy.txt\"")]), notFaithful, "an escaped placeholder in a path"),
        raw("Read", object([("file_path", "\"\(base)/x\\u22EFy.txt\"")]), notFaithful, "an upper-case escape in a path"),
        bash("ls \u{22EF} 12 code points elided \u{22EF}", notFaithful),
        bash("cat (value unserializable)", notFaithful),
        bash("echo 'code points elided'", notFaithful),
        bash("echo 'CODE POINTS ELIDED'", notFaithful),
        raw("Bash", object([("command", quote("git status")), ("description", quote("x (value unserializable)"))]), notFaithful,
            "a placeholder in a Bash description"),
        raw("Bash", object([("command", quote("git status")), ("description", "\"code points elid\\u0065d\"")]), notFaithful,
            "an escaped placeholder in a Bash description"),
        raw("Write", object([("file_path", quote("\(base)/w.txt")), ("content", quote("HEAD\n\u{22EF} 500 code points elided \u{22EF}\nTAIL"))]),
            notFaithful, "a placeholder in content, between escaped line breaks"),
        raw("Write", object([("file_path", quote("\(base)/w.txt")), ("content", quote("(value unserializable)"))]), notFaithful,
            "a placeholder as the whole content"),
        raw("Edit", object([("file_path", quote("\(base)/a.swift")), ("old_string", quote("a")),
                            ("new_string", "\"(value unserializabl\\u0065)\"")]), notFaithful, "an escaped placeholder in an edit"),
        raw("Read", object([("file_path", quote("\(base)/a.txt")), ("pages", quote("1\u{22EF}3"))]), notFaithful,
            "a placeholder in an optional argument"),
        raw("Read", object([("file_path", quote("\(base)/a.txt")), ("\u{22EF}", quote("x"))]), notFaithful, "a placeholder as a key"),
        raw("mcp__x__y", object([("text", quote("(value unserializable)"))]), notFaithful, "a placeholder in an MCP prompt"),
        raw("Bash", "{\"command\": \"ls\" \u{22EF} 12 code points elided \u{22EF}}", notFaithful,
            "a placeholder in a preview that does not parse"),
        // The credential placeholder.
        read("\(base)/proj/[REDACTED].txt", forbidden(.secretAccess)),
        read("\(base)/proj/[redacted].txt", forbidden(.secretAccess)),
        raw("Read", object([("file_path", "\"\(base)/proj/[REDACT\\u0045D].txt\"")]), forbidden(.secretAccess),
            "an escaped credential placeholder"),
        bash("cat \"[REDACTED]\"", forbidden(.secretAccess)),
        bash("ls [REDACTED]", forbidden(.secretAccess)),
        raw("Bash", object([("command", quote("git status")), ("description", quote("token [REDACTED]"))]), forbidden(.secretAccess),
            "a credential placeholder in a Bash description"),
        raw("Write", object([("file_path", quote("\(base)/a.txt")), ("content", quote("key=[REDACTED]"))]), forbidden(.secretAccess),
            "a credential placeholder in content"),
        raw("Bash", "{\"command\":\"cat [REDACTED]", forbidden(.secretAccess), "a credential placeholder before the preview parses"),
    ]

    @Test(arguments: placeholders)
    func aPreviewHoldingARelayPlaceholderIsRefused(_ row: Row) {
        #expect(Self.classify(row) == row.expected)
    }

    /// The placeholders are matched where the rows above say: each list
    /// entry alone refuses an otherwise forwardable Bash prompt, and turns
    /// a Read that would be kept as `localOnly.read` into its own code.
    @Test func everyPlaceholderRefusesOnItsOwn() {
        for marker in ApprovalGate.unfaithfulMarkers {
            let row = Self.raw("Read", Self.object([("file_path", Self.quote("\(Self.base)/a.txt")), ("pages", Self.quote(marker))]),
                               Self.notFaithful, marker)
            #expect(Self.classify(row) == Self.notFaithful, "\(marker)")
            let bash = Self.raw("Bash", Self.object([("command", Self.quote("git status")), ("description", Self.quote(marker))]),
                                Self.notFaithful, marker)
            #expect(Self.classify(bash) == Self.notFaithful, "\(marker) in a Bash description")
        }
        for marker in ApprovalGate.maskMarkers {
            let row = Self.read("\(Self.base)/\(marker)", Self.forbidden(.secretAccess))
            #expect(Self.classify(row) == row.expected, "\(marker)")
            let bash = Self.raw("Bash", Self.object([("command", Self.quote("git status")), ("description", Self.quote(marker))]),
                                Self.forbidden(.secretAccess), marker)
            #expect(Self.classify(bash) == bash.expected, "\(marker) in a Bash description")
            #expect(marker == marker.lowercased(), "matched case-insensitively")
        }
        #expect(Self.classify(Self.read("\(Self.base)/a.txt", Self.keptRead)) == Self.keptRead, "control")
        #expect(Self.classify(Self.raw("Bash", Self.object([("command", Self.quote("git status")), ("description", Self.quote("x"))]),
                                       Self.forwardBash, "")) == Self.forwardBash, "control")
    }

    /// The whole preview is capped in Unicode code points of the text as
    /// relayed: at the cap it is read, one past it is refused, whatever the
    /// bytes.
    @Test func theWholePreviewIsCappedInCodePoints() {
        let shell = Self.object([("command", Self.quote("git status")), ("description", Self.quote(""))])
        let room = ApprovalGate.maxPreviewScalars - shell.unicodeScalars.count
        func preview(_ description: String) -> String {
            Self.object([("command", Self.quote("git status")), ("description", Self.quote(description))])
        }
        let atCap = preview(String(repeating: "x", count: room))
        let multibyte = preview(String(repeating: "\u{00E9}", count: room))
        #expect(atCap.unicodeScalars.count == ApprovalGate.maxPreviewScalars)
        #expect(multibyte.utf8.count > ApprovalGate.maxPreviewScalars, "more bytes than the cap, as many code points")
        #expect(Self.gate("Bash", atCap) == Self.forwardBash)
        #expect(Self.gate("Bash", multibyte) == Self.forwardBash)
        for over in [preview(String(repeating: "x", count: room + 1)), preview(String(repeating: "\u{00E9}", count: room + 1)),
                     preview(String(repeating: "x", count: 2 * ApprovalGate.maxPreviewScalars))] {
            #expect(Self.gate("Bash", over) == Self.unclassifiable(.previewTooLarge))
        }
        #expect(ApprovalGate.maxPreviewScalars == 3_000)
        // The size is decided before the floor reads anything (#253): a
        // preview past the cap that names the floor is kept for its size,
        // under every set; one at the cap is the floor's.
        let named = preview("Run the NapCat tests " + String(repeating: "x", count: room))
        let namedAtCap = preview("NapCat " + String(repeating: "x", count: room - 7))
        for (_, set) in ApprovalGateOracleTests.nineSets {
            #expect(Self.gate("Bash", named, topic: .unreadable, policy: set) == Self.unclassifiable(.previewTooLarge))
            #expect(Self.gate("Bash", namedAtCap, policy: set) == Self.floor(.ownNames))
        }
    }

    /// A forbidden path with a space is still logged as its family, or as
    /// the floor's code where the floor names it.
    @Test func aForbiddenPathWithASpaceKeepsItsFamily() {
        #expect(Self.classify(Self.read("/Library/Application Support/ClaudeCode/managed-settings.json",
                                        Self.floor(.claudeCodeHelpers)))
            == Self.floor(.claudeCodeHelpers))
        #expect(Self.classify(Self.read("/Users/someone/My Project/.git/config", Self.forbidden(.configurationOrHooks)))
            == Self.forbidden(.configurationOrHooks))
        #expect(Self.classify(Self.read("/Users/someone/My Keys/.ssh/id_rsa", Self.forbidden(.secretAccess)))
            == Self.forbidden(.secretAccess))
    }

    // MARK: - The path alphabet (#159)

    static let pathNotCanonical: ApprovalClassification = unclassifiable(.pathNotCanonical)

    /// Where a character can sit in a path: (before it, after it). Joined
    /// without it, each is a path that passes the path check (a Read of it
    /// is `localOnly.read`).
    static let pathPositions: [(String, String)] = [
        ("", "/Users/someone/a.txt"), ("/", "Users/someone/a.txt"), ("\(base)/", "a.txt"), ("\(base)/a", "b.txt"),
        ("\(base)/dir", "/a.txt"), ("\(base)/a.txt", ""),
    ]

    /// Each character refused after the families is refused wherever it
    /// sits: before the root, first after it, first, inside and last in a
    /// name, and as the path's last character. The same path without it
    /// passes the path check: a Read of it is `localOnly.read`.
    @Test(arguments: ApprovalGate.pathBytesRefusedAfterFamilies)
    func aCharacterRefusedAfterTheFamiliesIsRefusedAnywhere(_ byte: UInt8) {
        let character = Character(Unicode.Scalar(byte))
        for (before, after) in Self.pathPositions {
            let path = "\(before)\(character)\(after)"
            let control = "\(before)\(after)"
            #expect(Self.classify(Self.read(path, Self.pathNotCanonical)) == Self.pathNotCanonical, "Read \(path)")
            #expect(Self.classify(Self.write(path, Self.pathNotCanonical)) == Self.pathNotCanonical, "Write \(path)")
            #expect(Self.classify(Self.read(control, Self.keptRead)) == Self.keptRead, "control: \(control)")
        }
    }

    /// A forbidden path holding one of them is still logged as its family,
    /// whichever family and wherever the character sits; one the floor
    /// names is logged with the floor's code (#253), which comes first.
    @Test(arguments: ApprovalGate.pathBytesRefusedAfterFamilies)
    func aForbiddenPathWithARefusedCharacterKeepsItsFamily(_ byte: UInt8) {
        let character = Character(Unicode.Scalar(byte))
        let paths: [(String, ApprovalSuppression)] = [
            ("/etc/a\(character)b", .forbidden(.privilegeEscalation)), ("/etc/hosts\(character)", .forbidden(.privilegeEscalation)),
            ("/etc/sudoers\(character)", .floor(.privilegedFootprint)),
            ("/Users/someone/.claude/a\(character)b.json", .forbidden(.configurationOrHooks)),
            ("\(Self.base)/\(character)x/.git/config", .forbidden(.configurationOrHooks)),
            ("/Users/someone/.ssh/id\(character)rsa", .forbidden(.secretAccess)),
            ("\(Self.base)/a\(character)b/.env", .forbidden(.secretAccess)),
        ]
        for (path, code) in paths {
            let found = Self.classify(Self.read(path, .suppress(code)))
            #expect(found == .suppress(code), "\(path)")
            guard case .suppress(let suppression) = found else { continue }
            #expect(suppression.auditCode == code.auditCode, "the logged code names the family or the floor's group: \(path)")
        }
    }

    /// Whether a copy's only quotes are its members' own (two per key, two
    /// per string value) and it holds no backslash: then no path in it can
    /// draw a member boundary.
    static func ownQuotesOnly(_ copy: String) throws -> Bool {
        let members: [PreviewMember] = try #require(ApprovalPreview.parseObject(copy))
        let strings: Int = members.filter { if case .string = $0.value { return true } else { return false } }.count
        let quotes: Int = copy.filter { $0 == "\"" }.count
        let own: Int = 2 * (members.count + strings)
        return quotes == own && !copy.contains("\\")
    }

    /// The whole alphabet, character by character: a path passes the path
    /// check with any printable ASCII character from `!` to `~` in a name
    /// except the double quote and the backslash (a Read of it is then
    /// `localOnly.read`: no Read forwards, #231). Those two, the space, a
    /// tab, a newline and a carriage return are `pathNotCanonical`; NUL is
    /// `previewNotStrictJSON`; every other control character is
    /// `hiddenText` (the codes the refusal catalogue names). No Read of a
    /// path holding a passing character, in any of the six positions, has a
    /// copy that could leave the Mac. The wire is unchanged.
    @Test func thePathAlphabetIsPrintableASCIIWithoutQuoteOrBackslash() {
        let pinned: [UInt8] = [UInt8(ascii: " "), UInt8(ascii: "\"")]
        #expect(ApprovalGate.pathBytesRefusedAfterFamilies == pinned)
        let refused: Set<UInt8> = [UInt8(ascii: " "), UInt8(ascii: "\""), UInt8(ascii: "\\")]
        let tabAndLineBreaks: Set<UInt8> = [UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r")]
        var passed = 0
        var withoutCopy = 0
        for byte in UInt8(0)...UInt8(0x7F) {
            let character = Character(Unicode.Scalar(byte))
            let path = "\(Self.base)/a\(character)b.txt"
            let found: ApprovalClassification = Self.classify(Self.read(path, Self.keptRead))
            let printable: Bool = byte >= 0x20 && byte <= 0x7E
            if printable && !refused.contains(byte) {
                #expect(found == Self.keptRead, "byte \(byte)")
                passed += 1
                for (before, after) in Self.pathPositions {
                    let preview: String = Self.readPreview("\(before)\(character)\(after)")
                    #expect(ApprovalGate.forwardedPreview(toolName: "Read", inputPreview: preview) == nil, "byte \(byte)")
                    withoutCopy += 1
                }
            } else if printable || tabAndLineBreaks.contains(byte) {
                #expect(found == Self.pathNotCanonical, "byte \(byte)")
            } else if byte == 0 {
                #expect(found == Self.unclassifiable(.previewNotStrictJSON), "byte \(byte): a NUL escape")
            } else {
                #expect(found == Self.unclassifiable(.hiddenText), "byte \(byte)")
            }
        }
        #expect(passed == 92, "vacuity: 95 printable characters less the space, the quote and the backslash")
        #expect(withoutCopy == 552, "vacuity: the 92 passing characters, each in six positions")
        #expect(ApprovalWire.wireVersion == 1)
        #expect(ApprovalChannel.frameVersion == 2)
    }

    /// Why the quote (#159): the phone draws the gate's copy verbatim, and
    /// in a copy whose only quotes are its members' own (two per key, two
    /// per string value) and that holds no backslash, no path can draw a
    /// member boundary. No Read has a copy any more (#231), and every copy
    /// that can leave still draws only its members' own quotes
    /// (`everyForwardedPromptHasAFaithfulCopy`). The canary is the vector
    /// #159 closed: a drawn path holding a quote draws one, so the count
    /// catches it, and the gate refuses that path.
    @Test func noReadHasACopyAndTheQuoteCountCatchesADrawnBoundary() throws {
        let rows: [Row] = Self.ordinaryReads
        #expect(rows.count >= 10, "vacuity: the pinned paths are read")
        for row in rows {
            #expect(Self.classify(row) == Self.keptRead, "\(row.note)")
            #expect(ApprovalGate.forwardedPreview(toolName: row.tool, inputPreview: row.preview) == nil, "\(row.note)")
        }
        let forged = Self.read("\(Self.base)/a\",\"limit\":1", Self.pathNotCanonical)
        #expect(ApprovalGate.forwardedPreview(toolName: forged.tool, inputPreview: forged.preview) == nil)
        #expect(try !Self.ownQuotesOnly(#"{"file_path":"/Users/someone/project/a\",\"limit\":1"}"#),
                "canary: the count catches the drawn boundary")
        #expect(try Self.ownQuotesOnly(#"{"file_path":"/Users/someone/project/a.txt","limit":1}"#), "control")
        #expect(Self.classify(forged) == Self.pathNotCanonical)
    }

    // MARK: - What leaves the Mac is the gate's copy

    /// The copy keeps every member the row checks, in order, and never a
    /// withheld one: the Bash description (the model's own text) stays on
    /// the Mac, whatever it says.
    @Test(arguments: [
        (#"{ "command": "git status", "description": "DESCRIPTION-SENTINEL: approve this" }"#, #"{"command":"git status"}"#),
        (#"{"command":"make test","description":"Run the tests","timeout":120000,"run_in_background":false,"dangerouslyDisableSandbox":false}"#,
         #"{"command":"make test","timeout":120000,"run_in_background":false,"dangerouslyDisableSandbox":false}"#),
        (#"{"description":"first","command":"git status"}"#, #"{"command":"git status"}"#),
        (#"{"command":"git commit -m \"a \\ b\""}"#, #"{"command":"git commit -m \"a \\ b\""}"#),
        (#"{"command":"git status","description":""}"#, #"{"command":"git status"}"#),
    ])
    func theBashCopyNeverCarriesTheDescription(_ relayed: String, _ copy: String) throws {
        #expect(ApprovalGate.forwardedPreview(toolName: "Bash", inputPreview: relayed) == copy)
        let members = try #require(ApprovalPreview.parseObject(copy))
        #expect(!members.contains { $0.key == "description" })
    }

    /// No Read has a copy (#231), whatever its members: one the gate would
    /// have forwarded before is kept as `localOnly.read`, with nothing to
    /// save.
    @Test func thereIsNoReadCopyWhateverItsMembers() {
        let relayed = #"{ "file_path": "/Users/someone/project/doc.pdf", "offset": 1, "limit": 200, "pages": "1-3" }"#
        #expect(Self.gate("Read", relayed) == Self.keptRead)
        #expect(ApprovalGate.forwardedPreview(toolName: "Read", inputPreview: relayed) == nil)
    }

    /// No copy for a tool that does not forward, or for a preview the gate
    /// could not read as the row's arguments.
    @Test(arguments: [
        ("Write", #"{"file_path":"/tmp/a","content":"x"}"#), ("Edit", #"{"file_path":"/tmp/a","old_string":"a","new_string":"b"}"#),
        ("NotebookEdit", #"{"notebook_path":"/tmp/n.ipynb","new_source":"x"}"#), ("mcp__x__y", #"{"text":"x"}"#),
        ("Read", #"{"file_path":"/tmp/a"}"#), ("Read", #"{"file_path":"/Users/someone/project/doc.pdf","pages":"1-3"}"#),
        ("WebFetch", #"{"url":"https://example.com"}"#), ("bash", #"{"command":"git status"}"#),
        ("Bash", #"{"command":"git status","shell":"zsh"}"#), ("Bash", #"{"command":["git","status"]}"#),
        ("Bash", #"{"command":null}"#), ("Bash", #"{"command":{"a":1}}"#), ("Bash", "not json"),
        ("Bash", #"{"command":"git status","command":"rm -rf x"}"#),
    ])
    func thereIsNoCopyOfWhatCannotForward(_ tool: String, _ preview: String) {
        #expect(ApprovalGate.forwardedPreview(toolName: tool, inputPreview: preview) == nil)
    }

    /// Every prompt the gate forwards has a copy, the copy reads back under
    /// the strict reader as the same members minus the description, the
    /// gate forwards the copy exactly as it forwarded the original, and the
    /// copy's only quotes are its members' own. Since #231 these are Bash
    /// prompts only: every listed command, and every forwarded row above.
    @Test func everyForwardedPromptHasAFaithfulCopy() throws {
        let rows = ApprovalGate.bashCommands.map { Self.bash($0, Self.forwardBash) }
            + Self.auxiliary.filter { $0.expected == Self.forwardBash } + [
            Self.raw("Bash", #"{ "command": "git status", "description": "x" }"#, Self.forwardBash, "relayed spacing"),
            Self.raw("Bash", Self.object([("command", Self.quote("make test")), ("timeout", "600000")]), Self.forwardBash, "timeout"),
        ]
        #expect(rows.count >= 10, "vacuity: \(rows.count) forwarded prompts")
        for row in rows {
            #expect(Self.classify(row) == row.expected, "\(row.note)")
            let copy = try #require(ApprovalGate.forwardedPreview(toolName: row.tool, inputPreview: row.preview), "\(row.note)")
            let original = try #require(ApprovalPreview.parseObject(row.preview))
            #expect(ApprovalPreview.parseObject(copy) == original.filter { $0.key != "description" }, "\(row.note)")
            #expect(Self.gate(row.tool, copy) == row.expected, "\(row.note)")
            #expect(try Self.ownQuotesOnly(copy), "\(row.note): \(copy)")
        }
    }

    /// The Bash description is the one withheld argument.
    @Test func onlyTheBashDescriptionIsWithheld() {
        let withheld = ApprovalGate.toolTable.flatMap { row in
            (row.required + row.optional).filter { if case .withheld = $0.kind { return true } else { return false } }
                .map { "\(row.tool.rawValue).\($0.name)" }
        }
        #expect(withheld == ["Bash.description"])
    }

    // MARK: - Secrets (the alert topic)

    static let topic = "napcat-TESTONLYa1b2c3d4e5f6"
    static let topicValue = ApprovalFloorTopic.value(Array(topic.utf8))

    /// The alert topic is on the gate's floor (#253): anywhere in a prompt,
    /// as written, escaped or before the preview parses, it keeps the prompt
    /// with the floor's code.
    @Test func aKnownSecretAnywhereIsSecretAccess() {
        let escaped = Self.topic.unicodeScalars.map { String(format: "\\u%04x", $0.value) }.joined()
        let rows = [
            Self.bash("echo \(Self.topic)", Self.floor(.alertTopic)),
            Self.raw("Write", Self.object([("file_path", Self.quote("\(Self.base)/a.txt")), ("content", Self.quote("t=\(Self.topic)"))]),
                     Self.floor(.alertTopic), "in content"),
            Self.raw("Write", Self.object([("file_path", Self.quote("\(Self.base)/a.txt")), ("content", "\"\(escaped)\"")]),
                     Self.floor(.alertTopic), "JSON-escaped in content"),
            Self.raw("Bash", Self.object([("command", Self.quote("ls")), ("description", Self.quote(Self.topic))]),
                     Self.floor(.alertTopic), "in the Bash description argument"),
            Self.raw("Bash", "{\"command\":\"\(Self.topic)", Self.floor(.alertTopic), "before the preview even parses"),
            Self.read("\(Self.base)/\(Self.topic).txt", Self.floor(.alertTopic)),
            Self.raw("mcp__x__\(Self.topic.replacingOccurrences(of: "-", with: "_"))", "{}", .suppress(.localOnlyMCP), "control"),
        ]
        for row in rows {
            #expect(Self.classify(row, topic: Self.topicValue) == row.expected, "\(row.note)")
        }
        let toolNameSecret = "SECRETNAME"
        #expect(Self.gate("mcp__\(toolNameSecret)", "{}", topic: .value(Array(toolNameSecret.utf8)))
            == Self.floor(.alertTopic), "in the tool name")
        let described = Self.raw("Bash", Self.object([("command", Self.quote("git status")), ("description", Self.quote(Self.topic))]),
                                 Self.floor(.alertTopic), "a listed command, the topic in its description")
        #expect(Self.classify(described, topic: Self.topicValue) == described.expected)
        #expect(Self.classify(described) == Self.forwardBash, "control: without the secret the same prompt forwards")
        // A topic the floor cannot check for keeps every prompt: one that
        // could not be read, and an empty value.
        for topic: ApprovalFloorTopic in [.unreadable, .value([])] {
            #expect(Self.classify(Self.bash("git status", Self.forwardBash), topic: topic) == .suppress(.floorUnreadable(.topic)))
        }
    }

    /// The gate's names for where the topic lives match the Mac app's own.
    @Test func theSecretNamesMatchTheTopicStorage() {
        #expect(ApprovalGate.secretNames.contains(KeychainItemName.ntfyTopic.account.lowercased()))
        #expect(ApprovalGate.secretNames.contains(RetiredDefaultsKey.lidGuardNtfyTopic.lowercased()))
        #expect(ApprovalGate.secretNames.allSatisfy { $0 == $0.lowercased() }, "matched case-insensitively")
    }

    // MARK: - Audit vocabulary

    /// Every suppression the gate can return, one per audit code.
    static let everySuppression: [ApprovalSuppression] = ApprovalFloorGroup.allCases.map { ApprovalSuppression.floor($0) }
        + ApprovalFloorUnreadable.allCases.map { ApprovalSuppression.floorUnreadable($0) }
        + ForbiddenFamily.allCases.map { ApprovalSuppression.forbidden($0) }
        + [.localOnlyMCP, .localOnlyFileEdit, .localOnlyRead] + Unclassifiable.allCases.map { ApprovalSuppression.unclassifiable($0) }

    @Test func auditCodesAreAClosedVocabulary() {
        #expect(ApprovalSuppression.forbidden(.secretAccess).auditCode == "forbidden.secretAccess")
        #expect(ApprovalSuppression.localOnlyMCP.auditCode == "localOnly.mcp")
        #expect(ApprovalSuppression.localOnlyFileEdit.auditCode == "localOnly.fileEdit")
        #expect(ApprovalSuppression.localOnlyRead.auditCode == "localOnly.read")
        #expect(ApprovalSuppression.unclassifiable(.unknownTool).auditCode == "unclassifiable.unknownTool")
        let all = Self.everySuppression
        #expect(Set(all.map(\.auditCode)).count == all.count, "codes are distinct")
        for code in all.map(\.auditCode) {
            #expect(code.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) || $0 == "." }, "\(code)")
        }
    }

    /// The refusal catalogue names every code the gate logs (an
    /// `unclassifiable` or a floor one in full or by its reason or group
    /// alone, as the catalogue's lists do), names no code the gate does not
    /// have, and its list of the codes names every local-only one. (Only the
    /// vocabulary: the catalogue's rows are not compared with the gate's.)
    @Test func theCatalogueNamesExactlyTheGatesCodes() throws {
        let catalogue = try String(contentsOf: LidGuardStructureTests.repoRoot()
            .appendingPathComponent("design/remote-approvals-catalogue.md"), encoding: .utf8)
        let codes = Self.everySuppression.map(\.auditCode)
        for (suppression, code) in zip(Self.everySuppression, codes) {
            var named = catalogue.contains("`\(code)`")
            switch suppression {
            case .unclassifiable(let reason): named = named || catalogue.contains("`\(reason.rawValue)`")
            case .floor(let group): named = named || catalogue.contains("`\(group.rawValue)`")
            case .floorUnreadable(let reason): named = named || catalogue.contains("`\(reason.rawValue)`")
            case .forbidden, .localOnlyMCP, .localOnlyFileEdit, .localOnlyRead: break
            }
            #expect(named, "the catalogue never names \(code)")
        }
        let prefixes = #"(?:forbidden|localOnly|unclassifiable|floorUnreadable|floor)\."#
        let cited = Set(ApprovalRecordPathStructureTests.matches(#"(?<![A-Za-z0-9_])"# + prefixes + #"[A-Za-z]+"#, in: catalogue))
        #expect(!cited.isEmpty && cited.isSubset(of: codes), "codes the gate does not have: \(cited.subtracting(codes).sorted())")
        let anchor = try #require(catalogue.range(of: "The codes are the gate's own:"), "the catalogue's list of the codes")
        let rest = catalogue[anchor.upperBound...]
        let list = String(rest[..<(rest.range(of: "\n\n")?.lowerBound ?? rest.endIndex)])
        let listed = Set(ApprovalRecordPathStructureTests.matches("`" + prefixes + "[^`]+`", in: list))
        let expected = Set(["`floor.<group>`", "`floorUnreadable.<reason>`", "`forbidden.<family>`", "`unclassifiable.<reason>`"]
            + codes.filter { $0.hasPrefix("localOnly.") }.map { "`\($0)`" })
        #expect(listed == expected, "the catalogue's list of the codes: \(listed.sorted())")
    }

    // MARK: - The strict preview reader

    @Test func theReaderDecodesEscapesAndKeepsOrder() throws {
        let members = try #require(ApprovalPreview.parseObject(
            "{ \"a\" : \"\\u00e9\\ud83d\\ude00\\n\\/\" , \"b\":[1,-0.5e+3,true,false,null,{\"c\":\"d\"}] }"))
        #expect(members.map(\.key) == ["a", "b"])
        #expect(members[0].value == .string("\u{00E9}\u{1F600}\n/"))
        #expect(ApprovalPreview.strings(in: members) == ["a", "\u{00E9}\u{1F600}\n/", "b", "c", "d"])
    }

    @Test func theReaderRefusesDuplicatesAndDepthAtEveryLevel() {
        #expect(ApprovalPreview.parseObject("{\"a\":{\"b\":1,\"b\":2}}") == nil, "nested duplicate")
        #expect(ApprovalPreview.parseObject("{\"\\u0061\":1,\"a\":2}") == nil, "duplicate after decoding")
        let deep = { (levels: Int) in "{\"a\":" + String(repeating: "[", count: levels) + String(repeating: "]", count: levels) + "}" }
        #expect(ApprovalPreview.parseObject(deep(ApprovalPreview.maxDepth)) != nil, "at the limit")
        #expect(ApprovalPreview.parseObject(deep(ApprovalPreview.maxDepth + 1)) == nil, "past the limit")
        #expect(ApprovalPreview.parseObject("{\"a\":\"\\u0000\"}") == nil, "NUL")
        #expect(ApprovalPreview.parseObject("{\"a\":1e}") == nil, "bare exponent")
        #expect(ApprovalPreview.parseObject("{\"a\":-}") == nil, "bare minus")
        #expect(ApprovalPreview.parseObject("{\"a\":.5}") == nil, "leading dot")
        #expect(ApprovalPreview.parseObject("{\"a\":tru}") == nil, "truncated literal")
        #expect(ApprovalPreview.parseObject("{\"a\":1" + String(repeating: "0", count: ApprovalPreview.maxNumberBytes) + "}") == nil,
                "number past the length cap")
        #expect(ApprovalPreview.parseObject(" {} ") == [], "whitespace around an empty object")
    }

    // MARK: - The floor and the policy (#253)

    /// The floor's second pass reads every decoded string as free text, and
    /// its ASCII rule later reads the row's names: so the strings a row reads
    /// as names are scanned for names exactly as free text is, which this
    /// pins on every spelling of the floor's catalogue and on the corpus.
    @Test func theNameScanReadsANameAsItReadsFreeText() {
        var texts: [String] = ApprovalFloorTests.coveredSpellings.compactMap { $0.strings.first.map(ApprovalFloor.text(of:)) }
        for index in 0..<2_000 {
            guard let members = ApprovalPreview.parseObject(ApprovalGateOracleTests.corpusInput(index).preview) else { continue }
            texts += ApprovalPreview.strings(in: members)
        }
        #expect(texts.count >= 3_000, "vacuity: \(texts.count) strings")
        var named = 0
        for text in texts {
            for topic: ApprovalFloorTopic in [.absent, .value(Array(ApprovalFloorTests.topic.utf8))] {
                let asName = ApprovalFloor.matchedGroups([.naming(text)], topic: topic)
                #expect(asName == ApprovalFloor.matchedGroups([.freeText(text)], topic: topic), "\(text.debugDescription)")
                if !asName.isEmpty { named += 1 }
            }
        }
        #expect(named >= 300, "vacuity: \(named) strings name the floor")
    }

    /// The strings a row reads as names: its command and its paths, as
    /// strings, in the preview's order; nothing else.
    @Test func aRowsNamesAreItsCommandAndItsPaths() throws {
        func names(_ tool: String, _ preview: String) throws -> [String] {
            let row = try #require(ApprovalGate.toolTable.first { $0.tool.rawValue == tool })
            return ApprovalGate.namingStrings(try #require(ApprovalPreview.parseObject(preview)), row)
        }
        #expect(try names("Bash", #"{"description":"d","command":"git status","timeout":5}"#) == ["git status"])
        #expect(try names("Write", #"{"file_path":"/tmp/a","content":"c"}"#) == ["/tmp/a"])
        #expect(try names("Edit", #"{"file_path":"/tmp/a","old_string":"o","new_string":"n","replace_all":true}"#) == ["/tmp/a"])
        #expect(try names("NotebookEdit", #"{"notebook_path":"/tmp/n.ipynb","new_source":"s","cell_id":"c"}"#) == ["/tmp/n.ipynb"])
        #expect(try names("Read", #"{"file_path":"/tmp/a","pages":"1-3","offset":1}"#) == ["/tmp/a"])
        #expect(try names("Bash", #"{"command":["git","status"]}"#).isEmpty, "a command that is not a string is no name")
    }

    /// Every family a path or a command names is collected, not just the
    /// first: each is a risky kind the prompt carries.
    @Test func everyFamilyAPromptNamesIsCollected() {
        let paths: [(String, Set<ApprovalRiskyKind>)] = [
            ("/Users/someone/.claude/.env", [.claudeConfig, .secrets]), ("/etc/.ssh/x", [.privileged, .secrets]),
            ("/Users/someone/project/.git/credentials", [.claudeConfig, .secrets]), ("/Users/someone/project/a.txt", []),
        ]
        for (path, kinds) in paths {
            var found = ApprovalGate.Findings()
            _ = ApprovalGate.pathRefusal(Array(path.utf8), &found)
            #expect(found.riskyKinds == kinds, "\(path): \(found.families)")
        }
        let commands: [(String, Set<ApprovalRiskyKind>)] = [
            ("cat ~/.ssh/x && ls ~/.config/git", [.secrets, .claudeConfig]), ("sudo ls ~/.claude", [.privileged, .claudeConfig]),
            ("ls /etc && cat .env && cat .zshrc", [.privileged, .secrets, .claudeConfig]), ("git status", []),
            ("cat a/../.ssh/x", [.secrets]),
        ]
        for (command, kinds) in commands {
            var found = ApprovalGate.Findings()
            _ = ApprovalGate.commandRefusal(Array(command.utf8), &found)
            #expect(found.riskyKinds == kinds, "\(command): \(found.families)")
        }
        // The code is the first family found, as the gate logged it before.
        #expect(Self.classify(Self.bash("sudo ls ~/.claude", Self.notInTable)) == Self.forbidden(.privilegeEscalation))
        #expect(Self.classify(Self.read("/Users/someone/.claude/.env", Self.keptRead)) == Self.forbidden(.configurationOrHooks))
    }

    /// Kept for good under every set, with the code the gate has always
    /// logged: an unsandboxed run, a background run, and a listed command
    /// with an unknown argument. A listed command kept only for the
    /// credential mask is logged with the first reason the set does not
    /// admit, and every set admits the listed commands.
    @Test func whatIsFinalStaysFinalUnderEverySet() {
        let sets = ApprovalGateOracleTests.nineSets
        let finals: [(String, ApprovalClassification)] = [
            (#"{"command":"git status","dangerouslyDisableSandbox":true}"#, Self.forbidden(.privilegeEscalation)),
            (#"{"command":"git status","run_in_background":true}"#, Self.unclassifiable(.argumentValue)),
            (#"{"command":"git status","shell":"zsh"}"#, Self.unclassifiable(.unknownArgument)),
            (#"{"command":"git status","description":"[REDACTED] \u200b"}"#, Self.forbidden(.secretAccess)),
        ]
        for (name, set) in sets {
            #expect(set.kinds.contains(.listedCommand), "\(name) admits the listed commands")
            for (preview, listedOnly) in finals.dropLast() {
                #expect(Self.gate("Bash", preview, policy: set) == listedOnly, "\(name): \(preview)")
            }
            let masked = Self.gate("Bash", finals[3].0, policy: set)
            #expect(masked == (set.riskyKinds.contains(.secrets) ? Self.unclassifiable(.hiddenText) : finals[3].1), "\(name): \(masked)")
        }
    }

    // MARK: - Structure locks

    static func gateCode() throws -> String { try WireContractTests.wireCode("ApprovalClassification.swift") }

    /// THERE IS NO DEFAULT-FORWARD BRANCH: `.forward(` is constructed exactly
    /// once, after the table lookup whose miss refuses and after the policy
    /// and the gate's copy; no switch has a catch-all; no row forwards by
    /// omission; the description never reaches the gate; the gate's steps
    /// come in their order, each floor pass final; and the set the gate is
    /// handed is read in its policy step and its codes alone.
    @Test func theGateHasNoDefaultForwardBranch() throws {
        let code = try Self.gateCode()
        #expect(Self.defaultForwardFailures(code).isEmpty, "\(Self.defaultForwardFailures(code))")
    }

    static let missRefusal = "else {\n            return kept(.unclassifiable(.unknownTool))\n        }"
    /// The gate's last steps, in one block, the single forward last: a row
    /// with a local-only code keeps its prompt with that code, read from the
    /// table (never a code fixed here); then the policy, which forwards only
    /// when the set admits the row's kind and every risky kind found; then
    /// the gate's own copy.
    static let localOnlyRefusal = "if let localOnly = row.localOnly {\n            return kept(localOnly)\n        }\n"
        + "        guard policy.admits(row.kind, carrying: found.riskyKinds) else {\n"
        + "            return kept(.unclassifiable(.commandNotInTable))\n        }\n"
        + "        guard forwardedPreview(toolName: toolName, inputPreview: inputPreview) != nil else {\n"
        + "            return kept(.unclassifiable(.previewNotStrictJSON))\n        }\n"
        + "        return .forward(row.tool)"
    /// The gate's signature: the tool name, the preview, the topic and the
    /// effective set, none with a default (the description is never an
    /// input).
    static let signature = "public static func classify(toolName: String, inputPreview: String, topic: ApprovalFloorTopic,\n"
        + "                                policy: ApprovalForwardingSet) -> ApprovalClassification {"
    /// A floor pass, final: its outcome returns at once.
    static func floorPass(_ strings: String) -> String {
        "if let floor = floorRefusal(ApprovalFloor.outcome(of: \(strings), topic: topic)) {\n            return .suppress(floor)\n        }"
    }
    /// The gate's order, each step once, in this order: the size check and
    /// directly after it the floor over the tool name and the raw preview;
    /// the strict reader; hidden text and directly after it the floor over
    /// every decoded string; the MCP tools; the table's miss; the row's
    /// refusal and directly after it the floor's ASCII rule over the row's
    /// names; and the last steps (`localOnlyRefusal`).
    static let orderAnchors: [String] = [
        "return .suppress(.unclassifiable(.previewTooLarge))\n        }\n        "
            + floorPass("[.naming(toolName), .freeText(inputPreview)]"),
        "guard let members = ApprovalPreview.parseObject(inputPreview) else {",
        "return kept(.unclassifiable(.hiddenText))\n        }\n        " + floorPass("strings.map { .freeText($0) }"),
        "if name.starts(with: mcpPrefix.utf8) {",
        missRefusal,
        "if let refusal = refusal(members, row, &found) {\n            return kept(refusal)\n        }\n"
            + "        let names: [ApprovalFloorString] = ([toolName] + namingStrings(members, row)).map { .naming($0) }\n        "
            + floorPass("names"),
        localOnlyRefusal,
    ]
    /// Where the gate reads the set it is handed: its signature, the code a
    /// kept prompt is logged with, and the policy's one guard.
    static let policySites: [String: Int] = [
        "policy: ApprovalForwardingSet) -> ApprovalClassification {": 1,
        ".suppress(found.firstUnadmitted(by: policy) ?? reason)": 1,
        "guard policy.admits(row.kind, carrying: found.riskyKinds) else {": 1,
        "func firstUnadmitted(by policy: ApprovalForwardingSet) -> ApprovalSuppression? {": 1,
        "families.first { !policy.riskyKinds.contains($0.riskyKind) }.map { .forbidden($0) }": 1,
    ]
    /// A row forwards when its local-only code is nil, so no row may forward
    /// by leaving its code out: the member is declared on exactly this line,
    /// a `let` with no default (a `var` optional gets an implicit `nil`, and
    /// the memberwise init would then let a row omit it).
    static let localOnlyDeclaration = "        let localOnly: ApprovalSuppression?"
    /// Whole words, however they are spaced: `localOnly: nil` is written
    /// once (the Bash row), and the code is never a `var` or given a default
    /// (on the member or on an init's parameter).
    static let omissionPins: [(pattern: String, expected: Int, rule: String)] = [
        (#"(?<![A-Za-z0-9_])localOnly\s*:\s*nil(?![A-Za-z0-9_])"#, 1, "`localOnly: nil` is written once, in the Bash row"),
        (#"(?<![A-Za-z0-9_])var\s+localOnly(?![A-Za-z0-9_])"#, 0, "the row's local-only code is never a `var`"),
        (#"(?<![A-Za-z0-9_])localOnly\s*:\s*ApprovalSuppression\?\s*="#, 0, "the row's local-only code has no default"),
    ]

    static func defaultForwardFailures(_ code: String) -> [String] {
        var failures: [String] = []
        let forwards = code.components(separatedBy: ".forward(").count - 1
        if forwards != 1 { failures.append("`.forward(` is constructed \(forwards) times, expected once") }
        for token in ["default:", "case _", "?? .forward", "fallthrough"] where code.contains(token) {
            failures.append("'\(token)' in the gate")
        }
        if let miss = code.range(of: missRefusal), let forward = code.range(of: "return .forward(row.tool)") {
            if forward.lowerBound < miss.upperBound { failures.append("the forward precedes the table-miss refusal") }
        } else {
            failures.append("the table-miss refusal or the single forward is missing")
        }
        if !code.contains(localOnlyRefusal) {
            failures.append("the single forward must follow the row's local-only guard directly")
        }
        for pin in omissionPins {
            let found = ApprovalRecordPathStructureTests.matches(pin.pattern, in: code).count
            if found != pin.expected { failures.append("\(pin.rule) (found \(found))") }
        }
        let declarations = code.split(separator: "\n", omittingEmptySubsequences: false).filter {
            $0.hasPrefix(localOnlyDeclaration) && $0.dropFirst(localOnlyDeclaration.count).allSatisfy { $0 == " " || $0 == "\t" }
        }
        if declarations.count != 1 {
            failures.append("the row's local-only code must be declared once, exactly as `\(localOnlyDeclaration)` (found \(declarations.count))")
        }
        if !code.contains(signature) {
            failures.append("classify's parameters changed (the description must never be an input; the topic and the set have no default)")
        }
        var cursor = code.startIndex
        for anchor in orderAnchors {
            guard ApprovalChannelStructureTests.count(anchor, in: code) == 1,
                  let found = code.range(of: anchor), found.lowerBound >= cursor else {
                failures.append("the gate's order: '\(anchor.prefix(60))' must come once, after the step before it")
                continue
            }
            cursor = found.upperBound
        }
        failures += ApprovalRecordPathStructureTests.siteFailures(#"\bpolicy\b"#, in: code, file: "ApprovalClassification.swift", allowed: policySites,
                                            rule: "the gate reads the set it is handed in its policy step and its codes alone")
        return failures
    }

    /// The lock can fail: each planted default-forward is caught.
    @Test func theDefaultForwardLockCatchesMutants() throws {
        let code = try Self.gateCode()
        let mutants = [
            code.replacingOccurrences(of: "return kept(.unclassifiable(.unknownTool))", with: "return .forward(.bash)"),
            code.replacingOccurrences(of: "        case (.path, _),", with: "        default: return nil\n        case (.path, _),"),
            code + "\nlet x = y ?? .forward(.bash)\n",
            code.replacingOccurrences(of: "inputPreview: String, topic", with: "inputPreview: String, description: String, topic"),
            code.replacingOccurrences(of: "if let localOnly = row.localOnly {", with: "if false, let localOnly = row.localOnly {"),
            code.replacingOccurrences(of: "        if let localOnly = row.localOnly {\n            return kept(localOnly)\n        }\n",
                                      with: ""),
            code.replacingOccurrences(of: "            return kept(localOnly)\n", with: "            return kept(.localOnlyFileEdit)\n"),
            // #253: the floor after the policy; a floor match that does not
            // return; too-large decided after the floor; the second pass
            // dropped; the policy step dropped, or reading a set of its own;
            // a default on the topic or the set; and the old signature.
            code.replacingOccurrences(of: "        " + Self.floorPass("[.naming(toolName), .freeText(inputPreview)]") + "\n", with: "")
                .replacingOccurrences(of: "        return .forward(row.tool)\n",
                                      with: "        " + Self.floorPass("[.naming(toolName), .freeText(inputPreview)]") + "\n        return .forward(row.tool)\n"),
            code.replacingOccurrences(of: Self.floorPass("strings.map { .freeText($0) }"),
                                      with: "if let floor = floorRefusal(ApprovalFloor.outcome(of: strings.map { .freeText($0) }, topic: topic)) {\n"
                                        + "            _ = floor\n        }"),
            code.replacingOccurrences(of: "        guard preview.count <= maxPreviewBytes, inputPreview.unicodeScalars.count <= maxPreviewScalars else {\n"
                                        + "            return .suppress(.unclassifiable(.previewTooLarge))\n        }\n", with: "")
                .replacingOccurrences(of: "        var found = Findings()\n", with: "        guard preview.count <= maxPreviewBytes, "
                                        + "inputPreview.unicodeScalars.count <= maxPreviewScalars else {\n"
                                        + "            return .suppress(.unclassifiable(.previewTooLarge))\n        }\n        var found = Findings()\n"),
            code.replacingOccurrences(of: "        " + Self.floorPass("strings.map { .freeText($0) }") + "\n", with: ""),
            code.replacingOccurrences(of: "        guard policy.admits(row.kind, carrying: found.riskyKinds) else {\n"
                                        + "            return kept(.unclassifiable(.commandNotInTable))\n        }\n", with: ""),
            code.replacingOccurrences(of: "guard policy.admits(row.kind, carrying: found.riskyKinds) else {",
                                      with: "guard ApprovalForwardingSet.listedOnly.admits(row.kind, carrying: found.riskyKinds) else {"),
            code.replacingOccurrences(of: "topic: ApprovalFloorTopic,\n", with: "topic: ApprovalFloorTopic = .absent,\n"),
            code.replacingOccurrences(of: "policy: ApprovalForwardingSet) -> ApprovalClassification {",
                                      with: "policy: ApprovalForwardingSet = .listedOnly) -> ApprovalClassification {"),
            code.replacingOccurrences(of: Self.signature,
                                      with: "public static func classify(toolName: String, inputPreview: String, secrets: [String] = []) -> ApprovalClassification {"),
            // A row that forwards by omission (#231): a second row written
            // with no code, spaced or not; the member made a `var`, given a
            // default, or both with the Bash row leaving its code out; an
            // init that defaults the code; and the member made a `var`
            // beside a decoy of its declaration line.
            code.replacingOccurrences(of: "ToolRow(tool: .read, kind: .outsideRead, localOnly: .localOnlyRead,",
                                      with: "ToolRow(tool: .read, kind: .outsideRead, localOnly: nil,"),
            code.replacingOccurrences(of: "ToolRow(tool: .read, kind: .outsideRead, localOnly: .localOnlyRead,",
                                      with: "ToolRow(tool: .read, kind: .outsideRead, localOnly:nil,"),
            code.replacingOccurrences(of: Self.localOnlyDeclaration + "\n", with: "        var localOnly: ApprovalSuppression?\n"),
            code.replacingOccurrences(of: Self.localOnlyDeclaration + "\n", with: Self.localOnlyDeclaration + " = nil\n"),
            code.replacingOccurrences(of: Self.localOnlyDeclaration + "\n", with: "        var localOnly: ApprovalSuppression? = nil\n")
                .replacingOccurrences(of: "ToolRow(tool: .bash, kind: .listedCommand, localOnly: nil, ", with: "ToolRow(tool: .bash, kind: .listedCommand, "),
            code.replacingOccurrences(of: "        var forwards: Bool {", with: "        init(tool: ApprovalTool, localOnly: ApprovalSuppression? = nil, "
                + "required: [Argument], optional: [Argument]) {\n            self.tool = tool\n            self.localOnly = localOnly\n"
                + "            self.required = required\n            self.optional = optional\n        }\n        var forwards: Bool {"),
            code.replacingOccurrences(of: Self.localOnlyDeclaration + "\n", with: "        var localOnly: ApprovalSuppression?\n")
                + "\nfunc zz() {\n" + Self.localOnlyDeclaration + "\n}\n",
        ]
        for mutant in mutants {
            #expect(mutant != code, "canary setup")
            #expect(!Self.defaultForwardFailures(mutant).isEmpty, "a mutant was NOT caught")
        }
        // Over-match controls: a trailing comment on the declaration line, a
        // comment naming what the omission pins look for, and names that
        // only contain the pinned ones.
        let raw = try String(contentsOf: WireContractTests.wireDirectory().appendingPathComponent("ApprovalClassification.swift"),
                             encoding: .utf8)
        let controls = LidGuardStructureTests.codeOnly(
            raw.replacingOccurrences(of: Self.localOnlyDeclaration + "\n", with: Self.localOnlyDeclaration + "  // nil: the row forwards\n")
                + "\n// A row with `localOnly: nil` forwards; a `var localOnly` would let a row omit it.\n"
                + "let zz_localOnly: nil, zz = (localOnlyCode: nil, localOnly: nilCode)\n"
                + "struct ZZ { var localOnlyNote: ApprovalSuppression? = nil }\n")
        #expect(controls != code, "the controls applied")
        #expect(Self.defaultForwardFailures(controls).isEmpty, "over-match: \(Self.defaultForwardFailures(controls))")
    }

    /// A shell, an interpreter, a wrapper that runs its arguments, or a
    /// command that deletes, moves or fetches.
    static let executors: Set<String> = ["sh", "bash", "zsh", "fish", "env", "xargs", "exec", "eval", "command", "builtin", "source",
                                         ".", "nohup", "nice", "time", "timeout", "watch", "python", "python3", "node", "perl",
                                         "ruby", "osascript", "awk", "sed", "find", "cd", "open", "curl", "wget", "ssh", "scp", "rm",
                                         "mv", "cp", "chmod", "tee", "dd", "run", "npx", "install", "add", "push", "-c"]

    /// The list never names an executor, or a one-word forbidden command, as
    /// any of its words.
    @Test func theBashListHasNoExecutors() {
        let words = Set(ApprovalGate.bashCommands.flatMap { $0.split(separator: " ").map(String.init) })
        #expect(words.isDisjoint(with: Self.executors), "\(words.intersection(Self.executors))")
        let forbidden = Set(ApprovalGate.commandFamilies.filter { $0.words.count == 1 }.map { $0.words[0] })
        #expect(words.isDisjoint(with: forbidden), "\(words.intersection(forbidden))")
    }

    @Test func theToolTableIsExactlyTheForwardableTools() {
        let tools = ApprovalGate.toolTable.map(\.tool)
        #expect(tools == ApprovalTool.allCases, "one row per tool, in order")
        #expect(ApprovalGate.toolTable.filter(\.forwards).map(\.tool) == [.bash],
                "the file-edit tools and Read are local-only")
        #expect(ApprovalGate.toolTable.map(\.localOnly) == [nil, .localOnlyFileEdit, .localOnlyFileEdit, .localOnlyFileEdit, .localOnlyRead],
                "each kept tool with its own code")
        #expect(!ApprovalGate.toolTable.contains { $0.tool.rawValue.hasPrefix(ApprovalGate.mcpPrefix) })
        for row in ApprovalGate.toolTable {
            let names = (row.required + row.optional).map(\.name)
            #expect(Set(names).count == names.count, "\(row.tool): an argument is listed twice")
        }
    }
}
