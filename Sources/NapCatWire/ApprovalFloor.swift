// NapCatWire — F4 remote approvals: the never-sent floor's name tables and
// text scans. Design: design/remote-approvals.md.
//
// PURE — no imports, no I/O, no clock, no logging. UNWIRED: nothing calls
// `ApprovalFloor.outcome(of:topic:)` yet, so the gate (`ApprovalGate`) and
// what happens to every prompt are unchanged (ApprovalFloorTests locks it).
//
// The floor names what a prompt may never carry off the Mac, whatever any
// setting says: the alert topic, NapCat's own names, its privileged
// footprint, its source tree, the keychain as a whole, Claude Code's helper
// list, and the signing and iCloud plumbing. A match is its own outcome
// with a closed reason code (the group), never the matched text.
//
// Two scans read every string of a prompt:
// - The name scan needs no command grammar. It reads the text as written,
//   a copy with every `'`, `"` and `\`, and every `$` before a `'` or `"`,
//   removed, each of the two percent-decoded, and each of those four with
//   every `//` and `/./` written as `/`, each reading lowercased (ASCII
//   letters only, as the gate lowercases). A WORD name matches a whole
//   piece of the text split on every byte that is not an ASCII letter,
//   digit, `_`, `.`, `+` or `-`, and the rest of a piece made of `-`, one
//   letter and more (`-aNapCat` gives `NapCat`); a SUBSTRING name matches
//   anywhere. Each table says which of its names are which.
// - ASCII or kept: a string that names a command, a path, a URL or a tool
//   must be printable ASCII as written, or the outcome is `unreadable` and
//   the prompt is kept. The name scan also reads case-folded each reading
//   of free text (a file's text, a search query, a connector's argument,
//   which may hold any script) and each reading of a naming string that is
//   not printable ASCII (a percent-encoded letter, say). The fold turns
//   U+212A KELVIN SIGN into `k`, U+017F LATIN SMALL LETTER LONG S into `s`,
//   both sharp s letters (U+00DF, U+1E9E) into `ss`, and the ligatures
//   U+FB01 and U+FB06 into `fi` and `st`.
// The alert topic is matched as exact bytes: as written, without quotes,
// backslashes and every `$` before a quote, and each of the two
// percent-decoded. An empty topic is one that cannot be read. Its bytes are
// a parameter of each check and are never kept.
//
// Anything the floor does not name is left to the gate's fail-closed rule.

/// The floor's groups: the closed reason a match carries, never the matched
/// text. An outcome names the first group, in this order, that matches.
public enum ApprovalFloorGroup: String, CaseIterable, Sendable {
    /// The alert topic's own bytes (the topic is the alert feed's password).
    case alertTopic
    /// NapCat's bundle and keychain names, its preference keys, its helper,
    /// watchdog, socket and receipt, its record zone, subscriptions, policy
    /// header and signing domains, its connector's tools, and the word
    /// `napcat`.
    case ownNames
    /// The root helper's folder, the sleep setting, the sudoers file, the
    /// failsafe login item, the busy hook and the install scripts.
    case privilegedFootprint
    /// NapCat's source folders and build files.
    case sourceTree
    /// The keychain as a whole: its tool, its files and its API names.
    case keychain
    /// The files and settings that decide which helpers Claude Code runs
    /// and how its prompts are answered, and the `claude` command.
    case claudeCodeHelpers
    /// Code signing, the provisioning profile and the CloudKit tool.
    case signingAndICloud
}

/// Why the floor cannot judge a prompt. Either way the prompt is kept.
public enum ApprovalFloorUnreadable: String, CaseIterable, Sendable {
    /// An alert topic exists but could not be read, or is empty, so no
    /// prompt can be checked for it.
    case topic
    /// A string that names a command, a path, a URL or a tool holds a byte
    /// outside printable ASCII.
    case notPrintableASCII
}

/// The floor's answer for one prompt. It carries closed codes only.
public enum ApprovalFloorOutcome: Equatable, Sendable {
    /// No floor name, and nothing the floor cannot read.
    case noMatch
    /// A floor name of this group: the prompt is never sent.
    case floor(ApprovalFloorGroup)
    /// The floor cannot judge the prompt: it is kept.
    case unreadable(ApprovalFloorUnreadable)
}

/// One string of a prompt, as the caller reads it.
public enum ApprovalFloorString: Sendable {
    /// A string that names a command, a path, a URL or a tool (a Bash
    /// command, a file tool's path, a web address, the tool name): it must
    /// be printable ASCII as written, and each of its readings outside
    /// printable ASCII is scanned case-folded as well.
    case naming(String)
    /// Free text (a file's text, a search query, a connector's argument):
    /// any script, each reading scanned case-folded as well.
    case freeText(String)
}

/// The alert topic for one check: its bytes are handed in for that call
/// alone and never kept.
public enum ApprovalFloorTopic: Sendable {
    /// No topic is set: there is nothing to match.
    case absent
    /// The topic's bytes. An empty value cannot be checked for: it is read
    /// as `unreadable`, and every prompt is kept.
    case value([UInt8])
    /// A topic exists but could not be read: every prompt is kept.
    case unreadable
}

public enum ApprovalFloor {
    /// The floor's answer for the strings of one prompt: `unreadable` when
    /// the topic could not be read or is empty; otherwise the first group,
    /// in `ApprovalFloorGroup` order, that any string matches; otherwise
    /// `unreadable` when a naming string is not printable ASCII; otherwise
    /// `noMatch`.
    public static func outcome(of strings: [ApprovalFloorString], topic: ApprovalFloorTopic) -> ApprovalFloorOutcome {
        if case .unreadable = topic {
            return .unreadable(.topic)
        }
        if case .value(let bytes) = topic, bytes.isEmpty {
            return .unreadable(.topic)
        }
        if let group = matchedGroups(strings, topic: topic).first {
            return .floor(group)
        }
        for case .naming(let text) in strings where !isPrintableASCII(text) {
            return .unreadable(.notPrintableASCII)
        }
        return .noMatch
    }

    // MARK: - Tables

    /// One group's names, lowercase ASCII (the scans lowercase the text
    /// first). A word matches a whole piece of the split text
    /// (`pieces`); a substring matches anywhere in a copy.
    struct Table: Sendable {
        let group: ApprovalFloorGroup
        let words: [String]
        let substrings: [String]
    }

    /// Every name table, in group order. The alert topic has no table: its
    /// bytes are a parameter.
    static let tables: [Table] = [ownNames, privilegedFootprint, sourceTree, keychain, claudeCodeHelpers, signingAndICloud]

    /// NapCat's own names. The one word is `napcat`: it matches as a path
    /// component, a quoted app name or a process name. The rest are
    /// substrings, each specific to NapCat: the bundle ID (also the keychain
    /// service and the end of the iCloud container's name), the two keychain
    /// accounts (the paired key's by `paired-iphone`, which it starts with)
    /// and their labels, the account reserved for the forwarding policy,
    /// the preference keys of the alert server and of remote approvals, the
    /// helper, the app bundle, the support folder, the seam socket and the
    /// channel receipt, the watchdog, the record zone, the prompt and alert
    /// subscriptions, the forwarding policy's header and the signing domains
    /// (version suffix left off, so a later version matches too), and
    /// NapCat's connector tools, also as a plugin's.
    static let ownNames = Table(
        group: .ownNames,
        words: ["napcat"],
        substrings: ["com.muratalkan.napcat", "ntfy-topic", "lidguardntfy", "paired-iphone", "napcat ntfy topic",
                     "napcat paired iphone key", "forwarding-policy", "napcat-channel", "napcat.app", "support/napcat",
                     "seam.sock", "channel-registration", "remoteapprovals", "pairingrecordtodelete", "napcat-watchdog",
                     "napcat-approvals", "napcat-prompt-created", "napcat-alert-created", "napcat-forwarding",
                     "napcat-decision", "napcat-shown", "napcat-pair", "mcp__napcat", "mcp__plugin_napcat"])

    /// NapCat's privileged footprint, all substrings: the root helper's
    /// folder (written without its leading `/`, so a relative spelling
    /// matches too), the sleep setting its passwordless entries change, the
    /// sudoers file, the failsafe login item, the busy hook, and the
    /// scripts that install the channel and the hook (each also inside the
    /// matching uninstall script's name).
    static let privilegedFootprint = Table(
        group: .privilegedFootprint,
        words: [],
        substrings: ["usr/local/napcat", "disablesleep", "sudoers", "com.napcat.failsafe", "napcat-busy-hook", "install-channel",
                     "uninstall-channel", "install-claude-busy-hook"])

    /// NapCat's source tree, all substrings: the targets' folders, under
    /// `Sources` and by the three names that are NapCat's alone, the tests'
    /// folder, the phone app, the vendored helper's source and build output,
    /// the entitlements, and the scripts folder and build files at the top
    /// of a folder named `napcat`.
    static let sourceTree = Table(
        group: .sourceTree,
        words: [],
        substrings: ["sources/napcat", "napcatwire", "napcatseam", "napcatchannel", "napcattests", "napcatphone",
                     "third_party/smc", "dist/smc", "napcat.entitlements", "napcat/scripts", "napcat/makefile",
                     "napcat/package.swift"])

    /// The keychain as a whole. The one word is `security`, the tool's
    /// name: it matches standing alone, as `/usr/bin/security`, and quoted
    /// or escaped. The substrings cover the keychain's files (`keychain` is
    /// in every one of their names), its API names and the tool's item
    /// verbs.
    static let keychain = Table(
        group: .keychain,
        words: ["security"],
        substrings: ["keychain", "secitem", "ksec", "seckeychain", "generic-password", "internet-password"])

    /// Claude Code's helper list. The words are the `claude` command and
    /// the `claude-code` package; the substrings are the files that list
    /// helpers or settings Claude Code obeys (the user and project lists,
    /// the managed and remote settings, the managed settings folder and the
    /// managed preferences domain) and the setting names and hook names that
    /// load helpers or answer prompts.
    static let claudeCodeHelpers = Table(
        group: .claudeCodeHelpers,
        words: ["claude", "claude-code"],
        substrings: [".claude.json", ".mcp.json", "managed-settings", "managed-mcp.json", "remote-settings.json",
                     "application support/claudecode", "com.anthropic.claudecode", "mcpjsonservers", "projectmcpservers",
                     "development-channels", "permissionrequest", "permissiondecision"])

    /// Signing and iCloud plumbing, all substrings: the signing tool, the
    /// certificate kind and team ID NapCat is signed with, provisioning
    /// profiles, and Apple's CloudKit command-line tool.
    static let signingAndICloud = Table(
        group: .signingAndICloud,
        words: [],
        substrings: ["codesign", "developer id application", "hjsc985877", "provisionprofile", "cktool"])

    // MARK: - Scans

    /// Every group some string matches, in group order: the alert topic's
    /// when its bytes are given and some string holds them, then each name
    /// table's.
    static func matchedGroups(_ strings: [ApprovalFloorString], topic: ApprovalFloorTopic) -> [ApprovalFloorGroup] {
        var found: [ApprovalFloorGroup] = []
        if case .value(let bytes) = topic, strings.contains(where: { holdsTopic($0, bytes) }) {
            found.append(.alertTopic)
        }
        let copies: [[UInt8]] = strings.flatMap(nameCopies)
        for table in tables where copies.contains(where: { matches(table, $0) }) {
            found.append(table.group)
        }
        return found
    }

    /// Whether `string` holds the topic's bytes exactly: as written,
    /// without quotes, backslashes and every `$` before a quote, or either
    /// of the two percent-decoded.
    static func holdsTopic(_ string: ApprovalFloorString, _ topic: [UInt8]) -> Bool {
        let raw: [UInt8] = Array(text(of: string).utf8)
        let stripped: [UInt8] = quotesRemoved(raw)
        return [raw, stripped, percentDecoded(raw), percentDecoded(stripped)].contains { ApprovalGate.contains($0, topic) }
    }

    /// The readings the name scan reads, each once: the text as written,
    /// without quotes, backslashes and every `$` before a quote, either of
    /// the two percent-decoded, and each of those four with its slashes
    /// collapsed.
    static func readings(_ raw: [UInt8]) -> [[UInt8]] {
        let stripped: [UInt8] = quotesRemoved(raw)
        let four: [[UInt8]] = [raw, stripped, percentDecoded(raw), percentDecoded(stripped)]
        var once: [[UInt8]] = []
        for reading in four + four.map(slashesCollapsed) where !once.contains(reading) {
            once.append(reading)
        }
        return once
    }

    /// The copies the name scan reads: each reading lowercased, then,
    /// case-folded, each reading of free text and each reading of a naming
    /// string that is not printable ASCII.
    static func nameCopies(_ string: ApprovalFloorString) -> [[UInt8]] {
        let readings: [[UInt8]] = readings(Array(text(of: string).utf8))
        let copies: [[UInt8]] = readings.map { ApprovalGate.lowercased($0) }
        let toFold: [[UInt8]]
        switch string {
        case .naming: toFold = readings.filter { !$0.allSatisfy(isPrintableASCII) }
        case .freeText: toFold = readings
        }
        return copies + toFold.map { folded(String(decoding: $0, as: UTF8.self)) }
    }

    /// Whether one copy holds a name of `table`: a substring anywhere, or a
    /// word as a whole piece or as the rest of a glued option's piece.
    static func matches(_ table: Table, _ copy: [UInt8]) -> Bool {
        table.substrings.contains { ApprovalGate.contains(copy, Array($0.utf8)) }
            || pieces(copy).contains { piece in
                let rest: ArraySlice<UInt8>? = gluedOptionValue(piece)
                return table.words.contains { piece.elementsEqual($0.utf8) || rest?.elementsEqual($0.utf8) == true }
            }
    }

    /// The pieces a word name is compared with: `copy` split on every byte
    /// that is not an ASCII letter, digit, `_`, `.`, `+` or `-`.
    static func pieces(_ copy: [UInt8]) -> [ArraySlice<UInt8>] {
        copy.split(whereSeparator: { !isPieceByte($0) })
    }

    static func isPieceByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || pieceMarks.contains(byte)
    }

    /// The rest of a piece that starts with `-` and one ASCII letter, a
    /// one-letter option with its value glued to it (`-aNapCat` gives
    /// `NapCat`); nil for any other piece, or when nothing follows.
    static func gluedOptionValue(_ piece: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
        guard piece.count > 2, piece.first == hyphen, isLetter(piece[piece.startIndex + 1]) else { return nil }
        return piece.dropFirst(2)
    }

    /// `bytes` with every run of slashes written as one, and every slash,
    /// dot, slash written as one slash: two spellings of the same path.
    static func slashesCollapsed(_ bytes: [UInt8]) -> [UInt8] {
        var collapsed: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == slash, collapsed.last == slash {
                index += 1
            } else if bytes[index] == dot, collapsed.last == slash, index + 1 < bytes.count, bytes[index + 1] == slash {
                index += 2
            } else {
                collapsed.append(bytes[index])
                index += 1
            }
        }
        return collapsed
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    /// Whether every byte of `text` is printable ASCII (space to tilde), the
    /// gate's rule for a Bash command and a file path: no tab, line break or
    /// other control character, and nothing outside ASCII.
    static func isPrintableASCII(_ text: String) -> Bool {
        text.utf8.allSatisfy(isPrintableASCII)
    }

    /// Whether `byte` is printable ASCII (space to tilde).
    static func isPrintableASCII(_ byte: UInt8) -> Bool {
        byte >= 0x20 && byte <= 0x7E
    }

    /// `bytes` without any `'`, `"` or `\`, and without every `$` before a
    /// `'` or `"` (the `$` of `$'…'` and `$"…"` quoting). These are ASCII,
    /// so the result of valid UTF-8 is valid UTF-8.
    static func quotesRemoved(_ bytes: [UInt8]) -> [UInt8] {
        var kept: [UInt8] = []
        for index in bytes.indices where !quoteMarks.contains(bytes[index]) {
            let quoting = bytes[index] == dollar && index + 1 < bytes.count && quotes.contains(bytes[index + 1])
            if !quoting { kept.append(bytes[index]) }
        }
        return kept
    }

    /// `bytes` with each `%` and two hex digits replaced by the byte they
    /// write; any other `%` is kept as it is.
    static func percentDecoded(_ bytes: [UInt8]) -> [UInt8] {
        var decoded: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == percent, index + 2 < bytes.count,
               let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                decoded.append(high << 4 | low)
                index += 3
            } else {
                decoded.append(bytes[index])
                index += 1
            }
        }
        return decoded
    }

    /// `text` case-folded by the standard library's Unicode case mappings,
    /// lower, upper, then lower again: U+212A becomes `k`, U+017F `s`,
    /// U+00DF and U+1E9E `ss`, U+FB01 `fi`, U+FB06 `st`, and ASCII letters
    /// lowercase.
    static func folded(_ text: String) -> [UInt8] {
        Array(text.lowercased().uppercased().lowercased().utf8)
    }

    static func text(of string: ApprovalFloorString) -> String {
        switch string {
        case .naming(let text), .freeText(let text): return text
        }
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    // MARK: - Bytes

    private static let percent = UInt8(ascii: "%")
    private static let hyphen = UInt8(ascii: "-")
    private static let slash = UInt8(ascii: "/")
    private static let dot = UInt8(ascii: ".")
    private static let dollar = UInt8(ascii: "$")
    private static let quotes: [UInt8] = [UInt8(ascii: "'"), UInt8(ascii: "\"")]
    private static let quoteMarks: [UInt8] = quotes + [UInt8(ascii: "\\")]
    private static let pieceMarks: [UInt8] = [UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "+"), UInt8(ascii: "-")]
}
