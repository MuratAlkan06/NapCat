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
    /// An ARMED intake over fakes, with the secrets answer under test.
    final class World {
        let sink = RecordingApprovalSink()
        var audits: [String] = []
        var secrets: [String]?
        private var nextLow: UInt64 = 0

        init(secrets: [String]?) { self.secrets = secrets }

        lazy var intake = ApprovalIntake(
            armed: { true }, secrets: { [unowned self] in secrets },
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
        ("Write", #"{"file_path":"/Users/someone/project/notes.md","content":"hello"}"#),
        ("Read", #"{"file_path":"/Users/someone/project/README.md"}"#),
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
        #expect(world.audits.last?.hasSuffix(" suppressed.gate.forbidden.secretAccess") == true)
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
