// NapCatWire — F4 remote approvals: the Mac-side category gate. It decides
// whether one open permission prompt may leave the Mac at all. Design:
// design/remote-approvals.md (CL-2 and the security requirements).
//
// PURE — no imports, no I/O, no clock. DATA-DRIVEN: every decision comes from
// the tables below, and the code that walks them can only refuse. A prompt is
// forwarded ONLY by the single `.forward` at the end of `classify`, after
// every check passed; a table miss is a refusal (there is no default-forward
// branch, lint-locked in ApprovalClassificationTests). Classification reads
// the tool name and the parsed input preview, never the description.

/// The tools whose prompts may be forwarded (one row each in the tool table).
public enum ApprovalTool: String, CaseIterable, Sendable {
    case bash = "Bash"
    case write = "Write"
    case edit = "Edit"
    case notebookEdit = "NotebookEdit"
    case read = "Read"
}

/// The never-forwarded categories (#98). A prompt in one of them stays
/// answerable locally and is only ever logged as suppressed.
public enum ForbiddenFamily: String, CaseIterable, Sendable {
    /// sudo and its relatives, the privileged-helper and system paths.
    case privilegeEscalation
    /// Claude configuration and hook directories, and the other places whose
    /// contents run as code later (git hooks and config, shell startup files,
    /// launch agents).
    case configurationOrHooks
    /// The keychain, the alert topic, token and key files.
    case secretAccess
}

/// Why a prompt could not be classified with confidence (fail closed).
public enum Unclassifiable: String, CaseIterable, Sendable {
    case malformedToolName
    case previewTooLarge
    case previewNotStrictJSON
    /// A string holds a character that renders invisibly or reorders text
    /// (bidi controls, zero-width characters, control characters other than
    /// tab, newline and carriage return), so the phone could not show what
    /// would be approved.
    case hiddenText
    case unknownTool
    case unknownArgument
    case missingArgument
    case argumentKind
    case pathNotCanonical
    case commandOutsideGrammar
    case commandNotInTable
}

/// Why a prompt stays on the Mac.
public enum ApprovalSuppression: Equatable, Sendable {
    case forbidden(ForbiddenFamily)
    /// MCP tools are local-only in the MVP (CL-2).
    case localOnlyMCP
    case unclassifiable(Unclassifiable)

    /// A closed-vocabulary code for the audit log (never any prompt text).
    public var auditCode: String {
        switch self {
        case .forbidden(let family): return "forbidden.\(family.rawValue)"
        case .localOnlyMCP: return "localOnly.mcp"
        case .unclassifiable(let reason): return "unclassifiable.\(reason.rawValue)"
        }
    }
}

/// The gate's answer for one prompt.
public enum ApprovalClassification: Equatable, Sendable {
    case forward(ApprovalTool)
    case suppress(ApprovalSuppression)
}

public enum ApprovalGate {
    public static let maxToolNameBytes = 64
    public static let maxPreviewBytes = 32_768
    public static let maxCommandBytes = 2_048
    public static let maxPathBytes = 1_024
    public static let maxCommandSegments = 8
    public static let maxCommandWords = 64
    /// The tool-name prefix of every MCP tool.
    public static let mcpPrefix = "mcp__"

    /// Classifies one prompt from the relay's `tool_name` and `input_preview`.
    /// `secrets` are strings that must never leave the Mac (the alert topic):
    /// a prompt containing one, anywhere, is secret access.
    public static func classify(toolName: String, inputPreview: String, secrets: [String] = []) -> ApprovalClassification {
        let name = Array(toolName.utf8)
        let preview = Array(inputPreview.utf8)
        guard !name.isEmpty, name.count <= maxToolNameBytes, name.allSatisfy(isToolNameByte) else {
            return .suppress(.unclassifiable(.malformedToolName))
        }
        guard preview.count <= maxPreviewBytes else {
            return .suppress(.unclassifiable(.previewTooLarge))
        }
        let secretBytes = secrets.map { Array($0.utf8) }.filter { !$0.isEmpty }
        if revealsSecret(name, secretBytes) || revealsSecret(preview, secretBytes) {
            return .suppress(.forbidden(.secretAccess))
        }
        guard let members = ApprovalPreview.parseObject(inputPreview) else {
            return .suppress(.unclassifiable(.previewNotStrictJSON))
        }
        let strings = ApprovalPreview.strings(in: members)
        for text in strings where revealsSecret(Array(text.utf8), secretBytes) {
            return .suppress(.forbidden(.secretAccess))
        }
        for text in strings where text.unicodeScalars.contains(where: isHidden) {
            return .suppress(.unclassifiable(.hiddenText))
        }
        if name.starts(with: mcpPrefix.utf8) {
            return .suppress(.localOnlyMCP)
        }
        guard let row = toolTable.first(where: { $0.tool.rawValue.utf8.elementsEqual(name) }) else {
            return .suppress(.unclassifiable(.unknownTool))
        }
        if let refusal = refusal(members, row) {
            return .suppress(refusal)
        }
        return .forward(row.tool)
    }

    // MARK: - Tables

    enum ArgumentKind: Sendable {
        /// An absolute, canonical file path, checked against `pathRules`.
        case path
        /// A Bash command, checked against the grammar and `commandRows`.
        case command
        /// Any string (scanned for secrets like everything else).
        case text
        case number
        case bool
        /// Present only as `false` (`true` would leave the sandbox).
        case falseOnly
    }

    struct Argument: Sendable {
        let name: String
        let kind: ArgumentKind
        init(_ name: String, _ kind: ArgumentKind) {
            self.name = name
            self.kind = kind
        }
    }

    struct ToolRow: Sendable {
        let tool: ApprovalTool
        let required: [Argument]
        let optional: [Argument]
    }

    /// The forwardable tools and their EXACT argument sets: an argument not
    /// listed, a missing required one, or a value of the wrong JSON type
    /// refuses the prompt.
    static let toolTable: [ToolRow] = [
        ToolRow(tool: .bash, required: [Argument("command", .command)],
                optional: [Argument("description", .text), Argument("timeout", .number),
                           Argument("run_in_background", .bool), Argument("dangerouslyDisableSandbox", .falseOnly)]),
        ToolRow(tool: .write, required: [Argument("file_path", .path), Argument("content", .text)], optional: []),
        ToolRow(tool: .edit, required: [Argument("file_path", .path), Argument("old_string", .text), Argument("new_string", .text)],
                optional: [Argument("replace_all", .bool)]),
        ToolRow(tool: .notebookEdit, required: [Argument("notebook_path", .path), Argument("new_source", .text)],
                optional: [Argument("cell_id", .text), Argument("cell_type", .text), Argument("edit_mode", .text)]),
        ToolRow(tool: .read, required: [Argument("file_path", .path)],
                optional: [Argument("offset", .number), Argument("limit", .number), Argument("pages", .text)]),
    ]

    enum PathPattern: Sendable {
        /// Some component equals this.
        case component(String)
        /// Some component starts with this.
        case componentPrefix(String)
        /// Some component ends with this.
        case componentSuffix(String)
        /// These components appear consecutively, anywhere.
        case run([String])
        /// An absolute path starts with these components.
        case rooted([String])
    }

    struct PathRule: Sendable {
        let family: ForbiddenFamily
        let pattern: PathPattern
        init(_ family: ForbiddenFamily, _ pattern: PathPattern) {
            self.family = family
            self.pattern = pattern
        }
    }

    /// The forbidden locations, matched on lowercased components (APFS is
    /// case-insensitive by default). Used for every file tool path and every
    /// word of a Bash command.
    static let pathRules: [PathRule] = [
        // Privilege escalation: system and privileged-helper locations, and
        // anything named like the escalation commands (a PATH shim).
        PathRule(.privilegeEscalation, .rooted(["etc"])),
        PathRule(.privilegeEscalation, .run(["private", "etc"])),
        PathRule(.privilegeEscalation, .rooted(["usr"])),
        PathRule(.privilegeEscalation, .rooted(["bin"])),
        PathRule(.privilegeEscalation, .rooted(["sbin"])),
        PathRule(.privilegeEscalation, .rooted(["system"])),
        PathRule(.privilegeEscalation, .run(["usr", "local", "napcat"])),
        PathRule(.privilegeEscalation, .run(["library", "launchdaemons"])),
        PathRule(.privilegeEscalation, .run(["library", "privilegedhelpertools"])),
        PathRule(.privilegeEscalation, .component("sudoers")),
        PathRule(.privilegeEscalation, .component("sudoers.d")),
        PathRule(.privilegeEscalation, .component("sudo")),
        PathRule(.privilegeEscalation, .component("doas")),
        // Claude configuration and hook directories, and code that runs later.
        PathRule(.configurationOrHooks, .component(".claude")),
        PathRule(.configurationOrHooks, .component(".claude.json")),
        PathRule(.configurationOrHooks, .component(".mcp.json")),
        PathRule(.configurationOrHooks, .component("claude.md")),
        PathRule(.configurationOrHooks, .component("claude.local.md")),
        PathRule(.configurationOrHooks, .component("managed-settings.json")),
        PathRule(.configurationOrHooks, .component("managed-mcp.json")),
        PathRule(.configurationOrHooks, .run(["library", "application support", "claudecode"])),
        PathRule(.configurationOrHooks, .component(".git")),
        PathRule(.configurationOrHooks, .component(".gitconfig")),
        PathRule(.configurationOrHooks, .component(".githooks")),
        PathRule(.configurationOrHooks, .component(".husky")),
        PathRule(.configurationOrHooks, .run([".config", "git"])),
        PathRule(.configurationOrHooks, .component(".zshrc")),
        PathRule(.configurationOrHooks, .component(".zshenv")),
        PathRule(.configurationOrHooks, .component(".zprofile")),
        PathRule(.configurationOrHooks, .component(".zlogin")),
        PathRule(.configurationOrHooks, .component(".zlogout")),
        PathRule(.configurationOrHooks, .component(".bashrc")),
        PathRule(.configurationOrHooks, .component(".bash_profile")),
        PathRule(.configurationOrHooks, .component(".bash_login")),
        PathRule(.configurationOrHooks, .component(".bash_logout")),
        PathRule(.configurationOrHooks, .component(".profile")),
        PathRule(.configurationOrHooks, .component(".envrc")),
        PathRule(.configurationOrHooks, .run(["library", "launchagents"])),
        PathRule(.configurationOrHooks, .rooted(["opt", "homebrew", "bin"])),
        // Secret access: the keychain, NapCat's old defaults file (which held
        // the alert topic), token and key files.
        PathRule(.secretAccess, .component("keychains")),
        PathRule(.secretAccess, .componentSuffix(".keychain")),
        PathRule(.secretAccess, .componentSuffix(".keychain-db")),
        PathRule(.secretAccess, .component("com.muratalkan.napcat.plist")),
        PathRule(.secretAccess, .component(".ssh")),
        PathRule(.secretAccess, .component(".gnupg")),
        PathRule(.secretAccess, .component(".aws")),
        PathRule(.secretAccess, .component(".azure")),
        PathRule(.secretAccess, .component(".kube")),
        PathRule(.secretAccess, .component(".docker")),
        PathRule(.secretAccess, .component(".netrc")),
        PathRule(.secretAccess, .component(".git-credentials")),
        PathRule(.secretAccess, .component(".npmrc")),
        PathRule(.secretAccess, .component(".pypirc")),
        PathRule(.secretAccess, .component(".pgpass")),
        PathRule(.secretAccess, .component(".password-store")),
        PathRule(.secretAccess, .run([".config", "gh"])),
        PathRule(.secretAccess, .run([".config", "gcloud"])),
        PathRule(.secretAccess, .component(".env")),
        PathRule(.secretAccess, .componentPrefix(".env.")),
        PathRule(.secretAccess, .component("credentials")),
        PathRule(.secretAccess, .component("credentials.json")),
        PathRule(.secretAccess, .component(".credentials.json")),
        PathRule(.secretAccess, .componentPrefix("id_rsa")),
        PathRule(.secretAccess, .componentPrefix("id_dsa")),
        PathRule(.secretAccess, .componentPrefix("id_ecdsa")),
        PathRule(.secretAccess, .componentPrefix("id_ed25519")),
        PathRule(.secretAccess, .componentSuffix(".pem")),
        PathRule(.secretAccess, .componentSuffix(".p12")),
        PathRule(.secretAccess, .componentSuffix(".pfx")),
        PathRule(.secretAccess, .componentSuffix(".p8")),
        PathRule(.secretAccess, .componentSuffix(".key")),
        PathRule(.secretAccess, .componentSuffix(".kdbx")),
    ]

    /// Where NapCat keeps the alert topic, by name: its keychain account and
    /// its retired defaults key (parity-linted against the Mac app). Matched
    /// case-insensitively in the whole preview, for every tool.
    static let secretNames = ["ntfy-topic", "lidguardntfytopic"]

    struct CommandFamilyRule: Sendable {
        let words: [String]
        let family: ForbiddenFamily
        init(_ words: [String], _ family: ForbiddenFamily) {
            self.words = words
            self.family = family
        }
    }

    /// Commands that are a forbidden family whatever their arguments. Checked
    /// before the command table, so the suppression names the family.
    static let commandFamilies: [CommandFamilyRule] = [
        CommandFamilyRule(["sudo"], .privilegeEscalation),
        CommandFamilyRule(["sudoedit"], .privilegeEscalation),
        CommandFamilyRule(["visudo"], .privilegeEscalation),
        CommandFamilyRule(["su"], .privilegeEscalation),
        CommandFamilyRule(["doas"], .privilegeEscalation),
        CommandFamilyRule(["pkexec"], .privilegeEscalation),
        CommandFamilyRule(["osascript"], .privilegeEscalation),
        CommandFamilyRule(["launchctl"], .privilegeEscalation),
        CommandFamilyRule(["dscl"], .privilegeEscalation),
        CommandFamilyRule(["dseditgroup"], .privilegeEscalation),
        CommandFamilyRule(["sysadminctl"], .privilegeEscalation),
        CommandFamilyRule(["authopen"], .privilegeEscalation),
        CommandFamilyRule(["chown"], .privilegeEscalation),
        CommandFamilyRule(["chgrp"], .privilegeEscalation),
        CommandFamilyRule(["pmset"], .privilegeEscalation),
        CommandFamilyRule(["nvram"], .privilegeEscalation),
        CommandFamilyRule(["claude"], .configurationOrHooks),
        CommandFamilyRule(["crontab"], .configurationOrHooks),
        CommandFamilyRule(["git", "config"], .configurationOrHooks),
        CommandFamilyRule(["security"], .secretAccess),
    ]

    struct Needle: Sendable {
        let family: ForbiddenFamily
        let text: String
        init(_ family: ForbiddenFamily, _ text: String) {
            self.family = family
            self.text = text
        }
    }

    /// Belt and braces for Bash: substrings of the lowercased command text
    /// that suppress it before it is even tokenized.
    static let commandNeedles: [Needle] = [
        Needle(.privilegeEscalation, "sudo"),
        Needle(.privilegeEscalation, "/usr/local/napcat"),
        Needle(.privilegeEscalation, "launchdaemons"),
        Needle(.privilegeEscalation, "privilegedhelpertools"),
        Needle(.privilegeEscalation, "administrator privileges"),
        Needle(.configurationOrHooks, ".claude"),
        Needle(.configurationOrHooks, "claude.md"),
        Needle(.configurationOrHooks, ".mcp.json"),
        Needle(.configurationOrHooks, ".git/"),
        Needle(.configurationOrHooks, "launchagents"),
        Needle(.configurationOrHooks, ".zshrc"),
        Needle(.configurationOrHooks, ".bashrc"),
        Needle(.secretAccess, "keychain"),
        Needle(.secretAccess, ".ssh"),
        Needle(.secretAccess, ".aws"),
        Needle(.secretAccess, ".gnupg"),
        Needle(.secretAccess, ".netrc"),
        Needle(.secretAccess, "id_rsa"),
        Needle(.secretAccess, "id_ed25519"),
    ]

    enum OperandKind: Sendable {
        case none
        /// Paths (every word is checked against `pathRules` anyway).
        case paths
        /// Unquoted names: make targets, npm scripts.
        case names
        /// Any word, quoted or not.
        case text
    }

    enum ValueKind: Sendable {
        /// 1 to 6 ASCII digits, unquoted.
        case count
        /// An unquoted name (see `isName`).
        case name
        /// Any word.
        case text
    }

    struct ValueOption: Sendable {
        let option: String
        let kind: ValueKind
        init(_ option: String, _ kind: ValueKind) {
            self.option = option
            self.kind = kind
        }
    }

    struct CommandRow: Sendable {
        /// The leading words, exact and unquoted (`git`, `status`).
        let words: [String]
        /// Letters allowed in a bundled short flag (`-la`).
        var flags: String = ""
        /// Long options allowed exactly (no `=value` form).
        var longFlags: [String] = []
        /// Options that take the next word as their value.
        var values: [ValueOption] = []
        var operands: OperandKind = .none
        var minOperands = 0
        var maxOperands = 0
    }

    /// THE POSITIVE COMMAND TABLE (CL-2). A Bash segment is forwardable only
    /// when its leading words match a row exactly and every further word is
    /// an option or operand the row allows. Nothing else runs: no wrapper
    /// (`env`, `xargs`, `exec`), no interpreter, no shell.
    static let commandRows: [CommandRow] = [
        CommandRow(words: ["ls"], flags: "1AFGSadhlrt", operands: .paths, maxOperands: 16),
        CommandRow(words: ["cat"], flags: "n", operands: .paths, minOperands: 1, maxOperands: 16),
        CommandRow(words: ["head"], values: [ValueOption("-n", .count)], operands: .paths, maxOperands: 16),
        CommandRow(words: ["tail"], values: [ValueOption("-n", .count)], operands: .paths, maxOperands: 16),
        CommandRow(words: ["wc"], flags: "clmw", operands: .paths, maxOperands: 16),
        CommandRow(words: ["pwd"]),
        CommandRow(words: ["echo"], flags: "n", operands: .text, maxOperands: 16),
        CommandRow(words: ["grep"], flags: "EFHchilnoqsvwx", values: [ValueOption("-e", .text)],
                   operands: .text, maxOperands: 16),
        CommandRow(words: ["diff"], flags: "qu", operands: .paths, minOperands: 2, maxOperands: 2),
        CommandRow(words: ["mkdir"], flags: "p", operands: .paths, minOperands: 1, maxOperands: 16),
        CommandRow(words: ["make"], operands: .names, maxOperands: 8),
        CommandRow(words: ["swift", "build"], values: [ValueOption("-c", .name), ValueOption("--product", .name)]),
        CommandRow(words: ["swift", "test"], values: [ValueOption("--filter", .name)]),
        CommandRow(words: ["npm", "test"]),
        CommandRow(words: ["npm", "run"], operands: .names, minOperands: 1, maxOperands: 1),
        CommandRow(words: ["git", "status"], flags: "sb", longFlags: ["--short", "--branch", "--porcelain"],
                   operands: .paths, maxOperands: 16),
        CommandRow(words: ["git", "add"], operands: .paths, minOperands: 1, maxOperands: 16),
        CommandRow(words: ["git", "commit"], values: [ValueOption("-m", .text)]),
    ]

    /// Characters that render invisibly or reorder the text around them: the
    /// C0 controls except tab, newline and carriage return, DEL and the C1
    /// controls, the soft hyphen, zero-width and joiner characters, the bidi
    /// marks, embeddings, overrides and isolates, the byte order mark, the
    /// interlinear annotation controls and the tag characters.
    static let hiddenScalars: [ClosedRange<UInt32>] = [
        0x00...0x08, 0x0B...0x0C, 0x0E...0x1F, 0x7F...0x9F, 0xAD...0xAD, 0x34F...0x34F, 0x61C...0x61C,
        0x180E...0x180E, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069,
        0xFEFF...0xFEFF, 0xFFF9...0xFFFB, 0xE0000...0xE007F,
    ]

    /// The four operators that may join simple commands, as standalone words.
    static let commandOperators = ["&&", "||", "|", ";"]

    // MARK: - Arguments

    private static func refusal(_ members: [PreviewMember], _ row: ToolRow) -> ApprovalSuppression? {
        var checked: [(Argument, PreviewValue)] = []
        for member in members {
            guard let argument = (row.required + row.optional).first(where: { $0.name.utf8.elementsEqual(member.key.utf8) }) else {
                return .unclassifiable(.unknownArgument)
            }
            checked.append((argument, member.value))
        }
        for argument in row.required where !checked.contains(where: { $0.0.name == argument.name }) {
            return .unclassifiable(.missingArgument)
        }
        var firstRefusal: ApprovalSuppression?
        for (argument, value) in checked {
            guard let found = refusal(value, argument.kind) else { continue }
            if case .forbidden = found { return found }
            firstRefusal = firstRefusal ?? found
        }
        return firstRefusal
    }

    private static func refusal(_ value: PreviewValue, _ kind: ArgumentKind) -> ApprovalSuppression? {
        switch (kind, value) {
        case (.path, .string(let text)): return pathRefusal(Array(text.utf8))
        case (.command, .string(let text)): return commandRefusal(Array(text.utf8))
        case (.text, .string): return nil
        case (.number, .number): return nil
        case (.bool, .bool): return nil
        case (.falseOnly, .bool(let flag)): return flag ? .forbidden(.privilegeEscalation) : nil
        case (.path, _), (.command, _), (.text, _), (.number, _), (.bool, _), (.falseOnly, _):
            return .unclassifiable(.argumentKind)
        }
    }

    /// A file tool's path: absolute, printable ASCII without a backslash, no
    /// empty, `.` or `..` component, no trailing slash — then the families.
    static func pathRefusal(_ path: [UInt8]) -> ApprovalSuppression? {
        guard path.count >= 2, path.count <= maxPathBytes, path.first == slash, path.last != slash,
              path.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E && $0 != backslash }) else {
            return .unclassifiable(.pathNotCanonical)
        }
        let components = path.dropFirst().split(separator: slash, omittingEmptySubsequences: false).map { lowercased(Array($0)) }
        guard components.allSatisfy({ !$0.isEmpty && $0 != dot && $0 != dotDot }) else {
            return .unclassifiable(.pathNotCanonical)
        }
        return pathFamily(components, rooted: true).map { .forbidden($0) }
    }

    /// The first family whose rule matches `components` (lowercased).
    static func pathFamily(_ components: [[UInt8]], rooted: Bool) -> ForbiddenFamily? {
        for rule in pathRules where matches(rule.pattern, components, rooted: rooted) {
            return rule.family
        }
        return nil
    }

    private static func matches(_ pattern: PathPattern, _ components: [[UInt8]], rooted: Bool) -> Bool {
        switch pattern {
        case .component(let name):
            return components.contains { $0.elementsEqual(name.utf8) }
        case .componentPrefix(let prefix):
            return components.contains { $0.starts(with: prefix.utf8) }
        case .componentSuffix(let suffix):
            return components.contains { $0.reversed().starts(with: suffix.utf8.reversed()) }
        case .run(let names):
            let run = names.map { Array($0.utf8) }
            guard components.count >= run.count else { return false }
            return (0...(components.count - run.count)).contains { Array(components[$0..<$0 + run.count]) == run }
        case .rooted(let names):
            return rooted && components.starts(with: names.map { Array($0.utf8) })
        }
    }

    // MARK: - Bash

    /// One word of a command after quote removal.
    struct Word: Equatable, Sendable {
        let text: [UInt8]
        /// Whether any part of it was quoted.
        let quoted: Bool
    }

    enum Token: Equatable, Sendable {
        case word(Word)
        case joiner
    }

    /// A Bash command, in order: the needles, the grammar, then per simple
    /// command its family, its table row and the families of its words.
    static func commandRefusal(_ command: [UInt8]) -> ApprovalSuppression? {
        let lower = lowercased(command)
        for needle in commandNeedles where contains(lower, Array(needle.text.utf8)) {
            return .forbidden(needle.family)
        }
        guard let segments = simpleCommands(command) else {
            return .unclassifiable(.commandOutsideGrammar)
        }
        var firstRefusal: ApprovalSuppression?
        for segment in segments {
            guard let found = segmentRefusal(segment) else { continue }
            if case .forbidden = found { return found }
            firstRefusal = firstRefusal ?? found
        }
        return firstRefusal
    }

    /// The simple commands of `command`, or nil when it is outside the
    /// grammar: printable ASCII only (no tab, newline or other control
    /// character, no Unicode), at most `maxCommandBytes`, words joined only by
    /// standalone `&&`, `||`, `|` or `;`, none empty.
    static func simpleCommands(_ command: [UInt8]) -> [[Word]]? {
        guard let tokens = lex(command), !tokens.isEmpty else { return nil }
        var segments: [[Word]] = [[]]
        var words = 0
        for token in tokens {
            switch token {
            case .word(let word):
                segments[segments.count - 1].append(word)
                words += 1
            case .joiner:
                guard !segments[segments.count - 1].isEmpty else { return nil }
                segments.append([])
            }
        }
        guard !segments[segments.count - 1].isEmpty, segments.count <= maxCommandSegments,
              words <= maxCommandWords else { return nil }
        return segments
    }

    /// The tokens of `command`, or nil when any character is outside the
    /// grammar. Unquoted, a word may hold only letters, digits and
    /// `. _ / : = @ % + , -`, plus `~` as its first character when `/` or the
    /// end of the word follows. Single and double quotes take any printable
    /// character except `$`, a backquote, a backslash and `!` up to their
    /// closing quote. A word may not start with `=`, and the four joiners count only
    /// as whole unquoted words. Anything else — `;` or `&` inside a word,
    /// redirection, substitution, globbing, braces, comments, escapes — is
    /// refused.
    static func lex(_ command: [UInt8]) -> [Token]? {
        guard command.count <= maxCommandBytes, command.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else { return nil }
        var tokens: [Token] = []
        var index = 0
        while index < command.count {
            if command[index] == space {
                index += 1
                continue
            }
            let start = index
            var text: [UInt8] = []
            var quoted = false
            var joinerCharacters = false
            while index < command.count, command[index] != space {
                let byte = command[index]
                if byte == singleQuote || byte == doubleQuote {
                    quoted = true
                    index += 1
                    while index < command.count, command[index] != byte {
                        guard isQuotedByte(command[index]) else { return nil }
                        text.append(command[index])
                        index += 1
                    }
                    guard index < command.count else { return nil }
                    index += 1
                } else if byte == tilde {
                    let next = index + 1 < command.count ? command[index + 1] : space
                    guard index == start, next == slash || next == space else { return nil }
                    text.append(byte)
                    index += 1
                } else if isJoinerByte(byte) {
                    joinerCharacters = true
                    text.append(byte)
                    index += 1
                } else {
                    guard isUnquotedByte(byte) else { return nil }
                    text.append(byte)
                    index += 1
                }
            }
            if joinerCharacters {
                guard !quoted, commandOperators.contains(where: { $0.utf8.elementsEqual(text) }) else { return nil }
                tokens.append(.joiner)
                continue
            }
            guard text.first != equals else { return nil }
            tokens.append(.word(Word(text: text, quoted: quoted)))
        }
        return tokens
    }

    private static func segmentRefusal(_ words: [Word]) -> ApprovalSuppression? {
        for rule in commandFamilies where leads(words, rule.words) {
            return .forbidden(rule.family)
        }
        guard let row = commandRows.filter({ leads(words, $0.words) }).max(by: { $0.words.count < $1.words.count }) else {
            return .unclassifiable(.commandNotInTable)
        }
        let rest = Array(words.dropFirst(row.words.count))
        for word in rest {
            if let found = wordRefusal(word) { return found }
        }
        return argumentsAllowed(rest, row) ? nil : .unclassifiable(.commandNotInTable)
    }

    /// Whether `words` start with `names`, each word unquoted and exact.
    private static func leads(_ words: [Word], _ names: [String]) -> Bool {
        guard words.count >= names.count else { return false }
        return zip(words, names).allSatisfy { word, name in !word.quoted && word.text.elementsEqual(name.utf8) }
    }

    /// A word after the command name: no `..` and no empty component (a
    /// trailing slash aside), and no forbidden location, read as a path.
    private static func wordRefusal(_ word: Word) -> ApprovalSuppression? {
        let rooted = word.text.first == slash
        var parts = word.text.split(separator: slash, omittingEmptySubsequences: false).map { lowercased(Array($0)) }
        if rooted { parts.removeFirst() }
        if parts.count > 1, parts.last?.isEmpty == true { parts.removeLast() }
        guard parts.allSatisfy({ $0 != dotDot }), parts.count == 1 || parts.allSatisfy({ !$0.isEmpty }) else {
            return .unclassifiable(.commandOutsideGrammar)
        }
        return pathFamily(parts, rooted: rooted).map { .forbidden($0) }
    }

    /// The options and operands after a row's words, against the row.
    private static func argumentsAllowed(_ words: [Word], _ row: CommandRow) -> Bool {
        var operands = 0
        var index = 0
        while index < words.count {
            let word = words[index]
            index += 1
            if word.text.first == dash {
                guard !word.quoted, word.text.count >= 2 else { return false }
                if let option = row.values.first(where: { $0.option.utf8.elementsEqual(word.text) }) {
                    guard index < words.count, valueAllowed(words[index], option.kind) else { return false }
                    index += 1
                } else if word.text[1] == dash {
                    guard row.longFlags.contains(where: { $0.utf8.elementsEqual(word.text) }) else { return false }
                } else {
                    guard word.text.dropFirst().allSatisfy({ row.flags.utf8.contains($0) }) else { return false }
                }
                continue
            }
            operands += 1
            switch row.operands {
            case .none: return false
            case .paths, .text: break
            case .names: guard !word.quoted, isName(word.text) else { return false }
            }
        }
        return operands >= row.minOperands && operands <= row.maxOperands
    }

    private static func valueAllowed(_ word: Word, _ kind: ValueKind) -> Bool {
        switch kind {
        case .count: return !word.quoted && (1...6).contains(word.text.count) && word.text.allSatisfy(isDigit)
        case .name: return !word.quoted && isName(word.text)
        case .text: return true
        }
    }

    // MARK: - Bytes

    private static let space = UInt8(ascii: " ")
    private static let slash = UInt8(ascii: "/")
    private static let backslash = UInt8(ascii: "\\")
    private static let dash = UInt8(ascii: "-")
    private static let tilde = UInt8(ascii: "~")
    private static let equals = UInt8(ascii: "=")
    private static let singleQuote = UInt8(ascii: "'")
    private static let doubleQuote = UInt8(ascii: "\"")
    private static let dot = [UInt8(ascii: ".")]
    private static let dotDot = [UInt8(ascii: "."), UInt8(ascii: ".")]

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    private static func isLetterOrDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    private static func isToolNameByte(_ byte: UInt8) -> Bool {
        isLetterOrDigit(byte) || byte == UInt8(ascii: "_") || byte == dash
    }

    private static func isUnquotedByte(_ byte: UInt8) -> Bool {
        isLetterOrDigit(byte) || "._/:=@%+,-".utf8.contains(byte)
    }

    private static func isJoinerByte(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "&") || byte == UInt8(ascii: "|") || byte == UInt8(ascii: ";")
    }

    /// Printable ASCII inside quotes, minus what any shell or tool could
    /// still expand there. The caller stops at the closing quote first.
    private static func isQuotedByte(_ byte: UInt8) -> Bool {
        byte >= 0x20 && byte <= 0x7E && !"$`\\!".utf8.contains(byte)
    }

    /// `[A-Za-z0-9][A-Za-z0-9._:-]*`, at most 64 bytes.
    static func isName(_ text: [UInt8]) -> Bool {
        guard let first = text.first, isLetterOrDigit(first), text.count <= 64 else { return false }
        return text.allSatisfy { isLetterOrDigit($0) || "._:-".utf8.contains($0) }
    }

    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        hiddenScalars.contains { $0.contains(scalar.value) }
    }

    static func lowercased(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        return (0...(haystack.count - needle.count)).contains { haystack[$0..<$0 + needle.count].elementsEqual(needle) }
    }

    /// Whether `bytes` holds one of `secrets` (exactly) or one of the
    /// `secretNames` (case-insensitively).
    private static func revealsSecret(_ bytes: [UInt8], _ secrets: [[UInt8]]) -> Bool {
        let lower = lowercased(bytes)
        return secrets.contains { contains(bytes, $0) } || secretNames.contains { contains(lower, Array($0.utf8)) }
    }
}
