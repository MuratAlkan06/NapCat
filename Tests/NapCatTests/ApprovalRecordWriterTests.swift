// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import CloudKit
import NapCatWire
import Testing
@testable import NapCat

/// A prompt the gate forwarded, as a test states it.
struct TestPrompt: GateApprovedPrompt {
    var promptID = PromptID(high: 0x0123_4567_89ab_cdef, low: 0x0fed_cba9_8765_4321)!
    var toolName = "Bash"
    var inputPreview = #"{"command":"git status --short"}"#
    var projectLabel = "napcat"
    var createdAt = Date(timeIntervalSince1970: 1_800_000_000)
    var expiresAt = Date(timeIntervalSince1970: 1_800_000_000 + Double(ApprovalWire.promptTimeToLiveSeconds))
}

/// The record path's database seam, played by a test: it keeps every
/// operation it is handed and, when given a script, plays CloudKit's part on
/// it at once. Nothing reaches iCloud.
final class ScriptedApprovalDatabase: ApprovalRecordDatabase, @unchecked Sendable {
    private let lock = NSLock()
    private let script: ModifyOperationScript?
    private var operations: [CKModifyRecordsOperation] = []

    init(_ script: ModifyOperationScript? = nil) {
        self.script = script
    }

    func submit(_ operation: CKModifyRecordsOperation) {
        lock.lock()
        operations.append(operation)
        lock.unlock()
        script?.run(on: operation)
    }

    var submitted: [CKModifyRecordsOperation] {
        lock.lock()
        defer { lock.unlock() }
        return operations
    }
}

/// Collects what a completion and the audit trail received.
final class RecordPathLog: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [ApprovalRecordOutcome] = []
    private var lines: [String] = []

    func note(_ outcome: ApprovalRecordOutcome) { lock.lock(); outcomes.append(outcome); lock.unlock() }
    func audit(_ event: ApprovalRecordAudit) { lock.lock(); lines.append(event.code); lock.unlock() }
    var all: [ApprovalRecordOutcome] { lock.lock(); defer { lock.unlock() }; return outcomes }
    var audits: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

/// F4 slice S3: the Mac's PromptRequest writer, against a scripted database.
struct ApprovalRecordWriterTests {
    static func ck(_ code: CKError.Code, _ underlying: NSError?) -> NSError {
        ModifyOperationScript.ck(code, underlying: underlying)
    }

    static func writer(_ database: ScriptedApprovalDatabase, _ log: RecordPathLog) -> ApprovalRecordWriter {
        ApprovalRecordWriter(database: database, audit: { log.audit($0) })
    }

    // MARK: - The record

    /// Type, zone, name, and every wire field, encrypted exactly where the
    /// wire says: what the phone reads.
    @Test func theRecordIsTheWiresPromptRequest() throws {
        let prompt = TestPrompt()
        let record = try #require(ApprovalRecordWriter.makePromptRecord(prompt))
        #expect(record.recordType == ApprovalWire.RecordType.prompt.rawValue)
        #expect(record.recordID.recordName == prompt.promptID.hex)
        #expect(record.recordID.recordName.count == ApprovalWire.promptIDHexDigits)
        #expect(record.recordID.zoneID.zoneName == ApprovalWire.zoneName)
        #expect(record.recordID.zoneID.ownerName == CKCurrentUserDefaultName)
        let encrypted = Set(record.encryptedValues.allKeys())
        let plain = Set(record.allKeys()).subtracting(encrypted)
        #expect(encrypted == Set(ApprovalWire.encryptedPromptFields.map(\.rawValue)))
        #expect(plain.union(encrypted) == Set(ApprovalWire.PromptField.allCases.map(\.rawValue)))
        typealias Field = ApprovalWire.PromptField
        #expect(record[Field.wireVersion.rawValue] as? Int == ApprovalWire.wireVersion)
        #expect(record.encryptedValues[Field.toolName.rawValue] as? String == prompt.toolName)
        #expect(record.encryptedValues[Field.inputPreview.rawValue] as? String == prompt.inputPreview)
        #expect(record.encryptedValues[Field.projectLabel.rawValue] as? String == prompt.projectLabel)
        #expect(record[Field.createdAt.rawValue] as? Date == prompt.createdAt)
        #expect(record[Field.expiresAt.rawValue] as? Date == prompt.expiresAt)
        // Nothing readable in the clear.
        for field in ApprovalWire.encryptedPromptFields {
            #expect(record[field.rawValue] == nil, "\(field) in the clear")
        }
    }

    struct UnfitRow: CustomTestStringConvertible, Sendable {
        let name: String
        let prompt: TestPrompt
        var testDescription: String { name }
    }

    static let unfitRows: [UnfitRow] = {
        var noTool = TestPrompt(); noTool.toolName = ""
        var instant = TestPrompt(); instant.expiresAt = instant.createdAt
        var backwards = TestPrompt(); backwards.expiresAt = backwards.createdAt.addingTimeInterval(-1)
        var tooLong = TestPrompt(); tooLong.expiresAt = tooLong.createdAt.addingTimeInterval(Double(ApprovalWire.promptTimeToLiveSeconds + 1))
        return [UnfitRow(name: "no tool name", prompt: noTool), UnfitRow(name: "an empty window", prompt: instant),
                UnfitRow(name: "a window that ends first", prompt: backwards),
                UnfitRow(name: "a window past the TTL", prompt: tooLong)]
    }()

    /// An unfit prompt is never submitted, and says so.
    @Test(arguments: unfitRows)
    func anUnfitPromptIsRejectedBeforeAnythingIsSubmitted(_ row: UnfitRow) {
        #expect(ApprovalRecordWriter.makePromptRecord(row.prompt) == nil)
        let database = ScriptedApprovalDatabase()
        let log = RecordPathLog()
        Self.writer(database, log).write(row.prompt) { log.note($0) }
        #expect(database.submitted.isEmpty)
        #expect(log.all == [.rejected])
        #expect(log.audits == ["prompt=\(row.prompt.promptID.hex) record.write.rejected"])
    }

    /// A shorter window than the TTL is still fit (the TTL is a ceiling).
    @Test func aShorterWindowIsFit() {
        var prompt = TestPrompt()
        prompt.expiresAt = prompt.createdAt.addingTimeInterval(60)
        #expect(ApprovalRecordWriter.makePromptRecord(prompt) != nil)
    }

    /// The operation: a new record only, atomic, the alert lane's ceiling,
    /// user-initiated.
    @Test func theOperationSavesANewRecordOnly() throws {
        let database = ScriptedApprovalDatabase()
        let log = RecordPathLog()
        Self.writer(database, log).write(TestPrompt()) { log.note($0) }
        let operation = try #require(database.submitted.first)
        #expect(database.submitted.count == 1)
        #expect(operation.recordsToSave?.count == 1)
        #expect(operation.recordIDsToDelete?.isEmpty ?? true)
        #expect(operation.savePolicy == .ifServerRecordUnchanged)
        #expect(operation.isAtomic)
        #expect(operation.configuration.qualityOfService == .userInitiated)
        #expect(!operation.configuration.isLongLived)
        #expect(operation.configuration.timeoutIntervalForRequest == LidGuardTuning.requestTimeout)
        #expect(operation.configuration.timeoutIntervalForResource == LidGuardTuning.requestTimeout)
        #expect(log.all.isEmpty, "nothing is decided before CloudKit answers")
    }

    // MARK: - Each record's own result counts (issue #139)

    struct OutcomeRow: CustomTestStringConvertible, Sendable {
        let name: String
        let steps: [ModifyOperationScript.Step]
        let expected: ApprovalRecordOutcome
        var testDescription: String { name }
    }

    static let writeRows: [OutcomeRow] = [
        OutcomeRow(name: "saved + batch success", steps: [.saved(0), .batchSucceeded], expected: .confirmed),
        // The live #139 shape: a refused record inside a successful batch.
        OutcomeRow(name: "refused (quotaExceeded) + batch success",
                   steps: [.saveFailed(0, ck(.quotaExceeded, nil)), .batchSucceeded], expected: .refused("quotaExceeded (25)")),
        OutcomeRow(name: "refused (internalError, unlisted) + batch success",
                   steps: [.saveFailed(0, ck(.internalError, nil)), .batchSucceeded], expected: .refused("internalError (1)")),
        OutcomeRow(name: "refused (an unknown code) + batch success",
                   steps: [.saveFailed(0, NSError(domain: CKErrorDomain, code: 9_999)), .batchSucceeded],
                   expected: .refused("code 9999")),
        OutcomeRow(name: "refused over a timed-out connection + batch success",
                   steps: [.saveFailed(0, ck(.networkFailure, CloudKitMessageSenderTests.url(.timedOut))), .batchSucceeded],
                   expected: .refused("networkFailure (4)")),
        OutcomeRow(name: "batch success with no per-record result", steps: [.batchSucceeded], expected: .unconfirmed),
        OutcomeRow(name: "batch failure (serverResponseLost)", steps: [.batchFailed(ck(.serverResponseLost, nil))],
                   expected: .unconfirmed),
        OutcomeRow(name: "batch failure (networkUnavailable)", steps: [.batchFailed(ck(.networkUnavailable, nil))],
                   expected: .refused("networkUnavailable (3)")),
        OutcomeRow(name: "batch failure (quotaExceeded)", steps: [.batchFailed(ck(.quotaExceeded, nil))],
                   expected: .refused("quotaExceeded (25)")),
        OutcomeRow(name: "batch failure (networkFailure over a timeout)",
                   steps: [.batchFailed(ck(.networkFailure, CloudKitMessageSenderTests.url(.timedOut)))], expected: .unconfirmed),
        OutcomeRow(name: "batch failure (internalError)", steps: [.batchFailed(ck(.internalError, nil))], expected: .unconfirmed),
        OutcomeRow(name: "saved + batch failure (internalError)", steps: [.saved(0), .batchFailed(ck(.internalError, nil))],
                   expected: .unconfirmed),
        OutcomeRow(name: "batch failure from another domain", steps: [.batchFailed(NSError(domain: "x", code: 1))],
                   expected: .unconfirmed),
    ]

    @Test(arguments: writeRows)
    func aWriteHonoursTheRecordsOwnResult(_ row: OutcomeRow) {
        let prompt = TestPrompt()
        let log = RecordPathLog()
        Self.writer(ScriptedApprovalDatabase(ModifyOperationScript(row.steps)), log).write(prompt) { log.note($0) }
        #expect(log.all == [row.expected])
        #expect(log.audits == ["prompt=\(prompt.promptID.hex) record.write.\(ApprovalRecordAudit.code(row.expected))"])
    }

    // MARK: - Retraction

    /// The prompt's record and the decisions read for it, in the zone. A
    /// record already gone counts as deleted.
    @Test func aRetractionDeletesThePromptAndItsDecisions() throws {
        let prompt = TestPrompt()
        let database = ScriptedApprovalDatabase(ModifyOperationScript([
            .deleted(0), .deleteFailed(1, Self.ck(.unknownItem, nil)), .batchSucceeded]))
        let log = RecordPathLog()
        Self.writer(database, log).retract(prompt.promptID, decisions: ["decision-a"]) { log.note($0) }
        let operation = try #require(database.submitted.first)
        #expect(operation.recordsToSave?.isEmpty ?? true)
        #expect(operation.recordIDsToDelete == [ApprovalRecordWriter.promptRecordID(prompt.promptID),
                                                CKRecord.ID(recordName: "decision-a", zoneID: ApprovalRecordWriter.zoneID)])
        #expect(log.all == [.confirmed])
        #expect(log.audits == ["prompt=\(prompt.promptID.hex) record.retract.confirmed"])
    }

    static let retractRows: [OutcomeRow] = [
        OutcomeRow(name: "deleted + batch success", steps: [.deleted(0), .batchSucceeded], expected: .confirmed),
        OutcomeRow(name: "already gone + batch success", steps: [.deleteFailed(0, ck(.unknownItem, nil)), .batchSucceeded],
                   expected: .confirmed),
        OutcomeRow(name: "refused (quotaExceeded) + batch success",
                   steps: [.deleteFailed(0, ck(.quotaExceeded, nil)), .batchSucceeded], expected: .refused("quotaExceeded (25)")),
        OutcomeRow(name: "no per-record result + batch success", steps: [.batchSucceeded], expected: .unconfirmed),
        OutcomeRow(name: "batch failure (serverResponseLost)", steps: [.batchFailed(ck(.serverResponseLost, nil))],
                   expected: .unconfirmed),
    ]

    @Test(arguments: retractRows)
    func aRetractionHonoursTheRecordsOwnResult(_ row: OutcomeRow) {
        let log = RecordPathLog()
        Self.writer(ScriptedApprovalDatabase(ModifyOperationScript(row.steps)), log)
            .retract(TestPrompt().promptID) { log.note($0) }
        #expect(log.all == [row.expected])
    }

    // MARK: - The audit trail

    /// Closed codes and the random prompt ID: never the tool, the preview,
    /// the project or an error's own text.
    @Test func theAuditTrailCarriesNoPromptText() {
        var prompt = TestPrompt()
        prompt.toolName = "Bash"
        prompt.inputPreview = #"{"command":"echo secret-preview-text"}"#
        prompt.projectLabel = "secret-project-label"
        let log = RecordPathLog()
        let refusal = NSError(domain: CKErrorDomain, code: CKError.Code.quotaExceeded.rawValue,
                              userInfo: [NSLocalizedDescriptionKey: "secret-error-text"])
        for steps in Self.writeRows.map(\.steps) + [[.saveFailed(0, refusal), .batchSucceeded]] {
            Self.writer(ScriptedApprovalDatabase(ModifyOperationScript(steps)), log).write(prompt) { _ in }
        }
        #expect(log.audits.count == Self.writeRows.count + 1)
        for line in log.audits {
            for secret in ["Bash", "secret-preview-text", "secret-project-label", "secret-error-text", "echo"] {
                #expect(!line.contains(secret), "'\(line)' carries prompt or error text")
            }
            #expect(line.hasPrefix("prompt=\(prompt.promptID.hex) record.write."))
        }
    }
}
