import CloudKit
import Foundation
import NapCatWire
import os

/// THE ONE CloudKit FILE of the receiver: the only file that imports
/// CloudKit and the only file that builds a container, in two places, each
/// behind `LiveCapability`: `makeLive()` for the alerts and, since
/// S-PAIR-C1.6 (#172), `makeLiveApprovalDatabase()` for the pairing
/// response (and, since #194, the prompts and their push subscription).
/// `CloudKitStructureTests` locks both.
///
/// It reads what the Mac's `CloudKitMessageSender` writes: one record per
/// alert in the owner's PRIVATE database, default zone of
/// `AlertWire.containerIdentifier`, record type `AlertWire.recordType`,
/// exactly the three `AlertWire.Field`s, named `<lane>-<epoch milliseconds>`.
///
/// The phone OWNS the alert push subscription (the frozen F3 ADR; the Mac
/// refuses to create it in Production), and since #194 the prompt one
/// (`makePromptSubscription`). The alert one's shape is the F3 spike's,
/// field for field: a query subscription on `AlertWire.recordType`,
/// TRUEPREDICATE, fires on record creation only, and a notification the
/// SYSTEM renders (title "NapCat", the record's `body` as the alert text,
/// default sound), so there is no notification service extension and the
/// app does not have to run for the iPhone to buzz.
actor CloudKitAlertSource: AlertSource {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat.phone", category: "cloudkit")

    /// The notification's title, as the frozen ADR has it.
    static let notificationTitle = "NapCat"
    /// The alert text's format: a key the app's strings do not define is
    /// used as the format itself, so "%1$@" with the `body` argument shows
    /// the record's body verbatim.
    static let notificationFormat = "%1$@"
    static let notificationSound = "default"

    private let database: any CloudKitAlertDatabase
    /// Set once the subscription is known to exist on the server; until
    /// then every `connect()` checks again (cheap: one fetch by ID).
    private var subscriptionReady = false

    /// `database` is the TEST SEAM. Production builds it only in
    /// `makeLive()`; tests inject a fixture database, so no test ever builds
    /// a container or talks to iCloud.
    init(database: any CloudKitAlertDatabase) {
        self.database = database
    }

    /// THE one place a container is built, and only in a build that can
    /// hold the iCloud entitlement (`LiveCapability`): an unentitled
    /// construction traps.
    static func makeLive() -> CloudKitAlertSource? {
        guard LiveCapability.isAvailable else { return nil }
        let container = CKContainer(identifier: AlertWire.containerIdentifier)
        return CloudKitAlertSource(database: LiveCloudKitAlertDatabase(container: container))
    }

    /// S-PAIR-C1.6 (#172): the OTHER place a container is built, for the
    /// approvals database the pairing response is written through, behind
    /// the same `LiveCapability` guard (an unentitled build gets nil, and its
    /// pairing writes nothing: `UnsentPairingWriter`). Called once, by the
    /// live inbox's factory (`RequestInbox.make`, since #194), which shares it
    /// with the live pairing and the live prompt source.
    static func makeLiveApprovalDatabase() -> (any CloudKitApprovalDatabase)? {
        guard LiveCapability.isAvailable else { return nil }
        let container = CKContainer(identifier: ApprovalWire.containerIdentifier)
        return LiveCloudKitApprovalDatabase(container: container)
    }

    // MARK: - AlertSource

    /// `.availableWithoutPush` until the subscription is confirmed on the
    /// server (created now, or found), so the pill never says "Connected"
    /// while nothing would be pushed.
    func connect() async -> AccountAvailability {
        let availability: AccountAvailability
        do {
            availability = Self.availability(try await database.accountStatus())
        } catch {
            Self.logger.error("account check failed (code \(Self.code(of: error)))")
            availability = .unavailable
        }
        guard availability == .available else { return availability }
        if !subscriptionReady {
            subscriptionReady = await ensureSubscription()
        }
        return subscriptionReady ? .available : .availableWithoutPush
    }

    func fetchRecent() async throws -> [PhoneAlert] {
        let records = try await database.records(matching: Self.makeQuery(), resultsLimit: AlertFeed.listLimit)
        let alerts = records.compactMap(Self.alert(from:))
        if alerts.count != records.count {
            Self.logger.info("skipped \(records.count - alerts.count) malformed record(s)")
        }
        return alerts
    }

    nonisolated func pushedRecordName(in userInfo: [AnyHashable: Any]) -> String? {
        Self.pushedRecordName(in: userInfo)
    }

    /// The pushed record, by ID, in the default zone (where the Mac writes
    /// and the only zone the subscription watches).
    func fetchAlert(named recordName: String) async throws -> PhoneAlert? {
        let record = try await database.record(for: CKRecord.ID(recordName: recordName, zoneID: .default))
        guard let alert = Self.alert(from: record) else {
            Self.logger.info("skipped 1 malformed pushed record")
            return nil
        }
        return alert
    }

    // MARK: - The push payload (pure, fixture-tested)

    /// The record name the alert subscription's push carries: only a query
    /// notification from `AlertWire.subscriptionID` for a default-zone
    /// record counts. Anything else (another subscription, a payload that
    /// is not CloudKit's, or one pruned of its record ID) is nil, and the
    /// query alone catches up.
    static func pushedRecordName(in userInfo: [AnyHashable: Any]) -> String? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              notification.subscriptionID == AlertWire.subscriptionID,
              let recordID = notification.recordID,
              recordID.zoneID.zoneName == CKRecordZone.ID.defaultZoneName,
              !recordID.recordName.isEmpty else { return nil }
        return recordID.recordName
    }

    // MARK: - The subscription (idempotent, fetch first)

    /// Fetches the subscription by its fixed ID and creates it only when the
    /// server has none, so there is never a second one (a second would buzz
    /// twice per alert). An existing one is left as it is. Returns whether
    /// it exists now; a refusal is logged and retried on the next connect.
    func ensureSubscription() async -> Bool {
        do {
            _ = try await database.subscription(for: AlertWire.subscriptionID)
            return true
        } catch where Self.isMissing(error) {
            do {
                try await database.save(Self.makeSubscription())
                Self.logger.info("push subscription created")
                return true
            } catch {
                Self.logger.error("push subscription not created (code \(Self.code(of: error)))")
                return false
            }
        } catch {
            Self.logger.error("push subscription check failed (code \(Self.code(of: error)))")
            return false
        }
    }

    /// The spike's subscription shape, exactly (F3 spike `--subscribe`).
    static func makeSubscription() -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: AlertWire.recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: AlertWire.subscriptionID,
            options: [.firesOnRecordCreation]
        )
        let info = CKSubscription.NotificationInfo()
        info.title = notificationTitle
        info.alertLocalizationKey = notificationFormat
        info.alertLocalizationArgs = [AlertWire.Field.body.rawValue]
        info.soundName = notificationSound
        subscription.notificationInfo = info
        return subscription
    }

    /// Fetching a subscription the server does not have fails with
    /// `unknownItem`, possibly wrapped in a one-item partial failure.
    static func isMissing(_ error: any Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == CKErrorDomain else { return false }
        if nsError.code == CKError.Code.unknownItem.rawValue { return true }
        guard nsError.code == CKError.Code.partialFailure.rawValue,
              let partial = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Any],
              partial.count == 1, let only = partial.values.first as? NSError else { return false }
        return only.domain == CKErrorDomain && only.code == CKError.Code.unknownItem.rawValue
    }

    // MARK: - The fetch (pure, fixture-tested)

    /// Every alert, newest first: the spike's proven query (TRUEPREDICATE,
    /// sorted by `firedAt` descending, which the deployed SORTABLE index
    /// serves).
    static func makeQuery() -> CKQuery {
        let query = CKQuery(recordType: AlertWire.recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: AlertWire.Field.firedAt.rawValue, ascending: false)]
        return query
    }

    /// One record as an alert, or nil when it is not a well-formed alert:
    /// another record type, a missing or mistyped field, an empty body, or a
    /// lane outside `AlertWire.Lane` (the F3 spike's own test records carry
    /// lane "spike"). The record name is kept verbatim: it is the dedupe key.
    static func alert(from record: CKRecord) -> PhoneAlert? {
        guard record.recordType == AlertWire.recordType,
              let body = record[AlertWire.Field.body.rawValue] as? String, !body.isEmpty,
              let rawLane = record[AlertWire.Field.lane.rawValue] as? String,
              let lane = AlertWire.Lane(rawValue: rawLane),
              let firedAt = record[AlertWire.Field.firedAt.rawValue] as? Date else { return nil }
        return PhoneAlert(body: body, lane: lane, firedAt: firedAt, recordName: record.recordID.recordName)
    }

    // MARK: - F4 permission prompts (slice S3; pure, fixture-tested)

    /// The dedicated approvals zone of the owner's private database, where
    /// the Mac writes prompt records (never the default zone the alerts use).
    static var approvalsZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: ApprovalWire.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// One PromptRequest record as a pending request, or nil when it is not
    /// a well-formed one: another record type or zone, a name that is not a
    /// prompt ID, a field outside the wire, a field stored in the clear that
    /// the wire encrypts (or the reverse), another wire version, a missing or
    /// mistyped value, or an unfit window (`PendingRequest.init`). Encrypted
    /// fields are read from the encrypted values only.
    static func pendingRequest(from record: CKRecord) -> PendingRequest? {
        typealias Field = ApprovalWire.PromptField
        guard record.recordType == ApprovalWire.RecordType.prompt.rawValue,
              record.recordID.zoneID.zoneName == ApprovalWire.zoneName,
              let id = PromptID(hex: record.recordID.recordName) else { return nil }
        let encrypted = Set(record.encryptedValues.allKeys())
        let plain = Set(record.allKeys()).subtracting(encrypted)
        guard encrypted == Set(ApprovalWire.encryptedPromptFields.map(\.rawValue)),
              plain.union(encrypted) == Set(Field.allCases.map(\.rawValue)),
              record[Field.wireVersion.rawValue] as? Int == ApprovalWire.wireVersion,
              let toolName = record.encryptedValues[Field.toolName.rawValue] as? String,
              let inputPreview = record.encryptedValues[Field.inputPreview.rawValue] as? String,
              let projectLabel = record.encryptedValues[Field.projectLabel.rawValue] as? String,
              let createdAt = record[Field.createdAt.rawValue] as? Date,
              let expiresAt = record[Field.expiresAt.rawValue] as? Date else { return nil }
        return PendingRequest(id: id, toolName: toolName, inputPreview: inputPreview, projectLabel: projectLabel,
                              createdAt: createdAt, expiresAt: expiresAt)
    }

    /// The prompt a push from the phone's prompt subscription announces: only
    /// a query notification from `ApprovalWire.promptSubscriptionID` for a
    /// record in the approvals zone whose name is a prompt ID counts. The
    /// alert subscription's pushes are never read as prompts, nor the reverse
    /// (`pushedRecordName`).
    static func pushedPromptID(in userInfo: [AnyHashable: Any]) -> PromptID? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              notification.subscriptionID == ApprovalWire.promptSubscriptionID,
              let recordID = notification.recordID,
              recordID.zoneID.zoneName == ApprovalWire.zoneName else { return nil }
        return PromptID(hex: recordID.recordName)
    }

    // MARK: - F4 decisions (slice S3; built and tested here, run by nothing yet)

    /// A decision's record: named after its prompt, by the wire's one
    /// spelling (`ApprovalWire.decisionRecordName`, since #194), so there is one
    /// decision record per prompt. A retry names the same record, and a
    /// second answer to the same prompt is refused by iCloud as already
    /// answered instead of being written twice. The Mac does not rely on the
    /// name: it reads the prompt ID from the record's own (encrypted) field.
    static func decisionRecordID(for promptID: PromptID) -> CKRecord.ID {
        CKRecord.ID(recordName: ApprovalWire.decisionRecordName(for: promptID), zoneID: approvalsZoneID)
    }

    /// THE one place a PromptDecision record is built: the wire's fields,
    /// each stored encrypted exactly when the wire lists it in
    /// `encryptedDecisionFields`. Since S-PAIR-B the decision carries the
    /// paired key's 64-byte signature (CL-1), encrypted like the verdict;
    /// the Mac still reads every decision as a claim until it verifies it.
    static func makeDecisionRecord(_ decision: PhoneDecision) -> CKRecord {
        let record = CKRecord(recordType: ApprovalWire.RecordType.decision.rawValue,
                              recordID: decisionRecordID(for: decision.promptID))
        for field in ApprovalWire.DecisionField.allCases {
            guard let value = decisionValue(field, of: decision) else { continue }
            if ApprovalWire.encryptedDecisionFields.contains(field) {
                record.encryptedValues[field.rawValue] = value
            } else {
                record[field.rawValue] = value
            }
        }
        return record
    }

    /// One field's value. Exhaustive on purpose: a new wire field does not
    /// compile until it is decided here.
    static func decisionValue(_ field: ApprovalWire.DecisionField, of decision: PhoneDecision) -> CKRecordValue? {
        switch field {
        case .wireVersion: return ApprovalWire.wireVersion as NSNumber
        case .promptID: return decision.promptID.hex as NSString
        case .verdict: return decision.verdict.rawValue as NSString
        case .decidedAt: return decision.decidedAt as NSDate
        case .signature: return decision.signature as NSData
        }
    }

    /// THE save operation for one decision, built here so a test can play
    /// CloudKit's part on the real thing. A new record only (never overwrite
    /// an answer), user-initiated, with the alert fetch's ceilings. What
    /// `completion` receives, once: `decisionOutcome`.
    static func makeDecisionSaveOperation(
        _ record: CKRecord,
        completion: @escaping @Sendable (DecisionWriteOutcome) -> Void
    ) -> CKModifyRecordsOperation {
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        operation.savePolicy = .ifServerRecordUnchanged
        operation.isAtomic = true
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        operation.configuration = configuration
        let saved = CreatedRecordResult()
        operation.perRecordSaveBlock = { _, result in saved.note(result.map { _ in () }) }
        operation.modifyRecordsResultBlock = { batch in
            guard let outcome = saved.finish(batch: batch) else { return }
            if outcome != .saved { logger.error("decision not saved (\(outcome.rawValue, privacy: .public))") }
            completion(outcome)
        }
        return operation
    }

    /// The record's OWN result first (CloudKit hands a refused record to the
    /// result block as a batch success; the Mac's issue #139):
    /// - refused because a decision for this prompt is saved already
    ///   (`serverRecordChanged`) → `alreadyAnswered`;
    /// - refused for any other reason → `failed`;
    /// - reported saved, and the batch agreed → `saved`;
    /// - the batch succeeded with no per-record result → `unconfirmed`;
    /// - the batch failed: a timeout-class transport error underneath →
    ///   `unconfirmed`; a code that means nothing was saved → `failed`;
    ///   anything else → `unconfirmed`.
    static func decisionOutcome(record: Result<Void, any Error>?, batch: Result<Void, any Error>) -> DecisionWriteOutcome {
        if case .failure(let error)? = record {
            let nsError = error as NSError
            let collided = nsError.domain == CKErrorDomain && nsError.code == CKError.Code.serverRecordChanged.rawValue
            return collided ? .alreadyAnswered : .failed
        }
        switch batch {
        case .success:
            return record == nil ? .unconfirmed : .saved
        case .failure(let error):
            let nsError = recordLevelError(error as NSError)
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSURLErrorDomain, unconfirmedTransportCodes.contains(underlying.code) {
                return .unconfirmed
            }
            if nsError.domain == CKErrorDomain, nsError.code == CKError.Code.serverRecordChanged.rawValue {
                return .alreadyAnswered
            }
            guard nsError.domain == CKErrorDomain, let code = CKError.Code(rawValue: nsError.code),
                  nothingSavedCodes.contains(code) else { return .unconfirmed }
            return .failed
        }
    }

    /// Transport errors after which a save may still have landed (the Mac's
    /// `LidGuardPolicy.unconfirmedTransportErrorCodes`).
    static let unconfirmedTransportCodes: Set<Int> = [
        URLError.timedOut.rawValue, URLError.cancelled.rawValue, URLError.networkConnectionLost.rawValue,
    ]

    /// CloudKit codes that mean nothing was saved (the Mac's definitive
    /// table, plus the two that say the approvals zone is not there, and
    /// `invalidArguments`: the live approvals database's refusal of an
    /// operation it does not run, which never reached CloudKit).
    static let nothingSavedCodes: Set<CKError.Code> = [
        .networkUnavailable, .networkFailure, .notAuthenticated, .accountTemporarilyUnavailable, .badContainer,
        .missingEntitlement, .requestRateLimited, .serviceUnavailable, .quotaExceeded, .serverRejectedRequest,
        .permissionFailure, .zoneNotFound, .userDeletedZone, .invalidArguments,
    ]

    /// A batch `partialFailure` around exactly one record error is that
    /// record's error; anything else is returned unchanged.
    static func recordLevelError(_ error: NSError) -> NSError {
        guard error.domain == CKErrorDomain, error.code == CKError.Code.partialFailure.rawValue,
              let partial = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Any],
              partial.count == 1, let only = partial.values.first as? NSError else { return error }
        return only
    }

    // MARK: - F4 pairing (slice S-PAIR-C1.5; run since S-PAIR-C1.6 by the live pairing)

    /// The pairing response's record: in the approvals zone, named by the
    /// name the Mac's nonce derives (64 lowercase hex digits; the response
    /// holds no other), so the Mac fetches it by that name alone.
    static func pairingResponseRecordID(_ response: PairingResponse) -> CKRecord.ID {
        CKRecord.ID(recordName: response.recordName, zoneID: approvalsZoneID)
    }

    /// THE one place a PairingResponse record is built: every
    /// `ApprovalWire.PairingResponseField`, each stored encrypted exactly when
    /// the wire lists it in `encryptedPairingResponseFields` — every field
    /// but the version.
    static func makePairingResponseRecord(_ response: PairingResponse) -> CKRecord {
        let record = CKRecord(recordType: ApprovalWire.RecordType.pairingResponse.rawValue,
                              recordID: pairingResponseRecordID(response))
        for field in ApprovalWire.PairingResponseField.allCases {
            let value = pairingResponseValue(field, of: response)
            if ApprovalWire.encryptedPairingResponseFields.contains(field) {
                record.encryptedValues[field.rawValue] = value
            } else {
                record[field.rawValue] = value
            }
        }
        return record
    }

    /// One field's value, the response's own. Exhaustive on purpose: a new
    /// wire field does not compile until it is decided here.
    static func pairingResponseValue(_ field: ApprovalWire.PairingResponseField, of response: PairingResponse) -> CKRecordValue {
        switch field {
        case .wireVersion: return response.wireVersion as NSNumber
        case .publicKey: return response.publicKey as NSData
        case .confirmation: return response.confirmation as NSData
        case .proof: return response.proof as NSData
        }
    }

    /// THE save operation for the pairing response, built here so a test
    /// can play CloudKit's part on the real thing. CREATE-ONLY, like a
    /// decision's: the record is new (it has no change tag), so if one by its
    /// name exists the server refuses it (`serverRecordChanged`) instead of
    /// overwriting it. What `completion` receives, once: `pairingOutcome`.
    static func makePairingResponseSaveOperation(
        _ record: CKRecord,
        completion: @escaping @Sendable (PairingWriteOutcome) -> Void
    ) -> CKModifyRecordsOperation {
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        operation.savePolicy = .ifServerRecordUnchanged
        operation.isAtomic = true
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        operation.configuration = configuration
        let saved = CreatedRecordResult()
        operation.perRecordSaveBlock = { _, result in saved.note(result.map { _ in () }) }
        operation.modifyRecordsResultBlock = { batch in
            guard let outcome = saved.finish(batch: batch).map(pairingOutcome) else { return }
            if outcome != .saved { logger.error("pairing response not saved (\(outcome.rawValue, privacy: .public))") }
            completion(outcome)
        }
        return operation
    }

    /// The pairing response's outcome: a decision's table, case for case
    /// (`decisionOutcome`; both are create-only saves of one new record). A
    /// response for this code saved already is `alreadyAnswered`, judged by
    /// the error's code alone: the record the server holds is never read,
    /// adopted or shown (S-PAIR amendment 1).
    static func pairingOutcome(_ outcome: DecisionWriteOutcome) -> PairingWriteOutcome {
        switch outcome {
        case .saved: return .saved
        case .alreadyAnswered: return .alreadyAnswered
        case .failed: return .failed
        case .unconfirmed: return .unconfirmed
        }
    }

    /// What the live approvals database runs (S-PAIR-C1.6, #172), checked on
    /// the operation it is handed: the pairing response's create-only save
    /// and nothing else. Exactly one record to save and none to delete; a
    /// PairingResponse, NEW (no change tag), in this account's approvals
    /// zone, named by 64 lowercase hex digits; saved under
    /// `.ifServerRecordUnchanged`, so a response saved already is refused,
    /// never overwritten. A decision, a prompt, a deletion or an overwrite is
    /// never run: decisions stay unwired, and nothing arms.
    static func isPairingResponseCreation(_ operation: CKModifyRecordsOperation) -> Bool {
        guard operation.savePolicy == .ifServerRecordUnchanged, operation.recordIDsToDelete?.isEmpty ?? true,
              let records = operation.recordsToSave, records.count == 1, let record = records.first,
              record.recordType == ApprovalWire.RecordType.pairingResponse.rawValue, record.recordChangeTag == nil,
              record.recordID.zoneID == approvalsZoneID else { return false }
        let hex = Set("0123456789abcdef".utf8)
        let name = record.recordID.recordName.utf8
        return name.count == ApprovalSigning.recordNameHexDigits && name.allSatisfy(hex.contains)
    }

    // MARK: - F4 approvals zone (slice S-PAIR-C1.6; run by the live approvals database)

    /// The approvals zone's lookup, the first step of every pairing write
    /// (S-PAIR-C1.6, #172): the zone fetched by its ID, as Apple directs for
    /// a zone that may exist already (a zone object is never built for an
    /// existing zone). `then` hears once whether the zone is MISSING
    /// (`isZoneMissing`). A zone that exists, or a lookup that failed any
    /// other way, is not missing: nothing is created, and the pairing's save
    /// that follows decides on its own.
    ///
    /// The zone's OWN result decides first: CloudKit reports a zone that is
    /// not there on the zone (`perRecordZoneResultBlock`), and hands the
    /// lookup's result block a success for it (a partial failure never
    /// reaches that block as one: proven on the simulator's CloudKit), so a
    /// lookup that read its result block alone would never find the zone
    /// missing, and never create it.
    static func makeApprovalsZoneLookup(then: @escaping @Sendable (Bool) -> Void) -> CKFetchRecordZonesOperation {
        let lookup = CKFetchRecordZonesOperation(recordZoneIDs: [approvalsZoneID])
        lookup.configuration = approvalsZoneConfiguration
        let found = ZoneLookupResult()
        lookup.perRecordZoneResultBlock = { _, result in found.note(result) }
        lookup.fetchRecordZonesResultBlock = { batch in
            guard let result = found.finish(batch: batch) else { return }
            guard case .failure(let error) = result else { return then(false) }
            let missing = isZoneMissing(error)
            if !missing { logger.error("approvals zone lookup failed (code \(code(of: error)))") }
            then(missing)
        }
        return lookup
    }

    /// THE approvals zone's creation, its one site (S-PAIR-C1.6, #172):
    /// create only. One zone saved, none deleted, and only after the lookup
    /// found it missing, so an existing zone is never saved over. `then`
    /// runs once it ends, created or not: a zone still missing fails the
    /// save after it (`zoneNotFound` reads as unsent, dark), and a failure
    /// here, the zone's own or the operation's, is logged by its code.
    static func makeApprovalsZoneCreation(then: @escaping @Sendable () -> Void) -> CKModifyRecordZonesOperation {
        let creation = CKModifyRecordZonesOperation(recordZonesToSave: [CKRecordZone(zoneID: approvalsZoneID)],
                                                    recordZoneIDsToDelete: nil)
        creation.configuration = approvalsZoneConfiguration
        creation.perRecordZoneSaveBlock = { _, result in
            if case .failure(let error) = result { logger.error("approvals zone not created (code \(code(of: error)))") }
        }
        creation.modifyRecordZonesResultBlock = { result in
            if case .failure(let error) = result { logger.error("approvals zone not created (code \(code(of: error)))") }
            then()
        }
        return creation
    }

    /// A lookup's error that says the zone is not there: `zoneNotFound`, or
    /// `userDeletedZone` (the owner deleted the app's iCloud data, and now
    /// pairs again), on its own or as a one-item partial failure.
    static func isZoneMissing(_ error: any Error) -> Bool {
        let nsError = recordLevelError(error as NSError)
        return nsError.domain == CKErrorDomain
            && (nsError.code == CKError.Code.zoneNotFound.rawValue || nsError.code == CKError.Code.userDeletedZone.rawValue)
    }

    /// The zone steps' ceilings: the pairing's save's own.
    static var approvalsZoneConfiguration: CKOperation.Configuration {
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return configuration
    }

    // MARK: - F4 permission prompts, received live (#194; run by the live approvals database)

    /// The prompt push's words: fixed, the same for every prompt. Nothing of
    /// a prompt reaches the push or the lock screen; the app shows it.
    static let promptNotificationBody = "A permission prompt is waiting on your Mac."

    /// THE prompt subscription (#194), the phone's second: a query subscription
    /// on PromptRequest records in the approvals zone, TRUEPREDICATE, on
    /// creation only, under `ApprovalWire.promptSubscriptionID`. Its push is
    /// the app's title over the fixed words above, with the default sound:
    /// no record field (no desired keys, no localization arguments), no
    /// action (no category) and no silent wake.
    static func makePromptSubscription() -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: ApprovalWire.RecordType.prompt.rawValue,
            predicate: NSPredicate(value: true),
            subscriptionID: ApprovalWire.promptSubscriptionID,
            options: [.firesOnRecordCreation]
        )
        subscription.zoneID = approvalsZoneID
        let info = CKSubscription.NotificationInfo()
        info.title = notificationTitle
        info.alertBody = promptNotificationBody
        info.soundName = notificationSound
        subscription.notificationInfo = info
        return subscription
    }

    /// Whether `subscription` is the prompt subscription exactly as made
    /// above: its ID, type, zone, trigger and predicate, and a push that
    /// says the fixed words and carries nothing of a record.
    static func isPromptSubscription(_ subscription: CKSubscription) -> Bool {
        guard let query = subscription as? CKQuerySubscription, let info = query.notificationInfo,
              query.subscriptionID == ApprovalWire.promptSubscriptionID,
              query.recordType == ApprovalWire.RecordType.prompt.rawValue, query.zoneID == approvalsZoneID,
              query.querySubscriptionOptions == [.firesOnRecordCreation],
              query.predicate.predicateFormat == "TRUEPREDICATE" else { return false }
        guard info.title == notificationTitle, info.alertBody == promptNotificationBody,
              info.soundName == notificationSound, info.alertLocalizationKey == nil,
              info.desiredKeys?.isEmpty ?? true, info.alertLocalizationArgs?.isEmpty ?? true,
              info.titleLocalizationArgs?.isEmpty ?? true, info.subtitleLocalizationArgs?.isEmpty ?? true else { return false }
        return info.category == nil && info.collapseIDKey == nil && !info.shouldSendContentAvailable
            && !info.shouldSendMutableContent
    }

    /// The prompt subscription's lookup: by its one ID. `then` hears once
    /// whether it was found, is missing, or could not be read.
    static func makePromptSubscriptionLookup(then: @escaping @Sendable (SubscriptionLookup) -> Void) -> CKFetchSubscriptionsOperation {
        let lookup = CKFetchSubscriptionsOperation(subscriptionIDs: [ApprovalWire.promptSubscriptionID])
        lookup.configuration = approvalsZoneConfiguration
        let found = PromptResults()
        lookup.perSubscriptionResultBlock = { _, result in found.note(item: result.map { _ in () }) }
        lookup.fetchSubscriptionsResultBlock = { batch in
            guard let result = found.finish(batch: batch) else { return }
            switch result {
            case .success(let read): then(read.items == 1 ? .found : .failed)
            case .failure(let error) where isMissing(error): then(.missing)
            case .failure(let error):
                logger.error("prompt subscription check failed (code \(code(of: error)))")
                then(.failed)
            }
        }
        return lookup
    }

    /// What the prompt subscription's lookup came to.
    enum SubscriptionLookup: Equatable, Sendable {
        case found
        case missing
        case failed
    }

    /// The prompt subscription's creation, run only after its lookup found
    /// it missing: the one subscription, nothing deleted. `then` hears once
    /// whether it is saved.
    static func makePromptSubscriptionSave(then: @escaping @Sendable (Bool) -> Void) -> CKModifySubscriptionsOperation {
        let change = CKModifySubscriptionsOperation(subscriptionsToSave: [makePromptSubscription()], subscriptionIDsToDelete: nil)
        change.configuration = approvalsZoneConfiguration
        let saved = PromptResults()
        change.perSubscriptionSaveBlock = { _, result in saved.note(item: result.map { _ in () }) }
        change.modifySubscriptionsResultBlock = { batch in
            guard let result = saved.finish(batch: batch) else { return }
            switch result {
            case .success(let read): then(read.items == 1)
            case .failure(let error):
                logger.error("prompt subscription not created (code \(code(of: error)))")
                then(false)
            }
        }
        return change
    }

    /// The prompt subscription's removal, as the owner's switch goes off:
    /// its one ID, nothing saved. `then` hears once whether it is gone (a
    /// subscription that was not there is gone).
    static func makePromptSubscriptionRemoval(then: @escaping @Sendable (Bool) -> Void) -> CKModifySubscriptionsOperation {
        let change = CKModifySubscriptionsOperation(subscriptionsToSave: nil, subscriptionIDsToDelete: [ApprovalWire.promptSubscriptionID])
        change.configuration = approvalsZoneConfiguration
        let removed = PromptResults()
        change.perSubscriptionDeleteBlock = { _, result in removed.note(item: result) }
        change.modifySubscriptionsResultBlock = { batch in
            guard let result = removed.finish(batch: batch) else { return }
            switch result {
            case .success(let read): then(read.items == 1)
            case .failure(let error) where isMissing(error): then(true)
            case .failure(let error):
                logger.error("prompt subscription not removed (code \(code(of: error)))")
                then(false)
            }
        }
        return change
    }

    /// The fields a snapshot asks for: the prompt's six, and no other.
    static var promptKeys: [CKRecord.FieldKey] {
        ApprovalWire.PromptField.allCases.map(\.rawValue)
    }

    /// THE snapshot of the approvals zone (#194): every record it holds now (no
    /// change token), each with the prompt's six fields only. A prompt is
    /// read as it arrives (`pendingRequest(from:)`) and every other record is
    /// dropped unread. `then` hears once the prompts the Mac offers, or nil
    /// when any part of the read failed: a failed read changes nothing.
    static func makePromptSnapshot(then: @escaping @Sendable ([PendingRequest]?) -> Void) -> CKFetchRecordZoneChangesOperation {
        let zone = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        zone.desiredKeys = promptKeys
        let snapshot = CKFetchRecordZoneChangesOperation(recordZoneIDs: [approvalsZoneID],
                                                         configurationsByRecordZoneID: [approvalsZoneID: zone])
        snapshot.configuration = approvalsZoneConfiguration
        let read = PromptResults()
        snapshot.recordWasChangedBlock = { _, result in read.note(record: result.map { pendingRequest(from: $0) }) }
        snapshot.recordZoneFetchResultBlock = { _, result in
            if case .failure(let error) = result { read.note(item: .failure(error)) }
        }
        snapshot.fetchRecordZoneChangesResultBlock = { batch in
            guard let result = read.finish(batch: batch) else { return }
            switch result {
            case .success(let offered): then(offered.prompts)
            case .failure(let error):
                logger.error("prompt snapshot failed (code \(code(of: error)))")
                then(nil)
            }
        }
        return snapshot
    }

    /// What the live approvals database runs for an answer (#194): a
    /// decision's create-only save and nothing else. Exactly one record to
    /// save and none to delete; a PromptDecision, NEW (no change tag), in
    /// this account's approvals zone, named by the wire's decision name
    /// for the prompt its own `promptID` field names; saved under
    /// `.ifServerRecordUnchanged`, so a decision saved already is refused,
    /// never overwritten. Nothing builds a decision writer yet: nothing arms.
    static func isDecisionCreation(_ operation: CKModifyRecordsOperation) -> Bool {
        guard operation.savePolicy == .ifServerRecordUnchanged, operation.recordIDsToDelete?.isEmpty ?? true,
              let records = operation.recordsToSave, records.count == 1, let record = records.first,
              record.recordType == ApprovalWire.RecordType.decision.rawValue, record.recordChangeTag == nil,
              record.recordID.zoneID == approvalsZoneID,
              let promptHex = record.encryptedValues[ApprovalWire.DecisionField.promptID.rawValue] as? String,
              let promptID = PromptID(hex: promptHex) else { return false }
        return record.recordID.recordName == ApprovalWire.decisionRecordName(for: promptID)
    }

    /// What the live approvals database runs for a read (#194): the snapshot
    /// alone. The approvals zone only, from the start (no change token),
    /// every change fetched, asking for exactly the prompt's six fields.
    static func isPromptSnapshot(_ snapshot: CKFetchRecordZoneChangesOperation) -> Bool {
        guard snapshot.recordZoneIDs == [approvalsZoneID], snapshot.fetchAllChanges,
              let zones = snapshot.configurationsByRecordZoneID, zones.count == 1, let zone = zones[approvalsZoneID],
              zone.previousServerChangeToken == nil, let keys = zone.desiredKeys else { return false }
        return keys.count == promptKeys.count && Set(keys) == Set(promptKeys)
    }

    /// What the live approvals database runs for a lookup (#194): the prompt
    /// subscription's, by its one ID.
    static func isPromptSubscriptionLookup(_ lookup: CKFetchSubscriptionsOperation) -> Bool {
        lookup.subscriptionIDs == [ApprovalWire.promptSubscriptionID]
    }

    /// What the live approvals database runs for a change (#194): the prompt
    /// subscription saved, exactly as made (`isPromptSubscription`), with
    /// nothing deleted; or it alone deleted, with nothing saved.
    static func isPromptSubscriptionChange(_ change: CKModifySubscriptionsOperation) -> Bool {
        let saved: [CKSubscription] = change.subscriptionsToSave ?? []
        let removed: [CKSubscription.ID] = change.subscriptionIDsToDelete ?? []
        if removed.isEmpty { return saved.count == 1 && saved.allSatisfy(isPromptSubscription) }
        return saved.isEmpty && removed == [ApprovalWire.promptSubscriptionID]
    }

    /// Accounts other than `available` cannot receive anything.
    static func availability(_ status: CKAccountStatus) -> AccountAvailability {
        status == .available ? .available : .unavailable
    }

    /// A log-safe error code (a number only, never an error's own text).
    static func code(of error: any Error) -> Int {
        (error as NSError).code
    }
}

// MARK: - The CloudKit seam

/// THE seam over CloudKit I/O: the account check, the subscription fetch and
/// save, the alert query and the fetch of one pushed record. Production is
/// `LiveCloudKitAlertDatabase` (built only by `CloudKitAlertSource.makeLive()`);
/// tests inject a fixture.
protocol CloudKitAlertDatabase: Sendable {
    func accountStatus() async throws -> CKAccountStatus
    /// Throws `unknownItem` when the server has no subscription with that ID.
    func subscription(for subscriptionID: CKSubscription.ID) async throws -> CKSubscription
    func save(_ subscription: CKSubscription) async throws
    /// The matching records; a record that failed to load individually is
    /// left out.
    func records(matching query: CKQuery, resultsLimit: Int) async throws -> [CKRecord]
    /// One record by ID; throws `unknownItem` when the server has none.
    func record(for recordID: CKRecord.ID) async throws -> CKRecord
}

/// The real database: the owner's private database, user-initiated (a
/// discretionary request could be parked until some later network).
private struct LiveCloudKitAlertDatabase: CloudKitAlertDatabase {
    let container: CKContainer

    private var configuration: CKOperation.Configuration {
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return configuration
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    func subscription(for subscriptionID: CKSubscription.ID) async throws -> CKSubscription {
        try await container.privateCloudDatabase.configuredWith(configuration: configuration) { database in
            try await database.subscription(for: subscriptionID)
        }
    }

    func save(_ subscription: CKSubscription) async throws {
        _ = try await container.privateCloudDatabase.configuredWith(configuration: configuration) { database in
            try await database.save(subscription)
        }
    }

    func records(matching query: CKQuery, resultsLimit: Int) async throws -> [CKRecord] {
        try await container.privateCloudDatabase.configuredWith(configuration: configuration) { database in
            // `inZoneWith: nil` is the default zone, where the Mac writes.
            let (matches, _) = try await database.records(matching: query, inZoneWith: nil, resultsLimit: resultsLimit)
            return matches.compactMap { try? $0.1.get() }
        }
    }

    func record(for recordID: CKRecord.ID) async throws -> CKRecord {
        try await container.privateCloudDatabase.configuredWith(configuration: configuration) { database in
            try await database.record(for: recordID)
        }
    }
}

// MARK: - F4 decisions: the writer and its seam (slice S3)

/// THE seam over CloudKit I/O for decisions (and, since S-PAIR-C1.5, the
/// pairing response; since #194, the prompts' snapshot and their push
/// subscription): run this operation against the owner's private database.
/// Since S-PAIR-C1.6 (#172) the app has ONE conformer,
/// `LiveCloudKitApprovalDatabase` (lint-locked to its declaration's line),
/// built once per launch and shared by the live pairing and the live prompt
/// source; test fakes play the rest.
protocol CloudKitApprovalDatabase: Sendable {
    func submit(_ operation: CKModifyRecordsOperation)
    func submit(_ snapshot: CKFetchRecordZoneChangesOperation)
    func submit(_ lookup: CKFetchSubscriptionsOperation)
    func submit(_ change: CKModifySubscriptionsOperation)
}

/// The live approvals database (S-PAIR-C1.6, #172): the owner's PRIVATE
/// database, built only by `CloudKitAlertSource.makeLiveApprovalDatabase()`.
/// It checks what it is handed and runs exactly these (#194's admit list):
/// the pairing response's create-only save
/// (`CloudKitAlertSource.isPairingResponseCreation`), a decision's
/// create-only save (`isDecisionCreation`), the prompts' snapshot
/// (`isPromptSnapshot`), and the prompt subscription's lookup, save and
/// removal by its one ID (`isPromptSubscriptionLookup`,
/// `isPromptSubscriptionChange`). Anything else is never added: its own
/// result block is told `invalidArguments`, so its caller reads a closed
/// failure and never hangs.
///
/// Before a record save, the approvals zone: looked up, and created only
/// when missing, the app's one zone creation (zone-exists is success).
/// Whatever that came to, the save runs next, and its own result decides: a
/// zone that could not be made fails it (`zoneNotFound`), dark, never a
/// crash.
private struct LiveCloudKitApprovalDatabase: CloudKitApprovalDatabase {
    let container: CKContainer

    func submit(_ operation: CKModifyRecordsOperation) {
        guard CloudKitAlertSource.isPairingResponseCreation(operation) || CloudKitAlertSource.isDecisionCreation(operation) else {
            operation.modifyRecordsResultBlock?(.failure(CKError(.invalidArguments)))
            return
        }
        let database = container.privateCloudDatabase
        database.add(CloudKitAlertSource.makeApprovalsZoneLookup { missing in
            if missing {
                database.add(CloudKitAlertSource.makeApprovalsZoneCreation { database.add(operation) })
            } else {
                database.add(operation)
            }
        })
    }

    func submit(_ snapshot: CKFetchRecordZoneChangesOperation) {
        guard CloudKitAlertSource.isPromptSnapshot(snapshot) else {
            snapshot.fetchRecordZoneChangesResultBlock?(.failure(CKError(.invalidArguments)))
            return
        }
        container.privateCloudDatabase.add(snapshot)
    }

    func submit(_ lookup: CKFetchSubscriptionsOperation) {
        guard CloudKitAlertSource.isPromptSubscriptionLookup(lookup) else {
            lookup.fetchSubscriptionsResultBlock?(.failure(CKError(.invalidArguments)))
            return
        }
        container.privateCloudDatabase.add(lookup)
    }

    func submit(_ change: CKModifySubscriptionsOperation) {
        guard CloudKitAlertSource.isPromptSubscriptionChange(change) else {
            change.modifySubscriptionsResultBlock?(.failure(CKError(.invalidArguments)))
            return
        }
        container.privateCloudDatabase.add(change)
    }
}

/// The CloudKit `DecisionWriter`: one signed decision record per answer
/// (`CloudKitAlertSource.makeDecisionRecord`), saved through the seam. Built
/// by no app source yet (lint-locked): nothing arms.
struct CloudKitDecisionWriter: DecisionWriter {
    let database: any CloudKitApprovalDatabase

    func write(_ decision: PhoneDecision) async -> DecisionWriteOutcome {
        let record = CloudKitAlertSource.makeDecisionRecord(decision)
        return await withCheckedContinuation { continuation in
            database.submit(CloudKitAlertSource.makeDecisionSaveOperation(record) { continuation.resume(returning: $0) })
        }
    }
}

// MARK: - F4 pairing: the response writer (slice S-PAIR-C1.5)

/// The CloudKit `PairingResponseWriter` (S-PAIR-C1.5, #170): the pairing's
/// one record (`CloudKitAlertSource.makePairingResponseRecord`), created
/// through the approvals seam and never an overwrite. A response saved
/// already for the code reads as `alreadyAnswered`, and the record the
/// server holds is never read or adopted. Built once, by the live pairing's
/// wiring (`LivePairing.make`, S-PAIR-C1.6), over the live approvals
/// database (lint-locked).
struct CloudKitPairingResponseWriter: PairingResponseWriter {
    let database: any CloudKitApprovalDatabase

    func write(_ response: PairingResponse) async -> PairingWriteOutcome {
        let record = CloudKitAlertSource.makePairingResponseRecord(response)
        return await withCheckedContinuation { continuation in
            database.submit(CloudKitAlertSource.makePairingResponseSaveOperation(record) { continuation.resume(returning: $0) })
        }
    }
}

/// Holds one new record's own result (a decision, or the pairing response)
/// until the batch result arrives, then says what the save came to, once
/// (`CloudKitAlertSource.decisionOutcome`). It keeps only whether the
/// record saved or why it did not: a saved record is dropped unread.
private final class CreatedRecordResult: @unchecked Sendable {
    private let lock = NSLock()
    private var record: Result<Void, any Error>?
    private var finished = false

    /// A failure is kept over a success: the record's own refusal decides.
    func note(_ result: Result<Void, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        if case .failure = result {
            record = result
        } else if record == nil {
            record = result
        }
    }

    func finish(batch: Result<Void, any Error>) -> DecisionWriteOutcome? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        finished = true
        return CloudKitAlertSource.decisionOutcome(record: record, batch: batch)
    }
}

/// Holds the approvals zone's own failure, if its lookup reported one,
/// until the lookup's result arrives, then says once what the lookup came
/// to (S-PAIR-C1.6, #172): the zone's failure first, else the lookup's
/// result. A zone found is dropped unread: only whether it failed, and why.
private final class ZoneLookupResult: @unchecked Sendable {
    private let lock = NSLock()
    private var zoneFailure: (any Error)?
    private var finished = false

    func note(_ result: Result<CKRecordZone, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        if case .failure(let error) = result, zoneFailure == nil { zoneFailure = error }
    }

    func finish(batch: Result<Void, any Error>) -> Result<Void, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        finished = true
        return zoneFailure.map { .failure($0) } ?? batch
    }
}

/// Holds a prompt operation's per-item results until its batch result
/// arrives, then says once what came in (#194): how many items arrived, the
/// prompts among them (a snapshot's), or the first failure, an item's
/// before the batch's (CloudKit can hand the batch a success for a refused
/// item). A record that is no prompt is counted and dropped unread.
private final class PromptResults: @unchecked Sendable {
    private let lock = NSLock()
    private var items = 0
    private var prompts: [PendingRequest] = []
    private var failure: (any Error)?
    private var finished = false

    func note(item result: Result<Void, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        switch result {
        case .success: items += 1
        case .failure(let error): if failure == nil { failure = error }
        }
    }

    func note(record result: Result<PendingRequest?, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        switch result {
        case .success(let prompt):
            items += 1
            if let prompt { prompts.append(prompt) }
        case .failure(let error): if failure == nil { failure = error }
        }
    }

    func finish(batch: Result<Void, any Error>) -> Result<(items: Int, prompts: [PendingRequest]), any Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        finished = true
        if let failure { return .failure(failure) }
        if case .failure(let error) = batch { return .failure(error) }
        return .success((items, prompts))
    }
}
