// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat
@testable import NapCatSeam
@testable import NapCatWire

/// The never-sent floor's tables and scans (`ApprovalFloor`). Every
/// spelling in the catalogue below is caught, in each form a prompt can
/// carry it (a Bash command, a file path, a file's text, a URL, a
/// connector's argument, a tool name); both look-alike letters, both sharp
/// s letters and two ligatures are caught through the fold; each name that
/// mirrors a constant matches that constant's definition;
/// ordinary text is not matched; the outcome carries closed codes only; and
/// nothing calls the floor yet. Fixtures are synthetic: made-up topics, no
/// real home folder.
struct ApprovalFloorTests {
    // MARK: - Fixtures

    /// A made-up alert topic, present in every catalogue row.
    static let topic = "AbCdEf12"
    static let topicValue = ApprovalFloorTopic.value(Array(topic.utf8))

    static let kelvin = "\u{212A}"
    static let longS = "\u{017F}"

    /// Where a string sits in a prompt. A Bash command, a path, a URL and a
    /// tool name name something (`naming`); a file's text and a connector's
    /// argument are free text.
    enum Form: String, Sendable {
        case bashCommand = "Bash command"
        case filePath = "file path"
        case fileText = "file text"
        case url = "URL"
        case connectorArgument = "connector argument"
        case toolName = "tool name"

        func string(_ text: String) -> ApprovalFloorString {
            switch self {
            case .bashCommand, .filePath, .url, .toolName: return .naming(text)
            case .fileText, .connectorArgument: return .freeText(text)
            }
        }
    }

    struct Row: Sendable, CustomTestStringConvertible {
        let strings: [ApprovalFloorString]
        /// Every group the strings match, in group order.
        let groups: [ApprovalFloorGroup]
        let note: String
        var testDescription: String { note }
    }

    static func row(_ form: Form, _ text: String, _ groups: [ApprovalFloorGroup]) -> Row {
        Row(strings: [form.string(text)], groups: groups, note: "\(form.rawValue): \(text)")
    }

    /// A prompt's strings as a caller hands them in: the tool name, the raw
    /// preview, then each decoded string (the naming ones as `naming`).
    static func prompt(_ tool: String, _ members: [(key: String, value: String, naming: Bool)]) -> [ApprovalFloorString] {
        let raw = ApprovalClassificationTests.object(members.map { ($0.key, ApprovalClassificationTests.quote($0.value)) })
        return [.naming(tool), .freeText(raw)] + members.map { $0.naming ? ApprovalFloorString.naming($0.value) : .freeText($0.value) }
    }

    static func groups(_ strings: [ApprovalFloorString], topic: ApprovalFloorTopic = topicValue) -> [ApprovalFloorGroup] {
        ApprovalFloor.matchedGroups(strings, topic: topic)
    }

    static func outcome(_ strings: [ApprovalFloorString], topic: ApprovalFloorTopic = topicValue) -> ApprovalFloorOutcome {
        ApprovalFloor.outcome(of: strings, topic: topic)
    }

    // MARK: - The catalogue of covered spellings

    /// The keychain item calls, spelled split so no test file names one.
    static let itemDelete = "Sec" + "Item" + "Delete"

    /// Each spelling the floor's tables catch, in the forms a prompt carries
    /// it, with every group it matches.
    static let coveredSpellings: [Row] = [
        // The alert topic, with an empty quote pair inside it or
        // percent-encoded.
        row(.bashCommand, "curl -s https://ntfy.sh/AbCd''Ef12/json?poll=1", [.alertTopic]),
        row(.connectorArgument, "https://ntfy.sh/AbCd''Ef12/json?poll=1", [.alertTopic]),
        row(.url, "https://ntfy.sh/%41bCdEf12/publish?message=x", [.alertTopic]),
        row(.bashCommand, "curl -d x https://ntfy.sh/%41bCdEf12", [.alertTopic]),
        row(.bashCommand, "curl -d hi https://ntfy.sh/AbCdEf12", [.alertTopic]),
        row(.toolName, "mcp__relay__AbCdEf12", [.alertTopic]),
        row(.fileText, "topic = \"AbCd\"'Ef12'", [.alertTopic]),
        row(.bashCommand, "echo AbCd\\Ef12", [.alertTopic]),
        row(.bashCommand, "curl -d x https://ntfy.sh/AbCd$'E'f12", [.alertTopic]),
        row(.bashCommand, "curl https://ntfy.sh/%41bCd''Ef12", [.alertTopic]),
        row(.bashCommand, "curl https://ntfy.sh/%41\"bCdEf12\"", [.alertTopic]),
        row(.bashCommand, "curl https://ntfy.sh/A\\%62CdEf12", [.alertTopic]),
        row(.bashCommand, "curl https://ntfy.sh/%4'1'bCdEf12", [.alertTopic]),
        row(.connectorArgument, "https://ntfy.sh/%\\41bCdEf12", [.alertTopic]),

        // NapCat's own names, split by empty quote pairs.
        row(.bashCommand, "defaults write com.muratalkan.napca\"\"t remote\"\"ApprovalsEnabled -bool true", [.ownNames]),
        row(.fileText, "#!/bin/sh\ndefaults write com.muratalkan.napca\"\"t remote\"\"ApprovalsEnabled -bool true\n", [.ownNames]),
        // The app's name as a word: a process, an application, a path part.
        row(.bashCommand, "osascript -e 'tell application \"System Events\" to tell process \"NapCat\" to click checkbox 1 of window 1'",
            [.ownNames]),
        row(.fileText, "tell application \"NapCat\" to quit", [.ownNames]),
        row(.bashCommand, "pkill -x NapCat", [.ownNames]),
        row(.bashCommand, "open -a NapCat", [.ownNames]),
        row(.bashCommand, "open -aNapCat", [.ownNames]),
        row(.bashCommand, "lldb -nNapCat", [.ownNames]),
        row(.bashCommand, "open -a Nap$'C'at", [.ownNames]),
        row(.bashCommand, "defaults write com.muratalkan.nap$'c'at remote$'A'pprovalsEnabled -bool true", [.ownNames]),
        row(.url, "file:///Applications/NapC%61t.app", [.ownNames]),
        row(.url, "https://example.invalid/?f=com.muratalkan.%6Eapcat", [.ownNames]),
        row(.filePath, "/Users/someone/Library/Containers/NapCat/Data", [.ownNames]),
        // The keychain item labels, accounts and service.
        row(.bashCommand, "/usr/bin/security delete-generic-password -l \"NapCat ntfy topic\"", [.ownNames, .keychain]),
        row(.bashCommand, "security find-generic-password -l \"NapCat ntfy topic\" -w", [.ownNames, .keychain]),
        row(.fileText, "label: NapCat paired iPhone key", [.ownNames]),
        row(.bashCommand, "security delete-generic-password -s com.muratalkan.napcat -a paired-iphone-key", [.ownNames, .keychain]),
        row(.connectorArgument, "ntfy-topic", [.ownNames]),
        row(.connectorArgument, "paired-iphone-key", [.ownNames]),
        row(.connectorArgument, "forwarding-policy", [.ownNames]),
        // The preference keys.
        row(.bashCommand, "defaults write com.example.other lidGuardNtfyServer https://example.invalid", [.ownNames]),
        row(.bashCommand, "plutil -replace lidGuardNtfyTopic -string x prefs.plist", [.ownNames]),
        row(.bashCommand, "defaults delete com.example.other remoteApprovalsEnabled", [.ownNames]),
        row(.fileText, "<key>pairingRecordToDelete</key>", [.ownNames]),
        // The helper, the bundle, the support folder, the socket, the receipt.
        row(.bashCommand, "/Applications/Example/Contents/MacOS/napcat-channel --version", [.ownNames]),
        row(.bashCommand, "ditto /Volumes/X/NapCat.app /Applications/NapCat.app", [.ownNames]),
        row(.bashCommand, "rm ~/Library/Application\\ Support/NapCat/approvals/seam.sock", [.ownNames]),
        row(.filePath, "/Users/someone/Library/Application Support/NapCat/approvals/channel-registration", [.ownNames]),
        row(.filePath, "/tmp/elsewhere/seam.sock", [.ownNames]),
        row(.fileText, "receipt: channel-registration", [.ownNames]),
        // The watchdog.
        row(.bashCommand, "pkill -f napcat-watchdog", [.ownNames]),
        // The record zone, the subscriptions, the forwarding policy's header
        // and the signing domains.
        row(.bashCommand, "xcrun cktool delete-record --zone-name napcat-approvals-v1", [.ownNames, .signingAndICloud]),
        row(.connectorArgument, "napcat-prompt-created-v1", [.ownNames]),
        row(.connectorArgument, "napcat-alert-created-v1", [.ownNames]),
        row(.fileText, "napcat-forwarding-v1\n", [.ownNames]),
        row(.fileText, "napcat-decision-v1\nwire:1\n", [.ownNames]),
        row(.fileText, "napcat-shown-v1", [.ownNames]),
        row(.fileText, "napcat-pair-confirm-v1", [.ownNames]),
        // NapCat's connector tools, also as a plugin's.
        row(.toolName, "mcp__napcat__reply", [.ownNames]),
        row(.toolName, "mcp__NapCat__reply", [.ownNames]),
        row(.toolName, "mcp__plugin_napcat_napcat__reply", [.ownNames]),

        // The privileged footprint.
        row(.bashCommand, "ls /usr/local/napcat", [.ownNames, .privilegedFootprint]),
        row(.bashCommand, "cd / && ls usr/local/napcat", [.ownNames, .privilegedFootprint]),
        row(.url, "file:///usr/local/n%61pcat/smc", [.ownNames, .privilegedFootprint]),
        row(.bashCommand, "pmset -a disablesleep 1", [.privilegedFootprint]),
        row(.bashCommand, "cat /private/etc/sudoers", [.privilegedFootprint]),
        row(.filePath, "/etc/sudoers.d/napcat", [.ownNames, .privilegedFootprint]),
        row(.bashCommand, "launchctl bootout gui/501/com.napcat.failsafe", [.privilegedFootprint]),
        row(.filePath, "/Users/someone/.claude/hooks/napcat-busy-hook.sh", [.privilegedFootprint]),
        row(.bashCommand, "./scripts/install-channel.sh", [.privilegedFootprint]),
        row(.bashCommand, "./scripts/uninstall-channel.sh", [.privilegedFootprint]),
        row(.bashCommand, "./scripts/install-claude-busy-hook.sh", [.privilegedFootprint]),
        row(.bashCommand, "./scripts/uninstall-claude-busy-hook.sh", [.privilegedFootprint]),

        // The source tree.
        row(.filePath, "/Users/someone/src/fork/Sources/NapCatWire/ApprovalClassification.swift", [.sourceTree]),
        row(.bashCommand, "vi Sources//NapCatWire/ApprovalClassification.swift", [.sourceTree]),
        row(.bashCommand, "vi Sources/./NapCatWire/ApprovalClassification.swift", [.sourceTree]),
        row(.bashCommand, "cd Sources && vi NapCatWire/ApprovalClassification.swift", [.sourceTree]),
        row(.bashCommand, "vi NapCatSeam/SeamSocket.swift", [.sourceTree]),
        row(.filePath, "NapCatChannel/main.swift", [.sourceTree]),
        row(.filePath, "/Users/someone/src/fork/Tests/NapCatTests/ScaffoldTests.swift", [.sourceTree]),
        row(.filePath, "/Users/someone/src/fork/ios/NapCatPhone/project.yml", [.sourceTree]),
        row(.filePath, "/Users/someone/src/fork/third_party/smc/smc.c", [.sourceTree]),
        row(.bashCommand, "vi third_party//smc/smc.c", [.sourceTree]),
        row(.bashCommand, "vi third_party/./smc/smc.c", [.sourceTree]),
        row(.bashCommand, "cp dist/smc /tmp/smc", [.sourceTree]),
        row(.bashCommand, "cp dist//smc /tmp/smc", [.sourceTree]),
        row(.bashCommand, "cp dist/./smc /tmp/smc", [.sourceTree]),
        row(.filePath, "/Users/someone/src/fork/Resources/NapCat.entitlements", [.sourceTree]),
        row(.filePath, "/Users/someone/src/NapCat/scripts/setup.sh", [.ownNames, .sourceTree]),
        row(.filePath, "/Users/someone/src/NapCat/Makefile", [.ownNames, .sourceTree]),
        row(.filePath, "/Users/someone/src/NapCat/Package.swift", [.ownNames, .sourceTree]),

        // The keychain: the tool by path, escaped, split or quoted, its API
        // names and its item verbs.
        row(.bashCommand, "/usr/bin/security find-certificate -a", [.keychain]),
        row(.bashCommand, "\\security find-certificate -a", [.keychain]),
        row(.bashCommand, "sec\"\"urity find-certificate -a", [.keychain]),
        row(.bashCommand, "'security' find-certificate -a", [.keychain]),
        row(.bashCommand, "sec$'u'rity find-certificate -a", [.keychain]),
        row(.bashCommand, "sec$\"u\"rity find-certificate -a", [.keychain]),
        row(.bashCommand, "env -Ssecurity\\ list-smartcards", [.keychain]),
        row(.bashCommand, "env -S'sec\"\"urity list-smartcards'", [.keychain]),
        row(.bashCommand, "swift -e 'import Security; " + itemDelete
            + "([kSecClass: kSecClassGenericPassword, kSecAttrAccount: \"x\"] as CFDictionary)'", [.keychain]),
        row(.fileText, "let query = [kSecValueData: data]", [.keychain]),
        row(.bashCommand, "swift -e 'SecKeychainCopyDefault(nil)'", [.keychain]),
        row(.bashCommand, "security add-internet-password -s example.invalid -a someone", [.keychain]),
        row(.filePath, "/Users/someone/Library/Keychains/login.keychain-db", [.keychain]),
        row(.bashCommand, "curl file:///Users/someone/Library/Keych%61ins/login.keych%61in-db -o /tmp/k", [.keychain]),

        // Claude Code's helper list: the command in any shape, the package,
        // the lists, the managed and remote settings, the setting and hook
        // names.
        row(.bashCommand, "claude mcp add napcat --scope local -- /tmp/x 2>/dev/null", [.ownNames, .claudeCodeHelpers]),
        row(.bashCommand, "npx @anthropic-ai/claude-code mcp add napcat -s local -- /tmp/x", [.ownNames, .claudeCodeHelpers]),
        row(.bashCommand, "npx @anthropic-ai/claude-code mcp list", [.claudeCodeHelpers]),
        row(.bashCommand, "'claude' mcp list", [.claudeCodeHelpers]),
        row(.bashCommand, "cd /tmp && claude mcp list > out.txt", [.claudeCodeHelpers]),
        row(.bashCommand, "claude --dangerously-load-development-channels server:x", [.claudeCodeHelpers]),
        row(.bashCommand, "cl$'a'ude mcp add x -- /tmp/x", [.claudeCodeHelpers]),
        row(.bashCommand, "env -Sclaude\\ mcp\\ add\\ x\\ --\\ /tmp/x", [.claudeCodeHelpers]),
        row(.connectorArgument, "/Users/someone/.claude.json", [.claudeCodeHelpers]),
        row(.connectorArgument, "{\"path\": \"/Users/someone/.claude.json\"}", [.claudeCodeHelpers]),
        row(.filePath, "/Users/someone/.claude.json", [.claudeCodeHelpers]),
        row(.bashCommand, "cat ~/.claude$'.'json", [.claudeCodeHelpers]),
        row(.url, "file:///Users/someone/.claude%2Ejson", [.claudeCodeHelpers]),
        row(.filePath, "/Users/someone/project/.mcp.json", [.claudeCodeHelpers]),
        row(.bashCommand, "curl -T x file:///Users/someone/project/%2Emcp.json", [.claudeCodeHelpers]),
        row(.filePath, "/Library/Application Support/ClaudeCode/managed-settings.json", [.claudeCodeHelpers]),
        row(.filePath, "/Library/Application Support/ClaudeCode/managed-settings.d/10-team.json", [.claudeCodeHelpers]),
        row(.filePath, "/Library/Application Support/ClaudeCode/managed-mcp.json", [.claudeCodeHelpers]),
        row(.url, "https://example.invalid/Library/Application%20Support/ClaudeCode/x.json", [.claudeCodeHelpers]),
        row(.bashCommand, "ls \"/Library/Application Support//ClaudeCode\"", [.claudeCodeHelpers]),
        row(.bashCommand, "defaults write com.anthropic.claudecode x -bool true", [.claudeCodeHelpers]),
        row(.filePath, "/Library/Managed Preferences/com.anthropic.claudecode.plist", [.claudeCodeHelpers]),
        row(.filePath, "/Users/someone/.claude/remote-settings.json", [.claudeCodeHelpers]),
        row(.fileText, "{\"hooks\": {\"PermissionRequest\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"/tmp/x\"}]}]}}",
            [.claudeCodeHelpers]),
        row(.fileText, "{\"enabledMcpjsonServers\": [\"napcat\"]}", [.ownNames, .claudeCodeHelpers]),
        row(.fileText, "{\"enableAllProjectMcpServers\": true}", [.claudeCodeHelpers]),
        row(.fileText, "{\"hookSpecificOutput\": {\"permissionDecision\": \"allow\"}}", [.claudeCodeHelpers]),

        // Signing and iCloud plumbing.
        row(.bashCommand, "codesign -dv --verbose=4 /Applications/Example.app", [.signingAndICloud]),
        row(.bashCommand, "security find-identity -v -p codesigning", [.keychain, .signingAndICloud]),
        row(.fileText, "Developer ID Application: Someone (HJSC985877)", [.signingAndICloud]),
        row(.filePath, "/Users/someone/Downloads/release.provisionprofile", [.signingAndICloud]),
        row(.bashCommand, "xcrun cktool get-teams", [.signingAndICloud]),
    ]

    @Test(arguments: coveredSpellings)
    func eachCoveredSpellingIsCaught(_ row: Row) throws {
        #expect(Self.groups(row.strings) == row.groups)
        let first = try #require(row.groups.first, "a catalogue row names at least one group")
        #expect(Self.outcome(row.strings) == .floor(first), "the outcome names the first group")
    }

    /// Whole prompts, as a caller hands them in: the tool name, the raw
    /// preview and every decoded string.
    @Test func wholePromptsAreCaughtInAnyOfTheirStrings() {
        let bash = Self.prompt("Bash", [("command", "/usr/bin/security find-certificate -a", true), ("description", "List them", false)])
        #expect(Self.outcome(bash) == .floor(.keychain))
        let write = Self.prompt("Write", [("file_path", "/Users/someone/project/notes.txt", true),
                                          ("content", "remote\"\"ApprovalsEnabled = 1", false)])
        #expect(Self.outcome(write) == .floor(.ownNames), "the new text is scanned")
        let fetch = Self.prompt("WebFetch", [("url", "https://ntfy.sh/%41bCdEf12/publish", true), ("prompt", "Post it", false)])
        #expect(Self.outcome(fetch) == .floor(.alertTopic))
        let connector = Self.prompt("mcp__files__read", [("path", "/Users/someone/.claude.json", false)])
        #expect(Self.outcome(connector) == .floor(.claudeCodeHelpers))
        #expect(Self.outcome(Self.prompt("mcp__napcat__reply", [("text", "ok", false)])) == .floor(.ownNames), "in the tool name")
        // The description is scanned like every string.
        let described = Self.prompt("Bash", [("command", "git status", true), ("description", "Ask claude", false)])
        #expect(Self.outcome(described) == .floor(.claudeCodeHelpers))
    }

    // MARK: - The look-alike letters

    /// U+212A (KELVIN SIGN) and U+017F (LATIN SMALL LETTER LONG S) fold to
    /// `k` and `s`: in free text the folded copy holds the name; in a string
    /// that names something they are outside printable ASCII, so the prompt
    /// is kept as unreadable.
    @Test func bothLookAlikeLettersAreCaught() {
        let k = Self.kelvin, s = Self.longS
        let freeText: [(String, ApprovalFloorGroup)] = [
            ("plutil -p ~/Library/Preferences/com.muratal\(k)an.napcat.plist", .ownNames),
            ("/Users/someone/Library/\(k)eychains/login.\(k)eychain-db", .keychain),
            ("\"\(k)ey\"chain", .keychain),
            ("\(s)ecurity find-certificate -a", .keychain),
            ("seam.\(s)ock", .ownNames),
            ("di\(s)ablesleep", .privilegedFootprint),
            ("/Users/someone/.claude/hooks/napcat-bu\(s)y-hook.\(s)h", .privilegedFootprint),
            ("managed-\(s)ettings.json", .claudeCodeHelpers),
        ]
        for (text, group) in freeText {
            #expect(Self.groups([.freeText(text)]) == [group], "\(text)")
            #expect(Self.outcome([.freeText(text)]) == .floor(group), "\(text)")
            #expect(Self.outcome([.naming(text)]) == .unreadable(.notPrintableASCII), "named: \(text)")
        }
        // The fold reads the letters themselves, on their own.
        #expect(ApprovalFloor.folded(k) == Array("k".utf8))
        #expect(ApprovalFloor.folded(s) == Array("s".utf8))
        #expect(ApprovalFloor.folded("KeyCHAIN") == Array("keychain".utf8))
    }

    /// Both sharp s letters (U+00DF, U+1E9E) fold to `ss`, and the
    /// ligatures U+FB01 and U+FB06 to `fi` and `st`: in free text the folded
    /// copy holds the name; in a string that names something they are
    /// outside printable ASCII, so the prompt is kept as unreadable.
    @Test func theSharpSAndTheLigaturesAreCaught() {
        let freeText: [(String, ApprovalFloorGroup)] = [
            ("delete-generic-pa\u{DF}word", .keychain),
            ("delete-generic-pa\u{1E9E}word", .keychain),
            ("DELETE-GENERIC-PA\u{1E9E}WORD", .keychain),
            ("/Users/someone/Downloads/release.provisionpro\u{FB01}le", .signingAndICloud),
            ("/Users/someone/src/fork/Tests/NapCatTe\u{FB06}s/ScaffoldTests.swift", .sourceTree),
        ]
        for (text, group) in freeText {
            #expect(Self.groups([.freeText(text)]) == [group], "\(text)")
            #expect(Self.outcome([.freeText(text)]) == .floor(group), "\(text)")
            #expect(Self.outcome([.naming(text)]) == .unreadable(.notPrintableASCII), "named: \(text)")
        }
        #expect(ApprovalFloor.folded("\u{DF}") == Array("ss".utf8))
        #expect(ApprovalFloor.folded("\u{1E9E}") == Array("ss".utf8))
        #expect(ApprovalFloor.folded("\u{FB01}") == Array("fi".utf8))
        #expect(ApprovalFloor.folded("\u{FB06}") == Array("st".utf8))
    }

    /// ASCII letters match in any case, in every copy.
    @Test func namesMatchInAnyLetterCase() {
        for text in ["KEYCHAIN", "Security", "NAPCAT", "Com.MuratAlkan.NapCat", "CLAUDE", "CodeSign", "SEAM.SOCK"] {
            #expect(!Self.groups([.naming(text)]).isEmpty, "\(text)")
            #expect(!Self.groups([.freeText(text)]).isEmpty, "\(text)")
        }
    }

    // MARK: - Every name, in every shape

    /// `text`'s first byte written as `%` and two hex digits.
    static func firstBytePercentEncoded(_ text: String) -> String {
        let first: UInt8 = text.utf8.first ?? 0
        return "%" + String(first, radix: 16, uppercase: true) + String(text.dropFirst())
    }

    /// Each word matches standing alone, quoted, escaped, between path
    /// separators, before a joiner, in capitals, split by `$` and an empty
    /// quote pair, with its first letter percent-encoded, and glued to a
    /// one-letter option; and does not match inside a longer word.
    @Test func everyWordMatchesAsAWholePieceOnly() {
        for table in ApprovalFloor.tables {
            for word in table.words {
                let head = String(word.prefix(1)), tail = String(word.dropFirst())
                for text in ["run \(word) now", "'\(word)'", "\"\(word)\"", "\\\(word)", "/opt/\(word)/bin", "\(word);", "x=\(word)",
                             word.uppercased(), "\(head)$''\(tail)", "\(head)$\"\"\(tail)", Self.firstBytePercentEncoded(word),
                             "env -S\(word)", "open -a\(word.uppercased())"] {
                    #expect(Self.groups([.naming(text)]).contains(table.group), "\(text)")
                    #expect(Self.groups([.freeText(text)]).contains(table.group), "free text: \(text)")
                }
                for text in ["pre\(word)", "\(word)s", "-a\(word)s"] {
                    #expect(!Self.groups([.naming(text)]).contains(table.group), "\(text) holds \(word) inside a longer word")
                }
            }
        }
    }

    /// Each substring matches inside a longer text, in capitals, split by
    /// an empty quote pair, a backslash or `$` and an empty quote pair, with
    /// its first byte percent-encoded, and with each of its slashes written
    /// twice or as `/./`.
    @Test func everySubstringMatchesAnywhere() {
        for table in ApprovalFloor.tables {
            for name in table.substrings {
                let head = String(name.prefix(1)), tail = String(name.dropFirst())
                var texts = ["xx\(name)yy", "XX\(name.uppercased())YY", "\(head)\"\"\(tail)", "\(head)''\(tail)", "\(head)\\\(tail)",
                             "\(head)$''\(tail)", "\(head)$\"\"\(tail)", "xx" + Self.firstBytePercentEncoded(name)]
                if name.contains("/") {
                    texts += [name.replacingOccurrences(of: "/", with: "//"), name.replacingOccurrences(of: "/", with: "/./")]
                }
                for text in texts {
                    #expect(Self.groups([.naming(text)]).contains(table.group), "\(text)")
                    #expect(Self.groups([.freeText(text)]).contains(table.group), "free text: \(text)")
                }
            }
        }
    }

    /// The readings, each once: as written, without quotes, backslashes and
    /// `$`, either of the two percent-decoded, and each of those four with
    /// every run of slashes written as one and every `/./` as `/`.
    @Test func theNameScanReadsEachReadingOnce() {
        let readings = ApprovalFloor.readings(Array("a//$'b'%41".utf8)).map { String(decoding: $0, as: UTF8.self) }
        #expect(readings == ["a//$'b'%41", "a//b%41", "a//$'b'A", "a//bA", "a/$'b'%41", "a/b%41", "a/$'b'A", "a/bA"])
        #expect(ApprovalFloor.readings(Array("git status".utf8)) == [Array("git status".utf8)], "a plain text is read once")
        #expect(ApprovalFloor.slashesCollapsed(Array("a//b///c/./d/././e".utf8)) == Array("a/b/c/d/e".utf8))
        #expect(ApprovalFloor.slashesCollapsed(Array("./a/.b/c.".utf8)) == Array("./a/.b/c.".utf8), "other dots stay")
    }

    /// The split: every byte that is not an ASCII letter, digit, `_`, `.`,
    /// `+` or `-` ends a piece.
    @Test func thePiecesSplitOnEveryOtherByte() {
        let separators = [" ", "/", "\\", "'", "\"", "=", ":", ";", "(", ")", "@", ",", "|", "&", "$", "`", "*", "?", "[", "]",
                          "{", "}", "<", ">", "!", "#", "~", "^", "%", "\t", "\n", "\u{0}", "\u{7F}", "\u{E9}"]
        for separator in separators {
            let text = "x\(separator)security\(separator)y"
            #expect(ApprovalFloor.pieces(Array(text.utf8)).contains { $0.elementsEqual("security".utf8) }, "split on \(separator.debugDescription)")
            #expect(Self.groups([.freeText(text)]).contains(.keychain), "\(text.debugDescription)")
        }
        for joiner in ["_", ".", "+", "-"] {
            #expect(ApprovalFloor.pieces(Array("a\(joiner)b".utf8)).count == 1, "one piece")
        }
        #expect(ApprovalFloor.pieces(Array("a/b c=d:e;f(g'h\"i\\j@k,l\tm\nn".utf8)).count == 14)
    }

    // MARK: - Over-match controls

    /// Ordinary prompts and text match nothing: the gate's own listed
    /// commands, everyday paths and text, a folder whose name holds the
    /// app's name inside a longer word, longer words that hold a word name,
    /// everyday options, variables, percent signs and slashes, and other
    /// connectors' tools.
    @Test func ordinaryTextMatchesNothing() {
        var controls: [ApprovalFloorString] = ApprovalGate.bashCommands.map { .naming($0) }
        controls += [
            .naming("ls -la /Users/someone/Documents/NapCatalog"),
            .naming("/Users/someone/Pictures/snapcat/napcats-2024.png"),
            .naming("git commit -m 'Explain insecurity and cybersecurity'"),
            .naming("cat securityreview.txt securities.csv"),
            .naming("echo Claudette Claudia preclaude"),
            .naming("/Users/someone/project/README.md"),
            .naming("https://example.com/docs/getting-started"),
            .naming("Bash"), .naming("Write"), .naming("mcp__github__create_issue"),
            .freeText("Hello, world. Notes on insecurity and cybersecurity."),
            .freeText("Find the release notes for version 1.5"),
            .freeText("Gr\u{FC}\u{DF}e aus K\u{F6}ln, \u{17F}ch\u{F6}n, \u{41F}\u{440}\u{438}\u{432}\u{435}\u{442}, \u{4E16}\u{754C}"),
            .freeText("{\"command\":\"git status\"}"),
            .naming("ls -la --color=auto src//lib/./util"), .naming("grep -rn -e pattern -f file.txt ."),
            .naming("tar -xzf archive.tar.gz -C /tmp/out"), .naming("echo $HOME $PATH ${USER}"),
            .naming("curl -sS https://example.com/a%20b/c%2Fd?q=100%25"), .naming("rg -isecurityx"), .naming("make -j8 -Ccore"),
            .naming("swift build -c release -Xswiftc -O"), .naming("printf '%s\\n' \"$x\""), .naming("cc -lclaudex"),
            .naming("open -a Safari https://example.com"), .naming("git log -n5 --oneline"), .naming("cat a//b/./c.txt"),
            .freeText("price is $5, 100% sure; see a//b and ./c"),
            .freeText("Stra\u{DF}e und Fu\u{DF}ball, \u{FB01}ne \u{FB06}yle"),
            .naming("mcp__plugin_github_github__create_issue"), .naming("mcp__claude_ai_Notion__search"),
        ]
        for control in controls {
            #expect(Self.groups([control]).isEmpty, "\(control)")
            #expect(Self.outcome([control]) == .noMatch, "\(control)")
        }
        #expect(Self.outcome(controls) == .noMatch, "all of them at once")
    }

    // MARK: - The alert topic

    @Test func theTopicIsMatchedAsWrittenUnquotedAndPercentDecoded() {
        let other = ApprovalFloorTopic.value(Array("ZzJjKk99".utf8))
        let caught = ["https://ntfy.sh/ZzJjKk99", "Zz\"Jj\"Kk99", "Zz'Jj'Kk99", "Zz\\JjKk99", "Zz$'Jj'Kk99", "%5AzJjKk99",
                      "Zz%4ajKk99", "Zz%4AjKk99", "%5A%7A%4A%6A%4B%6B%39%39", "%5Az''JjKk99", "%5A\"zJj\"Kk99", "Zz\\%4AjKk99",
                      "%5'A'zJjKk99", "%\\5AzJjKk99", "Zz$'%4A'jKk99"]
        for text in caught {
            #expect(Self.groups([.naming(text)], topic: other) == [.alertTopic], "\(text)")
            #expect(Self.groups([.freeText(text)], topic: other) == [.alertTopic], "free text: \(text)")
        }
        // Percent signs without two hex digits stay as they are.
        #expect(ApprovalFloor.percentDecoded(Array("100%".utf8)) == Array("100%".utf8))
        #expect(ApprovalFloor.percentDecoded(Array("%4".utf8)) == Array("%4".utf8))
        #expect(ApprovalFloor.percentDecoded(Array("%zz%41".utf8)) == Array("%zzA".utf8))
        #expect(ApprovalFloor.percentDecoded(Array("%41%".utf8)) == Array("A%".utf8))
    }

    /// No topic set matches nothing; a topic that exists but could not be
    /// read, or is empty, keeps every prompt, whatever it holds.
    @Test func aTopicThatCannotBeReadKeepsEveryPrompt() {
        let text: [ApprovalFloorString] = [.naming("curl -d hi https://ntfy.sh/AbCdEf12")]
        #expect(Self.outcome(text, topic: .absent) == .noMatch)
        #expect(Self.outcome(text, topic: .value([])) == .unreadable(.topic), "an empty topic cannot be checked for")
        #expect(Self.outcome([], topic: .value([])) == .unreadable(.topic))
        #expect(Self.outcome([.naming("security")], topic: .value([])) == .unreadable(.topic), "before any name")
        #expect(Self.outcome(text, topic: .unreadable) == .unreadable(.topic))
        #expect(Self.outcome([], topic: .unreadable) == .unreadable(.topic))
        #expect(Self.outcome([.naming("git status")], topic: .unreadable) == .unreadable(.topic))
        #expect(Self.outcome([.naming("security")], topic: .unreadable) == .unreadable(.topic), "before any name")
        #expect(Self.outcome([], topic: Self.topicValue) == .noMatch)
    }

    // MARK: - The outcome

    /// The order: an unreadable topic, then the first matching group, then
    /// a naming string outside printable ASCII, then no match.
    @Test func theOutcomeOrder() {
        #expect(Self.outcome([.freeText("AbCdEf12 security")]) == .floor(.alertTopic))
        #expect(Self.groups([.freeText("AbCdEf12 security napcat")]) == [.alertTopic, .ownNames, .keychain])
        #expect(Self.outcome([.naming("ls \(Self.kelvin)"), .naming("security")]) == .floor(.keychain), "a name before ASCII")
        #expect(Self.outcome([.naming("ls \(Self.kelvin)")]) == .unreadable(.notPrintableASCII))
        #expect(Self.outcome([.freeText("ls \(Self.kelvin)")]) == .noMatch, "free text may hold any script")
        for control in ["git\tstatus", "git status\n", "git\u{7F}", "caf\u{E9}", "\u{0}"] {
            #expect(Self.outcome([.naming(control)]) == .unreadable(.notPrintableASCII), "\(control.debugDescription)")
        }
        #expect(Self.outcome([.naming(" ~")]) == .noMatch, "space to tilde is printable")
        #expect(Self.outcome([]) == .noMatch)
        // Every group is reachable on its own.
        let alone: [ApprovalFloorGroup: String] = [
            .alertTopic: "AbCdEf12", .ownNames: "napcat", .privilegedFootprint: "disablesleep", .sourceTree: "third_party/smc",
            .keychain: "keychain", .claudeCodeHelpers: ".mcp.json", .signingAndICloud: "cktool",
        ]
        #expect(Set(alone.keys) == Set(ApprovalFloorGroup.allCases))
        for (group, text) in alone {
            #expect(Self.groups([.naming(text)]) == [group], "\(group)")
        }
    }

    /// The outcome can carry no text: its cases hold the two closed code
    /// enums, which hold no value at all, and its size is a code's, not a
    /// string's.
    @Test func theOutcomeCarriesClosedCodesOnly() throws {
        #expect(MemoryLayout<ApprovalFloorOutcome>.size <= 2, "a string member would make it at least 16 bytes")
        #expect(MemoryLayout<ApprovalFloorGroup>.size == 1)
        #expect(MemoryLayout<ApprovalFloorUnreadable>.size == 1)
        let code = try WireContractTests.wireCode(Self.floorFile)
        #expect(Self.caseLines(of: "public enum ApprovalFloorOutcome", in: code)
            == ["case noMatch", "case floor(ApprovalFloorGroup)", "case unreadable(ApprovalFloorUnreadable)"])
        for codes in ["public enum ApprovalFloorGroup", "public enum ApprovalFloorUnreadable"] {
            let lines = Self.caseLines(of: codes, in: code)
            #expect(!lines.isEmpty && lines.allSatisfy { !$0.contains("(") }, "\(codes): \(lines)")
        }
        #expect(ApprovalFloorGroup.allCases.map(\.rawValue) == ["alertTopic", "ownNames", "privilegedFootprint", "sourceTree",
                                                                "keychain", "claudeCodeHelpers", "signingAndICloud"])
        #expect(ApprovalFloorUnreadable.allCases.map(\.rawValue) == ["topic", "notPrintableASCII"])
        // The reader can fail: a planted text member is seen.
        let planted = code.replacingOccurrences(of: "case floor(ApprovalFloorGroup)", with: "case floor(ApprovalFloorGroup, String)")
        #expect(planted != code && Self.caseLines(of: "public enum ApprovalFloorOutcome", in: planted).contains("case floor(ApprovalFloorGroup, String)"))
    }

    static let floorFile = "ApprovalFloor.swift"

    /// The trimmed `case` lines of the enum declared by `head`, up to its
    /// closing brace at the start of a line.
    static func caseLines(of head: String, in code: String) -> [String] {
        guard let start = code.range(of: head + ":") ?? code.range(of: head + " ") else { return [] }
        let body = code[start.upperBound...]
        let end = body.range(of: "\n}")?.lowerBound ?? body.endIndex
        return body[..<end].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("case ") }
    }

    // MARK: - The tables

    /// One table per group but the topic's, in group order; every name
    /// lowercase printable ASCII, free of `//`, of `/./` and of every I/O
    /// token the wire's purity scan reads; every word made of piece bytes
    /// only (so it can match a piece); no name twice; and no table empty.
    @Test func theTablesAreWellFormed() {
        #expect(ApprovalFloor.tables.map(\.group) == ApprovalFloorGroup.allCases.filter { $0 != .alertTopic })
        var seen: Set<String> = []
        for table in ApprovalFloor.tables {
            #expect(!(table.words + table.substrings).isEmpty, "\(table.group) has names")
            for name in table.words + table.substrings {
                #expect(!name.isEmpty && name == name.lowercased() && ApprovalFloor.isPrintableASCII(name), "\(name)")
                #expect(!name.contains("//") && !name.contains("/./"), "\(name)")
                for token in WireContractTests.ioTokens {
                    #expect(!name.contains(token), "'\(token)' in \(name)")
                }
                #expect(seen.insert(name).inserted, "\(name) is listed twice")
            }
            for word in table.words {
                #expect(word.utf8.allSatisfy(ApprovalFloor.isPieceByte), "\(word) can match a piece")
            }
        }
    }

    /// The group of each name, as the tables list it, and whether it is a
    /// word or a substring.
    static func listing(_ name: String) -> (group: ApprovalFloorGroup, word: Bool)? {
        for table in ApprovalFloor.tables {
            if table.words.contains(name) { return (table.group, true) }
            if table.substrings.contains(name) { return (table.group, false) }
        }
        return nil
    }

    static var allNames: Set<String> { Set(ApprovalFloor.tables.flatMap { $0.words + $0.substrings }) }

    // MARK: - Parity with the definitions they mirror

    enum Relation: Sendable {
        /// The definition, lowercased, is the name.
        case equal
        /// The definition, lowercased, starts with the name.
        case prefix
        /// The definition, lowercased, holds the name.
        case contains
        /// The definition, lowercased, is the name, `-v` and a version.
        case versioned
    }

    struct Parity {
        let name: String
        let group: ApprovalFloorGroup
        let relation: Relation
        let definitions: [String]
        let source: String
    }

    static func holds(_ relation: Relation, _ name: String, _ definition: String) -> Bool {
        let lower = definition.lowercased()
        switch relation {
        case .equal: return lower == name
        case .prefix: return lower.hasPrefix(name)
        case .contains: return lower.contains(name)
        case .versioned:
            guard lower.hasPrefix(name + "-v") else { return false }
            let version = lower.dropFirst(name.count + 2)
            return !version.isEmpty && version.allSatisfy(\.isNumber)
        }
    }

    static func repoFile(_ path: String) throws -> String {
        try String(contentsOf: LidGuardStructureTests.repoRoot().appendingPathComponent(path), encoding: .utf8)
    }

    static func plistString(_ path: String, _ key: String) -> String {
        let url = LidGuardStructureTests.repoRoot().appendingPathComponent(path)
        return (NSDictionary(contentsOf: url)?[key] as? String) ?? ""
    }

    /// A shell script's `NAME="value"` line, read as written ("" if absent).
    static func shellValue(_ name: String, _ script: String) -> String {
        for line in script.split(separator: "\n") where line.hasPrefix(name + "=\"") {
            return String(line.dropFirst(name.count + 2).prefix { $0 != "\"" })
        }
        return ""
    }

    /// A Makefile's `NAME := value` line ("" if absent).
    static func makeValue(_ name: String, _ makefile: String) -> String {
        for line in makefile.split(separator: "\n") where line.hasPrefix(name + " ") || line.hasPrefix(name + ":") {
            let parts = line.components(separatedBy: ":=")
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == name {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    /// The string literal that follows `marker` in `text`, read as written
    /// ("" if absent).
    static func literal(after marker: String, in text: String) -> String {
        guard let range = text.range(of: marker) else { return "" }
        return String(text[range.upperBound...].prefix { $0 != "\"" })
    }

    /// The Security identifiers NapCat's keychain store uses, read from its
    /// source (the item calls and the `kSec` keys).
    static func keychainIdentifiers() throws -> [String] {
        let text = try repoFile("Sources/NapCat/KeychainTopicStore.swift")
        let pattern = try NSRegularExpression(pattern: "(?<![A-Za-z0-9_])k?Sec[A-Z][A-Za-z0-9_]*")
        let whole = NSRange(text.startIndex..., in: text)
        return Array(Set(pattern.matches(in: text, range: whole).compactMap { Range($0.range, in: text).map { String(text[$0]) } })).sorted()
    }

    /// Each name with a definition elsewhere in the repository: the four
    /// Mac targets' constants (for the watchdog, the two literals its
    /// controller spells), and where a value lives only in a script, the
    /// Makefile, the manifest or a property list, there.
    static func parities() throws -> [Parity] {
        let makefile = try repoFile("Makefile"), manifest = try repoFile("Package.swift")
        let setup = try repoFile("scripts/setup.sh"), uninstall = try repoFile("scripts/uninstall.sh")
        let installChannel = try repoFile("scripts/install-channel.sh"), uninstallChannel = try repoFile("scripts/uninstall-channel.sh")
        let identifiers = try keychainIdentifiers()
        let watchdog = try repoFile("Sources/NapCat/WatchdogController.swift")
        let executable = manifest.components(separatedBy: ".executable(name: \"").dropFirst().first.map { String($0.prefix { $0 != "\"" }) } ?? ""
        let smc: [String] = PrivilegedCommand.allCases.map(\.executablePath).filter { $0.hasSuffix("/smc") }
        let sleep: [String] = [PrivilegedCommand.stayAwakeOn, .stayAwakeOff].map { $0.argv.joined(separator: " ") }
        let receipt = { (script: String) in String(shellValue("RECEIPT", script).split(separator: "/").last ?? "") }
        return [
            Parity(name: "napcat", group: .ownNames, relation: .equal,
                   definitions: [ApprovalChannel.serverName, ChannelPolicy.pluginName, ChannelPolicy.marketplaceName,
                                 shellValue("SERVER_NAME", installChannel), shellValue("SERVER_NAME", uninstallChannel),
                                 makeValue("APP_NAME", makefile)],
                   source: "the channel's server, plugin and marketplace names, the scripts' server name, the app's name"),
            Parity(name: "com.muratalkan.napcat", group: .ownNames, relation: .equal,
                   definitions: [KeychainItemName.ntfyTopic.service, KeychainItemName.pairedPhone.service,
                                 plistString("Resources/Info.plist", "CFBundleIdentifier"), shellValue("DEFAULTS_DOMAIN", uninstall),
                                 shellValue("KEYCHAIN_SERVICE", uninstall), shellValue("PAIRED_KEY_SERVICE", uninstall),
                                 shellValue("BUNDLE_IDENTIFIER", installChannel)],
                   source: "the keychain service, the bundle ID, the defaults domain"),
            Parity(name: "com.muratalkan.napcat", group: .ownNames, relation: .contains,
                   definitions: [AlertWire.containerIdentifier, makeValue("CHANNEL_IDENTIFIER", makefile),
                                 plistString("Resources/NapCat.entitlements", "com.apple.application-identifier")],
                   source: "the iCloud container, the helper's identifier, the application identifier"),
            Parity(name: "ntfy-topic", group: .ownNames, relation: .equal,
                   definitions: [KeychainItemName.ntfyTopic.account, shellValue("KEYCHAIN_ACCOUNT", uninstall)],
                   source: "the topic's keychain account"),
            Parity(name: "lidguardntfy", group: .ownNames, relation: .prefix,
                   definitions: [DefaultsKey.lidGuardNtfyServer, RetiredDefaultsKey.lidGuardNtfyTopic],
                   source: "the alert server key and the retired topic key"),
            Parity(name: "paired-iphone", group: .ownNames, relation: .prefix,
                   definitions: [KeychainItemName.pairedPhone.account, shellValue("PAIRED_KEY_ACCOUNT", uninstall)],
                   source: "the paired key's keychain account"),
            Parity(name: "napcat ntfy topic", group: .ownNames, relation: .equal, definitions: [KeychainTopicStore.itemLabel],
                   source: "the topic item's label"),
            Parity(name: "napcat paired iphone key", group: .ownNames, relation: .equal,
                   definitions: [KeychainTopicStore.pairedPhoneItemLabel], source: "the paired key item's label"),
            Parity(name: "napcat-channel", group: .ownNames, relation: .equal, definitions: [makeValue("CHANNEL", makefile), executable],
                   source: "the helper's product and bundled name"),
            Parity(name: "napcat-channel", group: .ownNames, relation: .prefix, definitions: [ApprovalChannel.serverVersionStampPrefix],
                   source: "the helper's version stamp"),
            Parity(name: "napcat.app", group: .ownNames, relation: .equal, definitions: [makeValue("APP_NAME", makefile) + ".app"],
                   source: "the app bundle's name"),
            Parity(name: "support/napcat", group: .ownNames, relation: .contains,
                   definitions: [SeamPaths.directoryRelativePath, ClaudeBusyConstants.markerDirRelativePath,
                                 shellValue("APPROVALS_DIR", installChannel), shellValue("APPROVALS_DIR", uninstallChannel)],
                   source: "the seam's and the busy marker's folders"),
            Parity(name: "seam.sock", group: .ownNames, relation: .equal, definitions: [SeamPaths.socketName], source: "the seam socket"),
            Parity(name: "channel-registration", group: .ownNames, relation: .equal,
                   definitions: [receipt(installChannel), receipt(uninstallChannel)], source: "the channel receipt"),
            Parity(name: "remoteapprovals", group: .ownNames, relation: .prefix, definitions: [DefaultsKey.remoteApprovalsEnabled],
                   source: "the remote approvals switch's key"),
            Parity(name: "pairingrecordtodelete", group: .ownNames, relation: .equal, definitions: [DefaultsKey.pairingRecordToDelete],
                   source: "the pairing clean-up key"),
            Parity(name: "napcat-watchdog", group: .ownNames, relation: .equal,
                   definitions: [literal(after: "forResource: \"", in: watchdog), literal(after: "command.contains(\"", in: watchdog)],
                   source: "the watchdog's script and the process it reaps"),
            Parity(name: "napcat-approvals", group: .ownNames, relation: .versioned, definitions: [ApprovalWire.zoneName],
                   source: "the record zone"),
            Parity(name: "napcat-prompt-created", group: .ownNames, relation: .versioned, definitions: [ApprovalWire.promptSubscriptionID],
                   source: "the prompt subscription"),
            Parity(name: "napcat-alert-created", group: .ownNames, relation: .versioned, definitions: [AlertWire.subscriptionID],
                   source: "the alert subscription"),
            Parity(name: "napcat-forwarding", group: .ownNames, relation: .versioned, definitions: [ApprovalForwardingPolicy.header],
                   source: "the forwarding policy's header"),
            Parity(name: "napcat-decision", group: .ownNames, relation: .versioned, definitions: [ApprovalSigning.decisionDomain],
                   source: "the decision domain"),
            Parity(name: "napcat-shown", group: .ownNames, relation: .versioned, definitions: [ApprovalSigning.shownDomain],
                   source: "the shown-copy domain"),
            Parity(name: "napcat-pair", group: .ownNames, relation: .versioned, definitions: [ApprovalSigning.pairDomain],
                   source: "the pairing domain"),
            Parity(name: "napcat-pair", group: .ownNames, relation: .prefix,
                   definitions: [ApprovalSigning.pairConfirmDomain, ApprovalSigning.pairProofDomain, ApprovalSigning.pairNameLabel],
                   source: "the pairing response's domains and name label"),
            Parity(name: "mcp__napcat", group: .ownNames, relation: .equal, definitions: [ApprovalGate.mcpPrefix + ApprovalChannel.serverName],
                   source: "the tool-name prefix of NapCat's connector"),
            Parity(name: "mcp__plugin_napcat", group: .ownNames, relation: .equal,
                   definitions: [ApprovalGate.mcpPrefix + "plugin_" + ChannelPolicy.pluginName],
                   source: "the tool-name prefix of NapCat's connector as a plugin's"),
            Parity(name: "usr/local/napcat", group: .privilegedFootprint, relation: .contains,
                   definitions: smc + [shellValue("SMC_DIR", setup), shellValue("SMC_DIR", uninstall)], source: "the root helper's folder"),
            Parity(name: "disablesleep", group: .privilegedFootprint, relation: .contains, definitions: sleep,
                   source: "the stay-awake commands"),
            Parity(name: "sudoers", group: .privilegedFootprint, relation: .contains,
                   definitions: [shellValue("SUDOERS_FILE", setup), shellValue("SUDOERS_FILE", uninstall)], source: "the sudoers file"),
            Parity(name: "com.napcat.failsafe", group: .privilegedFootprint, relation: .equal,
                   definitions: [shellValue("AGENT_LABEL", setup), shellValue("AGENT_LABEL", uninstall)], source: "the failsafe login item"),
            Parity(name: "napcat-busy-hook", group: .privilegedFootprint, relation: .contains,
                   definitions: [ClaudeBusyConstants.installedHookRelativePath], source: "the installed busy hook"),
            Parity(name: "secitem", group: .keychain, relation: .prefix, definitions: identifiers.filter { $0.hasPrefix("Sec") },
                   source: "the item calls of NapCat's keychain store"),
            Parity(name: "ksec", group: .keychain, relation: .prefix, definitions: identifiers.filter { $0.hasPrefix("kSec") },
                   source: "the keys of NapCat's keychain store"),
            Parity(name: "generic-password", group: .keychain, relation: .contains,
                   definitions: uninstall.split(separator: "\n").map(String.init).filter { $0.contains("/usr/bin/security ") },
                   source: "the uninstall script's keychain commands"),
            Parity(name: "managed-settings", group: .claudeCodeHelpers, relation: .prefix,
                   definitions: [ChannelPolicyProbe.settingsFileName, ChannelPolicyProbe.dropInDirectoryName],
                   source: "the managed settings file and folder the probe reads"),
            Parity(name: "application support/claudecode", group: .claudeCodeHelpers, relation: .contains,
                   definitions: [ChannelPolicyProbe.systemDirectory], source: "the managed settings' system folder"),
            Parity(name: "codesign", group: .signingAndICloud, relation: .prefix, definitions: [makeValue("CODESIGN", makefile)],
                   source: "the Makefile's signing command"),
            Parity(name: "hjsc985877", group: .signingAndICloud, relation: .equal,
                   definitions: [shellValue("TEAM_IDENTIFIER", installChannel),
                                 plistString("Resources/NapCat.entitlements", "com.apple.developer.team-identifier")],
                   source: "the signing team"),
            Parity(name: "provisionprofile", group: .signingAndICloud, relation: .contains,
                   definitions: makefile.split(separator: "\n").map(String.init).filter { $0.hasPrefix("\t") && $0.contains("Contents/embedded.") },
                   source: "the profile the Makefile installs"),
        ]
    }

    /// Each mirrored name is in its group's table, and matches each of its
    /// definitions as stated; the floor then catches each definition in
    /// that group.
    @Test func eachMirroredNameMatchesItsDefinitions() throws {
        for parity in try Self.parities() {
            #expect(Self.listing(parity.name)?.group == parity.group, "\(parity.name) is listed in \(parity.group)")
            #expect(!parity.definitions.isEmpty, "\(parity.name): \(parity.source) were read")
            for definition in parity.definitions {
                #expect(!definition.isEmpty, "\(parity.name): \(parity.source) — an empty definition")
                #expect(Self.holds(parity.relation, parity.name, definition), "\(parity.name) vs \(definition) (\(parity.source))")
                #expect(Self.groups([.naming(definition)]).contains(parity.group), "\(definition) is caught")
            }
        }
    }

    /// The floor agrees with the gate: every rule the gate keeps for these
    /// names is a floor match in the same sense.
    @Test func theFloorCatchesWhatTheGateNamesForTheseThings() {
        let familyWords: [String] = ApprovalGate.commandFamilies.filter { $0.words.count == 1 }.map { $0.words[0] }
        for (word, group) in [("security", ApprovalFloorGroup.keychain), ("claude", .claudeCodeHelpers)] {
            #expect(familyWords.contains(word), "the gate names \(word)")
            #expect(Self.listing(word)?.group == group && Self.listing(word)?.word == true, "\(word) is a floor word")
        }
        for secret in ApprovalGate.secretNames {
            #expect(Self.groups([.naming(secret)]).contains(.ownNames), "\(secret)")
        }
        var gateNames: [String: ApprovalFloorGroup] = [
            "keychain": .keychain, "keychains": .keychain, ".keychain": .keychain, ".keychain-db": .keychain,
            "com.muratalkan.napcat.plist": .ownNames, "/usr/local/napcat": .privilegedFootprint,
            "sudoers": .privilegedFootprint, "sudoers.d": .privilegedFootprint,
            ".claude.json": .claudeCodeHelpers, ".mcp.json": .claudeCodeHelpers, "managed-settings.json": .claudeCodeHelpers,
            "managed-mcp.json": .claudeCodeHelpers,
        ]
        gateNames["library/application support/claudecode"] = .claudeCodeHelpers
        gateNames["usr/local/napcat"] = .privilegedFootprint
        let gateTexts: Set<String> = Set(ApprovalGate.commandNeedles.map(\.text) + ApprovalGate.pathRules.flatMap { rule -> [String] in
            switch rule.pattern {
            case .component(let name), .componentPrefix(let name), .componentSuffix(let name): return [name]
            case .run(let names), .rooted(let names): return [names.joined(separator: "/")]
            }
        })
        for (name, group) in gateNames {
            #expect(gateTexts.contains(name), "the gate names \(name)")
            #expect(Self.groups([.naming(name)]).contains(group), "\(name) is a floor match")
        }
    }

    /// The installer names are the scripts' names: each is a script, and
    /// every install or uninstall script is caught.
    static let scriptNames = ["install-channel", "uninstall-channel", "install-claude-busy-hook"]

    @Test func theScriptNamesAreTheScripts() throws {
        let scripts = try FileManager.default.contentsOfDirectory(
            atPath: LidGuardStructureTests.repoRoot().appendingPathComponent("scripts").path)
        for name in Self.scriptNames {
            #expect(scripts.contains(name + ".sh"), "scripts/\(name).sh")
            #expect(Self.listing(name)?.group == .privilegedFootprint)
        }
        let installers = scripts.filter { ($0.hasPrefix("install-") || $0.hasPrefix("uninstall-")) && $0.hasSuffix(".sh") }
        #expect(installers.count >= 4, "vacuity: \(installers)")
        for script in installers where script != "uninstall.sh" {
            #expect(Self.groups([.naming("./scripts/" + script)]).contains(.privilegedFootprint), "\(script)")
        }
    }

    /// The source-tree names, read in a checkout in a folder named NapCat,
    /// name real parts of this tree.
    static let treePaths = ["Sources/NapCat", "Sources/NapCatWire", "Sources/NapCatSeam", "Sources/NapCatChannel", "Tests/NapCatTests",
                            "ios/NapCatPhone", "third_party/smc", "Resources/NapCat.entitlements", "scripts", "Makefile", "Package.swift"]

    @Test func theSourceTreeNamesAreThisTree() throws {
        let root = LidGuardStructureTests.repoRoot()
        for path in Self.treePaths {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), "\(path)")
        }
        let tree = try #require(ApprovalFloor.tables.first { $0.group == .sourceTree })
        for name in tree.substrings where name != "dist/smc" {
            #expect(Self.treePaths.contains { ("napcat/" + $0).lowercased().contains(name) }, "\(name)")
        }
        let makefile = try Self.repoFile("Makefile")
        #expect(Self.makeValue("DIST", makefile) + "/smc" == "dist/smc" && makefile.contains("\nsmc: $(DIST)/smc"), "the helper's build output")
        #expect(Self.shellValue("SMC_SRC", try Self.repoFile("scripts/setup.sh")).hasSuffix("/dist/smc"))
        // Every target folder starts with the app's name.
        let targets = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sources").path)
        #expect(targets.count >= 4 && targets.allSatisfy { Self.groups([.naming("x/Sources/" + $0 + "/y")]).contains(.sourceTree) }, "\(targets)")
    }

    /// Names that mirror no definition in this repository: Claude Code's
    /// and Apple's own names, and the keychain account reserved for the
    /// forwarding policy.
    static let namesWithNoDefinitionHere: Set<String> = [
        "forwarding-policy", "seckeychain", "internet-password", "claude-code", "remote-settings.json", "com.anthropic.claudecode",
        "mcpjsonservers", "projectmcpservers", "development-channels", "permissionrequest", "permissiondecision",
        "developer id application", "cktool",
    ]

    /// The names the gate's own tables mirror (see the test above).
    static let namesTheGateMirrors: Set<String> = ["security", "keychain", "claude", ".claude.json", ".mcp.json", "managed-mcp.json"]

    /// Every name is accounted for exactly once: mirrored by a definition,
    /// by the gate, by the scripts, by the tree, or listed as having none.
    @Test func everyNameIsAccountedFor() throws {
        let mirrored = Set(try Self.parities().map(\.name))
        let tree = Set(ApprovalFloor.tables.first { $0.group == .sourceTree }?.substrings ?? [])
        let parts: [Set<String>] = [mirrored, Self.namesTheGateMirrors, Set(Self.scriptNames), tree, Self.namesWithNoDefinitionHere]
        #expect(parts.reduce(Set<String>()) { $0.union($1) } == Self.allNames)
        #expect(parts.map(\.count).reduce(0, +) == Self.allNames.count, "no name is in two parts")
        for name in Self.namesWithNoDefinitionHere {
            #expect(Self.listing(name) != nil, "\(name) is a floor name")
        }
    }

    // MARK: - Unwired

    /// Nothing calls the floor yet: no file of the four Mac targets but the
    /// floor's own, and no phone source, names it; so the gate's file is as
    /// it was.
    static func callerFailures(_ sources: ApprovalChannelStructureTests.Sources) -> [String] {
        sources.filter { $0.name != floorFile && $0.text.contains("ApprovalFloor") }.map { "\($0.name) names the floor" }
    }

    @Test func nothingCallsTheFloorYet() throws {
        let sources = try ApprovalChannelStructureTests.sources()
        #expect(sources.contains { $0.name == Self.floorFile }, "vacuity: the scan reads the floor's file")
        #expect(sources.contains { $0.name == "ApprovalClassification.swift" }, "vacuity: the scan reads the gate's file")
        #expect(Self.callerFailures(sources).isEmpty, "\(Self.callerFailures(sources))")
        #expect(!(try WireContractTests.wireCode("ApprovalClassification.swift")).contains("ApprovalFloor"))
        let phone = LidGuardStructureTests.repoRoot().appendingPathComponent("ios/NapCatPhone/NapCatPhone")
        var phoneFiles = 0
        if let walker = FileManager.default.enumerator(at: phone, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "swift" {
                phoneFiles += 1
                let text = LidGuardStructureTests.codeOnly(try String(contentsOf: url, encoding: .utf8))
                #expect(!text.contains("ApprovalFloor"), "\(url.lastPathComponent) names the floor")
            }
        }
        #expect(phoneFiles > 0, "vacuity: the phone's sources were read")
        // The lock can fail: a call planted in the gate's file is seen.
        let planted = ApprovalChannelStructureTests.mutate(sources, "ApprovalClassification.swift") {
            $0 + "\nlet zz = ApprovalFloor.outcome(of: [], topic: .absent)"
        }
        #expect(!Self.callerFailures(planted).isEmpty)
    }
}
