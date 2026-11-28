// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import CryptoKit
import Testing
@testable import NapCat
@testable import NapCatWire

/// The frozen oracle (`FrozenApprovalGate`): a copy of the category gate as
/// it stood before the gate was routed through the never-sent floor and the
/// forwarding policy, pinned by its digest. Against it, under the listed
/// commands alone (`ApprovalForwardingSet.listedOnly`), the gate is never
/// looser and tighter in one way only: a prompt the oracle forwards may be
/// kept with a floor code, when the floor names something in the text that
/// never leaves the Mac (the model-written description) and nothing in the
/// gate's copy. A kept prompt's code changes only to a floor code, and on
/// the catalogue's rows only as `codeChanges` lists. Under each of the
/// nine effective sets, only listed commands forward, and nothing the floor
/// keeps does. Fixtures are synthetic: made-up topics, no real home folder.
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

    /// The alert topic as the floor reads it.
    static func floorTopic(_ input: Input) -> ApprovalFloorTopic {
        input.topic.map { .value(Array($0.utf8)) } ?? .absent
    }

    /// The gate's answer for the same prompt, under `policy`.
    static func live(_ input: Input, _ policy: ApprovalForwardingSet = .listedOnly) -> ApprovalClassification {
        ApprovalGate.classify(toolName: input.tool, inputPreview: input.preview, topic: floorTopic(input), policy: policy)
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


    // MARK: - The differential

    /// How one input's two answers, under the listed commands alone, may
    /// differ. A rule broken is a failure, named by the rule alone.
    enum Verdict: Equatable, Sendable {
        /// The same answer, and for a forward the same copy.
        case agree
        /// The accepted tightening: the oracle forwards, the gate keeps with
        /// a floor group, and the floor finds nothing in the copy that would
        /// have left the Mac.
        case floorKeepsAForward
        /// Both keep, the gate with a floor code where the oracle had another.
        case floorCodeOfAKeep
        case failure(String)
    }

    /// Whether `suppression` is one of the floor's codes.
    static func isFloorCode(_ suppression: ApprovalSuppression) -> Bool {
        switch suppression {
        case .floor, .floorUnreadable: return true
        case .forbidden, .localOnlyMCP, .localOnlyFileEdit, .localOnlyRead, .unclassifiable: return false
        }
    }

    /// The floor's answer for the gate's copy alone, with the strings of that
    /// copy as the gate would hand them over: the tool name, the copy's text,
    /// every decoded string, and the command and paths as names.
    static func floorOnCopy(tool: String, copy: String, topic: ApprovalFloorTopic) -> ApprovalFloorOutcome {
        guard let members = ApprovalPreview.parseObject(copy) else { return .unreadable(.notPrintableASCII) }
        let names: [ApprovalFloorString] = ApprovalGate.toolTable.first { $0.tool.rawValue == tool }
            .map { ApprovalGate.namingStrings(members, $0).map { .naming($0) } } ?? []
        let strings: [ApprovalFloorString] = [.naming(tool), .freeText(copy)] + ApprovalPreview.strings(in: members).map { .freeText($0) }
        return ApprovalFloor.outcome(of: strings + names, topic: topic)
    }

    /// The rules: never keep to forward; a forward of both has one copy; a
    /// forward of the oracle the gate keeps only with a floor group, when the
    /// floor finds nothing in the oracle's copy; a keep of both changes its
    /// code only to a floor code.
    static func verdict(oracle: ApprovalClassification, gate: ApprovalClassification, oracleCopy: String?, gateCopy: String?,
                        copyFloor: () -> ApprovalFloorOutcome) -> Verdict {
        switch (oracle, gate) {
        case (.forward(let was), .forward(let now)):
            return was == now && oracleCopy != nil && oracleCopy == gateCopy ? .agree : .failure("one forward, two copies")
        case (.suppress, .forward):
            return .failure("forwards what the oracle keeps")
        case (.forward, .suppress(let kept)):
            guard case .floor = kept else { return .failure("keeps a forward with a code that is not a floor group") }
            return copyFloor() == .noMatch ? .floorKeepsAForward : .failure("the floor names the copy itself")
        case (.suppress(let was), .suppress(let now)):
            if was == now { return .agree }
            return isFloorCode(now) ? .floorCodeOfAKeep : .failure("a code changed to one that is not the floor's")
        }
    }

    static func verdict(_ input: Input) -> Verdict {
        let gateCopy = ApprovalGate.forwardedPreview(toolName: input.tool, inputPreview: input.preview)
        let oracleCopy = FrozenApprovalGate.forwardedPreview(toolName: input.tool, inputPreview: input.preview)
        return verdict(oracle: oracle(input), gate: live(input), oracleCopy: oracleCopy, gateCopy: gateCopy) {
            floorOnCopy(tool: input.tool, copy: oracleCopy ?? "", topic: floorTopic(input))
        }
    }

    struct Counts: Equatable, Sendable {
        var agree = 0, floorKeepsAForward = 0, floorCodeOfAKeep = 0, forwarded = 0, failures = 0

        static func + (lhs: Counts, rhs: Counts) -> Counts {
            Counts(agree: lhs.agree + rhs.agree, floorKeepsAForward: lhs.floorKeepsAForward + rhs.floorKeepsAForward,
                   floorCodeOfAKeep: lhs.floorCodeOfAKeep + rhs.floorCodeOfAKeep, forwarded: lhs.forwarded + rhs.forwarded,
                   failures: lhs.failures + rhs.failures)
        }
    }

    /// One slice of the corpus, judged. A failure names the seed and the
    /// input's index, and nothing of the input.
    static func judge(_ slice: Int) -> Counts {
        var counts = Counts()
        for index in indices(of: slice) {
            let input = corpusInput(index)
            switch verdict(input) {
            case .agree: counts.agree += 1
            case .floorKeepsAForward: counts.floorKeepsAForward += 1
            case .floorCodeOfAKeep: counts.floorCodeOfAKeep += 1
            case .failure:
                counts.failures += 1
                Issue.record("seed \(seed) index \(index)")
            }
            if case .forward = oracle(input) { counts.forwarded += 1 }
        }
        return counts
    }

    /// The corpus's tally, as this seed gives it.
    static let corpusCounts = Counts(agree: 24_252, floorKeepsAForward: 2_559, floorCodeOfAKeep: 23_189, forwarded: 7_716, failures: 0)

    /// THE DIFFERENTIAL, over the seeded corpus (every slice in parallel):
    /// no input breaks a rule, and the tally of each class is pinned.
    @Test func theGateIsNeverLooserThanTheOracle() async {
        let total: Counts = await withTaskGroup(of: Counts.self) { group in
            for slice in 0..<Self.slices { group.addTask { Self.judge(slice) } }
            return await group.reduce(Counts()) { $0 + $1 }
        }
        #expect(total.agree + total.floorKeepsAForward + total.floorCodeOfAKeep + total.failures == Self.corpusSize)
        #expect(total == Self.corpusCounts, "the corpus's tally: \(total)")
        #expect(total.floorKeepsAForward > 0 && total.forwarded > total.floorKeepsAForward, "vacuity: both kinds of forward")
    }

    /// A listed command whose description names each floor group, and a
    /// made-up topic split by a quote, in it as written or escaped: the
    /// oracle forwards each, the gate keeps each with that group, and the
    /// floor finds nothing in the copy.
    static let describedRows: [(description: String, group: ApprovalFloorGroup)] = [
        ("Look up Ab'CdEf12 first", .alertTopic), ("Look up Ab\"CdEf12 first", .alertTopic),
        ("Run the NapCat unit tests", .ownNames), ("Check disablesleep after the build", .privilegedFootprint),
        ("Run the tests under third_party/smc", .sourceTree), ("Show changes to the keychain store", .keychain),
        ("Check the security fix is staged", .keychain), ("Build after the claude hook change", .claudeCodeHelpers),
        ("Check codesign before the release", .signingAndICloud),
    ]

    @Test func aListedCommandIsKeptWhenItsDescriptionNamesTheFloor() {
        #expect(Set(Self.describedRows.map(\.group)) == Set(ApprovalFloorGroup.allCases), "every group")
        for (description, group) in Self.describedRows {
            for command in ApprovalGate.bashCommands {
                for value in [Gate.quote(description), Gate.escapedQuote(description)] {
                    let input = Input(tool: "Bash", preview: Gate.object([("command", Gate.quote(command)), ("description", value)]),
                                      topic: "AbCdEf12")
                    #expect(Self.oracle(input) == .forward(.bash), "\(command): \(description)")
                    #expect(Self.live(input) == .suppress(.floor(group)), "\(command): \(description)")
                    #expect(Self.verdict(input) == .floorKeepsAForward, "\(command): \(description)")
                }
            }
        }
    }

    /// The rules can fail: each planted answer is caught.
    @Test func theDifferentialCatchesEveryLooserAnswer() {
        let forward = ApprovalClassification.forward(.bash)
        let copy = #"{"command":"git status"}"#
        let none: () -> ApprovalFloorOutcome = { .noMatch }
        let named: () -> ApprovalFloorOutcome = { .floor(.ownNames) }
        let kept = ApprovalClassification.suppress(.unclassifiable(.commandNotInTable))
        let cases: [(String, Verdict)] = [
            ("a keep forwarded", Self.verdict(oracle: kept, gate: forward, oracleCopy: nil, gateCopy: copy, copyFloor: none)),
            ("another copy", Self.verdict(oracle: forward, gate: forward, oracleCopy: copy, gateCopy: copy + " ", copyFloor: none)),
            ("another tool", Self.verdict(oracle: forward, gate: .forward(.read), oracleCopy: copy, gateCopy: copy, copyFloor: none)),
            ("a forward kept with another code", Self.verdict(oracle: forward, gate: kept, oracleCopy: copy, gateCopy: nil, copyFloor: none)),
            ("a forward kept as unreadable", Self.verdict(oracle: forward, gate: .suppress(.floorUnreadable(.topic)), oracleCopy: copy,
                                                         gateCopy: nil, copyFloor: none)),
            ("the floor names the copy", Self.verdict(oracle: forward, gate: .suppress(.floor(.ownNames)), oracleCopy: copy, gateCopy: nil,
                                                      copyFloor: named)),
            ("a code changed to a family", Self.verdict(oracle: kept, gate: .suppress(.forbidden(.secretAccess)), oracleCopy: nil,
                                                        gateCopy: nil, copyFloor: none)),
        ]
        for (name, found) in cases {
            guard case .failure = found else {
                Issue.record("canary '\(name)' was NOT caught: \(found)")
                continue
            }
        }
        // Controls: the accepted answers.
        #expect(Self.verdict(oracle: forward, gate: forward, oracleCopy: copy, gateCopy: copy, copyFloor: none) == .agree)
        #expect(Self.verdict(oracle: forward, gate: .suppress(.floor(.ownNames)), oracleCopy: copy, gateCopy: nil, copyFloor: none)
            == .floorKeepsAForward)
        #expect(Self.verdict(oracle: kept, gate: .suppress(.floorUnreadable(.notPrintableASCII)), oracleCopy: nil, gateCopy: nil,
                             copyFloor: none) == .floorCodeOfAKeep)
    }

    // MARK: - The catalogue's codes

    /// Every catalogue row whose code changes, by its note: the oracle's
    /// code, then the gate's. Each is a floor code.
    static let codeChanges: [String: (was: String, now: String)] = [
        "an MCP tool with no arguments": ("localOnly.mcp", "floor.ownNames"),
        "Bash: cat .mcp.json": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Bash: cat /etc/sudoers": ("forbidden.privilegeEscalation", "floor.privilegedFootprint"),
        "Bash: cat '/Users/someone/project/.claude.json/file'": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Bash: cat '/Users/someone/project/.mcp.json/file'": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Bash: cat '/Users/someone/project/com.muratalkan.napcat.plist/file'": ("forbidden.secretAccess", "floor.ownNames"),
        "Bash: cat '/Users/someone/project/keychains/file'": ("forbidden.secretAccess", "floor.keychain"),
        "Bash: cat '/Users/someone/project/library/application support/claudecode/file'": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Bash: cat '/Users/someone/project/managed-mcp.json/file'": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Bash: cat '/Users/someone/project/managed-settings.json/file'": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Bash: cat '/Users/someone/project/sudoers.d/file'": ("forbidden.privilegeEscalation", "floor.privilegedFootprint"),
        "Bash: cat '/Users/someone/project/sudoers/file'": ("forbidden.privilegeEscalation", "floor.privilegedFootprint"),
        "Bash: cat '/Users/someone/project/usr/local/napcat/file'": ("forbidden.privilegeEscalation", "floor.ownNames"),
        "Bash: cat '/Users/someone/project/x.keychain-db'": ("forbidden.secretAccess", "floor.keychain"),
        "Bash: cat '/Users/someone/project/x.keychain'": ("forbidden.secretAccess", "floor.keychain"),
        "Bash: claude mcp add evil": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Bash: claude x": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Bash: echo '.mcp.json'": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Bash: echo '.MCP.JSON'": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Bash: echo '/usr/local/napcat'": ("forbidden.privilegeEscalation", "floor.ownNames"),
        "Bash: echo '/USR/LOCAL/NAPCAT'": ("forbidden.privilegeEscalation", "floor.ownNames"),
        "Bash: echo 'keychain'": ("forbidden.secretAccess", "floor.keychain"),
        "Bash: echo 'KEYCHAIN'": ("forbidden.secretAccess", "floor.keychain"),
        "Bash: echo lidGuardNtfyTopic": ("forbidden.secretAccess", "floor.ownNames"),
        "Bash: echo napcat-TESTONLYa1b2c3d4e5f6, with the topic": ("forbidden.secretAccess", "floor.alertTopic"),
        "Bash: echo ntfy-topic": ("forbidden.secretAccess", "floor.ownNames"),
        "Bash: ls /usr/local/napcat": ("forbidden.privilegeEscalation", "floor.ownNames"),
        "Bash: ls ~/Library/Keychains": ("forbidden.secretAccess", "floor.keychain"),
        "Bash: pmset -a disablesleep 1": ("forbidden.privilegeEscalation", "floor.privilegedFootprint"),
        "Bash: security find-generic-password -s x -w": ("forbidden.secretAccess", "floor.keychain"),
        "Bash: Security find-generic-password": ("unclassifiable.commandNotInTable", "floor.keychain"),
        "Bash: security x": ("forbidden.secretAccess", "floor.keychain"),
        "Bash: sudo -n /usr/local/napcat/smc -k CHTE -r": ("forbidden.privilegeEscalation", "floor.ownNames"),
        "before the preview parses, with the topic": ("forbidden.secretAccess", "floor.alertTopic"),
        "in a listed command's description, with the topic": ("forbidden.secretAccess", "floor.alertTopic"),
        "in content, with the topic": ("forbidden.secretAccess", "floor.alertTopic"),
        "JSON-escaped in content, with the topic": ("forbidden.secretAccess", "floor.alertTopic"),
        "Read: /private/etc/sudoers": ("forbidden.privilegeEscalation", "floor.privilegedFootprint"),
        "Read: /Users/someone/Library/Keychains/login.keychain-db": ("forbidden.secretAccess", "floor.keychain"),
        "Read: /Users/someone/Library/Preferences/com.muratalkan.napcat.plist": ("forbidden.secretAccess", "floor.ownNames"),
        "Read: /Users/someone/project/.claude.json/file": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Read: /Users/someone/project/.mcp.json/file": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Read: /Users/someone/project/com.muratalkan.napcat.plist/file": ("forbidden.secretAccess", "floor.ownNames"),
        "Read: /Users/someone/project/keychains/file": ("forbidden.secretAccess", "floor.keychain"),
        "Read: /Users/someone/project/library/application support/claudecode/file": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Read: /Users/someone/project/managed-mcp.json/file": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Read: /Users/someone/project/managed-settings.json/file": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Read: /Users/someone/project/napcat-TESTONLYa1b2c3d4e5f6.txt, with the topic": ("forbidden.secretAccess", "floor.alertTopic"),
        "Read: /Users/someone/project/sudoers.d/file": ("forbidden.privilegeEscalation", "floor.privilegedFootprint"),
        "Read: /Users/someone/project/sudoers/file": ("forbidden.privilegeEscalation", "floor.privilegedFootprint"),
        "Read: /Users/someone/project/usr/local/napcat/file": ("forbidden.privilegeEscalation", "floor.ownNames"),
        "Read: /Users/someone/project/x.keychain-db": ("forbidden.secretAccess", "floor.keychain"),
        "Read: /Users/someone/project/x.keychain": ("forbidden.secretAccess", "floor.keychain"),
        "the topic's keychain account named in content": ("forbidden.secretAccess", "floor.ownNames"),
        "Write: /etc/sudoers.d/napcat": ("forbidden.privilegeEscalation", "floor.ownNames"),
        "Write: /Library/Application Support/ClaudeCode/managed-settings.json": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Write: /Users/someone/.claude.json": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Write: /Users/someone/.claude/hooks/napcat-busy-hook.sh": ("forbidden.configurationOrHooks", "floor.privilegedFootprint"),
        "Write: /Users/someone/project/.claude.json/file": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Write: /USERS/SOMEONE/PROJECT/.CLAUDE.JSON/FILE": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Write: /Users/someone/project/.mcp.json": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Write: /Users/someone/project/.mcp.json/file": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Write: /USERS/SOMEONE/PROJECT/.MCP.JSON/FILE": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Write: /Users/someone/project/com.muratalkan.napcat.plist/file": ("forbidden.secretAccess", "floor.ownNames"),
        "Write: /USERS/SOMEONE/PROJECT/COM.MURATALKAN.NAPCAT.PLIST/FILE": ("forbidden.secretAccess", "floor.ownNames"),
        "Write: /Users/someone/project/keychains/file": ("forbidden.secretAccess", "floor.keychain"),
        "Write: /USERS/SOMEONE/PROJECT/KEYCHAINS/FILE": ("forbidden.secretAccess", "floor.keychain"),
        "Write: /Users/someone/project/library/application support/claudecode/file": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Write: /USERS/SOMEONE/PROJECT/LIBRARY/APPLICATION SUPPORT/CLAUDECODE/FILE": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Write: /Users/someone/project/managed-mcp.json/file": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Write: /USERS/SOMEONE/PROJECT/MANAGED-MCP.JSON/FILE": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Write: /Users/someone/project/managed-settings.json/file": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Write: /USERS/SOMEONE/PROJECT/MANAGED-SETTINGS.JSON/FILE": ("forbidden.configurationOrHooks", "floor.claudeCodeHelpers"),
        "Write: /Users/someone/project/sudoers.d/file": ("forbidden.privilegeEscalation", "floor.privilegedFootprint"),
        "Write: /USERS/SOMEONE/PROJECT/SUDOERS.D/FILE": ("forbidden.privilegeEscalation", "floor.privilegedFootprint"),
        "Write: /Users/someone/project/sudoers/file": ("forbidden.privilegeEscalation", "floor.privilegedFootprint"),
        "Write: /USERS/SOMEONE/PROJECT/SUDOERS/FILE": ("forbidden.privilegeEscalation", "floor.privilegedFootprint"),
        "Write: /Users/someone/project/usr/local/napcat/file": ("forbidden.privilegeEscalation", "floor.ownNames"),
        "Write: /USERS/SOMEONE/PROJECT/USR/LOCAL/NAPCAT/FILE": ("forbidden.privilegeEscalation", "floor.ownNames"),
        "Write: /Users/someone/project/x.keychain-db": ("forbidden.secretAccess", "floor.keychain"),
        "Write: /USERS/SOMEONE/PROJECT/X.KEYCHAIN-DB": ("forbidden.secretAccess", "floor.keychain"),
        "Write: /Users/someone/project/x.keychain": ("forbidden.secretAccess", "floor.keychain"),
        "Write: /USERS/SOMEONE/PROJECT/X.KEYCHAIN": ("forbidden.secretAccess", "floor.keychain"),
        "Write: /usr/local/napcat/smc": ("forbidden.privilegeEscalation", "floor.ownNames"),
    ]

    /// On the catalogue's rows the codes change exactly as `codeChanges`
    /// lists, each to a floor code, and nothing forwards that the oracle
    /// keeps.
    @Test func theCatalogueCodesChangeOnlyAsListed() {
        let inputs = Self.catalogueInputs
        #expect(inputs.count >= 850, "vacuity: \(inputs.count) rows")
        var changed: [String: (was: String, now: String)] = [:]
        for input in inputs {
            let was = Self.oracle(input), now = Self.live(input)
            if case .suppress = was, case .forward = now { Issue.record("\(input.note) forwards") }
            guard was != now else { continue }
            guard case .suppress(let old) = was, case .suppress(let new) = now, Self.isFloorCode(new) else {
                Issue.record("\(input.note): \(was) became \(now)")
                continue
            }
            #expect(changed[input.note] == nil, "\(input.note) is two rows")
            changed[input.note] = (old.auditCode, new.auditCode)
        }
        for (note, codes) in changed where Self.codeChanges[note].map({ $0 != codes }) ?? true {
            Issue.record("unlisted: \(note.debugDescription): \(codes.was) -> \(codes.now)")
        }
        for note in Self.codeChanges.keys where changed[note] == nil {
            Issue.record("listed but unchanged: \(note.debugDescription)")
        }
    }

    /// Every spelling of the floor's catalogue, as a prompt, is kept: with a
    /// floor code, or (when a refusal that comes first in the gate's order
    /// keeps it) with the oracle's own code.
    @Test func everyFloorSpellingIsKeptAsAPrompt() {
        var floorCoded = 0
        for input in Self.floorInputs {
            let now = Self.live(input)
            guard case .suppress(let kept) = now else {
                Issue.record("\(input.note) forwards")
                continue
            }
            if Self.isFloorCode(kept) { floorCoded += 1 } else { #expect(now == Self.oracle(input), "\(input.note): \(now)") }
        }
        #expect(floorCoded == Self.floorInputs.count, "\(floorCoded) of \(Self.floorInputs.count) kept with a floor code")
    }

    // MARK: - The nine effective sets

    /// The nine sets: the listed commands alone, and Developer with each of
    /// the eight combinations of risky kinds (test-only: built through the
    /// one function, with every fact true).
    static var nineSets: [(name: String, set: ApprovalForwardingSet)] {
        typealias Policy = ApprovalForwardingPolicyTests
        return [("listed only", .listedOnly)] + (0..<8).compactMap { mask in
            let state = Policy.switches(mask, origin: .mac)
            guard let stored = ApprovalStoredPolicy(pairing: Policy.pairing, developer: true, privileged: state[0], claudeConfig: state[1],
                                                    secrets: state[2], phoneSwitch: false) else { return nil }
            return ("developer, mask \(mask)", Policy.effectiveWithEveryFact(ApprovalForwardingPolicy.text(of: stored),
                                                                              pairingInForce: Policy.pairing))
        }
    }

    /// A listed command whose description holds the relay's credential mask:
    /// its one risky kind is the secrets kind.
    static let maskedListedCommand = Input(tool: "Bash", preview: #"{"command":"git status","description":"token [REDACTED]"}"#,
                                           topic: nil, note: "a listed command, the credential mask in its description")

    /// What one set makes of `inputs`, with the listed-only answers beside
    /// them: whether each forwards, and every rule it breaks.
    static func underSet(_ name: String, _ set: ApprovalForwardingSet, _ inputs: [Input],
                         _ listedOnly: [ApprovalClassification]) -> (forwards: [Bool], broken: [String]) {
        var forwards: [Bool] = []
        var broken: [String] = []
        for (input, app) in zip(inputs, listedOnly) {
            let answer = live(input, set)
            if case .forward(let tool) = answer {
                let command = ApprovalPreview.parseObject(input.preview)?.first { $0.key == "command" }?.value
                if tool != .bash || !ApprovalGate.bashCommands.contains(where: { command == .string($0) }) {
                    broken.append("\(name): \(input.note) forwards a prompt that is not a listed command")
                }
                if oracle(input) != .forward(.bash), !(set.riskyKinds.contains(.secrets) && input.preview.lowercased().contains("[redacted]")) {
                    broken.append("\(name): \(input.note) forwards past the oracle")
                }
            }
            if case .suppress(let kept) = app, isFloorCode(kept), answer != app {
                broken.append("\(name): \(input.note): a floor keep is final under every set")
            }
            forwards.append(answer == .forward(.bash))
        }
        return (forwards, broken)
    }

    /// Under each of the nine sets: only listed Bash commands forward; one
    /// forwards beyond what the oracle forwards only when it carries the
    /// credential mask and the set admits the secrets kind; nothing the floor
    /// keeps forwards; a wider set forwards everything a narrower one does;
    /// and the listed-only set gives the app's answer.
    @Test func underEveryEffectiveSetOnlyListedCommandsForward() async {
        let sets = Self.nineSets
        #expect(sets.count == 9 && Set(sets.map(\.set.riskyKinds)).count == 8, "vacuity: the nine sets")
        let inputs: [Input] = Self.catalogueInputs + Self.floorInputs + [Self.maskedListedCommand] + (0..<1_000).map(Self.corpusInput)
        let app: [ApprovalClassification] = inputs.map { Self.live($0) }
        let results: [Int: (forwards: [Bool], broken: [String])] = await withTaskGroup(of: (Int, ([Bool], [String])).self) { group in
            for (index, entry) in sets.enumerated() {
                group.addTask { (index, Self.underSet(entry.name, entry.set, inputs, app)) }
            }
            var all: [Int: (forwards: [Bool], broken: [String])] = [:]
            for await (index, result) in group { all[index] = (result.0, result.1) }
            return all
        }
        let forwards: [[Bool]] = sets.indices.map { results[$0]?.forwards ?? [] }
        for index in sets.indices {
            for rule in results[index]?.broken ?? [] { Issue.record(Comment(rawValue: rule)) }
        }
        #expect(forwards[0] == app.map { $0 == .forward(.bash) }, "the listed-only set is the app's")
        #expect(forwards[0].contains(true), "vacuity: some inputs forward")
        for (wide, wideSet) in sets.enumerated() {
            for (narrow, narrowSet) in sets.enumerated() where narrowSet.set.riskyKinds.isSubset(of: wideSet.set.riskyKinds)
                && (narrow == 0 || wide != 0) {
                #expect(zip(forwards[narrow], forwards[wide]).allSatisfy { !$0 || $1 }, "\(wideSet.name) forwards all \(narrowSet.name) does")
            }
        }
        let masked = sets.map { Self.live(Self.maskedListedCommand, $0.set) == .forward(.bash) }
        #expect(masked == sets.map { $0.set.riskyKinds.contains(.secrets) }, "the mask forwards exactly where the secrets kind is admitted")
        #expect(Self.live(Self.maskedListedCommand) == .suppress(.forbidden(.secretAccess)), "kept, as the oracle keeps it")
        #expect(Self.oracle(Self.maskedListedCommand) == .suppress(.forbidden(.secretAccess)))
    }
}
