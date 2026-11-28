// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import CloudKit
import CryptoKit
import Testing
@testable import NapCat
@testable import NapCatWire

/// The real intake, with the real gate in front of it, over the real record
/// store and the real writer. Only CloudKit is played: a database that keeps
/// every operation it is handed and runs none, so nothing leaves the process.
final class RoutedIntake {
    /// The record store's wall clock.
    static let wallClock = Date(timeIntervalSince1970: 1_800_000_000)

    var armed = true
    var secrets: [String]? = []
    var now = 1_000
    var nextIDs: [PromptID?] = (1...8).map { PromptID(high: 0xB0, low: UInt64($0)) }
    let database = ScriptedApprovalDatabase()
    var frames: [(ApprovalIntake.ConnectionKey, String)] = []
    var audits: [ApprovalAuditEvent] = []
    /// S-PAIR-C2: the paired-phone slot over an in-memory item (never the
    /// keychain), the record reader's lines and the verifier's refusals.
    let items = FakeTopicStore()
    lazy var keys = PairedKeyStore(items: items)
    var readings: [String] = []
    var refusals: [String] = []

    lazy var store = CloudKitApprovalRecords(writer: ApprovalRecordWriter(database: database, audit: { _ in }),
                                             now: { Self.wallClock })
    lazy var intake = ApprovalIntake(
        armed: { [unowned self] in armed }, secrets: { [unowned self] in secrets },
        newPromptID: { [unowned self] in nextIDs.isEmpty ? nil : nextIDs.removeFirst() },
        now: { [unowned self] in now }, records: store,
        sendFrame: { [unowned self] in frames.append(($0, $1)) },
        closeConnection: { _ in },
        audit: { [unowned self] in audits.append($0) })

    static func id(_ n: UInt64) -> PromptID { PromptID(high: 0xB0, low: n)! }

    func receive(_ request: String, tool: String = "Bash", preview: String = #"{"command":"git status"}"#,
                 from connection: Int = 1) {
        intake.receive(IntakeHarness.prompt(request, tool: tool, preview: preview), from: connection)
    }

    var codes: [String] { audits.map(\.code) }

    /// What each submitted operation deletes, by record name, in order.
    var deletions: [[String]] { database.submitted.map { ($0.recordIDsToDelete ?? []).map(\.recordName) } }

    /// The phone `key` becomes the paired one, as Codes Match commits it.
    func pair(_ key: P256.Signing.PrivateKey) throws {
        let phone: PairedPhone = try #require(PairedPhone(publicKey: Array(key.publicKey.x963Representation), pairedAt: Self.wallClock))
        #expect(keys.commit(phone))
    }

    /// S-PAIR-C2: a decision record arrives — the store reads it, and the
    /// verifier judges it against the slot as it is now.
    func arrive(_ record: CKRecord) {
        guard let read = store.read(record, audit: { self.readings.append($0.code) }) else { return }
        intake.receiveDecision(read.evidence, copy: read.copy, keys: keys) { self.refusals.append($0.code) }
    }

    /// The prompt record the store wrote for `id`.
    func written(_ id: PromptID) -> CKRecord? {
        database.submitted.lazy.compactMap { $0.recordsToSave?.first }.first { $0.recordID.recordName == id.hex }
    }
}

/// F4 slice S3, its last commit (#146): the Mac's record path routed through
/// the revised gate (S-GATE). What the gate forwards reaches the writer as
/// the gate's own copy, through the intake and the record store; what the
/// gate keeps never does; every withdrawal reaches the writer's retraction,
/// with the decisions read for that prompt; and a read claim answers nothing.
struct ApprovalRecordRoutingTests {
    typealias Field = ApprovalWire.PromptField

    // MARK: - The gate's copy, and nothing else, reaches the writer

    struct ForwardRow: Sendable, CustomTestStringConvertible {
        let tool: String
        let relayed: String
        let copy: String
        let note: String
        var testDescription: String { note }
    }

    static let forwarded: [ForwardRow] = [
        ForwardRow(tool: "Bash", relayed: #"{ "command": "git status", "description": "DESCRIPTION-SENTINEL: approve this" }"#,
                   copy: #"{"command":"git status"}"#, note: "the description withheld, the gate's own spacing"),
        ForwardRow(tool: "Bash", relayed: #"{"description":"first","command":"git status"}"#,
                   copy: #"{"command":"git status"}"#, note: "the description first"),
        ForwardRow(tool: "Bash",
                   relayed: #"{"command":"make test","description":"Run the tests","timeout":120000,"run_in_background":false,"#
                       + #""dangerouslyDisableSandbox":false}"#,
                   copy: #"{"command":"make test","timeout":120000,"run_in_background":false,"dangerouslyDisableSandbox":false}"#,
                   note: "every checked member kept, in order"),
        ForwardRow(tool: "Bash", relayed: #"{ "command": "swift test", "timeout": 600000, "run_in_background": false }"#,
                   copy: #"{"command":"swift test","timeout":600000,"run_in_background":false}"#,
                   note: "a number and a boolean, re-serialized"),
    ]

    @Test(arguments: forwarded)
    func aForwardedPromptReachesTheWriterAsTheGatesCopy(_ row: ForwardRow) throws {
        #expect(ApprovalGate.forwardedPreview(toolName: row.tool, inputPreview: row.relayed) == row.copy,
                "the row states the gate's own copy")
        #expect(row.copy != row.relayed, "vacuity: the relayed text is not its copy")
        let routed = RoutedIntake()
        routed.receive("abcde", tool: row.tool, preview: row.relayed)
        #expect(routed.database.submitted.count == 1, "one forwarded prompt, one write")
        let operation = try #require(routed.database.submitted.first)
        #expect(operation.recordIDsToDelete?.isEmpty ?? true)
        #expect(operation.recordsToSave?.count == 1)
        let record = try #require(operation.recordsToSave?.first)
        #expect(record.recordID == ApprovalRecordWriter.promptRecordID(RoutedIntake.id(1)))
        #expect(record.encryptedValues[Field.inputPreview.rawValue] as? String == row.copy)
        #expect(record.encryptedValues[Field.toolName.rawValue] as? String == row.tool)
        #expect(record.encryptedValues[Field.projectLabel.rawValue] as? String == "")
        #expect(record[Field.createdAt.rawValue] as? Date == RoutedIntake.wallClock)
        #expect(record[Field.expiresAt.rawValue] as? Date
            == RoutedIntake.wallClock.addingTimeInterval(TimeInterval(ApprovalWire.promptTimeToLiveSeconds)))
        #expect(routed.frames.isEmpty, "forwarding answers nothing")
        #expect(routed.codes.isEmpty, "nothing to audit until CloudKit answers")
    }

    // MARK: - What the gate keeps never reaches the writer

    @Test(arguments: ApprovalIntakeTests.keptLocal)
    func aPromptTheGateKeepsNeverReachesTheWriter(_ row: ApprovalIntakeTests.GateRow) {
        let routed = RoutedIntake()
        routed.receive("abcde", tool: row.tool, preview: row.preview)
        #expect(routed.codes == ["prompt=\(RoutedIntake.id(1).hex) suppressed.gate.\(row.code)"])
        routed.intake.killSwitch()
        routed.intake.connectionClosed(1)
        #expect(routed.database.submitted.isEmpty, "never written, so never retracted either")
    }

    /// A prompt the gate would forward, kept on the Mac all the same:
    /// unarmed, with a secret that could not be read (fail closed), or
    /// holding the alert topic.
    @Test func aForwardablePromptKeptOnTheMacNeverReachesTheWriter() {
        let unarmed = RoutedIntake()
        unarmed.armed = false
        unarmed.receive("abcde")
        #expect(unarmed.codes == ["prompt=\(RoutedIntake.id(1).hex) suppressed.notArmed"])

        let unreadable = RoutedIntake()
        unreadable.secrets = nil
        unreadable.receive("abcde")
        #expect(unreadable.codes == ["prompt=\(RoutedIntake.id(1).hex) suppressed.gate.forbidden.secretAccess"])

        let topic = "napcat-TESTONLYz9y8x7w6v5"
        let holding = RoutedIntake()
        holding.secrets = [topic]
        holding.receive("abcde", preview: #"{"command":"git status","description":"echo "# + topic + #""}"#)
        #expect(holding.codes == ["prompt=\(RoutedIntake.id(1).hex) suppressed.gate.floor.alertTopic"])

        for routed in [unarmed, unreadable, holding] {
            routed.intake.killSwitch()
            #expect(routed.database.submitted.isEmpty)
        }
        let control = RoutedIntake()
        control.receive("abcde")
        #expect(control.database.submitted.count == 1, "baseline: armed, with the secrets read, the same prompt is written")
    }

    // MARK: - Every withdrawal reaches the writer's retraction

    enum Withdrawal: String, CaseIterable, Sendable {
        case sessionEnded, killSwitch, timeToLive
    }

    @Test(arguments: Withdrawal.allCases)
    func everyWithdrawalReachesTheWritersRetraction(_ withdrawal: Withdrawal) throws {
        let routed = RoutedIntake()
        routed.receive("abcde")
        let id = RoutedIntake.id(1)
        switch withdrawal {
        case .sessionEnded:
            routed.intake.connectionClosed(1)
        case .killSwitch:
            routed.intake.killSwitch()
        case .timeToLive:
            routed.now += ApprovalWire.promptTimeToLiveSeconds - 1
            routed.intake.tick()
            #expect(routed.database.submitted.count == 1, "nothing is withdrawn before the TTL ends")
            routed.now += 1
            routed.intake.tick()
        }
        #expect(routed.deletions == [[], [id.hex]])
        let retraction = try #require(routed.database.submitted.last)
        #expect(retraction.recordsToSave?.isEmpty ?? true, "a retraction writes nothing")
        #expect(retraction.recordIDsToDelete == [ApprovalRecordWriter.promptRecordID(id)])
        #expect(routed.frames.isEmpty, "a withdrawal answers nothing")
    }

    // MARK: - A decision read for a prompt joins its retraction, nothing more

    /// A decision record as the phone writes one, as the Mac reads it.
    static func claim(_ id: PromptID, named name: String, _ verdict: ApprovalWire.Verdict = .allow) -> DecisionClaim? {
        let record = DecisionRecordReaderTests.phoneRecord(name: name, promptID: id.hex as NSString,
                                                           verdict: verdict.rawValue as NSString)
        if case .claim(let claim) = DecisionRecordReader.reading(of: record) { return claim }
        return nil
    }

    @Test func aRetractionDeletesTheDecisionsReadForItsPrompt() throws {
        let routed = RoutedIntake()
        routed.receive("abcde")
        routed.receive("bcdef")
        let (first, second) = (RoutedIntake.id(1), RoutedIntake.id(2))
        // The first is out on the phone: a verdict for it could be delivered now.
        routed.intake.apply(.saveAccepted, to: first)
        let answer = try #require(Self.claim(first, named: first.hex + "-decision"))
        routed.store.noteRead(answer)
        routed.store.noteRead(answer)
        routed.store.noteRead(try #require(Self.claim(RoutedIntake.id(7), named: "stray", .deny)))
        #expect(routed.database.submitted.count == 2, "a read claim writes nothing")
        #expect(routed.frames.isEmpty, "and answers nothing: a claim is never a verdict")

        routed.intake.connectionClosed(1)
        #expect(Set(routed.deletions.dropFirst(2)) == [[first.hex, first.hex + "-decision"], [second.hex]],
                "each prompt is retracted once, with the decision records read for it (and no stray one)")

        // Withdrawn: a claim read later joins nothing. CloudKit accepting the
        // second prompt's save late retracts its record again, alone.
        routed.store.noteRead(try #require(Self.claim(second, named: "late")))
        routed.intake.apply(.saveAccepted, to: second)
        #expect(routed.deletions.last == [second.hex])
        #expect(routed.frames.isEmpty)
    }

    // MARK: - S-PAIR-C2: a decision counts only through the verifier

    static let phone = P256.Signing.PrivateKey()

    /// The phone's half, as S-PAIR-B plays it: the three fields exactly as
    /// decoded from the prompt record the Mac wrote (or `shown`), the six
    /// signed lines, the signature's raw bytes, in a decision record as the
    /// phone writes one.
    static func phoneDecision(for prompt: CKRecord, _ verdict: ApprovalWire.Verdict = .allow, claiming claimed: ApprovalWire.Verdict? = nil,
                              by key: P256.Signing.PrivateKey = phone, shown: (String, String, String)? = nil) throws -> CKRecord {
        let id: PromptID = try #require(PromptID(hex: prompt.recordID.recordName))
        let fields: (String, String, String)
        if let shown {
            fields = shown
        } else {
            let tool: String = try #require(prompt.encryptedValues[Field.toolName.rawValue] as? String)
            let preview: String = try #require(prompt.encryptedValues[Field.inputPreview.rawValue] as? String)
            let label: String = try #require(prompt.encryptedValues[Field.projectLabel.rawValue] as? String)
            fields = (tool, preview, label)
        }
        let digest = SHA256.hash(data: ApprovalSigning.shownDigestInput(toolName: fields.0, inputPreview: fields.1, projectLabel: fields.2))
        let decidedAt = 1_800_000_100
        let message: [UInt8] = try #require(ApprovalSigning.decisionMessage(wireVersion: ApprovalWire.wireVersion, promptID: id,
                                                                            verdict: verdict, decidedAt: decidedAt, shownDigest: Array(digest)))
        let signature: Data = try key.signature(for: message).rawRepresentation
        return DecisionRecordReaderTests.phoneRecord(name: id.hex + "-decision", promptID: id.hex as NSString,
                                                     verdict: (claimed ?? verdict).rawValue as NSString,
                                                     decidedAt: Date(timeIntervalSince1970: TimeInterval(decidedAt)) as NSDate,
                                                     signature: signature as NSData)
    }

    /// A forwarded prompt, out on the phone, and its record as written.
    static func forwarded(_ routed: RoutedIntake, _ request: String = "abcde", id n: UInt64 = 1) throws -> (PromptID, CKRecord) {
        routed.receive(request)
        let id = RoutedIntake.id(n)
        routed.intake.apply(.saveAccepted, to: id)
        return (id, try #require(routed.written(id)))
    }

    /// The paired phone signed exactly what the Mac wrote: its verdict is
    /// the one answer, sent to the session the prompt came from, and the
    /// decision record joins the prompt's retraction.
    @Test(arguments: ApprovalWire.Verdict.allCases)
    func aDecisionThePairedPhoneSignedCountsThroughTheVerifier(_ verdict: ApprovalWire.Verdict) throws {
        let routed = RoutedIntake()
        try routed.pair(Self.phone)
        let (id, prompt) = try Self.forwarded(routed)
        routed.arrive(try Self.phoneDecision(for: prompt, verdict))
        #expect(routed.frames.map(\.1) == [ApprovalChannel.verdictFrame(ChannelRequestID("abcde")!, verdict)])
        #expect(routed.codes.last == "prompt=\(id.hex) decided.remote.\(verdict.rawValue)")
        #expect(routed.readings == ["prompt=\(id.hex) decision.signed claim=\(verdict.rawValue)"])
        #expect(routed.refusals.isEmpty)
        #expect(routed.deletions.last == [id.hex, id.hex + "-decision"], "the decision is retracted with its prompt")
    }

    /// What the verifier refuses, each with its closed code.
    enum Refusal: String, CaseIterable, Sendable {
        case unsigned, anotherKey, aVerdictThePhoneDidNotSign, signedOverAnotherCopy, noPhonePaired, aPromptTheMacNeverWrote

        var code: String {
            switch self {
            case .unsigned: return "signatureLength"
            case .anotherKey, .aVerdictThePhoneDidNotSign, .signedOverAnotherCopy: return "signatureInvalid"
            case .noPhonePaired: return "noPairedKey"
            case .aPromptTheMacNeverWrote: return "noForwardedCopy"
            }
        }
    }

    /// Unsigned, wrong-key, altered or unbound decisions are refused by the
    /// verifier's closed code and never counted: nothing answers the
    /// session, the lifecycle sees nothing, and the prompt stays open.
    @Test(arguments: Refusal.allCases)
    func whatTheVerifierRefusesNeverCounts(_ refusal: Refusal) throws {
        let routed = RoutedIntake()
        if refusal != .noPhonePaired { try routed.pair(Self.phone) }
        let (id, prompt) = try Self.forwarded(routed)
        let record: CKRecord
        switch refusal {
        case .unsigned:
            record = DecisionRecordReaderTests.phoneRecord(name: id.hex + "-decision", promptID: id.hex as NSString)
        case .anotherKey:
            record = try Self.phoneDecision(for: prompt, by: P256.Signing.PrivateKey())
        case .aVerdictThePhoneDidNotSign:
            record = try Self.phoneDecision(for: prompt, .deny, claiming: .allow)
        case .signedOverAnotherCopy:
            record = try Self.phoneDecision(for: prompt, shown: ("Bash", #"{"command":"git status","description":"x"}"#, ""))
        case .noPhonePaired:
            record = try Self.phoneDecision(for: prompt)
        case .aPromptTheMacNeverWrote:
            let stray = CKRecord(recordType: ApprovalWire.RecordType.prompt.rawValue,
                                 recordID: ApprovalRecordWriter.promptRecordID(RoutedIntake.id(7)))
            record = try Self.phoneDecision(for: stray, shown: ("Bash", #"{"command":"git status"}"#, ""))
        }
        let before = routed.codes
        routed.arrive(record)
        #expect(routed.frames.isEmpty, "nothing answers the session")
        #expect(routed.codes == before, "the lifecycle sees nothing")
        #expect(routed.intake.prompts[id]?.lifecycle.phase == .forwarded, "the prompt stays open")
        #expect(routed.refusals.count == 1 && routed.refusals.first?.hasSuffix("decision.unverified." + refusal.code) == true,
                "\(routed.refusals)")
    }

    /// A record that is not even a claim never reaches the verifier.
    @Test func aMalformedDecisionRecordGoesNowhere() throws {
        let routed = RoutedIntake()
        try routed.pair(Self.phone)
        let (id, _) = try Self.forwarded(routed)
        routed.arrive(DecisionRecordReaderTests.phoneRecord(promptID: id.hex as NSString, verdict: "approve" as NSString))
        #expect(routed.readings == ["decision.malformed.unknownVerdict"])
        #expect(routed.refusals.isEmpty && routed.frames.isEmpty)
        #expect(routed.intake.prompts[id]?.lifecycle.phase == .forwarded)
    }

    /// The key is read from the slot at each verification: an Unpair between
    /// two decisions makes the second refuse, and after a new pairing only
    /// the new phone's signature counts.
    @Test func anUnpairBetweenTwoDecisionsMakesTheSecondRefuse() throws {
        let routed = RoutedIntake()
        try routed.pair(Self.phone)
        let (_, firstPrompt) = try Self.forwarded(routed, "abcde", id: 1)
        let (second, secondPrompt) = try Self.forwarded(routed, "bcdef", id: 2)
        routed.arrive(try Self.phoneDecision(for: firstPrompt))
        #expect(routed.frames.count == 1)
        #expect(routed.keys.unpair())
        routed.arrive(try Self.phoneDecision(for: secondPrompt))
        #expect(routed.frames.count == 1, "the second decision, after the Unpair, answers nothing")
        #expect(routed.refusals == ["prompt=\(second.hex) decision.unverified.noPairedKey"])
        #expect(routed.intake.prompts[second]?.lifecycle.phase == .forwarded)
        let newPhone = P256.Signing.PrivateKey()
        try routed.pair(newPhone)
        routed.arrive(try Self.phoneDecision(for: secondPrompt))
        #expect(routed.refusals.last == "prompt=\(second.hex) decision.unverified.signatureInvalid", "the old key counts no more")
        routed.arrive(try Self.phoneDecision(for: secondPrompt, .deny, by: newPhone))
        #expect(routed.frames.map(\.1).last == ApprovalChannel.verdictFrame(ChannelRequestID("bcdef")!, .deny))
        #expect(routed.codes.last == "prompt=\(second.hex) decided.remote.deny")
    }

    /// Nothing arms: unarmed (the app's one host), a forwardable prompt is
    /// never written, so the Mac holds no copy and the paired phone's
    /// signature counts for nothing; withdrawn, the copy is gone too.
    @Test func unarmedOrWithdrawnNoDecisionCounts() throws {
        let unarmed = RoutedIntake()
        unarmed.armed = false
        try unarmed.pair(Self.phone)
        unarmed.receive("abcde")
        let id = RoutedIntake.id(1)
        #expect(unarmed.database.submitted.isEmpty && unarmed.written(id) == nil)
        let shown: (String, String, String) = ("Bash", #"{"command":"git status"}"#, "")
        let never = CKRecord(recordType: ApprovalWire.RecordType.prompt.rawValue, recordID: ApprovalRecordWriter.promptRecordID(id))
        unarmed.arrive(try Self.phoneDecision(for: never, shown: shown))
        #expect(unarmed.frames.isEmpty && unarmed.refusals == ["prompt=\(id.hex) decision.unverified.noForwardedCopy"])

        let withdrawn = RoutedIntake()
        try withdrawn.pair(Self.phone)
        let (out, prompt) = try Self.forwarded(withdrawn)
        withdrawn.intake.killSwitch()
        withdrawn.arrive(try Self.phoneDecision(for: prompt))
        #expect(withdrawn.frames.isEmpty && withdrawn.refusals == ["prompt=\(out.hex) decision.unverified.noForwardedCopy"])
    }
}
