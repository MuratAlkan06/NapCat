import CloudKit
import Foundation
import NapCatWire
@testable import NapCatPhone
import Testing

/// The decision seam, played by a test: it keeps every operation it is
/// handed and plays CloudKit's part on it at once from a script. Nothing
/// reaches iCloud.
final class ScriptedApprovalDatabase: CloudKitApprovalDatabase, @unchecked Sendable {
    private let lock = NSLock()
    private let script: ModifyOperationScript
    private var operations: [CKModifyRecordsOperation] = []

    init(_ script: ModifyOperationScript) {
        self.script = script
    }

    func submit(_ operation: CKModifyRecordsOperation) {
        lock.lock()
        operations.append(operation)
        lock.unlock()
        script.run(on: operation)
    }

    var submitted: [CKModifyRecordsOperation] {
        lock.lock()
        defer { lock.unlock() }
        return operations
    }
}

/// F4 slice S3: the decision record the phone writes back, and what each
/// CloudKit answer to it means. CKRecords are plain values; the operation is
/// the real one, its callbacks fired by hand.
@Suite struct CloudKitDecisionWriterTests {
    static let promptID = RequestFixtures.id(0x77)
    static let decidedAt = Date(timeIntervalSince1970: 1_800_000_321)
    /// The writer only writes: any 64 bytes stand for the signature here
    /// (the signature's own tests are `DecisionSignerTests`).
    static let signature = Data((0..<64).map { UInt8($0) })
    static let decision = PhoneDecision(promptID: promptID, verdict: .allow, decidedAt: decidedAt, signature: signature)!
    typealias Field = ApprovalWire.DecisionField

    static func ck(_ code: CKError.Code, _ underlying: NSError? = nil) -> NSError {
        ModifyOperationScript.ck(code, underlying: underlying)
    }

    // MARK: The record

    /// The wire's PromptDecision, in the approvals zone: the prompt ID, the
    /// verdict and the 64-byte signature encrypted (S-PAIR-B), the version
    /// and the time in the clear.
    @Test func theRecordIsTheWiresSignedDecision() {
        let record = CloudKitAlertSource.makeDecisionRecord(Self.decision)
        #expect(record.recordType == ApprovalWire.RecordType.decision.rawValue)
        #expect(record.recordID.zoneID.zoneName == ApprovalWire.zoneName)
        #expect(record.recordID.zoneID.ownerName == CKCurrentUserDefaultName)
        let encrypted = Set(record.encryptedValues.allKeys())
        let plain = Set(record.allKeys()).subtracting(encrypted)
        #expect(encrypted == [Field.promptID.rawValue, Field.verdict.rawValue, Field.signature.rawValue])
        #expect(encrypted == Set(ApprovalWire.encryptedDecisionFields.map(\.rawValue)))
        #expect(plain == [Field.wireVersion.rawValue, Field.decidedAt.rawValue])
        #expect(encrypted.isSubset(of: Set(ApprovalWire.encryptedDecisionFields.map(\.rawValue))))
        #expect(plain.isDisjoint(with: Set(ApprovalWire.encryptedDecisionFields.map(\.rawValue))))
        #expect(record[Field.wireVersion.rawValue] as? Int == ApprovalWire.wireVersion)
        #expect(record.encryptedValues[Field.promptID.rawValue] as? String == Self.promptID.hex)
        #expect(record.encryptedValues[Field.verdict.rawValue] as? String == "allow")
        #expect(record[Field.decidedAt.rawValue] as? Date == Self.decidedAt)
        #expect(record.encryptedValues[Field.signature.rawValue] as? Data == Self.signature)
        #expect(Set(record.allKeys()) == Set(Field.allCases.map(\.rawValue)), "every wire field, nothing else")
    }

    /// One decision record per prompt: a retry names the same record, any
    /// other prompt another one, and none is the prompt's own record.
    @Test func eachPromptHasOneDecisionRecord() {
        let deny = PhoneDecision(promptID: Self.promptID, verdict: .deny, decidedAt: Self.decidedAt.addingTimeInterval(5),
                                 signature: Self.signature)!
        #expect(CloudKitAlertSource.makeDecisionRecord(deny).recordID == CloudKitAlertSource.makeDecisionRecord(Self.decision).recordID)
        let other = PhoneDecision(promptID: RequestFixtures.id(0x78), verdict: .allow, decidedAt: Self.decidedAt,
                                  signature: Self.signature)!
        #expect(CloudKitAlertSource.makeDecisionRecord(other).recordID != CloudKitAlertSource.makeDecisionRecord(Self.decision).recordID)
        #expect(CloudKitAlertSource.decisionRecordID(for: Self.promptID).recordName != Self.promptID.hex)
    }

    /// A new record only: an answer is never overwritten.
    @Test func theSaveNeverOverwritesAnAnswer() async throws {
        let database = ScriptedApprovalDatabase(ModifyOperationScript([.saved(0), .batchSucceeded]))
        _ = await CloudKitDecisionWriter(database: database).write(Self.decision)
        let operation = try #require(database.submitted.first)
        #expect(database.submitted.count == 1)
        #expect(operation.savePolicy == .ifServerRecordUnchanged)
        #expect(operation.isAtomic)
        #expect(operation.configuration.qualityOfService == .userInitiated)
        #expect(operation.recordsToSave?.map(\.recordID) == [CloudKitAlertSource.decisionRecordID(for: Self.promptID)])
    }

    // MARK: Each record's own result counts

    struct Row: CustomTestStringConvertible, Sendable {
        let name: String
        let steps: [ModifyOperationScript.Step]
        let expected: DecisionWriteOutcome
        var testDescription: String { name }
    }

    static let rows: [Row] = [
        Row(name: "saved + batch success", steps: [.saved(0), .batchSucceeded], expected: .saved),
        // The Mac's #139 shape: a refused record inside a successful batch.
        Row(name: "refused (quotaExceeded) + batch success", steps: [.saveFailed(0, ck(.quotaExceeded)), .batchSucceeded],
            expected: .failed),
        Row(name: "refused (zoneNotFound) + batch success", steps: [.saveFailed(0, ck(.zoneNotFound)), .batchSucceeded],
            expected: .failed),
        Row(name: "refused (internalError) + batch success", steps: [.saveFailed(0, ck(.internalError)), .batchSucceeded],
            expected: .failed),
        Row(name: "already answered + batch success", steps: [.saveFailed(0, ck(.serverRecordChanged)), .batchSucceeded],
            expected: .alreadyAnswered),
        Row(name: "batch success with no per-record result", steps: [.batchSucceeded], expected: .unconfirmed),
        Row(name: "batch failure (serverResponseLost)", steps: [.batchFailed(ck(.serverResponseLost))], expected: .unconfirmed),
        Row(name: "batch failure (networkUnavailable)", steps: [.batchFailed(ck(.networkUnavailable))], expected: .failed),
        Row(name: "batch failure (zoneNotFound)", steps: [.batchFailed(ck(.zoneNotFound))], expected: .failed),
        Row(name: "batch failure (networkFailure over a timeout)",
            steps: [.batchFailed(ck(.networkFailure, ModifyOperationScript.url(.timedOut)))], expected: .unconfirmed),
        Row(name: "batch failure (networkFailure)", steps: [.batchFailed(ck(.networkFailure))], expected: .failed),
        Row(name: "batch failure (internalError)", steps: [.batchFailed(ck(.internalError))], expected: .unconfirmed),
        Row(name: "saved + batch failure (internalError)", steps: [.saved(0), .batchFailed(ck(.internalError))],
            expected: .unconfirmed),
        Row(name: "batch failure from another domain", steps: [.batchFailed(NSError(domain: "x", code: 1))],
            expected: .unconfirmed),
    ]

    @Test(arguments: rows)
    func aWriteHonoursTheRecordsOwnResult(_ row: Row) async {
        let database = ScriptedApprovalDatabase(ModifyOperationScript(row.steps))
        #expect(await CloudKitDecisionWriter(database: database).write(Self.decision) == row.expected)
    }

    /// The outcome is decided once, on the first batch result.
    @Test func aSecondBatchResultChangesNothing() async {
        let database = ScriptedApprovalDatabase(ModifyOperationScript([.saved(0), .batchSucceeded,
                                                                       .batchFailed(Self.ck(.quotaExceeded))]))
        #expect(await CloudKitDecisionWriter(database: database).write(Self.decision) == .saved)
    }

    // MARK: Through the inbox

    /// The whole phone half: an answer goes from the inbox through the
    /// signer and the real record and operation, and CloudKit's answer
    /// decides what it shows. The record's signature is one the Mac counts.
    @MainActor
    @Test(arguments: [(DecisionWriteOutcome.saved, RequestStatus.sent(.deny)),
                      (.alreadyAnswered, .answered)])
    func anAnswerTravelsTheRecordPath(_ outcome: DecisionWriteOutcome, _ expected: RequestStatus) async throws {
        let steps: [ModifyOperationScript.Step] = outcome == .saved
            ? [.saved(0), .batchSucceeded] : [.saveFailed(0, Self.ck(.serverRecordChanged)), .batchSucceeded]
        let database = ScriptedApprovalDatabase(ModifyOperationScript(steps))
        let clock = TestClock()
        let keys = PhoneKeyringTests.World()
        let publicKey = try #require(keys.keyring.makeProvisional())
        #expect(keys.keyring.commitProvisional())
        let inbox = RequestInbox(writer: CloudKitDecisionWriter(database: database), biometrics: ScriptedBiometricGate(),
                                 keyring: keys.keyring, clock: { clock.now })
        let request = RequestFixtures.request(5, createdAt: clock.now)
        inbox.receive([request])
        await inbox.deny(request.id)
        #expect(inbox.status(of: request.id) == expected)
        let record = try #require(database.submitted.first?.recordsToSave?.first)
        #expect(record.encryptedValues[Field.verdict.rawValue] as? String == "deny")
        #expect(record.encryptedValues[Field.promptID.rawValue] as? String == request.id.hex)
        let signature = try #require(record.encryptedValues[Field.signature.rawValue] as? Data)
        let decidedAt = try #require(record[Field.decidedAt.rawValue] as? Date)
        let read = try #require(PhoneDecision(promptID: request.id, verdict: .deny, decidedAt: decidedAt, signature: signature))
        #expect(MacCheck.verifies(read, copy: request, publicKey: publicKey))
    }
}
