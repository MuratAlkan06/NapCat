// NapCatWire — F4 remote approvals: the Mac-side category gate. It decides
// whether one open permission prompt may leave the Mac at all. Design:
// design/remote-approvals.md (CL-2 and the security requirements).
//
// PURE — no imports, no I/O, no clock. DATA-DRIVEN: every decision comes from
// the tables below, and the code that walks them can only refuse. A prompt is
// forwarded ONLY by the single `.forward` at the end of `classify`, after
// every check passed; a table miss is a refusal (there is no default-forward
// branch, lint-locked in ApprovalClassificationTests). Classification reads
// the tool name and the parsed input preview, never the description. A
// description member INSIDE the preview is read only to refuse (it is
// scanned like every string), and what leaves the Mac is the gate's own copy
// without it (`forwardedPreview`), never the relayed text.

/// The tools the gate classifies (one row each in the tool table). Only the
/// rows marked `forwards` may leave the Mac: the file-edit tools (Write,
/// Edit, NotebookEdit) are local-only.
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
    /// The preview holds one of the relay's placeholders
    /// (`ApprovalGate.unfaithfulMarkers`), in a string or in the raw text: it
    /// is not a faithful copy of what would run.
    case previewNotFaithful
    /// A string holds a character that renders invisibly or reorders text
    /// (bidi controls, zero-width characters, control characters other than
    /// tab, newline and carriage return), so the phone could not show what
    /// would be approved.
    case hiddenText
    case unknownTool
    case unknownArgument
    case missingArgument
    case argumentKind
    /// A value of the right JSON type that its argument does not allow (a
    /// Bash run in the background, a timeout outside its bound, a Read page
    /// range, offset or limit outside its format).
    case argumentValue
    case pathNotCanonical
    case commandOutsideGrammar
    /// The command is not exactly one of `ApprovalGate.bashCommands`.
    case commandNotInTable
}

/// Why a prompt stays on the Mac.
public enum ApprovalSuppression: Equatable, Sendable {
    case forbidden(ForbiddenFamily)
    /// MCP tools are local-only in the MVP (CL-2).
    case localOnlyMCP
    /// The file-edit tools are local-only too: a Write, Edit or NotebookEdit
    /// prompt that passes every other check still stays on the Mac.
    case localOnlyFileEdit
    case unclassifiable(Unclassifiable)

    /// A closed-vocabulary code for the audit log (never any prompt text).
    public var auditCode: String {
        switch self {
        case .forbidden(let family): return "forbidden.\(family.rawValue)"
        case .localOnlyMCP: return "localOnly.mcp"
        case .localOnlyFileEdit: return "localOnly.fileEdit"
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
    /// The longest preview read, in Unicode code points of the text as
    /// relayed (so every string in it is shorter still).
    public static let maxPreviewScalars = 3_000
    public static let maxCommandBytes = 2_048
    public static let maxPathBytes = 1_024
    public static let maxCommandSegments = 8
    public static let maxCommandWords = 64
    /// The longest Bash timeout forwarded, in milliseconds (ten minutes).
    public static let maxTimeoutMilliseconds = 600_000
    /// The most PDF pages one forwarded Read may name: the Read tool's own
    /// maximum per request.
    public static let maxReadPages = 20
    /// The highest PDF page a forwarded Read may name (five digits).
    public static let maxReadPage = 99_999
    /// The furthest line a forwarded Read may start from (ten million). Zero
    /// is allowed: the Read tool's own schema starts its offset at 0.
    public static let maxReadOffset = 10_000_000
    /// The most lines one forwarded Read may ask for (a hundred thousand),
    /// and at least one.
    public static let maxReadLimit = 100_000
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
        guard preview.count <= maxPreviewBytes, inputPreview.unicodeScalars.count <= maxPreviewScalars else {
            return .suppress(.unclassifiable(.previewTooLarge))
        }
        let secretBytes = secrets.map { Array($0.utf8) }.filter { !$0.isEmpty }
        if revealsSecret(name, secretBytes) || revealsSecret(preview, secretBytes) {
            return .suppress(.forbidden(.secretAccess))
        }
        if holdsUnfaithfulMarker(preview) {
            return .suppress(.unclassifiable(.previewNotFaithful))
        }
        guard let members = ApprovalPreview.parseObject(inputPreview) else {
            return .suppress(.unclassifiable(.previewNotStrictJSON))
        }
        let strings = ApprovalPreview.strings(in: members)
        for text in strings where revealsSecret(Array(text.utf8), secretBytes) {
            return .suppress(.forbidden(.secretAccess))
        }
        for text in strings where holdsUnfaithfulMarker(Array(text.utf8)) {
            return .suppress(.unclassifiable(.previewNotFaithful))
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
        guard row.forwards else {
            return .suppress(.localOnlyFileEdit)
        }
        return .forward(row.tool)
    }

    /// The copy of a prompt's preview that may leave the Mac: the members its
    /// tool's row checks, re-serialized in their order, WITHOUT any member
    /// the row withholds (a Bash description, which the model writes). It is
    /// never the relayed text itself. Nil for a tool whose row does not
    /// forward, or a preview that is not one strict object of that row's
    /// arguments with plain values — the gate refuses those anyway.
    public static func forwardedPreview(toolName: String, inputPreview: String) -> String? {
        guard let row = toolTable.first(where: { $0.forwards && $0.tool.rawValue.utf8.elementsEqual(toolName.utf8) }),
              let members = ApprovalPreview.parseObject(inputPreview) else { return nil }
        var fields: [String] = []
        for member in members {
            guard let argument = (row.required + row.optional).first(where: { $0.name.utf8.elementsEqual(member.key.utf8) }) else {
                return nil
            }
            if case .withheld = argument.kind { continue }
            let value: String
            switch member.value {
            case .string(let text): value = ApprovalChannel.quoted(text)
            case .number(let literal): value = literal
            case .bool(let flag): value = flag ? "true" : "false"
            case .null, .array, .object: return nil
            }
            fields.append(ApprovalChannel.quoted(member.key) + ":" + value)
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    // MARK: - Tables

    enum ArgumentKind: Sendable {
        /// An absolute, canonical file path, checked against `pathRules`.
        case path
        /// A Bash command: the refusal filters, then exactly one of
        /// `bashCommands`.
        case command
        /// Any string (scanned for secrets like everything else).
        case text
        /// Any string, read only to refuse (scanned like every string) and
        /// never part of the copy that leaves the Mac (`forwardedPreview`).
        case withheld
        /// A Read page range (`isPageRange`): never free text.
        case pageRange
        /// A whole number in this range, written plainly (`wholeNumber`).
        case wholeNumber(ClosedRange<Int>)
        /// A whole number of milliseconds, 1 to `maxTimeoutMilliseconds`.
        case milliseconds
        case bool
        /// Present only as `false`; `true` is this refusal.
        case falseOnly(ApprovalSuppression)
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
        /// Whether a prompt that passes every check may leave the Mac. A row
        /// that does not forward is still checked in full, so a forbidden
        /// prompt is logged as its family.
        let forwards: Bool
        let required: [Argument]
        let optional: [Argument]
    }

    /// The classified tools and their EXACT argument sets: an argument not
    /// listed, a missing required one, or a value of the wrong JSON type
    /// refuses the prompt. Only Bash and Read forward.
    static let toolTable: [ToolRow] = [
        ToolRow(tool: .bash, forwards: true, required: [Argument("command", .command)],
                optional: [Argument("description", .withheld), Argument("timeout", .milliseconds),
                           Argument("run_in_background", .falseOnly(.unclassifiable(.argumentValue))),
                           Argument("dangerouslyDisableSandbox", .falseOnly(.forbidden(.privilegeEscalation)))]),
        ToolRow(tool: .write, forwards: false, required: [Argument("file_path", .path), Argument("content", .text)], optional: []),
        ToolRow(tool: .edit, forwards: false,
                required: [Argument("file_path", .path), Argument("old_string", .text), Argument("new_string", .text)],
                optional: [Argument("replace_all", .bool)]),
        ToolRow(tool: .notebookEdit, forwards: false, required: [Argument("notebook_path", .path), Argument("new_source", .text)],
                optional: [Argument("cell_id", .text), Argument("cell_type", .text), Argument("edit_mode", .text)]),
        ToolRow(tool: .read, forwards: true, required: [Argument("file_path", .path)],
                optional: [Argument("offset", .wholeNumber(0...maxReadOffset)), Argument("limit", .wholeNumber(1...maxReadLimit)),
                           Argument("pages", .pageRange)]),
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

    /// Placeholders the relay may write into a preview, matched in any
    /// letter case in the raw text and in every decoded string: a preview
    /// holding one is `previewNotFaithful`.
    static let unfaithfulMarkers = ["\u{22EF}", "code points elided", "(value unserializable)"]
    /// The relay's placeholder for a credential, matched the same way and in
    /// the same places as `secretNames`: secret access.
    static let maskMarkers = ["[redacted]"]

    struct CommandFamilyRule: Sendable {
        let words: [String]
        let family: ForbiddenFamily
        init(_ words: [String], _ family: ForbiddenFamily) {
            self.words = words
            self.family = family
        }
    }

    /// Commands that are a forbidden family whatever their arguments. Checked
    /// before the Bash list, so the suppression names the family.
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

    /// THE BASH LIST (CL-2, tightened by slice S-GATE). A Bash prompt is
    /// forwarded only when its WHOLE command is one of these, byte for byte:
    /// no operand, option, joiner or extra space of its own. Each entry is
    /// split-audited in ApprovalClassificationTests (every reading of each
    /// space it shows is harmless on macOS). The needles, the grammar and the
    /// families still run first, as refusal filters only.
    static let bashCommands = ["git status", "git diff", "make test", "swift build", "swift test", "npm test"]

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
        case (.withheld, .string): return nil
        case (.pageRange, .string(let text)): return isPageRange(Array(text.utf8)) ? nil : .unclassifiable(.argumentValue)
        case (.wholeNumber(let range), .number(let literal)):
            return wholeNumber(Array(literal.utf8), in: range) == nil ? .unclassifiable(.argumentValue) : nil
        case (.milliseconds, .number(let literal)): return isMilliseconds(Array(literal.utf8)) ? nil : .unclassifiable(.argumentValue)
        case (.bool, .bool): return nil
        case (.falseOnly(let refusal), .bool(let flag)): return flag ? refusal : nil
        case (.path, _), (.command, _), (.text, _), (.withheld, _), (.pageRange, _), (.wholeNumber, _), (.milliseconds, _), (.bool, _),
             (.falseOnly, _):
            return .unclassifiable(.argumentKind)
        }
    }

    /// What a file tool's path may not hold, checked after the families so a
    /// forbidden path holding one is still logged as its family: a space,
    /// and the double quote (#159). The phone draws the gate's copy of a
    /// Read verbatim, as JSON, and every member boundary there holds a
    /// double quote; a path's own quote is drawn as `\"` and could pass for
    /// the end of the path and the start of another member. Without it (and
    /// without a backslash, refused first) a path draws no quote at all, so
    /// its braces, brackets, commas and colons only ever read as part of the
    /// one quoted path, and they stay allowed: real paths hold them.
    static let pathBytesRefusedAfterFamilies: [UInt8] = [UInt8(ascii: " "), UInt8(ascii: "\"")]

    /// A file tool's path: absolute, printable ASCII without a backslash (so
    /// never a middle dot), no empty, `.` or `..` component, no trailing
    /// slash — then the families — and, last, no space or double quote
    /// (`pathBytesRefusedAfterFamilies`).
    static func pathRefusal(_ path: [UInt8]) -> ApprovalSuppression? {
        guard path.count >= 2, path.count <= maxPathBytes, path.first == slash, path.last != slash,
              path.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E && $0 != backslash }) else {
            return .unclassifiable(.pathNotCanonical)
        }
        let components = path.dropFirst().split(separator: slash, omittingEmptySubsequences: false).map { lowercased(Array($0)) }
        guard components.allSatisfy({ !$0.isEmpty && $0 != dot && $0 != dotDot }) else {
            return .unclassifiable(.pathNotCanonical)
        }
        if let family = pathFamily(components, rooted: true) {
            return .forbidden(family)
        }
        return path.contains { pathBytesRefusedAfterFamilies.contains($0) } ? .unclassifiable(.pathNotCanonical) : nil
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
    /// command its family and the families of its words — refusal filters
    /// only — and last the forward basis: the whole command is exactly one of
    /// `bashCommands`.
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
        if let firstRefusal { return firstRefusal }
        return bashCommands.contains(where: { $0.utf8.elementsEqual(command) }) ? nil : .unclassifiable(.commandNotInTable)
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
        for word in words.dropFirst() {
            if let found = wordRefusal(word) { return found }
        }
        return nil
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

    // MARK: - Bytes

    private static let space = UInt8(ascii: " ")
    private static let slash = UInt8(ascii: "/")
    private static let backslash = UInt8(ascii: "\\")
    private static let dash = UInt8(ascii: "-")
    private static let zero = UInt8(ascii: "0")
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

    /// A JSON number literal that is a whole number from 1 to
    /// `maxTimeoutMilliseconds`: digits only (no sign, fraction or exponent).
    static func isMilliseconds(_ literal: [UInt8]) -> Bool {
        guard (1...6).contains(literal.count), literal.allSatisfy(isDigit) else { return false }
        let value = literal.reduce(0) { $0 * 10 + Int($1 - 0x30) }
        return value >= 1 && value <= maxTimeoutMilliseconds
    }

    /// The whole number `digits` writes, when it is in `range` and written
    /// plainly: ASCII digits only (no sign, fraction, exponent or space), no
    /// leading zero, and no more digits than the bound has. Nil otherwise.
    static func wholeNumber(_ digits: [UInt8], in range: ClosedRange<Int>) -> Int? {
        guard !digits.isEmpty, digits.count <= String(range.upperBound).utf8.count, digits.allSatisfy(isDigit),
              digits.count == 1 || digits.first != zero else { return nil }
        let value = digits.reduce(0) { $0 * 10 + Int($1 - zero) }
        return range.contains(value) ? value : nil
    }

    /// A Read page range as the Read tool writes one: one page `N`, or `N-M`
    /// — each a page from 1 to `maxReadPage` (`wholeNumber`), `N` no later
    /// than `M`, at most `maxReadPages` pages. So only ASCII digits and at
    /// most one hyphen: never words, never an invisible character.
    static func isPageRange(_ text: [UInt8]) -> Bool {
        let parts = text.split(separator: dash, maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let start = wholeNumber(Array(first), in: 1...maxReadPage),
              let end = parts.count == 1 ? start : wholeNumber(Array(parts[1]), in: 1...maxReadPage) else { return false }
        return start <= end && end - start < maxReadPages
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
    /// `secretNames` or `maskMarkers` (case-insensitively).
    private static func revealsSecret(_ bytes: [UInt8], _ secrets: [[UInt8]]) -> Bool {
        let lower = lowercased(bytes)
        return secrets.contains { contains(bytes, $0) } || (secretNames + maskMarkers).contains { contains(lower, Array($0.utf8)) }
    }

    /// Whether `bytes` holds one of the `unfaithfulMarkers` (case-insensitively).
    private static func holdsUnfaithfulMarker(_ bytes: [UInt8]) -> Bool {
        let lower = lowercased(bytes)
        return unfaithfulMarkers.contains { contains(lower, Array($0.utf8)) }
    }
}
