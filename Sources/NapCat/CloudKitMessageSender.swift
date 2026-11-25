import CloudKit
import Foundation
import NapCatWire
import os
import Security

/// SECOND SANCTIONED NETWORKING FILE (F3 stage 1, deliberate lint amendment):
/// the ONLY file that may import CloudKit or name a CloudKit symbol, and the
/// only one that reads this process's own entitlements. HTTP stays where it
/// was — `URLSession`/`URLRequest` remain confined to NtfyMessageSender.swift
/// (`LidGuardStructureTests` enforces both).
///
/// It writes one alert as one record into the owner's PRIVATE CloudKit
/// database (default zone of `AlertWire.containerIdentifier`):
///
///     record type  Alert
///     record name  <lane>-<epoch milliseconds>     (deterministic)
///     body         <the app-generated message>     String
///     lane         lid | session                   String
///     firedAt      <event time>                    Date
///
/// Nothing else: no session id, no ntfy topic, no ntfy server, no text from a
/// Claude session. `body` is built here by `LidGuardPolicy.messageBody` — the
/// very path NtfyMessageSender uses — from the closed `LidGuardMessageKind`,
/// so the phone receives byte-for-byte the text ntfy would have carried.
///
/// ENTITLEMENT GATE (spike-proven 2026-11-20): `CKContainer(identifier:)` does
/// not return an error in a process that lacks the iCloud entitlement — it
/// TRAPS (SIGTRAP, exit 133). Ad-hoc `make` builds are unentitled by design
/// (AMFI kills ad-hoc + restricted entitlements), so the container is built
/// in exactly ONE place, `makeLiveStore()`, behind
/// `CloudKitEntitlementProbe.isEntitled`, which reads the running process's
/// own entitlements and needs none itself. An unentitled process never
/// constructs a container.
///
/// OUTCOMES (frozen F3 ADR), in the shared `MessageSendOutcome` vocabulary:
/// - save committed → `accepted` (durably in iCloud; the push is async) — and
///   only when the record ITSELF reported saved (issue #139);
/// - a DEFINITIVE failure — nothing was committed and the composite may fall
///   back to ntfy without risking a double buzz → `sendFailed(<fixed text>)`:
///   no network, iCloud unreachable, not signed in / account unavailable,
///   container or entitlement problems, iCloud refusing the request outright
///   (quota exceeded, request rejected, permission denied — widened by owner
///   ruling g, 2026-11-20), and — for this attempt — iCloud rate-limiting or
///   temporarily unavailable;
/// - the record's OWN failure, whatever its code (issue #139): CloudKit's
///   verdict that this record was not committed → `sendFailed`; and a batch
///   success with no per-record result at all → `sendFailed` (a rare double
///   buzz is preferred to silence);
/// - a BATCH-level timeout, lost response, or anything not listed →
///   `timedOutUnconfirmed` (the record may have landed; never retried, never
///   fallen back).
///
/// PER-LANE SINGLE FLIGHT, mirroring NtfyMessageSender: a busy lane refuses a
/// second send inline; the other lane is unaffected.
///
/// THE PAIRING RECORD'S DATABASE (S-PAIR-C1.5, #170): the container and the
/// database stay in this file, so the pairing record's live database lives
/// here too (`makeLivePairingDatabase`, behind the same probe). It runs only
/// the two operations the record path builds for the pairing record (a
/// fetch by ID, a deletion of that record) and builds nothing itself — and,
/// since the C1.5 security review's R2, it checks what it is handed
/// (`PairingRecordGuard`) and refuses anything else.
///
/// UNPRIVILEGED — no sudo, no PLAN §4 command, no subprocess.
final class CloudKitMessageSender: MessageSender, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "phone")

    // MARK: Fixed failure vocabulary (never an error's own message)

    static let notEntitledText = "this NapCat build is not entitled to use iCloud"
    static let storeUnavailableText = "iCloud is not available to this NapCat build"
    static let noInternetText = "this Mac had no internet connection"
    static let unreachableText = "iCloud could not be reached"
    static let notSignedInText = "this Mac is not signed in to iCloud"
    static let restrictedText = "iCloud is restricted on this Mac"
    static let accountUnavailableText = "the iCloud account is temporarily unavailable"
    static let accountUncheckedText = "the iCloud account could not be checked"
    static let containerText = "the NapCat iCloud container is not set up"
    static let rateLimitedText = "iCloud is rate-limiting this Mac"
    static let serviceUnavailableText = "iCloud is temporarily unavailable"
    static let quotaExceededText = "the iCloud quota was exceeded"
    static let serverRejectedText = "iCloud rejected the request"
    static let permissionText = "iCloud denied permission to save the alert"
    static let refusedText = "iCloud refused the alert"
    static let unconfirmedSaveText = "iCloud did not confirm the alert"
    static let busyLaneText = "another message is still being sent"

    private let isEntitled: @Sendable () -> Bool
    private let makeStore: @Sendable () -> (any CloudKitAlertStore)?
    private let lock = NSLock()
    /// Built lazily on the first entitled send, then reused.
    private var store: (any CloudKitAlertStore)?
    private var sending: [NtfySendLane: Bool] = [:]
    private var generation: [NtfySendLane: UInt64] = [:]

    /// Both parameters are TEST SEAMS. Production uses the cached probe and
    /// the probe-gated live store; a test injects a fixture store (and a probe
    /// answer) so no CloudKit object that talks to iCloud is ever built.
    init(
        isEntitled: @escaping @Sendable () -> Bool = { CloudKitEntitlementProbe.isEntitled },
        makeStore: @escaping @Sendable () -> (any CloudKitAlertStore)? = { CloudKitMessageSender.makeLiveStore() }
    ) {
        self.isEntitled = isEntitled
        self.makeStore = makeStore
    }

    /// THE ONE place a CKContainer is constructed — and only after the probe
    /// confirmed this process is entitled (an unentitled construction traps).
    /// `PhoneTransportStructureTests` locks both the single site and the
    /// guard in front of it.
    static func makeLiveStore() -> (any CloudKitAlertStore)? {
        guard CloudKitEntitlementProbe.isEntitled else { return nil }
        return LiveCloudKitAlertStore(container: CKContainer(identifier: AlertWire.containerIdentifier))
    }

    /// S-PAIR-C1.5 (#170): the OTHER place a CKContainer is constructed —
    /// for the pairing record's live database, behind the same probe guard
    /// (an unentitled build gets nil: its ceremony shows its code and waits,
    /// "iCloud is unreachable", until the window ends). Called only by the
    /// pairing controller's record source, on its first fetch or deletion
    /// (`PhoneTransportStructureTests` locks both factories alike).
    static func makeLivePairingDatabase() -> (any PairingRecordDatabase)? {
        guard CloudKitEntitlementProbe.isEntitled else { return nil }
        return LivePairingRecordDatabase(container: CKContainer(identifier: ApprovalWire.containerIdentifier))
    }

    // MARK: - Record construction (pure — unit-tested without iCloud)

    /// The wire value of a send lane.
    static func wireLane(_ lane: NtfySendLane) -> AlertWire.Lane {
        switch lane {
        case .lid: return .lid
        case .session: return .session
        }
    }

    /// Deterministic: `<lane>-<epoch milliseconds>`. A retry of the same
    /// message names the same record. Never a session id, never the topic.
    static func recordName(lane: AlertWire.Lane, firedAt: Date) -> String {
        let millis = Int64((firedAt.timeIntervalSince1970 * 1000).rounded(.down))
        return "\(lane.rawValue)-\(millis)"
    }

    /// The ONLY constructor of a `CloudKitAlertPayload`. The body comes from
    /// the same template NtfyMessageSender publishes — the closed kind plus
    /// the event clock time — so no caller text can reach a record.
    static func makePayload(kind: LidGuardMessageKind, firedAt: Date) -> CloudKitAlertPayload {
        let lane = wireLane(LidGuardPolicy.lane(for: kind))
        return CloudKitAlertPayload(
            recordName: recordName(lane: lane, firedAt: firedAt),
            body: LidGuardPolicy.messageBody(kind: kind, clockTime: LidGuardPolicy.clockTime(firedAt)),
            lane: lane,
            firedAt: firedAt
        )
    }

    /// The record for one payload: type `Alert`, the private database's
    /// DEFAULT zone, and exactly the three `AlertWire.Field`s.
    static func makeRecord(_ payload: CloudKitAlertPayload) -> CKRecord {
        let recordID = CKRecord.ID(recordName: payload.recordName, zoneID: CKRecordZone.ID.default)
        let record = CKRecord(recordType: AlertWire.recordType, recordID: recordID)
        record[AlertWire.Field.body.rawValue] = payload.body as NSString
        record[AlertWire.Field.lane.rawValue] = payload.lane.rawValue as NSString
        record[AlertWire.Field.firedAt.rawValue] = payload.firedAt as NSDate
        return record
    }

    // MARK: - Send

    func send(
        _ kind: LidGuardMessageKind,
        to destination: NtfyDestination,
        at firedAt: Date,
        completion: @escaping @Sendable (MessageSendOutcome) -> Void
    ) {
        // `destination` is the ntfy address. It is deliberately NOT used: an
        // iCloud record carries neither the topic nor the server.
        guard isEntitled() else {
            completion(.sendFailed(Self.notEntitledText))
            return
        }
        guard let store = resolvedStore() else {
            Self.logger.error("phone: the iCloud store could not be built")
            completion(.sendFailed(Self.storeUnavailableText))
            return
        }
        let payload = Self.makePayload(kind: kind, firedAt: firedAt)

        // SINGLE-FLIGHT PER LANE, exactly as the ntfy sender.
        let lane = LidGuardPolicy.lane(for: kind)
        lock.lock()
        guard !sending[lane, default: false] else {
            lock.unlock()
            completion(.sendFailed(Self.busyLaneText))
            return
        }
        sending[lane] = true
        let claim = generation[lane, default: 0] &+ 1
        generation[lane] = claim
        lock.unlock()

        // Account first: a save without an available account cannot succeed,
        // and NOTHING has left the Mac yet, so any refusal here is definitive.
        store.accountStatus { [weak self] status, error in
            if let refusal = Self.accountRefusal(status: status, error: error) {
                self?.clear(claim, on: lane)
                completion(refusal)
                return
            }
            store.save(payload) { [weak self] error in
                self?.clear(claim, on: lane)
                completion(Self.classifySave(error))
            }
        }
    }

    private func resolvedStore() -> (any CloudKitAlertStore)? {
        lock.lock()
        defer { lock.unlock() }
        if let store { return store }
        store = makeStore()
        return store
    }

    /// Releases `lane`'s claim ONLY when `claim` is still that lane's live one.
    private func clear(_ claim: UInt64, on lane: NtfySendLane) {
        lock.lock()
        if generation[lane] == claim { sending[lane] = false }
        lock.unlock()
    }

    // MARK: - Outcome classification (pure, fixture-tested)

    /// The account check, BEFORE anything is saved: `nil` = available, go
    /// ahead; anything else is a definitive `sendFailed` with a fixed text.
    static func accountRefusal(status: CKAccountStatus, error: (any Error)?) -> MessageSendOutcome? {
        if let error {
            if case .sendFailed(let detail) = classifySave(error) { return .sendFailed(detail) }
            return .sendFailed(accountUncheckedText)
        }
        switch status {
        case .available: return nil
        case .noAccount: return .sendFailed(notSignedInText)
        case .restricted: return .sendFailed(restrictedText)
        case .temporarilyUnavailable: return .sendFailed(accountUnavailableText)
        case .couldNotDetermine: return .sendFailed(accountUncheckedText)
        @unknown default: return .sendFailed(accountUncheckedText)
        }
    }

    /// One save's outcome (frozen F3 ADR, amended by issue #139):
    /// - no error → `accepted`;
    /// - `CloudKitSaveUnconfirmed` (batch success, no per-record result) →
    ///   `sendFailed(unconfirmedSaveText)`;
    /// - `CloudKitRecordRefusal` (the record's own failure) → `sendFailed`
    ///   ALWAYS: the code's fixed sentence where the definitive list has one,
    ///   otherwise `refusedText`;
    /// - for a BATCH-level error, unchanged:
    ///   - a TIMEOUT-class transport error underneath (timed out, cancelled,
    ///     connection lost — `LidGuardPolicy.unconfirmedTransportErrorCodes`) →
    ///     `timedOutUnconfirmed`, whatever CloudKit code carries it: the record
    ///     may have landed, so it must never be fallen back from (double buzz);
    ///   - a CloudKit code in the definitive list (`definitiveFailureText`) →
    ///     `sendFailed` with that code's fixed sentence;
    ///   - anything else, any other error domain included → `timedOutUnconfirmed`.
    ///   A one-record `partialFailure` is judged by the record's own error.
    static func classifySave(_ error: (any Error)?) -> MessageSendOutcome {
        guard let error else { return .accepted }
        if error is CloudKitSaveUnconfirmed { return .sendFailed(unconfirmedSaveText) }
        if let refusal = error as? CloudKitRecordRefusal { return .sendFailed(refusalText(refusal.error)) }
        let nsError = recordLevelError(error as NSError)
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain,
           LidGuardPolicy.unconfirmedTransportErrorCodes.contains(underlying.code) {
            return .timedOutUnconfirmed
        }
        guard nsError.domain == CKErrorDomain,
              let code = CKError.Code(rawValue: nsError.code),
              let detail = definitiveFailureText(code) else {
            return .timedOutUnconfirmed
        }
        return .sendFailed(detail)
    }

    /// The DEFINITIVE codes (nothing was committed), each with a fixed,
    /// secret-free sentence; nil for every other code — at the BATCH level a
    /// new or unknown code stays unconfirmed (the safe direction: no
    /// fallback, no double buzz). The record's own failure is definitive
    /// whatever its code (`refusalText`, issue #139).
    ///
    /// Owner ruling (g), 2026-11-20, added three refusals: `quotaExceeded`,
    /// `serverRejectedRequest` and `permissionFailure`. In each, iCloud turns
    /// the save down before committing anything, so the ntfy fallback cannot
    /// double-buzz. The live evidence was the F3 spike's burst: 21 saves in
    /// about 3 s, of which saves 3–20 came back `quotaExceeded` (25) and were
    /// never stored. Before the ruling those would have been unconfirmed, and
    /// the alert would have gone out nowhere.
    static func definitiveFailureText(_ code: CKError.Code) -> String? {
        switch code {
        case .networkUnavailable: return noInternetText
        case .networkFailure: return unreachableText
        case .notAuthenticated: return notSignedInText
        case .accountTemporarilyUnavailable: return accountUnavailableText
        case .badContainer: return containerText
        case .missingEntitlement: return notEntitledText
        case .requestRateLimited: return rateLimitedText
        case .serviceUnavailable: return serviceUnavailableText
        case .quotaExceeded: return quotaExceededText
        case .serverRejectedRequest: return serverRejectedText
        case .permissionFailure: return permissionText
        default: return nil
        }
    }

    /// A batch `partialFailure` around exactly ONE record error is that
    /// record's error; anything else is returned unchanged.
    static func recordLevelError(_ error: NSError) -> NSError {
        guard error.domain == CKErrorDomain, error.code == CKError.Code.partialFailure.rawValue,
              let partial = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Any],
              partial.count == 1, let only = partial.values.first as? NSError else {
            return error
        }
        return only
    }

    /// The sentence for the record's OWN failure (issue #139). CloudKit
    /// delivered it per record, so it is iCloud's verdict that this record
    /// was not committed: `sendFailed` whatever the code — the definitive
    /// list's sentence where it has one, `refusedText` for every other code
    /// and every other domain.
    static func refusalText(_ error: any Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == CKErrorDomain, let code = CKError.Code(rawValue: nsError.code),
              let detail = definitiveFailureText(code) else {
            return refusedText
        }
        return detail
    }

    // MARK: - Diagnostics (closed vocabulary)

    /// The ONLY thing a per-record failure may log (issue #139): the CloudKit
    /// code's name and number, e.g. `quotaExceeded (25)`. The name comes from
    /// the closed `codeName` switch; a code it does not name logs as
    /// `code N`, another domain as `non-CloudKit code N`. Never the error's
    /// own message or user info, a record name, the body or the topic.
    static func diagnosticCode(_ error: any Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == CKErrorDomain else { return "non-CloudKit code \(nsError.code)" }
        guard let name = CKError.Code(rawValue: nsError.code).flatMap(codeName) else {
            return "code \(nsError.code)"
        }
        return "\(name) (\(nsError.code))"
    }

    /// Every CloudKit code the oldest SDK in CI defines, by name. Closed on
    /// purpose: a newer or unknown code falls to `nil` (`code N` in the log)
    /// rather than to any text CloudKit supplies.
    static func codeName(_ code: CKError.Code) -> String? {
        switch code {
        case .internalError: return "internalError"
        case .partialFailure: return "partialFailure"
        case .networkUnavailable: return "networkUnavailable"
        case .networkFailure: return "networkFailure"
        case .badContainer: return "badContainer"
        case .serviceUnavailable: return "serviceUnavailable"
        case .requestRateLimited: return "requestRateLimited"
        case .missingEntitlement: return "missingEntitlement"
        case .notAuthenticated: return "notAuthenticated"
        case .permissionFailure: return "permissionFailure"
        case .unknownItem: return "unknownItem"
        case .invalidArguments: return "invalidArguments"
        case .serverRecordChanged: return "serverRecordChanged"
        case .serverRejectedRequest: return "serverRejectedRequest"
        case .assetFileNotFound: return "assetFileNotFound"
        case .assetFileModified: return "assetFileModified"
        case .incompatibleVersion: return "incompatibleVersion"
        case .constraintViolation: return "constraintViolation"
        case .operationCancelled: return "operationCancelled"
        case .changeTokenExpired: return "changeTokenExpired"
        case .batchRequestFailed: return "batchRequestFailed"
        case .zoneBusy: return "zoneBusy"
        case .badDatabase: return "badDatabase"
        case .quotaExceeded: return "quotaExceeded"
        case .zoneNotFound: return "zoneNotFound"
        case .limitExceeded: return "limitExceeded"
        case .userDeletedZone: return "userDeletedZone"
        case .tooManyParticipants: return "tooManyParticipants"
        case .alreadyShared: return "alreadyShared"
        case .referenceViolation: return "referenceViolation"
        case .managedAccountRestricted: return "managedAccountRestricted"
        case .participantMayNeedVerification: return "participantMayNeedVerification"
        case .serverResponseLost: return "serverResponseLost"
        case .assetNotAvailable: return "assetNotAvailable"
        case .accountTemporarilyUnavailable: return "accountTemporarilyUnavailable"
        default: return nil
        }
    }

    // MARK: - The save operation

    /// THE save operation for one payload, built here rather than inside the
    /// live store so a test can play CloudKit's part on the real thing — fire
    /// its per-record and batch callbacks by hand — with no container, no
    /// database and nothing sent. A new record only (never overwrite one that
    /// already exists), the same request/resource ceiling as an ntfy publish,
    /// user-initiated priority.
    ///
    /// What `completion` receives (issue #139 — batch success alone is NOT
    /// the record's verdict: `isAtomic` has no effect in the default zone,
    /// and CloudKit's Result overlay hands a batch `partialFailure` to the
    /// result block as SUCCESS, so a refused record arrives as batch success
    /// with the refusal only in the per-record callback):
    /// - the record reported saved and the batch succeeded → nil;
    /// - the record reported a failure → `CloudKitRecordRefusal`, whatever
    ///   the batch said;
    /// - the batch succeeded with no per-record result → `CloudKitSaveUnconfirmed`;
    /// - the batch failed and the record reported no failure → the batch
    ///   error, unchanged.
    static func makeSaveOperation(
        _ payload: CloudKitAlertPayload,
        completion: @escaping @Sendable ((any Error)?) -> Void
    ) -> CKModifyRecordsOperation {
        let operation = CKModifyRecordsOperation(recordsToSave: [makeRecord(payload)], recordIDsToDelete: nil)
        operation.savePolicy = .ifServerRecordUnchanged
        operation.isAtomic = true
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        configuration.isLongLived = false
        configuration.timeoutIntervalForRequest = LidGuardTuning.requestTimeout
        configuration.timeoutIntervalForResource = LidGuardTuning.requestTimeout
        operation.configuration = configuration
        let saveResult = RecordResultBox()
        operation.perRecordSaveBlock = { _, result in
            if case .failure(let error) = result {
                Self.logger.error("phone: iCloud refused the alert: \(Self.diagnosticCode(error), privacy: .public)")
            }
            saveResult.note(result)
        }
        operation.modifyRecordsResultBlock = { result in
            completion(saveResult.completionError(batch: result))
        }
        return operation
    }
}

/// The record's OWN failure, as CloudKit delivered it to the per-record
/// callback (issue #139) — always a definitive `sendFailed`.
struct CloudKitRecordRefusal: Error {
    let error: any Error
}

/// A batch success with no per-record result at all (issue #139): nothing
/// confirms the record landed — a definitive `sendFailed`.
struct CloudKitSaveUnconfirmed: Error {}

// MARK: - The payload and the CloudKit seam

/// One alert on its way to iCloud. Built ONLY by
/// `CloudKitMessageSender.makePayload(kind:firedAt:)`; its fields map 1:1 onto
/// the three `AlertWire.Field`s (plus the record name), and nothing else.
struct CloudKitAlertPayload: Equatable, Sendable {
    let recordName: String
    let body: String
    let lane: AlertWire.Lane
    let firedAt: Date
}

/// THE seam over CloudKit I/O: the account check and the one-record save.
/// Production is `LiveCloudKitAlertStore` (probe-gated); tests inject a
/// fixture, so no test ever talks to iCloud or builds a container. The save
/// takes a payload — never a String.
protocol CloudKitAlertStore: AnyObject, Sendable {
    func accountStatus(completion: @escaping @Sendable (CKAccountStatus, (any Error)?) -> Void)
    func save(_ payload: CloudKitAlertPayload, completion: @escaping @Sendable ((any Error)?) -> Void)
}

/// The real store: the owner's private database, one record per save
/// (`CloudKitMessageSender.makeSaveOperation`), with the same
/// request/resource ceiling as an ntfy publish and user-initiated priority (a
/// discretionary operation could be parked until some later network — we
/// want a fast, honest answer).
private final class LiveCloudKitAlertStore: CloudKitAlertStore, @unchecked Sendable {
    private let container: CKContainer
    private let database: CKDatabase

    init(container: CKContainer) {
        self.container = container
        self.database = container.privateCloudDatabase
    }

    func accountStatus(completion: @escaping @Sendable (CKAccountStatus, (any Error)?) -> Void) {
        container.accountStatus { status, error in completion(status, error) }
    }

    func save(_ payload: CloudKitAlertPayload, completion: @escaping @Sendable ((any Error)?) -> Void) {
        database.add(CloudKitMessageSender.makeSaveOperation(payload, completion: completion))
    }
}

/// The pairing record's live database (S-PAIR-C1.5, #170): the owner's
/// private database, running the operations the record path's pairing
/// source hands it — the fetch of one record by its ID, and the deletion of
/// that one record — as handed (each already configured there), once its
/// own check has passed them (`PairingRecordGuard`). It builds no record and
/// no operation of its own, and nothing but that source holds it
/// (lint-locked).
private final class LivePairingRecordDatabase: PairingRecordDatabase, @unchecked Sendable {
    private let container: CKContainer
    private let database: CKDatabase

    init(container: CKContainer) {
        self.container = container
        self.database = container.privateCloudDatabase
    }

    func submit(_ operation: CKFetchRecordsOperation) {
        guard PairingRecordGuard.admits(operation) else { return PairingRecordGuard.refuse(operation) }
        database.add(operation)
    }

    func submit(_ operation: CKModifyRecordsOperation) {
        guard PairingRecordGuard.admits(operation) else { return PairingRecordGuard.refuse(operation) }
        database.add(operation)
    }
}

/// The live pairing database's own check (S-PAIR-C1.5, the C1.5 security
/// review's R2). Whatever hands it an operation, it runs only the pairing
/// record's two: a fetch of exactly one record, and a deletion of exactly
/// one record that saves nothing — each by a pairing record's ID, the
/// approvals zone of this account and a pairing record name (64 lowercase
/// hex digits). Anything else is refused: never added to the database, and
/// its own result block is told `invalidArguments`, so its caller reads its
/// closed failure (a fetch unreachable, a deletion not done). The pairing
/// source hands it nothing else (ApprovalRecordPathStructureTests lock 10);
/// this holds even if something else ever does. Pure — unit-tested over the
/// real operations (CloudKitPairingRecordsTests) — and pinned whole, with
/// the two `submit`s that call it (PhoneTransportStructureTests).
enum PairingRecordGuard {
    static func admits(_ operation: CKFetchRecordsOperation) -> Bool {
        guard let ids = operation.recordIDs, ids.count == 1 else { return false }
        return isPairingRecord(ids[0])
    }

    static func admits(_ operation: CKModifyRecordsOperation) -> Bool {
        guard operation.recordsToSave?.isEmpty ?? true, let ids = operation.recordIDsToDelete, ids.count == 1 else { return false }
        return isPairingRecord(ids[0])
    }

    static func isPairingRecord(_ id: CKRecord.ID) -> Bool {
        id.zoneID.zoneName == ApprovalWire.zoneName && id.zoneID.ownerName == CKCurrentUserDefaultName
            && PairingResponseCheck.isRecordName(id.recordName)
    }

    static func refuse(_ operation: CKFetchRecordsOperation) {
        operation.fetchRecordsResultBlock?(.failure(CKError(.invalidArguments)))
    }

    static func refuse(_ operation: CKModifyRecordsOperation) {
        operation.modifyRecordsResultBlock?(.failure(CKError(.invalidArguments)))
    }
}

/// Holds the one record's own result until the batch result arrives, then
/// says what the save reports (see `CloudKitMessageSender.makeSaveOperation`).
private final class RecordResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reported = false
    private var failure: (any Error)?

    func note(_ result: Result<CKRecord, any Error>) {
        lock.lock()
        reported = true
        if case .failure(let error) = result { failure = error }
        lock.unlock()
    }

    func completionError(batch: Result<Void, any Error>) -> (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        switch batch {
        case .success:
            // Batch success is not the record's verdict (issue #139).
            if let failure { return CloudKitRecordRefusal(error: failure) }
            return reported ? nil : CloudKitSaveUnconfirmed()
        case .failure(let error):
            if let failure { return CloudKitRecordRefusal(error: failure) }
            return error
        }
    }
}

// MARK: - Entitlement probe

/// Reads THIS process's own iCloud entitlements — unprivileged, works in an
/// unentitled process, touches no daemon and no network. Entitled means BOTH
/// the CloudKit service and NapCat's container are granted; anything else
/// (ad-hoc `make` builds, the test runner) is unentitled.
enum CloudKitEntitlementProbe {
    static let servicesEntitlement = "com.apple.developer.icloud-services"
    static let containersEntitlement = "com.apple.developer.icloud-container-identifiers"
    static let cloudKitService = "CloudKit"

    /// Evaluated ONCE per process, on first use, then cached: a process's
    /// entitlements cannot change while it runs.
    static let isEntitled: Bool = grants(
        services: entitlementValue(servicesEntitlement),
        containers: entitlementValue(containersEntitlement)
    )

    /// Pure decision over the two raw entitlement values (table-tested).
    static func grants(services: Any?, containers: Any?) -> Bool {
        guard let services = services as? [String], services.contains(cloudKitService) else { return false }
        guard let containers = containers as? [String],
              containers.contains(AlertWire.containerIdentifier) else { return false }
        return true
    }

    private static func entitlementValue(_ key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }
}
