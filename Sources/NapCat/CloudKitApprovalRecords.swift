import CloudKit
import Foundation
import NapCatWire
import os

// F4 slice S3: the Mac's half of the CloudKit record path. Design:
// design/remote-approvals.md.
//
// SECOND FILE THAT MAY NAME CLOUDKIT (deliberate lint amendment, #146): its
// RECORD vocabulary only — records, record IDs and zones, the modify
// operation and CloudKit's error codes. Nothing that reaches iCloud by
// itself: the container, the database, the account check and the
// entitlement probe stay in CloudKitMessageSender.swift alone
// (LidGuardStructureTests, ApprovalRecordPathStructureTests).
//
// - The WRITER saves one PromptRequest record per prompt the category gate
//   already forwarded (`GateApprovedPrompt`: the writer never classifies),
//   into the approvals zone, named by the prompt's random 128-bit ID, with
//   every field a person could read stored encrypted, and RETRACTS it
//   (deletes it and the decision records read for it). Every verdict on an
//   operation honours each record's own result (issue #139).
// - The READER parses, validates and logs PromptDecision records in a
//   closed vocabulary, and does nothing else. A decision is UNSIGNED until
//   pairing (CL-1) exists, so a reading is a claim, never a verdict.
//
// FAIL-DARK (lint-locked): in this slice nothing in the app builds the
// writer or reads a decision, only test fakes conform to the database seam,
// and this file names nothing of the verdict API (the seam, the intake, the
// lifecycle, the channel's verdict wire, the gate). Routing the intake's
// forwarded prompts through the writer waits for the revised gate (#145).
// UNPRIVILEGED — no sudo, no PLAN §4 command, no subprocess.

/// A prompt the category gate already FORWARDED, as its record carries it.
/// The writer takes it as it is and never classifies anything: only a value
/// the gate decided may conform (the gate's own forward answer, once the
/// revised gate lands).
protocol GateApprovedPrompt: Sendable {
    var promptID: PromptID { get }
    /// The Claude Code tool name, exactly as the gate classified it.
    var toolName: String { get }
    /// The tool's arguments, exactly as the gate classified them.
    var inputPreview: String { get }
    /// The originating project's label.
    var projectLabel: String { get }
    var createdAt: Date { get }
    /// `createdAt` plus at most the wire's TTL.
    var expiresAt: Date { get }
}

/// THE seam over CloudKit I/O for the record path: run this operation
/// against the owner's private database. In this slice ONLY test fakes
/// conform (lint-locked), so no operation built here can run.
protocol ApprovalRecordDatabase: AnyObject, Sendable {
    func submit(_ operation: CKModifyRecordsOperation)
}

/// What one record operation came to.
enum ApprovalRecordOutcome: Equatable, Sendable {
    /// Every record reported done (saved; deleted or already gone) and the
    /// batch agreed.
    case confirmed
    /// A record's own failure, whatever its code, or a definitive batch
    /// refusal: nothing was committed. Carries the closed diagnostic code
    /// (`quotaExceeded (25)`), never the error's own text.
    case refused(String)
    /// It may or may not have landed: a batch timeout or lost response, a
    /// batch success with no per-record result, or a batch error the
    /// definitive table does not list.
    case unconfirmed
    /// The prompt was not fit to write; nothing was submitted.
    case rejected
}

/// Which record operation an audit line is about.
enum ApprovalRecordAction: String, Sendable {
    case write
    case retract
}

/// Writes and retracts PromptRequest records through the database seam.
final class ApprovalRecordWriter: Sendable {
    private let database: any ApprovalRecordDatabase
    private let audit: @Sendable (ApprovalRecordAudit) -> Void

    init(database: any ApprovalRecordDatabase,
         audit: @escaping @Sendable (ApprovalRecordAudit) -> Void = ApprovalRecordLog.record) {
        self.database = database
        self.audit = audit
    }

    /// Saves the prompt's record. An unfit prompt (`makePromptRecord`) is
    /// rejected before anything is submitted.
    func write(_ prompt: some GateApprovedPrompt, completion: @escaping @Sendable (ApprovalRecordOutcome) -> Void) {
        let id = prompt.promptID
        guard let record = Self.makePromptRecord(prompt) else {
            audit(.prompt(id, .write, .rejected))
            completion(.rejected)
            return
        }
        let audit = self.audit
        database.submit(Self.makeOperation(saving: [record], deleting: []) { outcome in
            audit(.prompt(id, .write, outcome))
            completion(outcome)
        })
    }

    /// Deletes the prompt's record and the decision records read for it (in
    /// the approvals zone; any other ID is dropped). A record that is
    /// already gone counts as deleted.
    func retract(_ id: PromptID, decisions: [String] = [],
                 completion: @escaping @Sendable (ApprovalRecordOutcome) -> Void) {
        let doomed = [Self.promptRecordID(id)] + decisions.map { CKRecord.ID(recordName: $0, zoneID: Self.zoneID) }
        let audit = self.audit
        database.submit(Self.makeOperation(saving: [], deleting: doomed) { outcome in
            audit(.prompt(id, .retract, outcome))
            completion(outcome)
        })
    }

    // MARK: - The record (pure, unit-tested without iCloud)

    /// The dedicated approvals zone of the owner's private database.
    static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: ApprovalWire.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// A prompt's record is named by its random 128-bit ID, nothing else.
    static func promptRecordID(_ id: PromptID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.hex, zoneID: zoneID)
    }

    /// THE one place a PromptRequest record is built: every
    /// `ApprovalWire.PromptField`, each stored encrypted exactly when the
    /// wire lists it in `encryptedPromptFields`. nil when the prompt is not
    /// fit to write: an empty tool name, or a window that is not a positive
    /// span of at most the TTL.
    static func makePromptRecord(_ prompt: some GateApprovedPrompt) -> CKRecord? {
        let window = prompt.expiresAt.timeIntervalSince(prompt.createdAt)
        guard !prompt.toolName.isEmpty, window > 0,
              window <= TimeInterval(ApprovalWire.promptTimeToLiveSeconds) else { return nil }
        let record = CKRecord(recordType: ApprovalWire.RecordType.prompt.rawValue,
                              recordID: promptRecordID(prompt.promptID))
        for field in ApprovalWire.PromptField.allCases {
            let value = promptValue(field, of: prompt)
            if ApprovalWire.encryptedPromptFields.contains(field) {
                record.encryptedValues[field.rawValue] = value
            } else {
                record[field.rawValue] = value
            }
        }
        return record
    }

    /// One field's value. Exhaustive on purpose: a new wire field does not
    /// compile until it has its value.
    static func promptValue(_ field: ApprovalWire.PromptField, of prompt: some GateApprovedPrompt) -> CKRecordValue {
        switch field {
        case .wireVersion: return ApprovalWire.wireVersion as NSNumber
        case .toolName: return prompt.toolName as NSString
        case .inputPreview: return prompt.inputPreview as NSString
        case .projectLabel: return prompt.projectLabel as NSString
        case .createdAt: return prompt.createdAt as NSDate
        case .expiresAt: return prompt.expiresAt as NSDate
        }
    }

    // MARK: - The operation (issue #139: each record's own result counts)

    /// THE record operation, built here so a test can play CloudKit's part
    /// on the real thing (`ModifyOperationScript`). A new record only (never
    /// overwrite one), atomic in the custom zone, the same request/resource
    /// ceiling as the alert lane, user-initiated priority.
    ///
    /// What `completion` receives (`RecordResults.outcome`):
    /// - a record's own failure → `refused(<its code>)`, whatever the batch
    ///   said — except a delete of a record already gone, which is done;
    /// - every record reported done and the batch succeeded → `confirmed`;
    /// - the batch succeeded with a record unreported → `unconfirmed`;
    /// - the batch failed and no record failed → `batchOutcome`.
    static func makeOperation(saving records: [CKRecord], deleting doomed: [CKRecord.ID],
                              completion: @escaping @Sendable (ApprovalRecordOutcome) -> Void)
        -> CKModifyRecordsOperation {
        let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: doomed)
        operation.savePolicy = .ifServerRecordUnchanged
        operation.isAtomic = true
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        configuration.isLongLived = false
        configuration.timeoutIntervalForRequest = LidGuardTuning.requestTimeout
        configuration.timeoutIntervalForResource = LidGuardTuning.requestTimeout
        operation.configuration = configuration
        let results = RecordResults(expected: records.count + doomed.count)
        operation.perRecordSaveBlock = { _, result in results.note(result.map { _ in () }, deleting: false) }
        operation.perRecordDeleteBlock = { _, result in results.note(result, deleting: true) }
        operation.modifyRecordsResultBlock = { batch in completion(results.outcome(batch: batch)) }
        return operation
    }

    /// A delete that found nothing: the record is gone, which is the point.
    static func isGone(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == CKErrorDomain && nsError.code == CKError.Code.unknownItem.rawValue
    }

    /// A BATCH failure with no record failure, as the alert lane judges one
    /// (issue #139): a timeout-class transport error underneath →
    /// `unconfirmed`; a code in the alert lane's definitive table →
    /// `refused`; anything else → `unconfirmed`.
    static func batchOutcome(_ error: any Error) -> ApprovalRecordOutcome {
        let nsError = CloudKitMessageSender.recordLevelError(error as NSError)
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain,
           LidGuardPolicy.unconfirmedTransportErrorCodes.contains(underlying.code) {
            return .unconfirmed
        }
        guard nsError.domain == CKErrorDomain, let code = CKError.Code(rawValue: nsError.code),
              CloudKitMessageSender.definitiveFailureText(code) != nil else {
            return .unconfirmed
        }
        return .refused(CloudKitMessageSender.diagnosticCode(nsError))
    }
}

/// Holds each record's own result until the batch result arrives, then says
/// what the operation came to (`ApprovalRecordWriter.makeOperation`).
private final class RecordResults: @unchecked Sendable {
    private let lock = NSLock()
    private let expected: Int
    private var reported = 0
    private var refusal: (any Error)?

    init(expected: Int) {
        self.expected = expected
    }

    func note(_ result: Result<Void, any Error>, deleting: Bool) {
        lock.lock()
        defer { lock.unlock() }
        reported += 1
        if case .failure(let error) = result, refusal == nil, !(deleting && ApprovalRecordWriter.isGone(error)) {
            refusal = error
        }
    }

    func outcome(batch: Result<Void, any Error>) -> ApprovalRecordOutcome {
        lock.lock()
        defer { lock.unlock() }
        if let refusal { return .refused(CloudKitMessageSender.diagnosticCode(refusal)) }
        switch batch {
        case .success: return reported >= expected ? .confirmed : .unconfirmed
        case .failure(let error): return ApprovalRecordWriter.batchOutcome(error)
        }
    }
}

// MARK: - The reader

/// A decision record as the Mac read it: a CLAIM about one prompt, or why
/// the record is malformed. There is no verified reading: nothing on this
/// Mac can verify a decision before pairing (CL-1), and no reading is handed
/// to anything that answers a dialog (lint-locked).
enum DecisionRecordReading: Equatable, Sendable {
    case claim(DecisionClaim)
    case malformed(DecisionRecordFault)
}

/// A well-formed decision record: what it claims, and nothing more.
struct DecisionClaim: Equatable, Sendable {
    /// The record's own name (approvals zone), so a retraction can delete it.
    let recordName: String
    let promptID: PromptID
    let claimedVerdict: ApprovalWire.Verdict
    /// The phone's clock: audit only (freshness is judged on the Mac's).
    let decidedAt: Date
    let signature: DecisionSignature
}

/// What a decision record carries in its signature field. Never "verified".
enum DecisionSignature: String, CaseIterable, Sendable {
    /// No signature at all: the phone's decisions before pairing.
    case absent
    /// Bytes nothing on this Mac can check yet (no paired key before CL-1).
    case unverifiable
}

/// Why a decision record is not even a claim.
enum DecisionRecordFault: String, CaseIterable, Sendable {
    case wrongRecordType
    case wrongZone
    /// A field outside `ApprovalWire.DecisionField`.
    case unknownField
    /// A field the wire encrypts, stored in the clear.
    case unencryptedField
    /// A field the wire keeps in the clear, stored encrypted.
    case misplacedField
    case wrongWireVersion
    case malformedPromptID
    case unknownVerdict
    case missingDecidedAt
    case malformedSignature
}

enum DecisionRecordReader {
    /// Reads one record and logs the reading (closed vocabulary). That is
    /// all a reading does in this slice.
    static func read(_ record: CKRecord,
                     audit: (ApprovalRecordAudit) -> Void = ApprovalRecordLog.record) -> DecisionRecordReading {
        let reading = reading(of: record)
        audit(.decision(reading))
        return reading
    }

    /// The strict reading: the record type and zone, then the exact field
    /// set (each field encrypted exactly when the wire encrypts it), then
    /// each value. Encrypted fields are read from the encrypted values only.
    static func reading(of record: CKRecord) -> DecisionRecordReading {
        guard record.recordType == ApprovalWire.RecordType.decision.rawValue else { return .malformed(.wrongRecordType) }
        guard record.recordID.zoneID.zoneName == ApprovalWire.zoneName else { return .malformed(.wrongZone) }
        let encrypted = Set(record.encryptedValues.allKeys())
        let plain = Set(record.allKeys()).subtracting(encrypted)
        let known = Set(ApprovalWire.DecisionField.allCases.map(\.rawValue))
        let secret = Set(ApprovalWire.encryptedDecisionFields.map(\.rawValue))
        guard encrypted.union(plain).isSubset(of: known) else { return .malformed(.unknownField) }
        guard plain.isDisjoint(with: secret) else { return .malformed(.unencryptedField) }
        guard encrypted.isSubset(of: secret) else { return .malformed(.misplacedField) }
        typealias Field = ApprovalWire.DecisionField
        guard record[Field.wireVersion.rawValue] as? Int == ApprovalWire.wireVersion else {
            return .malformed(.wrongWireVersion)
        }
        guard let hex = record.encryptedValues[Field.promptID.rawValue] as? String,
              let promptID = PromptID(hex: hex) else { return .malformed(.malformedPromptID) }
        guard let raw = record.encryptedValues[Field.verdict.rawValue] as? String,
              let verdict = ApprovalWire.Verdict(rawValue: raw) else { return .malformed(.unknownVerdict) }
        guard let decidedAt = record[Field.decidedAt.rawValue] as? Date else { return .malformed(.missingDecidedAt) }
        let signature: DecisionSignature
        switch record.encryptedValues[Field.signature.rawValue] {
        case nil:
            signature = .absent
        case let bytes as Data where !bytes.isEmpty:
            signature = .unverifiable
        default:
            return .malformed(.malformedSignature)
        }
        return .claim(DecisionClaim(recordName: record.recordID.recordName, promptID: promptID,
                                    claimedVerdict: verdict, decidedAt: decidedAt, signature: signature))
    }
}

// MARK: - The audit trail (closed vocabulary)

/// One record-path log line: the random prompt ID and closed codes, never a
/// tool name, a preview, a project label or an error's own text.
enum ApprovalRecordAudit: Equatable, Sendable {
    case prompt(PromptID, ApprovalRecordAction, ApprovalRecordOutcome)
    case decision(DecisionRecordReading)

    var code: String {
        switch self {
        case .prompt(let id, let action, let outcome):
            return "prompt=\(id.hex) record.\(action.rawValue).\(Self.code(outcome))"
        case .decision(.claim(let claim)):
            let state = claim.signature == .absent ? "unsigned" : "unverifiable"
            return "prompt=\(claim.promptID.hex) decision.\(state) claim=\(claim.claimedVerdict.rawValue)"
        case .decision(.malformed(let fault)):
            return "decision.malformed.\(fault.rawValue)"
        }
    }

    static func code(_ outcome: ApprovalRecordOutcome) -> String {
        switch outcome {
        case .confirmed: return "confirmed"
        case .refused(let diagnostic): return "refused " + diagnostic
        case .unconfirmed: return "unconfirmed"
        case .rejected: return "rejected"
        }
    }
}

enum ApprovalRecordLog {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "approvals")

    static func record(_ event: ApprovalRecordAudit) {
        logger.notice("\(event.code, privacy: .public)")
    }
}
