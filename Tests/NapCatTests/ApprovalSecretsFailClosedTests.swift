// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat
@testable import NapCatWire

/// F4: the category gate keeps every prompt holding the alert topic on the
/// Mac — and when a topic exists that NapCat could not read, it cannot look
/// for it, so EVERY prompt stays local (fail closed), logged with the gate's
/// own code: the floor's `floorUnreadable.topic`, or the tool name's shape or
/// the preview's size code the gate checks before the floor. No topic
/// configured is a different case: nothing to look for, nothing withheld.
struct ApprovalSecretsFailClosedTests {
    /// An ARMED intake over fakes, with the secrets answer under test: the
    /// one given, or the lid guard's own, asked for every prompt as the
    /// app's host asks it.
    final class World {
        let sink = RecordingApprovalSink()
        var audits: [String] = []
        var secrets: [String]?
        let lidGuard: LidGuardController?
        private var nextLow: UInt64 = 0

        init(secrets: [String]?) {
            self.secrets = secrets
            lidGuard = nil
        }

        init(lidGuard: LidGuardController) {
            secrets = nil
            self.lidGuard = lidGuard
        }

        lazy var intake = ApprovalIntake(
            armed: { true },
            secrets: { [unowned self] in
                if let lidGuard { return lidGuard.approvalSecrets }
                return secrets
            },
            newPromptID: { [unowned self] in
                nextLow += 1
                return PromptID(high: 0x5EC, low: nextLow)
            },
            now: { 1_000 }, records: sink, sendFrame: { _, _ in }, closeConnection: { _ in },
            audit: { [unowned self] in audits.append($0.code) })

        func receive(_ request: String, tool: String = "Bash", preview: String) {
            intake.receive(IntakeHarness.prompt(request, tool: tool, preview: preview), from: 1)
        }
    }

    static let forwardable: [(tool: String, preview: String)] = [
        ("Bash", #"{"command":"git status"}"#),
        ("Bash", #"{"command":"make test"}"#),
        ("Bash", #"{"command":"swift test","timeout":120000}"#),
    ]

    /// The suffix of the audit line the gate's code gives, armed.
    static func logged(_ code: String) -> String { " suppressed.gate." + code }

    /// Prompts the gate keeps for their shape before its floor reads the
    /// topic, with that code: a listed command whose preview is over the size
    /// limit, and tool names of the wrong shape.
    static let keptForShape: [(tool: String, preview: String, code: String)] = [
        ("Bash", #"{"command":"git status","description":""# + String(repeating: "x", count: ApprovalGate.maxPreviewScalars) + #""}"#,
         "unclassifiable.previewTooLarge"),
        ("Bash", #"{"command":"git status","description":""# + String(repeating: "\u{E9}", count: ApprovalGate.maxPreviewScalars) + #""}"#,
         "unclassifiable.previewTooLarge"),
        ("Bash ", #"{"command":"git status"}"#, "unclassifiable.malformedToolName"),
        ("B\u{0430}sh", #"{"command":"git status"}"#, "unclassifiable.malformedToolName"),
        (String(repeating: "B", count: ApprovalGate.maxToolNameBytes + 1), #"{"command":"git status"}"#, "unclassifiable.malformedToolName"),
    ]

    /// The code the gate gives a prompt of this tool name and preview while
    /// its floor cannot read the topic: a shape code it checks first (the
    /// checks written here apart from the gate), else the floor's.
    static func expectedWhileUnreadable(tool: String, preview: String) -> String {
        let name = Array(tool.utf8)
        let nameShape = !name.isEmpty && name.count <= ApprovalGate.maxToolNameBytes
            && name.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x5F || $0 == 0x2D }
        if !nameShape { return "unclassifiable.malformedToolName" }
        if preview.utf8.count > ApprovalGate.maxPreviewBytes || preview.unicodeScalars.count > ApprovalGate.maxPreviewScalars {
            return "unclassifiable.previewTooLarge"
        }
        return "floorUnreadable.topic"
    }

    /// Baseline: with the secrets known (none configured, or the topic),
    /// these prompts forward.
    @Test(arguments: [[], ["napcat-TESTONLYk3m9q2w7"]] as [[String]])
    func withKnownSecretsForwardablePromptsForward(_ secrets: [String]) {
        let world = World(secrets: secrets)
        for (index, prompt) in Self.forwardable.enumerated() {
            world.receive(IntakeHarness.requestIDs(4)[index], tool: prompt.tool, preview: prompt.preview)
        }
        #expect(world.sink.saved.count == Self.forwardable.count, "\(world.audits)")
    }

    /// The topic exists but could not be read: every prompt is kept with the
    /// floor's code for it, and none reaches the record store.
    @Test func anUnreadableTopicKeepsEveryPromptLocal() {
        let world = World(secrets: nil)
        for (index, prompt) in Self.forwardable.enumerated() {
            world.receive(IntakeHarness.requestIDs(4)[index], tool: prompt.tool, preview: prompt.preview)
        }
        #expect(world.sink.saved.isEmpty)
        #expect(world.audits.count == Self.forwardable.count)
        for code in world.audits {
            #expect(code.hasSuffix(Self.logged("floorUnreadable.topic")), "\(code)")
        }
        #expect(world.intake.recentForwardableTools(within: ApprovalIntake.waitingContextSeconds).isEmpty,
                "nor does a kept prompt count for a waiting buzz")
    }

    /// While the topic is unreadable, a prompt the gate keeps for its shape
    /// before the floor reads anything keeps that code; none reaches the
    /// record store.
    @Test func anUnreadableTopicKeepsAShapeCodeFoundBeforeTheFloor() {
        let world = World(secrets: nil)
        let ids = IntakeHarness.requestIDs(Self.keptForShape.count)
        for (index, prompt) in Self.keptForShape.enumerated() {
            #expect(Self.expectedWhileUnreadable(tool: prompt.tool, preview: prompt.preview) == prompt.code, "\(prompt.code)")
            world.receive(ids[index], tool: prompt.tool, preview: prompt.preview)
        }
        #expect(world.sink.saved.isEmpty)
        #expect(world.audits.count == Self.keptForShape.count, "\(world.audits)")
        for (code, prompt) in zip(world.audits, Self.keptForShape) {
            #expect(code.hasSuffix(Self.logged(prompt.code)), "\(code)")
        }
        // Control: with the topic known, the same prompts keep the same codes.
        let known = World(secrets: ["alerts-TESTONLYq4r8s2v6"])
        for (index, prompt) in Self.keptForShape.enumerated() {
            known.receive(ids[index], tool: prompt.tool, preview: prompt.preview)
        }
        #expect(known.audits == world.audits, "\(known.audits)")
    }

    /// The gate alone keeps every prompt while its floor cannot read the
    /// topic (unreadable, or an empty value), under each of the nine
    /// effective sets: on the catalogue, the floor's spellings, the credential
    /// mask and a slice of the corpus, its answer is a keep with the code a
    /// predicate written apart from the gate names, the same under every set.
    @Test func theGateAloneKeepsEveryPromptWhileTheTopicIsUnreadable() {
        typealias Oracle = ApprovalGateOracleTests
        let inputs: [Oracle.Input] = Oracle.catalogueInputs + Oracle.floorInputs + [Oracle.maskedListedCommand]
            + (0..<1_000).map(Oracle.corpusInput)
        let shaped: [(tool: String, preview: String)] = Self.forwardable + Self.keptForShape.map { ($0.tool, $0.preview) }
        let prompts: [(tool: String, preview: String)] = inputs.map { ($0.tool, $0.preview) } + shaped
        var seen: [String: Int] = [:]
        for prompt in prompts {
            let expected = Self.expectedWhileUnreadable(tool: prompt.tool, preview: prompt.preview)
            seen[expected, default: 0] += 1
            for topic in [ApprovalFloorTopic.unreadable, .value([])] {
                for (name, set) in Oracle.nineSets {
                    let answer = ApprovalGate.classify(toolName: prompt.tool, inputPreview: prompt.preview, topic: topic, policy: set)
                    guard case .suppress(let kept) = answer else {
                        Issue.record("\(name): a prompt forwards while the topic is unreadable")
                        continue
                    }
                    if kept.auditCode != expected { Issue.record("\(name): \(kept.auditCode), not \(expected)") }
                }
            }
        }
        #expect(prompts.contains { ApprovalGate.classify(toolName: $0.tool, inputPreview: $0.preview, topic: .absent, policy: .listedOnly)
            == .forward(.bash) }, "vacuity: some of these forward once the topic reads as absent")
        #expect(seen.keys.sorted() == ["floorUnreadable.topic", "unclassifiable.malformedToolName", "unclassifiable.previewTooLarge"],
                "vacuity: each of the three codes is met: \(seen)")
    }

    /// The answer is read per prompt: once the topic is known again (a new
    /// one saved), prompts forward again.
    @Test func theSecretsAreReadForEveryPrompt() {
        let world = World(secrets: nil)
        world.receive("abcde", preview: #"{"command":"git status"}"#)
        world.secrets = ["napcat-TESTONLYk3m9q2w7"]
        world.receive("bcdef", preview: #"{"command":"git status"}"#)
        #expect(world.sink.saved.count == 1)
        world.receive("cdefg", preview: #"{"command":"echo napcat-TESTONLYk3m9q2w7"}"#)
        #expect(world.sink.saved.count == 1, "and the known topic is a secret again")
        #expect(world.audits.last?.hasSuffix(" suppressed.gate.floor.alertTopic") == true)
    }

    /// The topic as the gate's floor is handed it (#253), from the lid
    /// guard's answer: none readable is unreadable, none set is absent, one
    /// is its value, and more than one is unreadable.
    @Test func theLidGuardsAnswerMapsToTheFloorsTopic() {
        let topic = "napcat-TESTONLYk3m9q2w7"
        func unreadable(_ read: ApprovalFloorTopic) -> Bool { if case .unreadable = read { return true } else { return false } }
        func absent(_ read: ApprovalFloorTopic) -> Bool { if case .absent = read { return true } else { return false } }
        func value(_ read: ApprovalFloorTopic) -> [UInt8]? { if case .value(let bytes) = read { return bytes } else { return nil } }
        #expect(unreadable(ApprovalIntake.floorTopic(nil)), "none readable")
        #expect(absent(ApprovalIntake.floorTopic([])), "none set")
        #expect(value(ApprovalIntake.floorTopic([topic])) == Array(topic.utf8), "one topic")
        #expect(value(ApprovalIntake.floorTopic([""])) == [], "an empty one, which the floor reads as unreadable")
        #expect(unreadable(ApprovalIntake.floorTopic([topic, "napcat-TESTONLYother"])), "two at once")
    }

    /// A topic the floor cannot check for (an empty value, or more than one
    /// at once) keeps every prompt, with the floor's code; none reaches the
    /// record store.
    @Test(arguments: [[""], ["napcat-TESTONLYk3m9q2w7", "napcat-TESTONLYother"]] as [[String]])
    func aTopicTheFloorCannotCheckForKeepsEveryPrompt(_ secrets: [String]) {
        let world = World(secrets: secrets)
        for (index, prompt) in Self.forwardable.enumerated() {
            world.receive(IntakeHarness.requestIDs(4)[index], tool: prompt.tool, preview: prompt.preview)
        }
        #expect(world.sink.saved.isEmpty)
        #expect(world.audits.count == Self.forwardable.count)
        for code in world.audits {
            #expect(code.hasSuffix(" suppressed.gate.floorUnreadable.topic"), "\(code)")
        }
    }

    /// End to end, over the lid guard's own answer from a fake store: an
    /// alert-topic item that exists reads as unreadable unless it holds a
    /// valid value, read from the item itself at launch (a launch that could
    /// not finish moving the topic into the keychain reads as unreadable),
    /// and then every listed command stays on the Mac with the floor's code
    /// for a topic it cannot look for, and a prompt kept for its shape first
    /// keeps that code. No item, or a valid value, forward the listed
    /// commands as before, and a prompt holding that value is kept by the
    /// floor.
    @Test(arguments: TopicItemRow.all)
    func theLidGuardsAnswerDecidesWhetherAListedCommandLeaves(_ row: TopicItemRow) {
        row.launch { harness in
            let world = World(lidGuard: harness.controller)
            for (index, prompt) in Self.forwardable.enumerated() {
                world.receive(IntakeHarness.requestIDs(4)[index], tool: prompt.tool, preview: prompt.preview)
            }
            switch row.reading {
            case .unreadable:
                #expect(world.sink.saved.isEmpty)
                #expect(world.audits.count == Self.forwardable.count, "\(world.audits)")
                for code in world.audits {
                    #expect(code.hasSuffix(Self.logged("floorUnreadable.topic")), "\(code)")
                }
                let ids = IntakeHarness.requestIDs(Self.forwardable.count + Self.keptForShape.count).suffix(Self.keptForShape.count)
                for (request, prompt) in zip(ids, Self.keptForShape) {
                    world.receive(request, tool: prompt.tool, preview: prompt.preview)
                    #expect(world.audits.last?.hasSuffix(Self.logged(prompt.code)) == true, "\(world.audits)")
                }
                #expect(world.sink.saved.isEmpty, "nothing forwards in any unreadable row")
                #expect(!world.audits.contains { $0.contains(".forbidden.") }, "never a family code: \(world.audits)")
                #expect(world.intake.recentForwardableTools(within: ApprovalIntake.waitingContextSeconds).isEmpty)
            case .absent:
                #expect(world.sink.saved.count == Self.forwardable.count, "\(world.audits)")
            case .value(let topic):
                #expect(world.sink.saved.count == Self.forwardable.count, "\(world.audits)")
                world.receive(IntakeHarness.requestIDs(4)[3], preview: #"{"command":"echo \#(topic)"}"#)
                #expect(world.sink.saved.count == Self.forwardable.count, "the value is a secret")
                #expect(world.audits.last?.hasSuffix(" suppressed.gate.floor.alertTopic") == true, "\(world.audits)")
            }
        }
    }

    /// The intake's own hold, over every answer the gate can give: with the
    /// secrets known it is the gate's answer; without them it passes every
    /// keep unchanged, and a forward (which the gate never gives then) is
    /// kept with the floor's code, never a family code.
    @Test func theFoldKeepsAForwardWithTheFloorsCodeAndPassesEveryKeep() {
        let kept: [ApprovalSuppression] = ApprovalClassificationTests.everySuppression
        #expect(kept.contains(.floorUnreadable(.topic)) && kept.contains(.forbidden(.secretAccess)), "vacuity: every code")
        for suppression in kept {
            #expect(ApprovalClassification.suppress(suppression).failingClosed(secretsKnown: true) == .suppress(suppression))
            #expect(ApprovalClassification.suppress(suppression).failingClosed(secretsKnown: false) == .suppress(suppression),
                    "\(suppression.auditCode) passes unchanged")
        }
        for tool in ApprovalTool.allCases {
            #expect(ApprovalClassification.forward(tool).failingClosed(secretsKnown: true) == .forward(tool))
            #expect(ApprovalClassification.forward(tool).failingClosed(secretsKnown: false) == .suppress(.floorUnreadable(.topic)),
                    "a forward is held with the floor's code")
        }
    }
}
