// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat
@testable import NapCatWire

/// F4: the category gate keeps every prompt holding the alert topic on the
/// Mac — and when a topic exists that NapCat could not read, it cannot look
/// for it, so EVERY prompt stays local (fail closed). No topic configured is
/// a different case: nothing to look for, nothing withheld.
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

    /// The topic exists but could not be read: every prompt is kept as
    /// secret access, and none reaches the record store.
    @Test func anUnreadableTopicKeepsEveryPromptLocal() {
        let world = World(secrets: nil)
        for (index, prompt) in Self.forwardable.enumerated() {
            world.receive(IntakeHarness.requestIDs(4)[index], tool: prompt.tool, preview: prompt.preview)
        }
        #expect(world.sink.saved.isEmpty)
        #expect(world.audits.count == Self.forwardable.count)
        for code in world.audits {
            #expect(code.hasSuffix(" suppressed.gate.forbidden.secretAccess"), "\(code)")
        }
        #expect(world.intake.recentForwardableTools(within: ApprovalIntake.waitingContextSeconds).isEmpty,
                "nor does a kept prompt count for a waiting buzz")
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
    /// valid value, and then every listed command stays on the Mac with the
    /// intake's code for a topic it cannot look for. No item, or a valid
    /// value, forward the listed commands as before, and a prompt holding
    /// that value is kept by the floor.
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
                    #expect(code.hasSuffix(" suppressed.gate.forbidden.secretAccess"), "\(code)")
                }
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

    @Test func theFoldIsTheGatesAnswerOnlyWhileTheSecretsAreKnown() {
        let forward = ApprovalClassification.forward(.bash)
        let kept = ApprovalClassification.suppress(.localOnlyMCP)
        #expect(forward.failingClosed(secretsKnown: true) == forward)
        #expect(kept.failingClosed(secretsKnown: true) == kept)
        #expect(forward.failingClosed(secretsKnown: false) == .suppress(.forbidden(.secretAccess)))
        #expect(kept.failingClosed(secretsKnown: false) == .suppress(.forbidden(.secretAccess)))
    }
}
