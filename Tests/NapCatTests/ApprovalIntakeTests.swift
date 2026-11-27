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
    /// How many times the intake read the secrets: once for each prompt the
    /// gate classifies.
    var secretReads = 0

    lazy var intake = ApprovalIntake(
        armed: { [unowned self] in armed }, secrets: { [unowned self] in
            secretReads += 1
            return secrets
        },
        newPromptID: { [unowned self] in nextIDs.isEmpty ? nil : nextIDs.removeFirst() },
        now: { [unowned self] in now }, records: sink,
        sendFrame: { [unowned self] in frames.append(($0, $1)) },
        closeConnection: { [unowned self] in closed.append($0) },
        audit: { [unowned self] in audits.append($0) })

    static func id(_ n: UInt64) -> PromptID { PromptID(high: 0xA0, low: n)! }

    /// The session's client as an honest server names it: the confirmed one.
    static let client: ChannelClient = ApprovalChannel.confirmedClients[0]

    static func prompt(_ request: String, tool: String = "Bash", preview: String = #"{"command":"git status"}"#) -> [UInt8] {
        Array(ApprovalChannel.promptFrame(ChannelPermissionRequest(requestID: ChannelRequestID(request)!, toolName: tool,
                                                                   inputPreview: preview), client: client)!.utf8)
    }

    func receive(_ request: String, tool: String = "Bash", preview: String = #"{"command":"git status"}"#, from connection: Int = 1) {
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

    /// A decision as the verifier hands it to the intake (S-PAIR-C2), so the
    /// lifecycle's own checks can be driven directly.
    static func decision(_ id: PromptID, _ verdict: ApprovalWire.Verdict = .allow, signed: Bool = true,
                         wireVersion: Int = ApprovalWire.wireVersion) -> DecisionVerification {
        .verified(ApprovalDecision(promptID: id, verdict: verdict, wireVersion: wireVersion, signatureVerified: signed))
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
        // No Read leaves, whatever its path (#231).
        GateRow(tool: "Read", preview: #"{"file_path":"/Users/someone/project/notes.md"}"#, code: "localOnly.read"),
        GateRow(tool: "Read", preview: #"{"file_path":"/Users/someone/.sometool/auth.json"}"#, code: "localOnly.read"),
        GateRow(tool: "Read", preview: #"{"file_path":"/Users/someone/project/doc.pdf","offset":1,"limit":200,"pages":"1-3"}"#,
                code: "localOnly.read"),
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
        // A double quote in a path (#159), and a forbidden one: its family.
        GateRow(tool: "Read", preview: #"{"file_path":"/Users/someone/project/a\",\"limit\":1"}"#,
                code: "unclassifiable.pathNotCanonical"),
        GateRow(tool: "Read", preview: #"{"file_path":"/Users/someone/.ssh/id\"rsa"}"#, code: "forbidden.secretAccess"),
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
        let preview = #"{"command":"git status","description":"echo "# + topic + #""}"#
        harness.receive("abcde", preview: preview)
        #expect(harness.sink.saved.isEmpty)
        #expect(harness.codes == ["prompt=\(IntakeHarness.id(1).hex) suppressed.gate.forbidden.secretAccess"])
        harness.secrets = []
        harness.receive("bcdef", preview: preview)
        #expect(harness.sink.saved.count == 1, "baseline: without the secret the same prompt forwards")
    }

    /// Armed, no Read is saved, whatever its path (#231): each is logged
    /// with the gate's `localOnly.read`, none counts for a waiting push, and
    /// a decision for one answers nothing. A listed command after them is
    /// saved, so the harness forwards what it may.
    @Test func armedNoReadPromptIsSavedOrCounted() {
        let harness = IntakeHarness()
        #expect(harness.armed, "the harness is armed")
        let paths = ["/Users/someone/project/notes.md", "/Users/someone/.sometool-token", "/tmp/a.txt",
                     "/Volumes/External/report.pdf", "/Users/someone/other-project/README"]
        for (path, request) in zip(paths, IntakeHarness.requestIDs(paths.count)) {
            harness.receive(request, tool: "Read", preview: #"{"file_path":"# + ApprovalClassificationTests.quote(path) + "}")
        }
        #expect(harness.sink.saved.isEmpty)
        #expect(harness.codes == (1...paths.count).map { "prompt=\(IntakeHarness.id(UInt64($0)).hex) suppressed.gate.localOnly.read" })
        #expect(harness.intake.recentForwardableTools(within: ApprovalIntake.waitingContextSeconds).isEmpty)
        harness.intake.decide(IntakeHarness.decision(IntakeHarness.id(1)))
        #expect(harness.frames.isEmpty)
        #expect(harness.codes.last == "prompt=\(IntakeHarness.id(1).hex) ignored.notForwarded")
        harness.receive("zzzzz")
        #expect(harness.sink.saved.map(\.tool) == [.bash], "control: a listed command after them is saved")
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
        #"{"frame":"prompt","v":2,"request":"abcde","tool":"Bash","preview":"{}","description":"x","server":2,"client":"claude-code","clientVersion":"2.1.326"}"#,
        #"{"frame":"prompt","v":2,"request":"abcde","tool":"Bash","preview":"{}"}"#,
        #"{"frame":"prompt","v":2,"request":"abcdl","tool":"Bash","preview":"{}","server":2,"client":"claude-code","clientVersion":"2.1.326"}"#,
        // A version-1 frame, as the server wrote one before #150.
        #"{"frame":"prompt","v":1,"request":"abcde","tool":"Bash","preview":"{\"command\":\"git status\"}"}"#,
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
        #expect(harness.secretReads == 0 && harness.nextIDs.count == 600, "nothing was classified or drawn")
    }

    // MARK: - The server and its client, checked again (#150)

    /// A prompt frame the gate would forward, as a server of `server`'s
    /// version would write it for this client: every member but the three
    /// the relay's own frame spells (`IntakeHarness.prompt`).
    struct OriginRow: Sendable, CustomTestStringConvertible {
        let server: String
        let client: String
        let version: String
        let code: String
        var testDescription: String { "server \(server), client '\(client)' '\(version)': \(code)" }

        var frame: String {
            let honest: String = String(decoding: IntakeHarness.prompt("abcde"), as: UTF8.self)
            let head: String = honest.components(separatedBy: #","server":"#)[0]
            let origin: String = #","server":"# + server + #","client":"# + ApprovalChannel.quoted(client)
                + #","clientVersion":"# + ApprovalChannel.quoted(version)
            return head + origin + "}"
        }
    }

    static let server: String = "seam.serverVersionRefused"
    static let client: String = "seam.clientRefused"
    /// NapCat's own server version, the one before it and the one after.
    static let own: String = String(ApprovalChannel.serverVersion)
    static let before: String = String(ApprovalChannel.serverVersion - 1)
    static let after: String = String(ApprovalChannel.serverVersion + 1)
    /// Another server version (one before, one after, none and negatives);
    /// then a client other than the confirmed build, byte for byte; a frame
    /// wrong in both is refused for its server first.
    static let otherOrigins: [OriginRow] = [
        OriginRow(server: before, client: "claude-code", version: "2.1.326", code: server),
        OriginRow(server: after, client: "claude-code", version: "2.1.326", code: server),
        OriginRow(server: "0", client: "claude-code", version: "2.1.326", code: server),
        OriginRow(server: "-2", client: "claude-code", version: "2.1.326", code: server),
        OriginRow(server: "20", client: "claude-code", version: "2.1.326", code: server),
        OriginRow(server: own, client: "claude-code", version: "2.1.327", code: client),
        OriginRow(server: own, client: "claude-code", version: "2.1.325", code: client),
        OriginRow(server: own, client: "claude-code", version: "2.1.3260", code: client),
        OriginRow(server: own, client: "claude-code", version: "2.1.32", code: client),
        OriginRow(server: own, client: "claude-code", version: "v2.1.326", code: client),
        OriginRow(server: own, client: "claude-code", version: "2.1.326 ", code: client),
        OriginRow(server: own, client: "claude-code", version: "2.1.326\n", code: client),
        OriginRow(server: own, client: "claude-code", version: "\u{FF12}.1.326", code: client),
        OriginRow(server: own, client: "claude-code", version: "", code: client),
        OriginRow(server: own, client: "Claude-Code", version: "2.1.326", code: client),
        OriginRow(server: own, client: "claude", version: "2.1.326", code: client),
        OriginRow(server: own, client: "claude-code ", version: "2.1.326", code: client),
        OriginRow(server: own, client: "other-client", version: "2.1.326", code: client),
        OriginRow(server: own, client: "", version: "", code: client),
        OriginRow(server: own, client: "2.1.326", version: "claude-code", code: client),
        OriginRow(server: before, client: "other-client", version: "9.9.9", code: server),
    ]

    /// The frame the relay writes for a confirmed client is exactly what the
    /// rows rewrite, and with its own values it opens a lifecycle.
    @Test func theRowsRewriteOnlyTheRelaysOrigin() throws {
        let confirmed = IntakeHarness.client
        let honest = OriginRow(server: String(ApprovalChannel.serverVersion), client: confirmed.name, version: confirmed.version,
                               code: "")
        #expect(honest.frame == String(decoding: IntakeHarness.prompt("abcde"), as: UTF8.self))
        let harness = IntakeHarness()
        harness.intake.receive(Array(honest.frame.utf8), from: 7)
        #expect(harness.sink.saved.count == 1 && harness.closed.isEmpty && harness.secretReads == 1)
    }

    /// A frame from a server of another version, or for a client NapCat has
    /// not confirmed, is refused BEFORE the gate: its closed code, the
    /// connection closed, the secrets never read, no prompt ID drawn, no
    /// lifecycle, nothing saved and nothing answered, though the gate would
    /// forward the prompt and the intake is armed.
    @Test(arguments: otherOrigins)
    func aFrameFromAnotherServerOrClientIsRefusedBeforeTheGate(_ row: OriginRow) {
        let harness = IntakeHarness()
        harness.intake.receive(Array(row.frame.utf8), from: 7)
        #expect(harness.codes == [row.code])
        #expect(harness.closed == [7])
        #expect(harness.secretReads == 0, "refused before the gate: the secrets it looks for were never read")
        #expect(harness.nextIDs.count == 600, "no prompt ID was drawn")
        #expect(harness.intake.prompts.isEmpty && harness.sink.saved.isEmpty && harness.frames.isEmpty)
    }

    /// The refusal is the frame's, not the connection's: one server's skewed
    /// frame leaves another server's prompt open, and the intake keeps
    /// reading that server's frames.
    @Test func aRefusedOriginLeavesOtherServersAlone() throws {
        let harness = IntakeHarness()
        let other = try #require(harness.forward("abcde", from: 2))
        harness.intake.receive(Array(Self.otherOrigins[0].frame.utf8), from: 7)
        #expect(harness.closed == [7])
        #expect(harness.intake.prompts[other]?.lifecycle.phase == .forwarded)
        #expect(harness.forward("bcdef", from: 2) != nil)
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
        let suppressions = ForbiddenFamily.allCases.map { ApprovalSuppression.forbidden($0) }
            + [.localOnlyMCP, .localOnlyFileEdit, .localOnlyRead] + Unclassifiable.allCases.map { ApprovalSuppression.unclassifiable($0) }
        let audits: [ApprovalAudit] = suppressions.map { .suppressed(.gate($0)) } + [.suppressed(.notArmed), .forwarded, .forwardFailed]
            + ApprovalWire.Verdict.allCases.map { .decided(.remote($0)) } + [.decided(.local), .expired]
            + ApprovalIgnoreReason.allCases.map { .ignored($0) } + ApprovalRetraction.allCases.map { .retracted($0) }
        let seam: [ApprovalAuditEvent] = [.frameRefused, .serverVersionRefused, .clientRefused, .duplicateRequest, .capacityReached,
                                          .connectionPromptLimit, .promptIDUnavailable, .unknownPrompt, .peerRefused]
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
        harness.intake.receive(Array(Self.otherOrigins[0].frame.utf8), from: 4)
        harness.intake.receive(Array(Self.otherOrigins[5].frame.utf8), from: 5)
        #expect(harness.codes.count == Self.keptLocal.count + 6)
        #expect(harness.codes.suffix(2) == [Self.server, Self.client])
        for code in harness.codes {
            var words = Substring(code)
            if words.hasPrefix("prompt=") {
                let hex = words.dropFirst("prompt=".count).prefix(ApprovalWire.promptIDHexDigits)
                #expect(PromptID(hex: String(hex)) != nil, "\(code)")
                words = words.dropFirst("prompt=".count + ApprovalWire.promptIDHexDigits + 1)
            }
            #expect(Self.vocabulary.contains(String(words)), "'\(code)' is outside the audit vocabulary")
        }
        #expect(Self.vocabulary.count == 19 + 3 + 4 + 7 + 2 + 9, "vacuity: the whole vocabulary")
    }

    // MARK: - What a waiting alert reads (#216)

    /// Where one relayed prompt stands when a waiting alert reads it. The
    /// test sets the record path's finding (the phone's prompt subscription
    /// found) on every one but `notFound`, so only its lifecycle tells them
    /// apart.
    enum PushCase: String, CaseIterable, Sendable {
        case covered, notFound, savePending, saveFailed, keptByTheGate, notArmed, answered, sessionEnded, killSwitch, expired
    }

    /// Evidence is the record accepted AND the subscription found, both: the
    /// finding alone never counts, on a prompt the gate keeps, one not armed,
    /// a save still in flight or one that failed, or one answered, withdrawn
    /// or expired since. Every relayed prompt still in the window is new to
    /// the first read, whatever became of it.
    @Test(arguments: PushCase.allCases)
    func evidenceIsAnAcceptedRecordWithItsSubscriptionFound(_ state: PushCase) {
        let harness = IntakeHarness()
        harness.armed = state != .notArmed
        let kept = #"{"command":"sudo pmset -a disablesleep 1"}"#
        harness.receive("abcde", preview: state == .keptByTheGate ? kept : #"{"command":"git status"}"#)
        let id = IntakeHarness.id(1)
        switch state {
        case .covered, .notFound, .answered, .sessionEnded, .killSwitch, .expired: harness.intake.apply(.saveAccepted, to: id)
        case .saveFailed: harness.intake.apply(.saveFailed, to: id)
        case .savePending, .keptByTheGate, .notArmed: break
        }
        if state != .notFound { harness.intake.noteSubscriptionFound(id) }
        switch state {
        case .answered: harness.intake.decide(IntakeHarness.decision(id))
        case .sessionEnded: harness.intake.connectionClosed(1)
        case .killSwitch: harness.intake.killSwitch()
        case .expired:
            harness.now += ApprovalWire.promptTimeToLiveSeconds
            harness.intake.apply(.tick, to: id)
        case .covered, .notFound, .savePending, .saveFailed, .keptByTheGate, .notArmed: break
        }
        let entry = harness.intake.prompts[id]
        #expect(entry?.subscriptionFound == (state != .notFound), "vacuity: the finding is set as the case says")
        let evident: Bool = state == .covered
        #expect(entry?.hasPushEvidence == evident)
        let read = harness.intake.waitingPromptRead(after: nil, within: ApprovalIntake.waitingContextSeconds)
        let inWindow: Bool = state != .expired
        #expect(read.newPrompts == (inWindow ? 1 : 0))
        #expect(read.newPromptsWithEvidence == (evident ? 1 : 0))
        #expect(read.recentWithEvidence == (evident ? [.bash] : []))
        let counted: Bool = inWindow && state != .keptByTheGate && state != .sessionEnded
        #expect(read.recent == (counted ? [.bash] : []), "the counts are the gate's, whatever the evidence")
    }

    /// A read's mark: a prompt is new to the first read after it opened and
    /// to no later one, and one that opens after a read is new to the next.
    /// One that opens in a read's own second, after it, is new to the next
    /// read too (here one in that same second), and to none after it. The
    /// counts do not depend on the mark, and a read changes nothing the
    /// intake holds.
    @Test func eachPromptIsNewToOneReadAtMost() {
        let harness = IntakeHarness()
        let within = ApprovalIntake.waitingContextSeconds
        harness.receive("abcde")
        harness.receive("bcdef", preview: #"{"command":"sudo pmset -a disablesleep 1"}"#)
        harness.receive("cdefg", tool: "Read", preview: #"{"file_path":"/Users/someone/project/notes.md"}"#)
        harness.receive("defgh", tool: "mcp__webhook__reply", preview: #"{"text":"hi"}"#)
        let held = harness.intake.prompts
        let first = harness.intake.waitingPromptRead(after: nil, within: within)
        #expect(first.newPrompts == 4, "whatever the gate made of them")
        #expect(first.recent == [.bash], "only the listed command is counted")
        #expect(harness.intake.prompts == held, "a read changes nothing the intake holds")
        let again = harness.intake.waitingPromptRead(after: first.mark, within: within)
        #expect(again.newPrompts == 0, "none is new twice")
        #expect(again.recent == [.bash], "the counts do not depend on the mark")
        harness.receive("efghi")
        let sameSecond = harness.intake.waitingPromptRead(after: again.mark, within: within)
        #expect(sameSecond.newPrompts == 1, "opened in the read's own second, after it: new to the next read")
        harness.now += 1
        harness.receive("fghij")
        let next = harness.intake.waitingPromptRead(after: sameSecond.mark, within: within)
        #expect(next.newPrompts == 1)
        #expect(harness.intake.waitingPromptRead(after: next.mark, within: within).newPrompts == 0)
        #expect(harness.intake.waitingPromptRead(after: nil, within: within).newPrompts == 6, "with no mark, every prompt in the window")
    }

    /// A prompt relayed later in a read's own second is new to the next read,
    /// in the next second, and to none after it, and never counted as having
    /// evidence, whatever it has: the mark holds that second and how many of
    /// its prompts the read saw, not which. So beside a covered prompt the
    /// read already saw, a kept one adds no evidence, and a covered one of
    /// its own is new without it.
    @Test func aPromptLaterInAReadsOwnSecondIsNewToTheNextReadWithoutEvidence() throws {
        let harness = IntakeHarness()
        let within = ApprovalIntake.waitingContextSeconds
        let seen = try #require(harness.forward("abcde"))
        harness.intake.noteSubscriptionFound(seen)
        let first = harness.intake.waitingPromptRead(after: nil, within: within)
        #expect(first.newPrompts == 1 && first.newPromptsWithEvidence == 1, "vacuity: the read saw the covered prompt")
        harness.receive("bcdef", preview: #"{"command":"sudo pmset -a disablesleep 1"}"#, from: 2)
        harness.now += 1
        let next = harness.intake.waitingPromptRead(after: first.mark, within: within)
        #expect(next.newPrompts == 1, "the kept prompt, relayed in the first read's second after it, is new to the next read")
        #expect(next.newPromptsWithEvidence == 0, "and adds no evidence: the covered one the first read saw is not new again")
        let third = harness.intake.waitingPromptRead(after: next.mark, within: within)
        #expect(third.newPrompts == 0, "new to one read at most")
        let own = try #require(harness.forward("cdefg"))
        harness.intake.noteSubscriptionFound(own)
        #expect(harness.intake.prompts[own]?.hasPushEvidence == true, "vacuity: this one has evidence")
        harness.now += 1
        let fourth = harness.intake.waitingPromptRead(after: third.mark, within: within)
        #expect(fourth.newPrompts == 1 && fourth.newPromptsWithEvidence == 0,
                "relayed in the third read's second after it: new, never counted as having evidence")
        #expect(fourth.recentWithEvidence == [.bash, .bash], "the counts' evidence is read as before")
    }

    /// A prompt relayed later in a read's own second is new to the next read
    /// only within `newPromptSeconds`, like any other: a next read 11 seconds
    /// later finds it new no more, though it is still held and counted.
    @Test func aPromptLaterInAReadsOwnSecondAgesOutOfTheWindow() {
        let harness = IntakeHarness()
        let within = ApprovalIntake.waitingContextSeconds
        let first = harness.intake.waitingPromptRead(after: nil, within: within)
        #expect(first.newPrompts == 0, "vacuity: the read sees no prompt")
        harness.receive("abcde")
        harness.now += ApprovalIntake.newPromptSeconds
        #expect(harness.intake.waitingPromptRead(after: first.mark, within: within).newPrompts == 1,
                "vacuity: a next read 10 seconds later finds it new")
        harness.now += 1
        let next = harness.intake.waitingPromptRead(after: first.mark, within: within)
        #expect(next.newPrompts == 0, "11 seconds later it is past the window")
        #expect(next.recent == [.bash], "vacuity: still held and counted; only the 10-second window drops it")
    }

    /// New prompts are those of the last `newPromptSeconds` (exactly that
    /// still counts). The counts and their evidence share the window the
    /// read is handed: a prompt's evidence covers it for as long as it is
    /// counted, and evidence outside the window takes nothing from a prompt
    /// inside it.
    @Test func newPromptsAndEvidenceKeepTheirWindows() throws {
        let harness = IntakeHarness()
        let within = ApprovalIntake.waitingContextSeconds
        let covered = try #require(harness.forward("abcde"))
        harness.intake.noteSubscriptionFound(covered)
        harness.now += ApprovalIntake.newPromptSeconds
        let edge = harness.intake.waitingPromptRead(after: nil, within: within)
        #expect(edge.newPrompts == 1 && edge.newPromptsWithEvidence == 1, "exactly the window still counts")
        harness.now += 1
        let past = harness.intake.waitingPromptRead(after: nil, within: within)
        #expect(past.newPrompts == 0 && past.newPromptsWithEvidence == 0, "older than the window: no new prompt")
        #expect(past.recent == [.bash] && past.recentWithEvidence == [.bash], "its evidence covers it while it is counted")
        harness.now = 1_000 + within - 5
        #expect(harness.forward("bcdef") != nil, "a second prompt, accepted, its subscription not found")
        harness.now = 1_000 + within + 1
        let later = harness.intake.waitingPromptRead(after: nil, within: within)
        #expect(later.recent == [.bash], "only the second is counted now")
        #expect(later.recentWithEvidence.isEmpty, "the first's evidence is outside the window and takes nothing from the second")
        #expect(later.newPrompts == 1 && later.newPromptsWithEvidence == 0)
    }

    /// The new-prompt window by value, which the tests above read by name: 10
    /// seconds, and its line in the intake as written, once.
    @Test func theNewPromptWindowIsTenSeconds() throws {
        #expect(ApprovalIntake.newPromptSeconds == 10)
        let constant: String = "    static let newPromptSeconds = 10\n"
        let intake: String = DecisionSinkStructureTests.text(ApprovalChannelStructureTests.intakeFile,
                                                             in: try DecisionSinkStructureTests.uncutSources())
        #expect(ApprovalChannelStructureTests.count(constant, in: intake) == 1, "the constant's line, once")
    }

    /// What crosses from the seam to the alert lane, by shape: tool kinds,
    /// counts and the mark, which holds two Ints (the intake's clock and how
    /// many prompts of that second the read saw), never a prompt ID, preview
    /// or session; and the lane's context, counts only. A new field fails
    /// this until it is read here.
    @Test func whatCrossesIsKindsCountsAndAMark() {
        let harness = IntakeHarness()
        harness.receive("abcde")
        let read = harness.intake.waitingPromptRead(after: nil, within: ApprovalIntake.waitingContextSeconds)
        let fields: [(label: String, type: String)] = Mirror(reflecting: read).children.map { ($0.label ?? "", "\(type(of: $0.value))") }
        #expect(fields.map(\.label) == ["recent", "recentWithEvidence", "newPrompts", "newPromptsWithEvidence", "mark"])
        #expect(fields.map(\.type) == ["Array<ApprovalTool>", "Array<ApprovalTool>", "Int", "Int", "PromptRelayMark"])
        #expect(Mirror(reflecting: read.mark).children.map { "\(type(of: $0.value))" } == ["Int", "Int"], "the mark is two Ints")
        #expect(Mirror(reflecting: WaitingPromptContext.none).children.map { "\(type(of: $0.value))" }
                == ["WaitingPromptCounts", "WaitingPromptCounts", "Int", "Int"])
    }

    /// The record path's finding is a flag and nothing else: no audit line,
    /// no effect, no lifecycle change; for a prompt not held it does nothing.
    @Test func theFindingChangesNothingButTheEvidence() throws {
        let harness = IntakeHarness()
        let id = try #require(harness.forward("abcde"))
        let codes = harness.codes, saved = harness.sink.saved, superseded = harness.sink.superseded
        let before = try #require(harness.intake.prompts[id])
        harness.intake.noteSubscriptionFound(id)
        harness.intake.noteSubscriptionFound(IntakeHarness.id(99))
        let after = try #require(harness.intake.prompts[id])
        #expect(!before.subscriptionFound && after.subscriptionFound)
        #expect(after.lifecycle == before.lifecycle && after.forwardable == before.forwardable)
        #expect(harness.codes == codes && harness.sink.saved == saved && harness.sink.superseded == superseded)
        #expect(harness.frames.isEmpty && harness.sink.retracted.isEmpty && harness.intake.prompts.count == 1)
    }
}
