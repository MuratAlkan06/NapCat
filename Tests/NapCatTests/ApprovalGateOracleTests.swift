// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import CryptoKit
import Testing
@testable import NapCat
@testable import NapCatWire

/// The frozen oracle (`FrozenApprovalGate`): a copy of the category gate as
/// it stands before the gate is routed through the never-sent floor and the
/// forwarding policy. The copy is pinned by its digest, and it gives the
/// gate's own answer, code and copy alike, on every row of the gate's
/// catalogue, on every spelling of the floor's catalogue as a prompt and on
/// a seeded corpus. Fixtures are synthetic: made-up topics, no real home
/// folder.
struct ApprovalGateOracleTests {
    // MARK: - Inputs

    /// One prompt as the gate is handed it, with the alert topic (nil: none
    /// set).
    struct Input: Sendable {
        let tool: String
        let preview: String
        let topic: String?
        /// The row it comes from, for the table of changed codes.
        var note: String = ""
    }

    /// The oracle's answer, the topic handed in as its one secret.
    static func oracle(_ input: Input) -> ApprovalClassification {
        FrozenApprovalGate.classify(toolName: input.tool, inputPreview: input.preview, secrets: input.topic.map { [$0] } ?? [])
    }

    /// The gate's answer for the same prompt.
    static func live(_ input: Input) -> ApprovalClassification {
        ApprovalGate.classify(toolName: input.tool, inputPreview: input.preview, secrets: input.topic.map { [$0] } ?? [])
    }

    static func input(_ row: ApprovalClassificationTests.Row, topic: String? = nil) -> Input {
        Input(tool: row.tool, preview: row.preview, topic: topic, note: row.note + (topic == nil ? "" : ", with the topic"))
    }

    /// Every spelling of the floor's catalogue (ApprovalFloorTests) as a
    /// prompt, in the form its row names, with the floor's made-up topic: a
    /// Bash command, a Write's path or text, a web fetch's URL, a connector's
    /// argument, a tool name.
    static var floorInputs: [Input] {
        ApprovalFloorTests.coveredSpellings.compactMap { row in
            guard let string = row.strings.first else { return nil }
            let text: String = ApprovalFloor.text(of: string)
            let forms: [ApprovalFloorTests.Form] = [.bashCommand, .filePath, .fileText, .url, .connectorArgument, .toolName]
            let form: ApprovalFloorTests.Form? = forms.first { row.note.hasPrefix($0.rawValue + ": ") }
            let preview: (String, [(String, String)]) -> Input = { tool, members in
                Input(tool: tool, preview: Gate.object(members), topic: ApprovalFloorTests.topic, note: row.note)
            }
            switch form {
            case .bashCommand?: return preview("Bash", [("command", Gate.quote(text))])
            case .filePath?: return preview("Write", [("file_path", Gate.quote(text)), ("content", Gate.quote("x"))])
            case .fileText?: return preview("Write", [("file_path", Gate.quote("\(Gate.base)/a.txt")), ("content", Gate.quote(text))])
            case .url?: return preview("WebFetch", [("url", Gate.quote(text))])
            case .connectorArgument?: return preview("mcp__notes__save", [("text", Gate.quote(text))])
            case .toolName?: return Input(tool: text, preview: "{}", topic: ApprovalFloorTests.topic, note: row.note)
            case nil: return nil
            }
        }
    }

    /// Every row of the gate's catalogue (ApprovalClassificationTests), the
    /// listed commands and the commands no longer forwarded, and the rows
    /// that hold the alert topic, with and without it.
    static var catalogueInputs: [Input] {
        let tables: [Gate.Row] = Gate.familyRows + Gate.bypassCatalogue + Gate.nearMisses + Gate.auxiliary + Gate.ordinaryReads
            + Gate.readAuxiliary + Gate.localOnlyFileEdits + Gate.failClosed + Gate.placeholders
        let commands: [Gate.Row] = (ApprovalGate.bashCommands + Gate.noLongerForwarded).map { Gate.bash($0, Gate.notInTable) }
        let topic = Gate.topic
        let holding: [Gate.Row] = [
            Gate.bash("echo \(topic)", Gate.notInTable),
            Gate.raw("Write", Gate.object([("file_path", Gate.quote("\(Gate.base)/a.txt")), ("content", Gate.quote("t=\(topic)"))]),
                     Gate.localOnly, "in content"),
            Gate.raw("Write", Gate.object([("file_path", Gate.quote("\(Gate.base)/a.txt")), ("content", Gate.escapedQuote(topic))]),
                     Gate.localOnly, "JSON-escaped in content"),
            Gate.raw("Bash", Gate.object([("command", Gate.quote("git status")), ("description", Gate.quote(topic))]),
                     Gate.forwardBash, "in a listed command's description"),
            Gate.raw("Bash", "{\"command\":\"\(topic)", Gate.notInTable, "before the preview parses"),
            Gate.read("\(Gate.base)/\(topic).txt", Gate.keptRead),
        ]
        var rules: [Gate.Row] = []
        for rule in ApprovalGate.pathRules {
            let path = Gate.samplePath(rule.pattern)
            rules += [Gate.write(path, Gate.localOnly), Gate.write(path.uppercased(), Gate.localOnly), Gate.read(path, Gate.keptRead),
                      Gate.bash("cat '\(path)'", Gate.notInTable)]
        }
        rules += ApprovalGate.commandFamilies.map { Gate.bash($0.words.joined(separator: " ") + " x", Gate.notInTable) }
        rules += ApprovalGate.commandNeedles.flatMap { needle in
            [needle.text, needle.text.uppercased()].map { Gate.bash("echo '\($0)'", Gate.notInTable) }
        }
        let all: [Input] = (tables + commands + rules).map { input($0) } + holding.flatMap { [input($0, topic: topic), input($0)] }
        var seen: Set<String> = []
        return all.filter { seen.insert($0.tool + "\u{0}" + $0.preview + "\u{0}" + ($0.topic ?? "")).inserted }
    }

    // MARK: - The corpus

    /// The corpus's seed and size: the same inputs on every run, and an
    /// input is rebuilt from the seed and its index alone.
    static let seed: UInt64 = 0x4E41_5043_4154_0253
    static let corpusSize = 50_000
    /// The corpus in slices, run as parallel test cases.
    static let slices = 50

    /// SplitMix64: a small, fixed generator.
    struct Generator: RandomNumberGenerator {
        var state: UInt64

        init(seed: UInt64, index: Int) {
            state = seed ^ (UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }

        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
        mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }
        mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
    }

    /// Made-up topics; nil is none set.
    static let topics: [String?] = [nil, nil, nil, "AbCdEf12", "Zq9xW2pL", "napcat-TESTONLYk3m9q2w7"]

    static let ordinaryWords = ["ls", "-la", "cat", "README.md", "echo", "hello", "world", "git", "status", "diff", "make", "test",
                                "swift", "build", "npm", "grep", "-n", "TODO", "Sources/App.swift", "/tmp/x", "~/Downloads", "a.txt",
                                "build/out", "--short", "-s", "HEAD", "Run", "the", "tests", "Show", "working", "tree", "changes",
                                "Check", "fix", "staged", "update", "notes", "project", "release", "unit", "list", "files"]
    static let familyWords = ["sudo", "/etc/hosts", "~/.ssh/id_rsa", ".env", "launchctl", "crontab", "~/.claude/settings.json",
                              ".git/hooks", "chown", "/usr/local/bin/x", ".aws/credentials", "CLAUDE.md", "config", "doas",
                              "/Library/LaunchAgents/x.plist", "id_ed25519", ".zshrc", "osascript"]
    static let floorWords = ["napcat", "NapCat", "disablesleep", "third_party/smc", "keychain", "security", "claude", "Claude",
                             "codesign", "sudoers", "cktool", "ntfy-topic", "com.muratalkan.napcat", "seam.sock", ".mcp.json",
                             "Sources/NapCatWire", "s'ecurity", "Nap\"Cat", "na%70cat", "claude-code", "/usr/local/napcat",
                             "generic-password", "-aNapCat", "\\security", "\u{212A}eychain", "\u{017F}ecurity", "NapCatPhone"]
    static let trickyWords = ["&&", "||", "|", ";", "$(id)", "`id`", "*", "..", "a//b", "'quoted words'", "\"dq\"", "\\x", "~root",
                              "=x", "x>f", "#", "$HOME", "$'\\x41'", "{a,b}", "!!"]
    static let strangeWords = ["caf\u{E9}", "\u{00A0}", "\u{200B}", "\u{22EF}", "Stra\u{DF}e", "\u{1F600}", "\u{0430}", "\t", "\n",
                               "\r", "\u{2028}", "[REDACTED]", "(value unserializable)", "code points elided", "\u{202E}"]
    static let paths = ["/Users/someone/project/README.md", "/Users/someone/project/Sources/App.swift", "/tmp/scratch.txt",
                        "/Users/someone/.claude/settings.json", "/etc/hosts", "/Users/someone/.ssh/id_rsa", "/Users/someone/project/.env",
                        "/Users/someone/project/NapCat/Makefile", "/Users/someone/Library/Keychains/login.keychain-db",
                        "/usr/local/napcat/smc", "/Users/someone/project/a b.txt", "README.md", "/Users/someone/project/../x",
                        "/Users/someone/project/na\u{EF}ve.txt", "/Users/someone/project/[slug]/page.tsx", "/Users/someone/project/dir/",
                        "/Users/someone/Library/Application Support/ClaudeCode/managed-settings.json",
                        "/Users/someone/project/third_party/smc/smc.c", "/Users/someone/.mcp.json", "/Volumes/NapCat/x"]
    static let mcpTools = ["mcp__github__create_issue", "mcp__x__y", "mcp__napcat__ping", "mcp__plugin_napcat_relay__y", "mcp__notes__save"]
    static let otherTools = ["WebFetch", "WebSearch", "Task", "Glob", "bash", "BASH", "Bash ", "", "B\u{0430}sh", "AskUserQuestion"]

    /// A word, mostly ordinary, sometimes a family's, the floor's, a shell
    /// operator, a strange character, or the topic (whole, quote-split,
    /// percent-encoded or in another case).
    static func word(_ generator: inout Generator, topic: String?) -> String {
        let roll = generator.below(100)
        if let topic, roll < 6 {
            let split = topic.index(topic.startIndex, offsetBy: 3)
            return generator.pick([topic, String(topic[..<split]) + "'" + String(topic[split...]),
                                   "%" + String(format: "%02X", topic.utf8.first ?? 0x41) + String(topic.dropFirst()), topic.lowercased(),
                                   "https://ntfy.sh/" + topic])
        }
        switch roll {
        case ..<55: return generator.pick(ordinaryWords)
        case ..<67: return generator.pick(familyWords)
        case ..<81: return generator.pick(floorWords)
        case ..<91: return generator.pick(trickyWords)
        default: return generator.pick(strangeWords)
        }
    }

    static func words(_ generator: inout Generator, _ count: Int, topic: String?) -> String {
        (0..<count).map { _ in word(&generator, topic: topic) }.joined(separator: generator.chance(90) ? " " : "  ")
    }

    /// A Bash command: often exactly a listed command, sometimes one with a
    /// small edit, otherwise a run of words.
    static func command(_ generator: inout Generator, topic: String?) -> String {
        let roll = generator.below(100)
        if roll < 45 { return generator.pick(ApprovalGate.bashCommands) }
        if roll < 55 {
            let listed = generator.pick(ApprovalGate.bashCommands)
            return generator.pick([listed + " ", " " + listed, listed.uppercased(), listed + " " + word(&generator, topic: topic),
                                   word(&generator, topic: topic) + " " + listed, listed.replacingOccurrences(of: " ", with: "  ")])
        }
        return words(&generator, 1 + generator.below(6), topic: topic)
    }

    typealias Gate = ApprovalClassificationTests

    /// One preview member: a key and its raw JSON value.
    typealias Member = (String, String)

    static func members(_ generator: inout Generator, tool: String, topic: String?) -> [Member] {
        let text: (inout Generator, Int) -> String = { generator, count in Gate.quote(words(&generator, count, topic: topic)) }
        switch tool {
        case "Bash":
            var members: [Member] = [("command", Gate.quote(command(&generator, topic: topic)))]
            if generator.chance(75) { members.append(("description", text(&generator, 1 + generator.below(8)))) }
            if generator.chance(15) { members.append(("timeout", generator.pick(["120000", "1", "600000", "0", "1.5", "600001", "\"5\""]))) }
            if generator.chance(12) { members.append(("run_in_background", generator.pick(["false", "true", "\"true\""]))) }
            if generator.chance(8) { members.append(("dangerouslyDisableSandbox", generator.pick(["false", "true"]))) }
            if generator.chance(3) { members.append(("shell", Gate.quote("zsh"))) }
            if generator.chance(2) { members.removeFirst() }
            return members
        case "Write":
            return [("file_path", Gate.quote(generator.pick(paths))), ("content", text(&generator, 1 + generator.below(10)))]
        case "Edit":
            var members: [Member] = [("file_path", Gate.quote(generator.pick(paths))), ("old_string", text(&generator, 2)),
                                     ("new_string", text(&generator, 3))]
            if generator.chance(30) { members.append(("replace_all", generator.pick(["true", "false"]))) }
            return members
        case "NotebookEdit":
            return [("notebook_path", Gate.quote(generator.pick(paths))), ("new_source", text(&generator, 4))]
        case "Read":
            var members: [Member] = [("file_path", Gate.quote(generator.pick(paths)))]
            if generator.chance(20) { members.append(("pages", Gate.quote(generator.pick(["1-3", "0", "1-30", "safe to approve"])))) }
            return members
        case _ where tool.hasPrefix(ApprovalGate.mcpPrefix):
            var members: [Member] = [("text", text(&generator, 1 + generator.below(6)))]
            if generator.chance(40) {
                members.append(("nested", "{\"level\":[" + text(&generator, 2) + ",1,true,null],\"k\":" + text(&generator, 1) + "}"))
            }
            return members
        default:
            return [(generator.pick(["url", "query", "pattern", "prompt"]), text(&generator, 1 + generator.below(5)))]
        }
    }

    /// `preview` with some of its letters written as `\u` escapes (inside
    /// strings, so it reads back as the same text).
    static func escapingSomeLetters(_ preview: String, _ generator: inout Generator) -> String {
        var out = ""
        var inString = false
        var escaped = false
        for scalar in preview.unicodeScalars {
            if inString, !escaped, scalar != "\\", scalar != "\"", scalar.properties.isAlphabetic, scalar.value < 0x80, generator.chance(20) {
                out += String(format: "\\u%04x", scalar.value)
                continue
            }
            out.unicodeScalars.append(scalar)
            if escaped { escaped = false } else if scalar == "\\" { escaped = true } else if scalar == "\"" { inString.toggle() }
        }
        return out
    }

    /// The corpus input at `index`, rebuilt from the seed and the index.
    static func corpusInput(_ index: Int) -> Input {
        var generator = Generator(seed: seed, index: index)
        let topic = generator.pick(topics)
        let roll = generator.below(100)
        let tool: String
        switch roll {
        case ..<55: tool = "Bash"
        case ..<65: tool = "Write"
        case ..<70: tool = "Edit"
        case ..<73: tool = "NotebookEdit"
        case ..<80: tool = "Read"
        case ..<90: tool = generator.pick(mcpTools)
        default: tool = generator.pick(otherTools)
        }
        var members = members(&generator, tool: tool, topic: topic)
        if generator.chance(10) { members.shuffle(using: &generator) }
        var preview: String = generator.chance(30)
            ? "{ " + members.map { "\(Gate.quote($0.0)): \($0.1)" }.joined(separator: ", ") + " }"
            : "{" + members.map { "\(Gate.quote($0.0)):\($0.1)" }.joined(separator: ",") + "}"
        if generator.chance(10) { preview = escapingSomeLetters(preview, &generator) }
        switch generator.below(100) {
        case 0: preview = String(preview.dropLast(1 + generator.below(min(5, preview.count))))
        case 1: preview += " x"
        case 2: preview = preview.replacingOccurrences(of: "\\n", with: "\n")
        case 3: preview = String(preview.dropLast()) + ",\"description\":\"" + String(repeating: "x", count: ApprovalGate.maxPreviewScalars) + "\"}"
        case 4: preview = "{\"command\":\"git status\",\"command\":\"rm -rf x\"}"
        default: break
        }
        return Input(tool: tool, preview: preview, topic: topic, note: "corpus")
    }

    /// The indices of one slice of the corpus.
    static func indices(of slice: Int) -> Range<Int> {
        let size = corpusSize / slices
        return slice * size..<(slice + 1) * size
    }

    // MARK: - The oracle is frozen

    static let oraclePath = "Tests/NapCatTests/FrozenApprovalGate.swift"
    /// The oracle file's SHA-256, as committed.
    static let oracleDigest = "66ed6d57b0df58fd7e9604b8031569ff3b3a949ef9203d1a8fc5add810f15877"

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The oracle is the file as committed, byte for byte: an edit anywhere
    /// in it, a comment or a space included, changes its digest.
    @Test func theOracleIsFrozen() throws {
        let text = try String(contentsOf: LidGuardStructureTests.repoRoot().appendingPathComponent(Self.oraclePath), encoding: .utf8)
        #expect(Self.digest(text) == Self.oracleDigest, "the frozen oracle was edited: \(Self.digest(text))")
        #expect(text.contains("enum FrozenApprovalGate {") && text.contains("// FROZEN. Do not edit this file."), "vacuity: the oracle is read")
        // The lock can fail: one changed character, one trailing space.
        #expect(Self.digest(text.replacingOccurrences(of: "maxCommandSegments = 8", with: "maxCommandSegments = 9")) != Self.oracleDigest)
        #expect(Self.digest(text + " ") != Self.oracleDigest)
    }


    // MARK: - The oracle is today's gate

    /// On every catalogue row, and every spelling of the floor's catalogue
    /// as a prompt, the oracle gives the gate's own answer, code and copy
    /// alike.
    @Test func theOracleGivesTheGatesAnswerOnEveryCatalogueRow() {
        let inputs = Self.catalogueInputs + Self.floorInputs
        #expect(Self.floorInputs.count == ApprovalFloorTests.coveredSpellings.count, "every floor spelling is a prompt")
        #expect(inputs.count >= 1_000, "vacuity: \(inputs.count) rows")
        var forwarded = 0
        for input in inputs {
            let answer = Self.oracle(input)
            #expect(answer == Self.live(input), "\(input.note)")
            #expect(FrozenApprovalGate.forwardedPreview(toolName: input.tool, inputPreview: input.preview)
                == ApprovalGate.forwardedPreview(toolName: input.tool, inputPreview: input.preview), "\(input.note)")
            if case .forward = answer { forwarded += 1 }
        }
        #expect(forwarded >= 10, "vacuity: \(forwarded) rows forward")
    }

    /// One slice of the corpus: how many the oracle forwards, and how many
    /// differ from the gate. A difference names the seed and the input's
    /// index, and nothing of the input.
    static func compare(_ slice: Int) -> (forwarded: Int, differ: Int) {
        var forwarded = 0, differ = 0
        for index in indices(of: slice) {
            let input = corpusInput(index)
            let answer = oracle(input)
            if answer != live(input) || FrozenApprovalGate.forwardedPreview(toolName: input.tool, inputPreview: input.preview)
                != ApprovalGate.forwardedPreview(toolName: input.tool, inputPreview: input.preview) {
                differ += 1
                Issue.record("seed \(seed) index \(index)")
            }
            if case .forward = answer { forwarded += 1 }
        }
        return (forwarded, differ)
    }

    /// On the seeded corpus (every slice in parallel) the oracle gives the
    /// gate's own answer and copy.
    @Test func theOracleGivesTheGatesAnswerOnTheCorpus() async {
        let total: (forwarded: Int, differ: Int) = await withTaskGroup(of: (Int, Int).self) { group in
            for slice in 0..<Self.slices { group.addTask { Self.compare(slice) } }
            return await group.reduce((0, 0)) { ($0.0 + $1.0, $0.1 + $1.1) }
        }
        #expect(total.differ == 0)
        #expect(total.forwarded >= 5_000, "vacuity: \(total.forwarded) of \(Self.corpusSize) forward")
    }
}
