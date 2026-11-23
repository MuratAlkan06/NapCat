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
/// exec-capable options, encoding tricks), and every unknown or malformed
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

    /// The minimal command of every row is forwarded — the table is the
    /// whole positive grammar, and each row is reachable.
    @Test func everyCommandRowForwardsItsMinimalForm() {
        for row in ApprovalGate.commandRows {
            let operands = Array(repeating: "a", count: row.minOperands)
            let command = (row.words + operands).joined(separator: " ")
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

    // MARK: - Bash positive grammar: the bypass catalogue

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

    // MARK: - What the grammar forwards

    static let forwardable: [String] = [
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
        "make test",
        "swift build -c release",
        "swift test --filter ApprovalTests",
        "npm test",
        "npm run test:unit",
        "git status",
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

    @Test(arguments: forwardable)
    func thePositiveGrammarForwardsPlainCommands(_ command: String) {
        #expect(Self.classify(Self.bash(command, Self.forwardBash)) == Self.forwardBash)
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
    ]

    @Test(arguments: forwardableFiles)
    func readForwardsOrdinaryPaths(_ row: Row) {
        #expect(Self.classify(row) == row.expected)
    }

    static let localOnly = ApprovalClassification.suppress(.localOnlyFileEdit)

    /// The file-edit tools are local-only: the same prompts that forwarded
    /// before stay on the Mac, each logged as `localOnly.fileEdit`.
    static let localOnlyFileEdits: [Row] = [
        write("\(base)/README.md", localOnly),
        write("\(base)/Sources/App.swift", localOnly),
        write("\(base)/.github/workflows/ci.yml", localOnly),
        write("\(base)/.gitignore", localOnly),
        write("\(base)/My Notes/todo.txt", localOnly),
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
        raw("Bash", object([("command", quote("ls")), ("timeout", quote("5"))]), unclassifiable(.argumentKind), "timeout as a string"),
        raw("Bash", object([("command", quote("ls")), ("run_in_background", quote("true"))]),
            unclassifiable(.argumentKind), "boolean as a string"),
        raw("Bash", object([("command", quote("ls")), ("dangerouslyDisableSandbox", quote("false"))]),
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
        #expect(Self.classify(Self.bash("echo \(Self.topic)", Self.forwardBash), secrets: []) == Self.forwardBash,
                "control: without the secret the same command forwards")
        #expect(Self.classify(Self.bash("echo hello", Self.forwardBash), secrets: [""]) == Self.forwardBash,
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

    /// The command table never lists a shell, an interpreter, a wrapper that
    /// runs its arguments, or a forbidden command.
    @Test func theCommandTableHasNoExecutors() {
        let heads = Set(ApprovalGate.commandRows.map { $0.words[0] })
        let executors = ["sh", "bash", "zsh", "fish", "env", "xargs", "exec", "eval", "command", "builtin", "source", ".",
                         "nohup", "nice", "time", "timeout", "watch", "python", "python3", "node", "perl", "ruby", "osascript",
                         "awk", "sed", "find", "cd", "open", "curl", "wget", "ssh", "scp", "rm", "mv", "cp", "chmod", "tee", "dd"]
        #expect(heads.isDisjoint(with: executors), "\(heads.intersection(executors))")
        let forbiddenHeads = Set(ApprovalGate.commandFamilies.filter { $0.words.count == 1 }.map { $0.words[0] })
        #expect(heads.isDisjoint(with: forbiddenHeads))
        // No recursive walk (ls's lowercase -r only reverses the sort).
        for row in ApprovalGate.commandRows {
            #expect(!row.flags.contains("R"), "\(row.words): no recursive flag")
            #expect(!row.flags.contains("r") || row.words == ["ls"], "\(row.words): no recursive flag")
        }
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
