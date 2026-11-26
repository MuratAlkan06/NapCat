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
/// command (slice S-GATE: each split-audited), and every unknown or malformed
/// input must fail closed. Fixtures are synthetic — no real topic, no real
/// home directory.
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
    static func unclassifiable(_ reason: Unclassifiable) -> ApprovalClassification { .suppress(.unclassifiable(reason)) }
    static let outside = unclassifiable(.commandOutsideGrammar)
    static let notInTable = unclassifiable(.commandNotInTable)
    static let forwardBash = ApprovalClassification.forward(.bash)

    static func classify(_ row: Row, secrets: [String] = []) -> ApprovalClassification {
        ApprovalGate.classify(toolName: row.tool, inputPreview: row.preview, secrets: secrets)
    }

    // MARK: - Forbidden families: never forwarded

    static let privilegeEscalation: [Row] = [
        bash("sudo ls", forbidden(.privilegeEscalation)),
        bash("sudo -n /usr/local/napcat/smc -k CHTE -r", forbidden(.privilegeEscalation)),
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
        bash("pmset -a disablesleep 1", forbidden(.privilegeEscalation)),
        bash("ls /usr/local/napcat", forbidden(.privilegeEscalation)),
        bash("cat /etc/sudoers", forbidden(.privilegeEscalation)),
        bash("ls /Library/LaunchDaemons", forbidden(.privilegeEscalation)),
        bash("cat /private/etc/hosts", forbidden(.privilegeEscalation)),
        write("/etc/sudoers.d/napcat", forbidden(.privilegeEscalation)),
        write("/usr/local/napcat/smc", forbidden(.privilegeEscalation)),
        write("/usr/local/bin/git", forbidden(.privilegeEscalation)),
        write("/Library/LaunchDaemons/com.example.plist", forbidden(.privilegeEscalation)),
        write("/Library/PrivilegedHelperTools/helper", forbidden(.privilegeEscalation)),
        write("\(base)/bin/sudo", forbidden(.privilegeEscalation)),
        read("/private/etc/sudoers", forbidden(.privilegeEscalation)),
        raw("Bash", object([("command", quote("ls")), ("dangerouslyDisableSandbox", "true")]),
            forbidden(.privilegeEscalation), "Bash outside the sandbox"),
    ]

    static let configurationOrHooks: [Row] = [
        bash("cat ~/.claude/settings.json", forbidden(.configurationOrHooks)),
        bash("ls .claude", forbidden(.configurationOrHooks)),
        bash("cat CLAUDE.md", forbidden(.configurationOrHooks)),
        bash("cat .mcp.json", forbidden(.configurationOrHooks)),
        bash("mkdir -p .git/hooks", forbidden(.configurationOrHooks)),
        bash("ls .husky", forbidden(.configurationOrHooks)),
        bash("git config core.hooksPath hooks", forbidden(.configurationOrHooks)),
        bash("claude mcp add evil", forbidden(.configurationOrHooks)),
        bash("crontab -l", forbidden(.configurationOrHooks)),
        bash("cat ~/.zshrc", forbidden(.configurationOrHooks)),
        write("/Users/someone/.claude/settings.json", forbidden(.configurationOrHooks)),
        write("/Users/someone/.claude/hooks/napcat-busy-hook.sh", forbidden(.configurationOrHooks)),
        write("\(base)/.claude/settings.local.json", forbidden(.configurationOrHooks)),
        write("/Users/someone/.CLAUDE/settings.json", forbidden(.configurationOrHooks)),
        write("/Users/someone/.claude.json", forbidden(.configurationOrHooks)),
        write("\(base)/.mcp.json", forbidden(.configurationOrHooks)),
        write("\(base)/CLAUDE.md", forbidden(.configurationOrHooks)),
        write("\(base)/sub/CLAUDE.local.md", forbidden(.configurationOrHooks)),
        write("/Library/Application Support/ClaudeCode/managed-settings.json", forbidden(.configurationOrHooks)),
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
        bash("security find-generic-password -s x -w", forbidden(.secretAccess)),
        bash("cat ~/.ssh/id_rsa", forbidden(.secretAccess)),
        bash("ls ~/Library/Keychains", forbidden(.secretAccess)),
        bash("cat ~/.aws/credentials", forbidden(.secretAccess)),
        bash("cat .env", forbidden(.secretAccess)),
        bash("cat .env.local", forbidden(.secretAccess)),
        bash("cat server.pem", forbidden(.secretAccess)),
        bash("cat ~/.config/gh/hosts.yml", forbidden(.secretAccess)),
        bash("echo ntfy-topic", forbidden(.secretAccess)),
        bash("echo lidGuardNtfyTopic", forbidden(.secretAccess)),
        read("/Users/someone/.ssh/id_ed25519", forbidden(.secretAccess)),
        read("/Users/someone/.SSH/config", forbidden(.secretAccess)),
        read("/Users/someone/Library/Keychains/login.keychain-db", forbidden(.secretAccess)),
        read("/Users/someone/Library/Preferences/com.muratalkan.napcat.plist", forbidden(.secretAccess)),
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
            forbidden(.secretAccess), "the topic's keychain account named in content"),
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

    /// Each path rule suppresses Write, Read and a Bash word, in any letter
    /// case, as its own family.
    @Test func everyPathRuleSuppressesEveryPathTool() {
        #expect(ApprovalGate.pathRules.count >= 40, "vacuity: the table is loaded")
        for rule in ApprovalGate.pathRules {
            let path = Self.samplePath(rule.pattern)
            let expected = Self.forbidden(rule.family)
            for row in [Self.write(path, expected), Self.write(path.uppercased(), expected), Self.read(path, expected),
                        Self.bash("cat '\(path)'", expected)] {
                #expect(Self.classify(row) == expected, "\(row.note)")
            }
        }
    }

    @Test func everyCommandFamilyIsForbidden() {
        for rule in ApprovalGate.commandFamilies {
            let row = Self.bash(rule.words.joined(separator: " ") + " x", Self.forbidden(rule.family))
            #expect(Self.classify(row) == row.expected, "\(row.note)")
        }
    }

    @Test func everyCommandNeedleIsForbiddenInAnyCase() {
        for needle in ApprovalGate.commandNeedles {
            for text in [needle.text, needle.text.uppercased()] {
                let row = Self.bash("echo '\(text)'", Self.forbidden(needle.family))
                #expect(Self.classify(row) == row.expected, "\(row.note)")
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
        bash("Security find-generic-password", notInTable),
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
        #expect(ApprovalGate.classify(toolName: "Bash", inputPreview: preview) == .forward(.bash))
    }

    static let forwardableFiles: [Row] = [
        read("\(base)/Package.swift", .forward(.read)),
        read("\(base)/.github/workflows/ci.yml", .forward(.read)),
        read("/tmp/scratch.txt", .forward(.read)),
        raw("Read", object([("file_path", quote("\(base)/doc.pdf")), ("offset", "1"), ("limit", "200"), ("pages", quote("1-3"))]),
            .forward(.read), "Read with every optional argument"),
        // The path alphabet (#159): dot, dash, underscore, slash and tilde,
        // and the punctuation that stays allowed because it draws no quote
        // in the phone's copy: real paths hold it.
        read("\(base)/Sources/my_module/file-name.v2.swift", .forward(.read)),
        read("\(base)/notes~1.txt", .forward(.read)),
        read("\(base)/~$report.docx", .forward(.read)),
        read("\(base)/app/[slug]/page.tsx", .forward(.read)),
        read("\(base)/app/[...slug]/page.tsx", .forward(.read)),
        read("\(base)/app/(marketing)/page.tsx", .forward(.read)),
        read("\(base)/{{cookiecutter.project_slug}}/README.md", .forward(.read)),
        read("\(base)/data/a,b.csv", .forward(.read)),
        read("\(base)/logs/12:30.log", .forward(.read)),
        read("\(base)/it's-done.txt", .forward(.read)),
        read("\(base)/icon#1@2x!.png", .forward(.read)),
        read("\(base)/{a:[1,2]}.json", .forward(.read)),
    ]

    @Test(arguments: forwardableFiles)
    func readForwardsOrdinaryPaths(_ row: Row) {
        #expect(Self.classify(row) == row.expected)
    }

    // MARK: - Read's other arguments

    static let forwardRead = ApprovalClassification.forward(.read)
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
    /// `limit` are plain whole numbers in their bounds.
    static let readAuxiliary: [Row] = [
        // Forwarded: the documented shapes and every bound.
        pages("3", forwardRead), pages("1-5", forwardRead), pages("10-20", forwardRead), pages("7-7", forwardRead),
        pages("1-20", forwardRead), pages("99980-99999", forwardRead), pages("99999", forwardRead),
        readWith([("offset", "0")], forwardRead, "offset 0"),
        readWith([("offset", "1")], forwardRead, "offset 1"),
        readWith([("offset", "10000000")], forwardRead, "the furthest offset"),
        readWith([("limit", "1")], forwardRead, "the smallest limit"),
        readWith([("limit", "100000")], forwardRead, "the largest limit"),
        readWith([("pages", quote("1-20")), ("offset", "10000000"), ("limit", "100000")], forwardRead, "every bound at once"),
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
        #expect(Self.classify(Self.pages("3", Self.forwardRead)) == Self.forwardRead, "control")
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
        // MCP: local-only in the MVP, whatever the arguments.
        raw("mcp__github__create_issue", object([("title", quote("x"))]), .suppress(.localOnlyMCP), "an MCP tool"),
        raw("mcp__napcat__ping", "{}", .suppress(.localOnlyMCP), "an MCP tool with no arguments"),
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
    /// entry alone refuses an otherwise forwardable prompt.
    @Test func everyPlaceholderRefusesOnItsOwn() {
        for marker in ApprovalGate.unfaithfulMarkers {
            let row = Self.raw("Read", Self.object([("file_path", Self.quote("\(Self.base)/a.txt")), ("pages", Self.quote(marker))]),
                               Self.notFaithful, marker)
            #expect(Self.classify(row) == Self.notFaithful, "\(marker)")
        }
        for marker in ApprovalGate.maskMarkers {
            let row = Self.read("\(Self.base)/\(marker)", Self.forbidden(.secretAccess))
            #expect(Self.classify(row) == row.expected, "\(marker)")
            #expect(marker == marker.lowercased(), "matched case-insensitively")
        }
        #expect(Self.classify(Self.read("\(Self.base)/a.txt", .forward(.read))) == .forward(.read), "control")
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
        #expect(ApprovalGate.classify(toolName: "Bash", inputPreview: atCap) == Self.forwardBash)
        #expect(ApprovalGate.classify(toolName: "Bash", inputPreview: multibyte) == Self.forwardBash)
        for over in [preview(String(repeating: "x", count: room + 1)), preview(String(repeating: "\u{00E9}", count: room + 1)),
                     preview(String(repeating: "x", count: 2 * ApprovalGate.maxPreviewScalars))] {
            #expect(ApprovalGate.classify(toolName: "Bash", inputPreview: over) == Self.unclassifiable(.previewTooLarge))
        }
        #expect(ApprovalGate.maxPreviewScalars == 3_000)
    }

    /// A forbidden path with a space is still logged as its family.
    @Test func aForbiddenPathWithASpaceKeepsItsFamily() {
        #expect(Self.classify(Self.read("/Library/Application Support/ClaudeCode/managed-settings.json", .forward(.read)))
            == Self.forbidden(.configurationOrHooks))
        #expect(Self.classify(Self.read("/Users/someone/My Keys/.ssh/id_rsa", .forward(.read))) == Self.forbidden(.secretAccess))
    }

    // MARK: - The path alphabet (#159)

    static let pathNotCanonical: ApprovalClassification = unclassifiable(.pathNotCanonical)

    /// Where a character can sit in a path: (before it, after it). Joined
    /// without it, each is a path that forwards.
    static let pathPositions: [(String, String)] = [
        ("", "/Users/someone/a.txt"), ("/", "Users/someone/a.txt"), ("\(base)/", "a.txt"), ("\(base)/a", "b.txt"),
        ("\(base)/dir", "/a.txt"), ("\(base)/a.txt", ""),
    ]

    /// Each character refused after the families is refused wherever it
    /// sits: before the root, first after it, first, inside and last in a
    /// name, and as the path's last character. The same path without it
    /// forwards.
    @Test(arguments: ApprovalGate.pathBytesRefusedAfterFamilies)
    func aCharacterRefusedAfterTheFamiliesIsRefusedAnywhere(_ byte: UInt8) {
        let character = Character(Unicode.Scalar(byte))
        for (before, after) in Self.pathPositions {
            let path = "\(before)\(character)\(after)"
            let control = "\(before)\(after)"
            #expect(Self.classify(Self.read(path, Self.pathNotCanonical)) == Self.pathNotCanonical, "Read \(path)")
            #expect(Self.classify(Self.write(path, Self.pathNotCanonical)) == Self.pathNotCanonical, "Write \(path)")
            #expect(Self.classify(Self.read(control, Self.forwardRead)) == Self.forwardRead, "control: \(control)")
        }
    }

    /// A forbidden path holding one of them is still logged as its family,
    /// whichever family and wherever the character sits.
    @Test(arguments: ApprovalGate.pathBytesRefusedAfterFamilies)
    func aForbiddenPathWithARefusedCharacterKeepsItsFamily(_ byte: UInt8) {
        let character = Character(Unicode.Scalar(byte))
        let paths: [(String, ForbiddenFamily)] = [
            ("/etc/a\(character)b", .privilegeEscalation), ("/etc/sudoers\(character)", .privilegeEscalation),
            ("/Users/someone/.claude/a\(character)b.json", .configurationOrHooks),
            ("\(Self.base)/\(character)x/.git/config", .configurationOrHooks),
            ("/Users/someone/.ssh/id\(character)rsa", .secretAccess), ("\(Self.base)/a\(character)b/.env", .secretAccess),
        ]
        for (path, family) in paths {
            let found = Self.classify(Self.read(path, Self.forbidden(family)))
            #expect(found == Self.forbidden(family), "\(path)")
            guard case .suppress(let suppression) = found else { continue }
            #expect(suppression.auditCode == "forbidden.\(family.rawValue)", "the logged code names the family: \(path)")
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

    /// The whole alphabet, character by character: a path forwards with any
    /// printable ASCII character from `!` to `~` in a name except the
    /// double quote and the backslash. Those two, the space, a tab, a
    /// newline and a carriage return are `pathNotCanonical`; NUL is
    /// `previewNotStrictJSON`; every other control character is
    /// `hiddenText` (the codes the refusal catalogue names). The copy of a
    /// path holding a forwarding character, in each of the six positions,
    /// draws no quote of its own (see `aForwardedPathDrawsNoQuoteOfItsOwn`).
    /// The wire is unchanged.
    @Test func theForwardedPathAlphabetIsPrintableASCIIWithoutQuoteOrBackslash() throws {
        let pinned: [UInt8] = [UInt8(ascii: " "), UInt8(ascii: "\"")]
        #expect(ApprovalGate.pathBytesRefusedAfterFamilies == pinned)
        let refused: Set<UInt8> = [UInt8(ascii: " "), UInt8(ascii: "\""), UInt8(ascii: "\\")]
        let tabAndLineBreaks: Set<UInt8> = [UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r")]
        var forwarded = 0
        var copies = 0
        for byte in UInt8(0)...UInt8(0x7F) {
            let character = Character(Unicode.Scalar(byte))
            let path = "\(Self.base)/a\(character)b.txt"
            let found: ApprovalClassification = Self.classify(Self.read(path, Self.forwardRead))
            let printable: Bool = byte >= 0x20 && byte <= 0x7E
            if printable && !refused.contains(byte) {
                #expect(found == Self.forwardRead, "byte \(byte)")
                forwarded += 1
                for (before, after) in Self.pathPositions {
                    let preview: String = Self.readPreview("\(before)\(character)\(after)")
                    let copy: String = try #require(ApprovalGate.forwardedPreview(toolName: "Read", inputPreview: preview), "byte \(byte)")
                    #expect(try Self.ownQuotesOnly(copy), "byte \(byte): \(copy)")
                    copies += 1
                }
            } else if printable || tabAndLineBreaks.contains(byte) {
                #expect(found == Self.pathNotCanonical, "byte \(byte)")
            } else if byte == 0 {
                #expect(found == Self.unclassifiable(.previewNotStrictJSON), "byte \(byte): a NUL escape")
            } else {
                #expect(found == Self.unclassifiable(.hiddenText), "byte \(byte)")
            }
        }
        #expect(forwarded == 92, "vacuity: 95 printable characters less the space, the quote and the backslash")
        #expect(copies == 552, "vacuity: the 92 forwarding characters, each in six positions")
        #expect(ApprovalWire.wireVersion == 1)
        #expect(ApprovalChannel.frameVersion == 2)
    }

    /// Why the quote: the phone draws the gate's copy verbatim, and in the
    /// copy of every forwarded Read the only quotes are its members' own
    /// (two per key, two per string value) and there is no backslash, so no
    /// path can draw a member boundary. The canary is the vector #159
    /// closes: the copy of a path holding a quote draws one, so the count
    /// catches it, and the gate refuses that path.
    @Test func aForwardedPathDrawsNoQuoteOfItsOwn() throws {
        let rows: [Row] = Self.forwardableFiles.filter { $0.tool == "Read" }
        #expect(rows.count >= 10, "vacuity: the pinned paths are read")
        for row in rows {
            #expect(Self.classify(row) == Self.forwardRead, "\(row.note)")
            let copy = try #require(ApprovalGate.forwardedPreview(toolName: row.tool, inputPreview: row.preview), "\(row.note)")
            #expect(try Self.ownQuotesOnly(copy), "\(row.note): \(copy)")
        }
        let forged = Self.read("\(Self.base)/a\",\"limit\":1", Self.pathNotCanonical)
        let copy = try #require(ApprovalGate.forwardedPreview(toolName: forged.tool, inputPreview: forged.preview))
        #expect(copy == #"{"file_path":"/Users/someone/project/a\",\"limit\":1"}"#)
        #expect(try !Self.ownQuotesOnly(copy), "canary: the count catches the drawn boundary")
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

    @Test func theReadCopyKeepsEveryMember() {
        let relayed = #"{ "file_path": "/Users/someone/project/doc.pdf", "offset": 1, "limit": 200, "pages": "1-3" }"#
        #expect(ApprovalGate.forwardedPreview(toolName: "Read", inputPreview: relayed)
            == #"{"file_path":"/Users/someone/project/doc.pdf","offset":1,"limit":200,"pages":"1-3"}"#)
    }

    /// No copy for a tool that does not forward, or for a preview the gate
    /// could not read as the row's arguments.
    @Test(arguments: [
        ("Write", #"{"file_path":"/tmp/a","content":"x"}"#), ("Edit", #"{"file_path":"/tmp/a","old_string":"a","new_string":"b"}"#),
        ("NotebookEdit", #"{"notebook_path":"/tmp/n.ipynb","new_source":"x"}"#), ("mcp__x__y", #"{"text":"x"}"#),
        ("WebFetch", #"{"url":"https://example.com"}"#), ("bash", #"{"command":"git status"}"#),
        ("Bash", #"{"command":"git status","shell":"zsh"}"#), ("Bash", #"{"command":["git","status"]}"#),
        ("Bash", #"{"command":null}"#), ("Bash", #"{"command":{"a":1}}"#), ("Bash", "not json"),
        ("Bash", #"{"command":"git status","command":"rm -rf x"}"#),
    ])
    func thereIsNoCopyOfWhatCannotForward(_ tool: String, _ preview: String) {
        #expect(ApprovalGate.forwardedPreview(toolName: tool, inputPreview: preview) == nil)
    }

    /// Every prompt the gate forwards has a copy, the copy reads back under
    /// the strict reader as the same members minus the description, and the
    /// gate forwards the copy exactly as it forwarded the original.
    @Test func everyForwardedPromptHasAFaithfulCopy() throws {
        let rows = Self.forwardableFiles + Self.readAuxiliary.filter { $0.expected == Self.forwardRead } + [
            Self.raw("Bash", #"{ "command": "git status", "description": "x" }"#, Self.forwardBash, "relayed spacing"),
            Self.raw("Bash", Self.object([("command", Self.quote("make test")), ("timeout", "600000")]), Self.forwardBash, "timeout"),
        ]
        for row in rows {
            #expect(Self.classify(row) == row.expected, "\(row.note)")
            let copy = try #require(ApprovalGate.forwardedPreview(toolName: row.tool, inputPreview: row.preview), "\(row.note)")
            let original = try #require(ApprovalPreview.parseObject(row.preview))
            #expect(ApprovalPreview.parseObject(copy) == original.filter { $0.key != "description" }, "\(row.note)")
            #expect(ApprovalGate.classify(toolName: row.tool, inputPreview: copy) == row.expected, "\(row.note)")
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

    @Test func aKnownSecretAnywhereIsSecretAccess() {
        let escaped = Self.topic.unicodeScalars.map { String(format: "\\u%04x", $0.value) }.joined()
        let rows = [
            Self.bash("echo \(Self.topic)", Self.forbidden(.secretAccess)),
            Self.raw("Write", Self.object([("file_path", Self.quote("\(Self.base)/a.txt")), ("content", Self.quote("t=\(Self.topic)"))]),
                     Self.forbidden(.secretAccess), "in content"),
            Self.raw("Write", Self.object([("file_path", Self.quote("\(Self.base)/a.txt")), ("content", "\"\(escaped)\"")]),
                     Self.forbidden(.secretAccess), "JSON-escaped in content"),
            Self.raw("Bash", Self.object([("command", Self.quote("ls")), ("description", Self.quote(Self.topic))]),
                     Self.forbidden(.secretAccess), "in the Bash description argument"),
            Self.raw("Bash", "{\"command\":\"\(Self.topic)", Self.forbidden(.secretAccess), "before the preview even parses"),
            Self.raw("mcp__x__\(Self.topic.replacingOccurrences(of: "-", with: "_"))", "{}", .suppress(.localOnlyMCP), "control"),
        ]
        for row in rows {
            #expect(Self.classify(row, secrets: [Self.topic]) == row.expected, "\(row.note)")
        }
        let toolNameSecret = "SECRETNAME"
        #expect(ApprovalGate.classify(toolName: "mcp__\(toolNameSecret)", inputPreview: "{}", secrets: [toolNameSecret])
            == Self.forbidden(.secretAccess), "in the tool name")
        let described = Self.raw("Bash", Self.object([("command", Self.quote("git status")), ("description", Self.quote(Self.topic))]),
                                 Self.forbidden(.secretAccess), "a listed command, the topic in its description")
        #expect(Self.classify(described, secrets: [Self.topic]) == described.expected)
        #expect(Self.classify(described, secrets: []) == Self.forwardBash, "control: without the secret the same prompt forwards")
        #expect(Self.classify(Self.bash("git status", Self.forwardBash), secrets: [""]) == Self.forwardBash,
                "an empty secret matches nothing")
    }

    /// The gate's names for where the topic lives match the Mac app's own.
    @Test func theSecretNamesMatchTheTopicStorage() {
        #expect(ApprovalGate.secretNames.contains(KeychainItemName.ntfyTopic.account.lowercased()))
        #expect(ApprovalGate.secretNames.contains(RetiredDefaultsKey.lidGuardNtfyTopic.lowercased()))
        #expect(ApprovalGate.secretNames.allSatisfy { $0 == $0.lowercased() }, "matched case-insensitively")
    }

    // MARK: - Audit vocabulary

    @Test func auditCodesAreAClosedVocabulary() {
        #expect(ApprovalSuppression.forbidden(.secretAccess).auditCode == "forbidden.secretAccess")
        #expect(ApprovalSuppression.localOnlyMCP.auditCode == "localOnly.mcp")
        #expect(ApprovalSuppression.localOnlyFileEdit.auditCode == "localOnly.fileEdit")
        #expect(ApprovalSuppression.unclassifiable(.unknownTool).auditCode == "unclassifiable.unknownTool")
        let all = ForbiddenFamily.allCases.map { ApprovalSuppression.forbidden($0) } + [.localOnlyMCP, .localOnlyFileEdit]
            + Unclassifiable.allCases.map { ApprovalSuppression.unclassifiable($0) }
        #expect(Set(all.map(\.auditCode)).count == all.count, "codes are distinct")
        for code in all.map(\.auditCode) {
            #expect(code.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) || $0 == "." }, "\(code)")
        }
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

    // MARK: - Structure locks

    static func gateCode() throws -> String { try WireContractTests.wireCode("ApprovalClassification.swift") }

    /// THERE IS NO DEFAULT-FORWARD BRANCH: `.forward(` is constructed exactly
    /// once, after the table lookup whose miss refuses; no switch has a
    /// catch-all; and the description never reaches the gate.
    @Test func theGateHasNoDefaultForwardBranch() throws {
        let code = try Self.gateCode()
        #expect(Self.defaultForwardFailures(code).isEmpty, "\(Self.defaultForwardFailures(code))")
    }

    static let missRefusal = "else {\n            return .suppress(.unclassifiable(.unknownTool))\n        }"
    /// The row's own switch, directly before the single forward.
    static let localOnlyRefusal = "guard row.forwards else {\n            return .suppress(.localOnlyFileEdit)\n        }\n"
        + "        return .forward(row.tool)"

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
        if !code.contains("public static func classify(toolName: String, inputPreview: String, secrets: [String] = [])") {
            failures.append("classify's parameters changed (the description must never be an input)")
        }
        return failures
    }

    /// The lock can fail: each planted default-forward is caught.
    @Test func theDefaultForwardLockCatchesMutants() throws {
        let code = try Self.gateCode()
        let mutants = [
            code.replacingOccurrences(of: "return .suppress(.unclassifiable(.unknownTool))", with: "return .forward(.bash)"),
            code.replacingOccurrences(of: "        case (.path, _),", with: "        default: return nil\n        case (.path, _),"),
            code + "\nlet x = y ?? .forward(.bash)\n",
            code.replacingOccurrences(of: "inputPreview: String, secrets", with: "inputPreview: String, description: String, secrets"),
            code.replacingOccurrences(of: "guard row.forwards else {", with: "guard true else {"),
            code.replacingOccurrences(of: "        guard row.forwards else {\n            return .suppress(.localOnlyFileEdit)\n        }\n",
                                      with: ""),
        ]
        for mutant in mutants {
            #expect(!Self.defaultForwardFailures(mutant).isEmpty, "a mutant was NOT caught")
        }
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
        #expect(ApprovalGate.toolTable.filter(\.forwards).map(\.tool) == [.bash, .read],
                "the file-edit tools are local-only")
        #expect(!ApprovalGate.toolTable.contains { $0.tool.rawValue.hasPrefix(ApprovalGate.mcpPrefix) })
        for row in ApprovalGate.toolTable {
            let names = (row.required + row.optional).map(\.name)
            #expect(Set(names).count == names.count, "\(row.tool): an argument is listed twice")
        }
    }
}
