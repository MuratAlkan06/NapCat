// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import CloudKit
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
        ForwardRow(tool: "Read", relayed: #"{ "file_path": "/Users/someone/project/doc.pdf", "offset": 1, "limit": 200, "pages": "1-3" }"#,
                   copy: #"{"file_path":"/Users/someone/project/doc.pdf","offset":1,"limit":200,"pages":"1-3"}"#,
                   note: "a Read, re-serialized"),
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
        #expect(holding.codes == ["prompt=\(RoutedIntake.id(1).hex) suppressed.gate.forbidden.secretAccess"])

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
}
