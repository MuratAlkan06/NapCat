import CloudKit
import Foundation
import NapCatWire
import os

// F4 slice S3: the Mac's half of the CloudKit record path. Design:
// design/remote-approvals.md.
//
// SECOND FILE THAT MAY NAME CLOUDKIT (deliberate lint amendment, #146): its
// RECORD vocabulary only — records, record IDs and zones, the modify
// operation and CloudKit's error codes (an exact allow-list). The container,
// the database, the account check and the entitlement probe stay in
// CloudKitMessageSender.swift alone. The operation built here COULD reach
// iCloud if it ran: one run with no database set targets the user's private
// database. So nothing here runs it — no start, no queue, no database `add` —
// it only goes to the database seam, which only test fakes conform to
// (LidGuardStructureTests, ApprovalRecordPathStructureTests lock 4).
//
// - The WRITER saves one PromptRequest record per prompt the category gate
//   already forwarded (`GateApprovedPrompt`: the writer never classifies),
//   into the approvals zone, named by the prompt's random 128-bit ID, with
//   every field a person could read stored encrypted, and RETRACTS it
//   (deletes it and the decision records read for it). Every verdict on an
//   operation honours each record's own result (issue #139).
// - The READER parses, validates and logs PromptDecision records in a
//   closed vocabulary, and does nothing else. A reading is a claim, never a
//   verdict: since S-PAIR-C2 (#181) the store hands a claim's evidence, with
//   its own copy of the prompt, on to the decision verifier, and only the
//   verifier's result reaches the intake.
// - The RECORD STORE (`CloudKitApprovalRecords`, routed through the revised
//   gate, #145) is the intake's record sink over the writer: it writes the
//   gate's forward answer as it is handed (the tool and the gate's own copy
//   of the preview), keeps its own copy of what it wrote (S-PAIR-C2), and
//   every withdrawal retracts the record together with the decisions read
//   for it.
// - The PAIRING RESPONSE READER (S-PAIR-C1, #168) reads a PairingResponse
//   record strictly, field by field, into its bytes or a closed fault. It
//   holds no key and checks no MAC or proof (the ceremony does, with its
//   nonce), and in this slice only tests hand it a record: no CloudKit
//   operation for the pairing record exists yet.
//
// FAIL-DARK (lint-locked): in this slice nothing in the app builds the
// writer or the record store, or reads a decision; only test fakes conform
// to the database seam; and this file names nothing of the verdict API (the
// seam, the intake, the lifecycle, the channel's verdict wire, the gate)
// but the intake's record-sink protocol, once, as the record store's own
// conformance.
// UNPRIVILEGED — no sudo, no PLAN §4 command, no subprocess.

/// A prompt the category gate already FORWARDED, as its record carries it.
/// The writer takes it as it is and never classifies anything: only the
/// gate's own forward answer conforms (`ForwardedPrompt`, built by the
/// record store alone; lint-locked).
protocol GateApprovedPrompt: Sendable {
    var promptID: PromptID { get }
    /// The Claude Code tool name, exactly as the gate classified it.
    var toolName: String { get }
    /// The gate's own copy of the tool's arguments
    /// (`ApprovalGate.forwardedPreview`: no description, never the relayed
    /// text).
    var inputPreview: String { get }
    /// The originating project's label.
    var projectLabel: String { get }
    var createdAt: Date { get }
    /// `createdAt` plus at most the wire's TTL.
    var expiresAt: Date { get }
}

/// THE seam over CloudKit I/O for the record path: run this operation
/// against the owner's private database. It is the only thing that runs an
/// operation built here: this file never starts or runs one itself, on a
/// receiver or on `self`, never queues one and never adds one to a database;
/// and in this slice ONLY test fakes conform (both lint-locked).
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

// MARK: - The intake's record store (routed through the revised gate)

/// The record store behind the intake: each prompt the category gate
/// forwarded becomes one PromptRequest record, and each withdrawal (the
/// session's end, the kill switch, the TTL) retracts it together with the
/// decision records read for it. It is handed the gate's forward answer —
/// the tool and the gate's own copy of the preview, never the relayed text —
/// and writes exactly that: it never classifies, and it holds no way back to
/// the dialog. Confined to the seam's queue, like the intake.
///
/// In this slice only tests build it (lint-locked): the app's host keeps the
/// sink that writes nothing, and only test fakes conform to the database
/// seam.
final class CloudKitApprovalRecords: ApprovalRecordSink {
    private let writer: ApprovalRecordWriter
    private let now: () -> Date
    /// Every prompt written and not yet retracted, with the names of the
    /// decision records read for it.
    private var pending: [PromptID: Set<String>] = [:]
    /// S-PAIR-C2: the Mac's own copy of each of those prompts, the three
    /// fields exactly as written — what the verifier rebuilds the phone's
    /// `shown` digest from.
    private var copies: [PromptID: ForwardedCopy] = [:]

    /// `now`: the wall clock a record states its window in.
    init(writer: ApprovalRecordWriter, now: @escaping () -> Date = Date.init) {
        self.writer = writer
        self.now = now
    }

    /// The intake saves only as the prompt's lifecycle opens (lint-locked),
    /// so the record's window is the whole TTL from now: `expiresAt` is that
    /// same end on the intake's monotonic clock, which a record cannot
    /// carry. The writer audits the outcome; telling the lifecycle is a later
    /// slice's (until then the prompt stays `saving`, and no decision can
    /// count).
    func save(_ id: PromptID, tool: ApprovalTool, inputPreview: String, expiresAt: Int) {
        let createdAt = now()
        let prompt = ForwardedPrompt(promptID: id, toolName: tool.rawValue, inputPreview: inputPreview, createdAt: createdAt,
                                     expiresAt: createdAt.addingTimeInterval(TimeInterval(ApprovalWire.promptTimeToLiveSeconds)))
        pending[id] = []
        copies[id] = ForwardedCopy(promptID: id, toolName: prompt.toolName, inputPreview: prompt.inputPreview,
                                   projectLabel: prompt.projectLabel)
        writer.write(prompt) { _ in }
    }

    func retract(_ id: PromptID) {
        copies[id] = nil
        let decisions = pending.removeValue(forKey: id) ?? []
        writer.retract(id, decisions: decisions.sorted()) { _ in }
    }

    /// The waiting buzz is the alert lane's to supersede (a later slice).
    func supersedeWaitingAlert(_ id: PromptID) {}

    /// A decision record read for a pending prompt joins that prompt's
    /// retraction and does nothing else: a claim is never a verdict. A claim
    /// for any other prompt is dropped.
    func noteRead(_ claim: DecisionClaim) {
        pending[claim.promptID]?.insert(claim.recordName)
    }

    /// S-PAIR-C2 (#181): a decision record, read strictly and audited. A
    /// claim joins its prompt's retraction (`noteRead`) and goes on, for the
    /// verifier, as its evidence with this store's own copy of that prompt —
    /// none once the prompt is retracted, or for one it never wrote. A
    /// record that is not even a claim goes nowhere.
    func read(_ record: CKRecord, audit: (ApprovalRecordAudit) -> Void = ApprovalRecordLog.record)
        -> (evidence: DecisionEvidence, copy: ForwardedCopy?)? {
        guard case .claim(let claim) = DecisionRecordReader.read(record, audit: audit) else { return nil }
        noteRead(claim)
        return (claim.evidence, copies[claim.promptID])
    }
}

/// The gate's forward answer as the record store hands it to the writer: the
/// ONE conformance to `GateApprovedPrompt` (lint-locked), built only in
/// `CloudKitApprovalRecords.save` from what the intake handed it.
private struct ForwardedPrompt: GateApprovedPrompt {
    let promptID: PromptID
    let toolName: String
    let inputPreview: String
    /// No project label crosses the seam yet (a later slice).
    let projectLabel = ""
    let createdAt: Date
    let expiresAt: Date
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
/// the record is malformed. There is no verified reading: no reading is
/// handed to anything that answers a dialog — a claim's evidence goes to the
/// decision verifier, whose result alone reaches the intake (S-PAIR-C2,
/// lint-locked).
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
    /// The signature field's bytes as read, unchecked (the verifier checks
    /// them); empty when the record carries none. Never "verified".
    let signature: Data

    /// What the claim hands the verifier (S-PAIR-C2): its fields as the
    /// record held them — the reader accepts each in one spelling only —
    /// every one of which the verifier checks again.
    var evidence: DecisionEvidence {
        DecisionEvidence(wireVersion: ApprovalWire.wireVersion, promptID: promptID.hex, verdict: claimedVerdict.rawValue,
                         decidedAt: decidedAt, signature: signature)
    }
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
        let signature: Data
        switch record.encryptedValues[Field.signature.rawValue] {
        case nil:
            signature = Data()
        case let bytes as Data where !bytes.isEmpty:
            signature = bytes
        default:
            return .malformed(.malformedSignature)
        }
        return .claim(DecisionClaim(recordName: record.recordID.recordName, promptID: promptID,
                                    claimedVerdict: verdict, decidedAt: decidedAt, signature: signature))
    }
}

// MARK: - The pairing response reader (S-PAIR-C1, #168)

/// A pairing response record as the Mac read it, field by field: what it
/// carries, or why it is not even that. A reading is NOT a pairing: the
/// ceremony checks the confirmation MAC and the proof against its own nonce
/// (`PairingResponseCheck`), and the owner compares the codes, before any key
/// is kept. Nothing here reads a decision or names the verdict API.
enum PairingResponseReading: Equatable, Sendable {
    case response(PairingResponseClaim)
    case malformed(PairingResponseFault)
}

/// A well-formed pairing response: its bytes, and nothing more.
struct PairingResponseClaim: Equatable, Sendable {
    /// x9.63, 65 bytes, the first 0x04.
    let publicKey: [UInt8]
    /// 32 bytes.
    let confirmation: [UInt8]
    /// Raw ECDSA, 64 bytes.
    let proof: [UInt8]
}

/// Why a pairing response record is not even a reading (closed vocabulary).
enum PairingResponseFault: String, CaseIterable, Sendable {
    case wrongRecordType
    case wrongZone
    /// Not the name the ceremony's nonce derives.
    case wrongRecordName
    /// A field outside `ApprovalWire.PairingResponseField`.
    case unknownField
    /// A field the wire encrypts, stored in the clear.
    case unencryptedField
    /// A field the wire keeps in the clear, stored encrypted.
    case misplacedField
    /// One of the four fields is absent.
    case missingField
    case wrongWireVersion
    case malformedPublicKey
    case malformedConfirmation
    case malformedProof
}

enum PairingResponseReader {
    /// The strict reading, as the phone's prompt reader reads its records:
    /// the record type, the zone and the name the ceremony derived, then the
    /// exact field set (each field encrypted exactly when the wire encrypts
    /// it, all four present), then each value. Encrypted fields are read from
    /// the encrypted values only. The first failure wins.
    static func reading(of record: CKRecord, expectedName: String) -> PairingResponseReading {
        guard record.recordType == ApprovalWire.RecordType.pairingResponse.rawValue else { return .malformed(.wrongRecordType) }
        guard record.recordID.zoneID.zoneName == ApprovalWire.zoneName else { return .malformed(.wrongZone) }
        guard record.recordID.recordName == expectedName else { return .malformed(.wrongRecordName) }
        let encrypted = Set(record.encryptedValues.allKeys())
        let plain = Set(record.allKeys()).subtracting(encrypted)
        let known = Set(ApprovalWire.PairingResponseField.allCases.map(\.rawValue))
        let secret = Set(ApprovalWire.encryptedPairingResponseFields.map(\.rawValue))
        guard encrypted.union(plain).isSubset(of: known) else { return .malformed(.unknownField) }
        guard plain.isDisjoint(with: secret) else { return .malformed(.unencryptedField) }
        guard encrypted.isSubset(of: secret) else { return .malformed(.misplacedField) }
        guard encrypted.union(plain) == known else { return .malformed(.missingField) }
        typealias Field = ApprovalWire.PairingResponseField
        guard record[Field.wireVersion.rawValue] as? Int == ApprovalWire.wireVersion else {
            return .malformed(.wrongWireVersion)
        }
        guard let key = record.encryptedValues[Field.publicKey.rawValue] as? Data,
              key.count == ApprovalSigning.publicKeyByteCount, key.first == 0x04 else {
            return .malformed(.malformedPublicKey)
        }
        guard let confirmation = record.encryptedValues[Field.confirmation.rawValue] as? Data,
              confirmation.count == ApprovalSigning.digestByteCount else { return .malformed(.malformedConfirmation) }
        guard let proof = record.encryptedValues[Field.proof.rawValue] as? Data,
              proof.count == ApprovalSigning.signatureByteCount else { return .malformed(.malformedProof) }
        return .response(PairingResponseClaim(publicKey: Array(key), confirmation: Array(confirmation), proof: Array(proof)))
    }
}

// MARK: - The pairing record, fetched and deleted (S-PAIR-C1.5, #170)

/// THE seam over CloudKit I/O for the pairing record: run this operation
/// against the owner's private database. Its one app conformer is the live
/// database `CloudKitMessageSender.makeLivePairingDatabase()` builds (the
/// container's own file, behind the entitlement probe), handed only to
/// `CloudKitPairingRecords`, which hands it only the two operations below
/// (all lint-locked).
protocol PairingRecordDatabase: AnyObject, Sendable {
    func submit(_ operation: CKFetchRecordsOperation)
    func submit(_ operation: CKModifyRecordsOperation)
}

/// The app's pairing record source: the ONE conformer to `PairingRecordSource`
/// in the four targets (lint-locked to this declaration's line). It reaches
/// the pairing record by its ID alone — the approvals zone and the name the
/// ceremony derived from its nonce: no query, no listing, no save — and it
/// acts only on a well-formed name (64 lowercase hex digits).
///
/// A fetch comes to one of three outcomes, a CLOSED mapping
/// (`fetchOutcome`): the record read → `found`, read strictly with that same
/// name (`PairingResponseReader`); no record by that ID (`unknownItem`) →
/// `nothing`; anything else — no network, a timeout, no iCloud account, no
/// approvals zone or schema yet, a build with no iCloud entitlement, any
/// other error — → `unreachable`, which the ceremony shows as "still trying"
/// until its window ends it. A deletion is the record path's own operation
/// (`ApprovalRecordWriter.makeOperation`), deleting that one record and
/// saving none; gone (deleted now, or never there) is true.
final class CloudKitPairingRecords: PairingRecordSource, @unchecked Sendable {
    private let makeDatabase: @Sendable () -> (any PairingRecordDatabase)?
    private let lock = NSLock()
    private var resolved = false
    private var live: (any PairingRecordDatabase)?

    /// `database` is asked once, on the first fetch or deletion
    /// (construction does no I/O); nil — a build with no iCloud entitlement —
    /// leaves every fetch unreachable and every deletion undone.
    init(database: @escaping @Sendable () -> (any PairingRecordDatabase)?) {
        makeDatabase = database
    }

    func fetch(recordName: String) async -> PairingFetch {
        guard PairingResponseCheck.isRecordName(recordName), let database = resolvedDatabase() else { return .unreachable }
        return await withCheckedContinuation { continuation in
            database.submit(Self.makeFetchOperation(recordName: recordName) { continuation.resume(returning: $0) })
        }
    }

    func delete(recordName: String) async -> Bool {
        guard PairingResponseCheck.isRecordName(recordName), let database = resolvedDatabase() else { return false }
        return await withCheckedContinuation { continuation in
            database.submit(ApprovalRecordWriter.makeOperation(saving: [], deleting: [Self.recordID(recordName)]) { outcome in
                continuation.resume(returning: outcome == .confirmed)
            })
        }
    }

    private func resolvedDatabase() -> (any PairingRecordDatabase)? {
        lock.lock()
        defer { lock.unlock() }
        if !resolved {
            live = makeDatabase()
            resolved = true
        }
        return live
    }

    /// The pairing record's ID: the approvals zone and the derived name.
    static func recordID(_ recordName: String) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: ApprovalRecordWriter.zoneID)
    }

    /// THE fetch operation, built here so a test can play CloudKit's part on
    /// the real thing: the one record by its ID, every field (the strict
    /// reading needs them all), the record path's request/resource ceiling,
    /// user-initiated. `completion` receives `fetchOutcome` once.
    static func makeFetchOperation(recordName: String, completion: @escaping @Sendable (PairingFetch) -> Void)
        -> CKFetchRecordsOperation {
        let operation = CKFetchRecordsOperation(recordIDs: [recordID(recordName)])
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        configuration.isLongLived = false
        configuration.timeoutIntervalForRequest = LidGuardTuning.requestTimeout
        configuration.timeoutIntervalForResource = LidGuardTuning.requestTimeout
        operation.configuration = configuration
        let fetched = FetchedRecord()
        operation.perRecordResultBlock = { _, result in fetched.note(result) }
        operation.fetchRecordsResultBlock = { batch in
            guard let outcome = fetched.finish(recordName: recordName, batch: batch) else { return }
            completion(outcome)
        }
        return operation
    }

    /// The closed mapping, the record's own result first:
    /// - the record came back → `found`, read strictly with the name asked
    ///   for; nothing else is ever `found`;
    /// - no record by that ID (`unknownItem`, alone or as the one item of a
    ///   partial failure), for the record or, with no result of its own, the
    ///   batch → `nothing`;
    /// - every other error, network-class included, and a batch that
    ///   reported no record at all → `unreachable`.
    static func fetchOutcome(recordName: String, record: Result<CKRecord, any Error>?,
                             batch: Result<Void, any Error>) -> PairingFetch {
        switch record {
        case .success(let read)?:
            return .found(PairingResponseReader.reading(of: read, expectedName: recordName))
        case .failure(let error)?:
            return isMissing(error) ? .nothing : .unreachable
        case nil:
            if case .failure(let error) = batch, isMissing(error) { return .nothing }
            return .unreachable
        }
    }

    /// No record by that ID: `unknownItem`, alone or as the one item of a
    /// partial failure.
    static func isMissing(_ error: any Error) -> Bool {
        ApprovalRecordWriter.isGone(CloudKitMessageSender.recordLevelError(error as NSError))
    }
}

/// Holds the record's own result until the batch result arrives, then says
/// what the fetch came to, once (`CloudKitPairingRecords.fetchOutcome`).
private final class FetchedRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var record: Result<CKRecord, any Error>?
    private var finished = false

    /// The first result is the record's.
    func note(_ result: Result<CKRecord, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        if record == nil { record = result }
    }

    func finish(recordName: String, batch: Result<Void, any Error>) -> PairingFetch? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        finished = true
        return CloudKitPairingRecords.fetchOutcome(recordName: recordName, record: record, batch: batch)
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
            let state = claim.signature.isEmpty ? "unsigned" : "signed"
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
