// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat
@testable import NapCatWire

/// Records what the intake asked of the record store (CloudKit, later).
final class RecordingApprovalSink: ApprovalRecordSink {
    struct Saved: Equatable {
        let id: PromptID
        let tool: ApprovalTool
        let inputPreview: String
        let expiresAt: Int
    }

    var saved: [Saved] = []
    var retracted: [PromptID] = []
    var superseded: [PromptID] = []

    func save(_ id: PromptID, tool: ApprovalTool, inputPreview: String, expiresAt: Int) {
        saved.append(Saved(id: id, tool: tool, inputPreview: inputPreview, expiresAt: expiresAt))
    }

    func retract(_ id: PromptID) { retracted.append(id) }
    func supersedeWaitingAlert(_ id: PromptID) { superseded.append(id) }
}

/// The intake with every input and output faked.
final class IntakeHarness {
    var armed = true
    var secrets: [String] = []
    var now = 1_000
    var nextIDs: [PromptID?] = (1...600).map { PromptID(high: 0xA0, low: UInt64($0)) }
    let sink = RecordingApprovalSink()
    var frames: [(ApprovalIntake.ConnectionKey, String)] = []
    var closed: [ApprovalIntake.ConnectionKey] = []
    var audits: [ApprovalAuditEvent] = []

    lazy var intake = ApprovalIntake(
        armed: { [unowned self] in armed }, secrets: { [unowned self] in secrets },
        newPromptID: { [unowned self] in nextIDs.isEmpty ? nil : nextIDs.removeFirst() },
        now: { [unowned self] in now }, records: sink,
        sendFrame: { [unowned self] in frames.append(($0, $1)) },
        closeConnection: { [unowned self] in closed.append($0) },
        audit: { [unowned self] in audits.append($0) })

    static func id(_ n: UInt64) -> PromptID { PromptID(high: 0xA0, low: n)! }

    static func prompt(_ request: String, tool: String = "Bash", preview: String = #"{"command":"ls -la"}"#) -> [UInt8] {
        Array(ApprovalChannel.promptFrame(ChannelPermissionRequest(requestID: ChannelRequestID(request)!, toolName: tool,
                                                                   inputPreview: preview))!.utf8)
    }

    func receive(_ request: String, tool: String = "Bash", preview: String = #"{"command":"ls -la"}"#, from connection: Int = 1) {
        intake.receive(Self.prompt(request, tool: tool, preview: preview), from: connection)
    }

    /// The prompt was saved and CloudKit accepted it.
    func forward(_ request: String, from connection: Int = 1) -> PromptID? {
        let before = sink.saved.count
        receive(request, from: connection)
        guard sink.saved.count == before + 1, let id = sink.saved.last?.id else { return nil }
        intake.apply(.saveAccepted, to: id)
        return id
    }

    static func decision(_ id: PromptID, _ verdict: ApprovalWire.Verdict = .allow, signed: Bool = true,
                         wireVersion: Int = ApprovalWire.wireVersion) -> ApprovalDecision {
        ApprovalDecision(promptID: id, verdict: verdict, wireVersion: wireVersion, signatureVerified: signed)
    }

    var codes: [String] { audits.map(\.code) }

    /// `count` distinct well-formed request IDs.
    static func requestIDs(_ count: Int) -> [String] {
        let alphabet = Array(ApprovalChannel.requestIDAlphabet)
        return (0..<count).map { index in
            var rest = index
            return String((0..<ApprovalChannel.requestIDLength).map { _ in
                defer { rest /= alphabet.count }
                return alphabet[rest % alphabet.count]
            })
        }
    }
}

/// F4 slice S1: the category gate and the prompt lifecycle wired into the
/// forwarding path (`ApprovalIntake`). Every prompt frame is classified by
/// the S0 gate before its lifecycle opens; nothing is saved unless the gate
/// forwards it AND the feature is armed; the one verdict frame is a valid
/// signed remote decision for that prompt, sent to the server it came from.
struct ApprovalIntakeTests {
    // MARK: - Dark by default

    /// S1's production posture: unarmed (the toggles are a later slice), so
    /// even a forwardable prompt stays local.
    @Test func unarmedNothingIsForwardedWhateverTheGateSays() {
        let harness = IntakeHarness()
        harness.armed = false
        harness.receive("abcde")
        #expect(harness.sink.saved.isEmpty)
        #expect(harness.codes == ["prompt=\(IntakeHarness.id(1).hex) suppressed.notArmed"])
        #expect(harness.frames.isEmpty)
    }

    // MARK: - The gate decides what may leave

    @Test func armedAForwardablePromptIsSavedAsTheGatesCopy() throws {
        let harness = IntakeHarness()
        let preview = #"{ "command": "git status", "description": "DESCRIPTION-SENTINEL: approve this" }"#
        harness.receive("abcde", preview: preview)
        let saved = try #require(harness.sink.saved.first)
        #expect(saved == RecordingApprovalSink.Saved(id: IntakeHarness.id(1), tool: .bash, inputPreview: #"{"command":"git status"}"#,
                                                     expiresAt: 1_000 + ApprovalWire.promptTimeToLiveSeconds))
        #expect(!saved.inputPreview.contains("SENTINEL"), "the model's description never reaches the record store")
        #expect(harness.sink.superseded.isEmpty, "the waiting alert yields only after CloudKit accepts")
        harness.intake.apply(.saveAccepted, to: saved.id)
        #expect(harness.sink.superseded == [saved.id])
        #expect(harness.codes == ["prompt=\(saved.id.hex) forwarded"])
        #expect(harness.frames.isEmpty, "forwarding answers nothing")
    }

    struct GateRow: Sendable, CustomTestStringConvertible {
        let tool: String
        let preview: String
        let code: String
        var testDescription: String { code + " " + tool }
    }

    /// Prompts the gate keeps on the Mac, armed or not: each is logged with
    /// the gate's own code and never reaches the record store.
    static let keptLocal: [GateRow] = [
        GateRow(tool: "Bash", preview: #"{"command":"sudo ls"}"#, code: "forbidden.privilegeEscalation"),
        GateRow(tool: "Bash", preview: #"{"command":"ls","dangerouslyDisableSandbox":true}"#, code: "forbidden.privilegeEscalation"),
        GateRow(tool: "Write", preview: #"{"file_path":"/Users/someone/.claude/settings.json","content":"{}"}"#,
                code: "forbidden.configurationOrHooks"),
        GateRow(tool: "Read", preview: #"{"file_path":"/Users/someone/.ssh/id_ed25519"}"#, code: "forbidden.secretAccess"),
        GateRow(tool: "Bash", preview: #"{"command":"security find-generic-password"}"#, code: "forbidden.secretAccess"),
        GateRow(tool: "mcp__webhook__reply", preview: #"{"text":"hi"}"#, code: "localOnly.mcp"),
        GateRow(tool: "Write", preview: #"{"file_path":"/Users/someone/project/notes.md","content":"hello"}"#,
                code: "localOnly.fileEdit"),
        GateRow(tool: "WebFetch", preview: #"{"url":"https://example.com"}"#, code: "unclassifiable.unknownTool"),
        GateRow(tool: "Bash", preview: #"{"command":"ls; rm -rf /tmp/x"}"#, code: "unclassifiable.commandOutsideGrammar"),
        GateRow(tool: "Bash", preview: #"{"command":"curl example.com"}"#, code: "unclassifiable.commandNotInTable"),
        // A relay marker sits INSIDE a value, in a preview that is otherwise
        // well formed: each row is kept for the marker's own reason.
        GateRow(tool: "Bash", preview: #"{"command":"ls ⋯ 12 code points elided ⋯"}"#,
                code: "unclassifiable.previewNotFaithful"),
        GateRow(tool: "Bash", preview: #"{"command":"cat (value unserializable)"}"#, code: "unclassifiable.previewNotFaithful"),
        GateRow(tool: "Read", preview: #"{"file_path":"/Users/someone/project/(value unserializable)"}"#,
                code: "unclassifiable.previewNotFaithful"),
        GateRow(tool: "Read", preview: #"{"file_path":"/Users/someone/project/[REDACTED].txt"}"#, code: "forbidden.secretAccess"),
        GateRow(tool: "Read", preview: #"{"file_path":"/Users/someone/project/my notes.txt"}"#, code: "unclassifiable.pathNotCanonical"),
    ]

    @Test(arguments: keptLocal)
    func aPromptTheGateKeepsNeverLeaves(_ row: GateRow) {
        let harness = IntakeHarness()
        harness.receive("abcde", tool: row.tool, preview: row.preview)
        #expect(harness.sink.saved.isEmpty)
        #expect(harness.codes == ["prompt=\(IntakeHarness.id(1).hex) suppressed.gate.\(row.code)"])
        harness.intake.decide(IntakeHarness.decision(IntakeHarness.id(1)))
        #expect(harness.frames.isEmpty, "a decision for a prompt that never left answers nothing")
        #expect(harness.codes.last == "prompt=\(IntakeHarness.id(1).hex) ignored.notForwarded")
    }

    /// The alert topic is a secret to the gate: a prompt that holds it is
    /// secret access, whatever else it is.
    @Test func theTopicIsASecretToTheGate() {
        let harness = IntakeHarness()
        let topic = "napcat-TESTONLYz9y8x7w6v5"
        harness.secrets = [topic]
        harness.receive("abcde", preview: #"{"command":"echo "# + topic + #""}"#)
        #expect(harness.sink.saved.isEmpty)
        #expect(harness.codes == ["prompt=\(IntakeHarness.id(1).hex) suppressed.gate.forbidden.secretAccess"])
        harness.secrets = []
        harness.receive("bcdef", preview: #"{"command":"echo "# + topic + #""}"#)
        #expect(harness.sink.saved.count == 1, "baseline: without the secret the same prompt forwards")
    }

    /// Every saved record holds the gate's copy: the relayed preview's
    /// members minus the description, never the relayed text.
    @Test func noSavedRecordCarriesTheDescription() throws {
        let harness = IntakeHarness()
        let previews = [
            #"{"command":"git status","description":"SENTINEL-1"}"#,
            #"{"description":"SENTINEL-2","command":"make test","timeout":60000}"#,
            #"{ "command": "git status", "description": "SENTINEL-3", "dangerouslyDisableSandbox": false }"#,
        ]
        for (preview, request) in zip(previews, IntakeHarness.requestIDs(previews.count)) {
            harness.receive(request, preview: preview)
        }
        #expect(harness.sink.saved.map(\.inputPreview) == [#"{"command":"git status"}"#, #"{"command":"make test","timeout":60000}"#,
                                                          #"{"command":"git status","dangerouslyDisableSandbox":false}"#])
        for saved in harness.sink.saved {
            #expect(!saved.inputPreview.contains("SENTINEL") && !saved.inputPreview.contains("description"))
        }
    }

    /// The fold: a forwarded prompt without a copy stays local; any other
    /// answer is the gate's own.
    @Test func aForwardWithoutACopyStaysLocal() {
        let forward = ApprovalClassification.forward(.bash)
        let kept = ApprovalClassification.suppress(.localOnlyMCP)
        #expect(forward.requiringCopy(#"{"command":"git status"}"#) == forward)
        #expect(forward.requiringCopy(nil) == .suppress(.unclassifiable(.previewNotStrictJSON)))
        #expect(kept.requiringCopy(nil) == kept)
        #expect(kept.requiringCopy("{}") == kept)
    }

    // MARK: - Decisions

    @Test(arguments: ApprovalWire.Verdict.allCases)
    func aValidSignedDecisionSendsOneVerdictFrameToTheServerItCameFrom(_ verdict: ApprovalWire.Verdict) throws {
        let harness = IntakeHarness()
        let first = try #require(harness.forward("abcde", from: 1))
        let second = try #require(harness.forward("bcdef", from: 2))
        harness.intake.decide(IntakeHarness.decision(second, verdict))
        #expect(harness.frames.count == 1)
        #expect(harness.frames.first?.0 == 2)
        #expect(harness.frames.first?.1 == ApprovalChannel.verdictFrame(ChannelRequestID("bcdef")!, verdict))
        #expect(harness.sink.retracted == [second])
        #expect(harness.intake.prompts[first]?.lifecycle.phase == .forwarded, "the other prompt is unchanged")
        #expect(harness.codes.last == "prompt=\(second.hex) decided.remote.\(verdict.rawValue)")
    }

    @Test func invalidDecisionsAnswerNothing() throws {
        let harness = IntakeHarness()
        let id = try #require(harness.forward("abcde"))
        harness.intake.decide(IntakeHarness.decision(id, signed: false))
        harness.intake.decide(IntakeHarness.decision(id, wireVersion: 2))
        harness.intake.decide(IntakeHarness.decision(IntakeHarness.id(999)))
        #expect(harness.frames.isEmpty)
        #expect(harness.codes.suffix(3) == ["prompt=\(id.hex) ignored.unauthenticated", "prompt=\(id.hex) ignored.wrongWireVersion",
                                            "seam.unknownPrompt"])
    }

    @Test func aDecisionBeforeCloudKitAcceptedThePromptAnswersNothing() throws {
        let harness = IntakeHarness()
        harness.receive("abcde")
        let id = try #require(harness.sink.saved.first?.id)
        harness.intake.decide(IntakeHarness.decision(id))
        #expect(harness.frames.isEmpty)
        #expect(harness.codes.last == "prompt=\(id.hex) ignored.notForwarded")
    }

    @Test func theFirstDecisionWins() throws {
        let harness = IntakeHarness()
        let id = try #require(harness.forward("abcde"))
        harness.intake.decide(IntakeHarness.decision(id, .deny))
        harness.intake.decide(IntakeHarness.decision(id, .allow))
        #expect(harness.frames.map(\.1) == [ApprovalChannel.verdictFrame(ChannelRequestID("abcde")!, .deny)])
        #expect(harness.codes.last == "prompt=\(id.hex) ignored.alreadyResolved")
    }

    @Test func aDecisionAfterTheTTLAnswersNothing() throws {
        let harness = IntakeHarness()
        let id = try #require(harness.forward("abcde"))
        harness.now += ApprovalWire.promptTimeToLiveSeconds
        harness.intake.decide(IntakeHarness.decision(id))
        #expect(harness.frames.isEmpty)
        #expect(harness.sink.retracted == [id])
    }

    // MARK: - Withdrawal, never an answer

    @Test func theTTLWithdrawsAnUnansweredPromptAndItIsForgottenAfter() throws {
        let harness = IntakeHarness()
        let id = try #require(harness.forward("abcde"))
        harness.now += ApprovalWire.promptTimeToLiveSeconds - 1
        harness.intake.tick()
        #expect(harness.sink.retracted.isEmpty)
        harness.now += 1
        harness.intake.tick()
        #expect(harness.sink.retracted == [id])
        #expect(harness.frames.isEmpty, "expiry never answers the dialog")
        #expect(harness.intake.prompts[id] == nil, "a finished prompt past its TTL is forgotten")
    }

    @Test func whenAServerGoesAwayItsOpenPromptsAreWithdrawn() throws {
        let harness = IntakeHarness()
        let gone = try #require(harness.forward("abcde", from: 1))
        let stays = try #require(harness.forward("bcdef", from: 2))
        harness.intake.connectionClosed(1)
        #expect(harness.sink.retracted == [gone])
        #expect(harness.intake.prompts[stays]?.lifecycle.phase == .forwarded)
        harness.intake.decide(IntakeHarness.decision(gone))
        #expect(harness.frames.isEmpty)
        #expect(harness.codes.last == "prompt=\(gone.hex) ignored.retracted")
    }

    @Test func theKillSwitchWithdrawsEveryOpenPromptAndSilencesLaterDecisions() throws {
        let harness = IntakeHarness()
        let first = try #require(harness.forward("abcde", from: 1))
        let second = try #require(harness.forward("bcdef", from: 2))
        harness.intake.killSwitch()
        #expect(Set(harness.sink.retracted) == [first, second])
        harness.intake.decide(IntakeHarness.decision(first))
        harness.intake.decide(IntakeHarness.decision(second, .deny))
        #expect(harness.frames.isEmpty)
        #expect(harness.codes.suffix(2) == ["prompt=\(first.hex) ignored.retracted", "prompt=\(second.hex) ignored.retracted"])
    }

    @Test func aFailedSaveKeepsThePromptLocalAndTheWaitingAlert() throws {
        let harness = IntakeHarness()
        harness.receive("abcde")
        let id = try #require(harness.sink.saved.first?.id)
        harness.intake.apply(.saveFailed, to: id)
        #expect(harness.sink.superseded.isEmpty)
        #expect(harness.codes == ["prompt=\(id.hex) forwardFailed"])
    }

    // MARK: - What the seam may send

    static let refusedFrames: [String] = [
        ApprovalChannel.verdictFrame(ChannelRequestID("abcde")!, .allow),
        "not json",
        #"{"frame":"prompt","v":1,"request":"abcde","tool":"Bash","preview":"{}","description":"x"}"#,
        #"{"frame":"prompt","v":2,"request":"abcde","tool":"Bash","preview":"{}"}"#,
        #"{"frame":"prompt","v":1,"request":"abcdl","tool":"Bash","preview":"{}"}"#,
    ]

    /// A verdict frame from a server, or anything the strict reader refuses,
    /// closes that connection and opens nothing.
    @Test(arguments: refusedFrames)
    func aRefusedFrameClosesTheConnectionAndOpensNothing(_ frame: String) {
        let harness = IntakeHarness()
        harness.intake.receive(Array(frame.utf8), from: 7)
        #expect(harness.closed == [7])
        #expect(harness.codes == ["seam.frameRefused"])
        #expect(harness.intake.prompts.isEmpty)
        #expect(harness.sink.saved.isEmpty)
    }

    @Test func aDuplicateRequestFromOneServerIsRefusedButAnotherServersIsItsOwn() {
        let harness = IntakeHarness()
        harness.receive("abcde", from: 1)
        harness.receive("abcde", from: 1)
        harness.receive("abcde", from: 2)
        #expect(harness.sink.saved.count == 2)
        #expect(harness.codes == ["seam.duplicateRequest"])
    }

    @Test func withoutAPromptIDOrPastCapacityThePromptStaysLocal() {
        let harness = IntakeHarness()
        harness.nextIDs = [nil]
        harness.receive("abcde")
        #expect(harness.codes == ["seam.promptIDUnavailable"])
        #expect(harness.intake.prompts.isEmpty)

        // Spread over servers, so no one of them meets its own cap (slice S2:
        // `maxPromptsPerConnection`) before the intake meets its global one.
        let full = IntakeHarness()
        let ids = IntakeHarness.requestIDs(ApprovalIntake.maxPrompts + 1)
        for (index, request) in ids.enumerated() { full.receive(request, from: index % 8 + 1) }
        #expect(full.intake.prompts.count == ApprovalIntake.maxPrompts)
        #expect(full.codes == ["seam.capacityReached"])
    }

    // MARK: - The audit trail

    /// Every code the intake can log, built from the S0 enums: the whole
    /// vocabulary, nothing else.
    static var vocabulary: Set<String> {
        let suppressions = ForbiddenFamily.allCases.map { ApprovalSuppression.forbidden($0) } + [.localOnlyMCP, .localOnlyFileEdit]
            + Unclassifiable.allCases.map { ApprovalSuppression.unclassifiable($0) }
        let audits: [ApprovalAudit] = suppressions.map { .suppressed(.gate($0)) } + [.suppressed(.notArmed), .forwarded, .forwardFailed]
            + ApprovalWire.Verdict.allCases.map { .decided(.remote($0)) } + [.decided(.local), .expired]
            + ApprovalIgnoreReason.allCases.map { .ignored($0) } + ApprovalRetraction.allCases.map { .retracted($0) }
        let seam: [ApprovalAuditEvent] = [.frameRefused, .duplicateRequest, .capacityReached, .connectionPromptLimit,
                                          .promptIDUnavailable, .unknownPrompt, .peerRefused]
        return Set(audits.map(ApprovalAuditEvent.code) + seam.map(\.code))
    }

    /// Every line is a random prompt ID (optional) and one vocabulary code:
    /// no preview, tool name, request ID or topic can appear.
    @Test func auditLinesAreAClosedVocabulary() throws {
        let harness = IntakeHarness()
        harness.secrets = ["napcat-TESTONLYz9y8x7w6v5"]
        for (row, request) in zip(Self.keptLocal, IntakeHarness.requestIDs(Self.keptLocal.count)) {
            harness.receive(request, tool: row.tool, preview: row.preview)
        }
        let id = try #require(harness.forward("zzzzz"))
        harness.intake.decide(IntakeHarness.decision(id))
        harness.intake.decide(IntakeHarness.decision(id))
        harness.intake.receive(Array("garbage".utf8), from: 3)
        #expect(harness.codes.count == Self.keptLocal.count + 4)
        for code in harness.codes {
            var words = Substring(code)
            if words.hasPrefix("prompt=") {
                let hex = words.dropFirst("prompt=".count).prefix(ApprovalWire.promptIDHexDigits)
                #expect(PromptID(hex: String(hex)) != nil, "\(code)")
                words = words.dropFirst("prompt=".count + ApprovalWire.promptIDHexDigits + 1)
            }
            #expect(Self.vocabulary.contains(String(words)), "'\(code)' is outside the audit vocabulary")
        }
        #expect(Self.vocabulary.count == 17 + 3 + 4 + 7 + 2 + 7, "vacuity: the whole vocabulary")
    }
}
