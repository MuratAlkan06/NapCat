import CloudKit
import CryptoKit
import Foundation
import NapCatWire
@testable import NapCatPhone
import Testing

/// F4 slice S-PAIR-C1.5 (#170): the pairing response the phone writes, and
/// what each CloudKit answer to it means. The record is a plain value; the
/// operation is the real one, its callbacks fired by hand
/// (`ModifyOperationScript`) through the decisions' scripted seam. Nothing
/// reaches iCloud.
@Suite struct CloudKitPairingWriterTests {
    typealias Field = ApprovalWire.PairingResponseField
    static let nonce = Array((0..<32).map { UInt8(($0 * 5 + 3) & 0xff) })
    static let recordName = ApprovalSigning.pairingRecordNameInput(nonce: nonce)
        .flatMap { ApprovalSigning.pairingRecordName(digest: Array(SHA256.hash(data: $0))) }!
    static let publicKey = Data([0x04] + (1...64).map { UInt8($0) })
    static let confirmation = Data((0..<32).map { UInt8(0xa0 + $0) })
    static let proof = Data((0..<64).map { UInt8(0x40 ^ $0) })
    static let response = PairingResponse(recordName: recordName, wireVersion: ApprovalWire.wireVersion, publicKey: publicKey,
                                          confirmation: confirmation, proof: proof)!

    static func ck(_ code: CKError.Code, _ underlying: NSError? = nil) -> NSError {
        ModifyOperationScript.ck(code, underlying: underlying)
    }

    // MARK: The record

    /// The wire's PairingResponse, in the approvals zone, named by the
    /// response's own record name: the key, the confirmation MAC and the
    /// proof encrypted, the version alone in the clear, nothing else.
    @Test func theRecordIsTheWiresPairingResponse() {
        let record = CloudKitAlertSource.makePairingResponseRecord(Self.response)
        #expect(record.recordType == ApprovalWire.RecordType.pairingResponse.rawValue)
        #expect(record.recordID.zoneID.zoneName == ApprovalWire.zoneName)
        #expect(record.recordID.zoneID.ownerName == CKCurrentUserDefaultName)
        #expect(record.recordID.recordName == Self.recordName && Self.recordName.utf8.count == 64)
        let encrypted = Set(record.encryptedValues.allKeys())
        let plain = Set(record.allKeys()).subtracting(encrypted)
        #expect(encrypted == [Field.publicKey.rawValue, Field.confirmation.rawValue, Field.proof.rawValue])
        #expect(encrypted == Set(ApprovalWire.encryptedPairingResponseFields.map(\.rawValue)))
        #expect(plain == [Field.wireVersion.rawValue])
        #expect(Set(record.allKeys()) == Set(Field.allCases.map(\.rawValue)), "every wire field, nothing else")
        #expect(record[Field.wireVersion.rawValue] as? Int == ApprovalWire.wireVersion)
        #expect(record.encryptedValues[Field.publicKey.rawValue] as? Data == Self.publicKey)
        #expect(record.encryptedValues[Field.confirmation.rawValue] as? Data == Self.confirmation)
        #expect(record.encryptedValues[Field.proof.rawValue] as? Data == Self.proof)
    }

    /// One record per code: another nonce names another record, and none
    /// is a prompt's or a decision's.
    @Test func eachCodeHasItsOwnRecord() throws {
        let other = Array(Self.nonce.reversed())
        let otherName = try #require(ApprovalSigning.pairingRecordNameInput(nonce: other)
            .flatMap { ApprovalSigning.pairingRecordName(digest: Array(SHA256.hash(data: $0))) })
        let otherResponse = try #require(PairingResponse(recordName: otherName, wireVersion: ApprovalWire.wireVersion,
                                                         publicKey: Self.publicKey, confirmation: Self.confirmation, proof: Self.proof))
        #expect(CloudKitAlertSource.pairingResponseRecordID(otherResponse) != CloudKitAlertSource.pairingResponseRecordID(Self.response))
        #expect(PromptID(hex: Self.recordName) == nil, "a pairing record is never named as a prompt")
        #expect(!Self.recordName.hasSuffix("-decision"))
    }

    // MARK: Create only

    /// A new record only: a response saved already is never overwritten,
    /// and the write names nothing to delete.
    @Test func theSaveIsCreateOnly() async throws {
        let database = ScriptedApprovalDatabase(ModifyOperationScript([.saved(0), .batchSucceeded]))
        #expect(await CloudKitPairingResponseWriter(database: database).write(Self.response) == .saved)
        let operation = try #require(database.submitted.first)
        #expect(database.submitted.count == 1, "one write, one operation")
        #expect(operation.savePolicy == .ifServerRecordUnchanged)
        #expect(operation.isAtomic)
        #expect(operation.configuration.qualityOfService == .userInitiated)
        #expect(operation.recordsToSave?.map(\.recordID) == [CloudKitAlertSource.pairingResponseRecordID(Self.response)])
        #expect(operation.recordsToSave?.first?.recordChangeTag == nil, "a new record carries no change tag")
        #expect(operation.recordIDsToDelete?.isEmpty ?? true)
    }

    /// A conflict is `alreadyAnswered`, decided by the error's code alone:
    /// the record the server holds (handed back inside the error) is never
    /// read, adopted or shown, whatever it carries.
    @Test func aConflictNeverReadsTheRecordTheServerHolds() async {
        let theirs = CKRecord(recordType: ApprovalWire.RecordType.pairingResponse.rawValue,
                              recordID: CloudKitAlertSource.pairingResponseRecordID(Self.response))
        theirs.encryptedValues[Field.publicKey.rawValue] = Data([0x04] + Array(repeating: UInt8(0xee), count: 64)) as NSData
        let conflict = NSError(domain: CKErrorDomain, code: CKError.Code.serverRecordChanged.rawValue,
                               userInfo: [CKRecordChangedErrorServerRecordKey: theirs,
                                          CKRecordChangedErrorAncestorRecordKey: theirs,
                                          CKRecordChangedErrorClientRecordKey: theirs])
        for steps: [ModifyOperationScript.Step] in [[.saveFailed(0, conflict), .batchSucceeded],
                                                    [.saveFailed(0, conflict), .batchFailed(Self.ck(.partialFailure))],
                                                    [.batchFailed(conflict)]] {
            let database = ScriptedApprovalDatabase(ModifyOperationScript(steps))
            #expect(await CloudKitPairingResponseWriter(database: database).write(Self.response) == .alreadyAnswered)
        }
    }

    // MARK: Each record's own result counts

    struct Row: CustomTestStringConvertible, Sendable {
        let name: String
        let steps: [ModifyOperationScript.Step]
        let expected: PairingWriteOutcome
        var testDescription: String { name }
    }

    static let rows: [Row] = [
        Row(name: "saved + batch success", steps: [.saved(0), .batchSucceeded], expected: .saved),
        Row(name: "already answered + batch success", steps: [.saveFailed(0, ck(.serverRecordChanged)), .batchSucceeded],
            expected: .alreadyAnswered),
        Row(name: "already answered at the batch", steps: [.batchFailed(ck(.serverRecordChanged))], expected: .alreadyAnswered),
        Row(name: "refused (quotaExceeded) + batch success", steps: [.saveFailed(0, ck(.quotaExceeded)), .batchSucceeded],
            expected: .failed),
        Row(name: "refused (zoneNotFound) + batch success", steps: [.saveFailed(0, ck(.zoneNotFound)), .batchSucceeded],
            expected: .failed),
        Row(name: "refused (unknown record type) + batch success", steps: [.saveFailed(0, ck(.serverRejectedRequest)), .batchSucceeded],
            expected: .failed),
        Row(name: "batch success with no per-record result", steps: [.batchSucceeded], expected: .unconfirmed),
        Row(name: "batch failure (networkUnavailable)", steps: [.batchFailed(ck(.networkUnavailable))], expected: .failed),
        Row(name: "batch failure (notAuthenticated)", steps: [.batchFailed(ck(.notAuthenticated))], expected: .failed),
        Row(name: "batch failure (networkFailure over a timeout)",
            steps: [.batchFailed(ck(.networkFailure, ModifyOperationScript.url(.timedOut)))], expected: .unconfirmed),
        Row(name: "batch failure (serverResponseLost)", steps: [.batchFailed(ck(.serverResponseLost))], expected: .unconfirmed),
        Row(name: "saved + batch failure (internalError)", steps: [.saved(0), .batchFailed(ck(.internalError))],
            expected: .unconfirmed),
        Row(name: "batch failure from another domain", steps: [.batchFailed(NSError(domain: "x", code: 1))],
            expected: .unconfirmed),
    ]

    @Test(arguments: rows)
    func aWriteHonoursTheRecordsOwnResult(_ row: Row) async {
        let database = ScriptedApprovalDatabase(ModifyOperationScript(row.steps))
        #expect(await CloudKitPairingResponseWriter(database: database).write(Self.response) == row.expected)
    }

    /// The pairing outcome is the decision's table, case for case.
    @Test(arguments: [(DecisionWriteOutcome.saved, PairingWriteOutcome.saved), (.alreadyAnswered, .alreadyAnswered),
                      (.failed, .failed), (.unconfirmed, .unconfirmed)])
    func theOutcomeIsTheDecisionsTable(_ decision: DecisionWriteOutcome, _ pairing: PairingWriteOutcome) {
        #expect(CloudKitAlertSource.pairingOutcome(decision) == pairing)
    }

    /// The outcome is decided once, on the first batch result.
    @Test func aSecondBatchResultChangesNothing() async {
        let database = ScriptedApprovalDatabase(ModifyOperationScript([.saved(0), .batchSucceeded,
                                                                       .batchFailed(Self.ck(.serverRecordChanged))]))
        #expect(await CloudKitPairingResponseWriter(database: database).write(Self.response) == .saved)
    }

    // MARK: What the live approvals database runs (S-PAIR-C1.6, #172)

    /// One operation to hand the live database's check: these records to
    /// save, these to delete, under this policy.
    static func operation(saving records: [CKRecord]?, deleting ids: [CKRecord.ID]? = nil,
                          policy: CKModifyRecordsOperation.RecordSavePolicy = .ifServerRecordUnchanged) -> CKModifyRecordsOperation {
        let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: ids)
        operation.savePolicy = policy
        return operation
    }

    /// A record of `type` named `name` in `zone`.
    static func record(_ type: ApprovalWire.RecordType = .pairingResponse, named name: String = recordName,
                       in zone: CKRecordZone.ID = CloudKitAlertSource.approvalsZoneID) -> CKRecord {
        CKRecord(recordType: type.rawValue, recordID: CKRecord.ID(recordName: name, zoneID: zone))
    }

    /// The writer's own save is exactly what the live database runs.
    @Test func theWritersOwnSaveIsWhatTheLiveDatabaseRuns() async throws {
        let database = ScriptedApprovalDatabase(ModifyOperationScript([.saved(0), .batchSucceeded]))
        _ = await CloudKitPairingResponseWriter(database: database).write(Self.response)
        let operation = try #require(database.submitted.first)
        #expect(CloudKitAlertSource.isPairingResponseCreation(operation))
        #expect(CloudKitAlertSource.isPairingResponseCreation(Self.operation(saving: [Self.record()])))
    }

    struct Refused: CustomTestStringConvertible, Sendable {
        let name: String
        let make: @Sendable () -> CKModifyRecordsOperation
        var testDescription: String { name }
    }

    /// Everything else, each on its own: another record type, zone, owner
    /// or name; more records or none; a deletion; an overwrite.
    static let refused: [Refused] = {
        let other = CKRecordZone.ID(zoneName: ApprovalWire.zoneName, ownerName: "_someoneElse")
        let deletion = CKRecord.ID(recordName: recordName, zoneID: CloudKitAlertSource.approvalsZoneID)
        let prompt = PromptID(hex: String(repeating: "ab", count: 16))!
        let decision = CKRecord(recordType: ApprovalWire.RecordType.decision.rawValue,
                                recordID: CloudKitAlertSource.decisionRecordID(for: prompt))
        let upper = recordName.uppercased()
        let short = String(recordName.dropLast())
        let long = recordName + "a"
        let nonHex = String(recordName.dropLast()) + "g"
        return [
            Refused(name: "a decision's record") { operation(saving: [decision]) },
            Refused(name: "a prompt named like a pairing") { operation(saving: [record(.prompt)]) },
            Refused(name: "a decision named like a pairing") { operation(saving: [record(.decision)]) },
            Refused(name: "the default zone") { operation(saving: [record(in: .default)]) },
            Refused(name: "another owner's approvals zone") { operation(saving: [record(in: other)]) },
            Refused(name: "an uppercase name") { operation(saving: [record(named: upper)]) },
            Refused(name: "a short name") { operation(saving: [record(named: short)]) },
            Refused(name: "a long name") { operation(saving: [record(named: long)]) },
            Refused(name: "a name that is not hex") { operation(saving: [record(named: nonHex)]) },
            Refused(name: "two pairing records") { operation(saving: [record(), record(named: String(repeating: "c", count: 64))]) },
            Refused(name: "no record") { operation(saving: []) },
            Refused(name: "a deletion alone") { operation(saving: nil, deleting: [deletion]) },
            Refused(name: "a save beside a deletion") { operation(saving: [record()], deleting: [deletion]) },
            Refused(name: "an overwrite (all keys)") { operation(saving: [record()], policy: .allKeys) },
            Refused(name: "an overwrite (changed keys)") { operation(saving: [record()], policy: .changedKeys) },
        ]
    }()

    @Test(arguments: refused)
    func theLiveDatabaseRefusesEverythingElse(_ row: Refused) {
        #expect(!CloudKitAlertSource.isPairingResponseCreation(row.make()))
    }

    /// A refusal, as the live database makes it (lock 6c pins it): the
    /// operation is never run, and its own result block hears
    /// `invalidArguments`. The write ends at once, closed (never saved,
    /// never hanging).
    @Test func aRefusalIsAClosedFailureToTheWriter() async {
        let database = RefusingApprovalDatabase()
        #expect(await CloudKitPairingResponseWriter(database: database).write(Self.response) == .unconfirmed)
        #expect(database.refused == 1)
    }

    // MARK: The approvals zone (S-PAIR-C1.6, #172)

    struct ZoneRow: CustomTestStringConvertible, Sendable {
        let name: String
        /// The zone's own result (`perRecordZoneResultBlock`): nil when
        /// CloudKit reports none, else the zone's error, or none for found.
        let zone: NSError??
        /// The lookup's result (`fetchRecordZonesResultBlock`).
        let lookup: NSError?
        let missing: Bool
        var testDescription: String { name }
    }

    /// Only a zone that is not there reads as missing; a zone found, or a
    /// lookup that failed any other way, creates nothing. The zone's own
    /// result decides first: CloudKit reports a missing zone on the zone
    /// and the lookup as a success (`aPartialFailureReachesTheLookupAsASuccess`).
    static let zoneRows: [ZoneRow] = [
        ZoneRow(name: "found", zone: .some(nil), lookup: nil, missing: false),
        ZoneRow(name: "zoneNotFound on the zone", zone: ck(.zoneNotFound), lookup: nil, missing: true),
        ZoneRow(name: "userDeletedZone on the zone", zone: ck(.userDeletedZone), lookup: nil, missing: true),
        ZoneRow(name: "zoneNotFound for the whole lookup", zone: nil, lookup: ck(.zoneNotFound), missing: true),
        ZoneRow(name: "userDeletedZone for the whole lookup", zone: nil, lookup: ck(.userDeletedZone), missing: true),
        ZoneRow(name: "zoneNotFound on the zone, the lookup failing otherwise", zone: ck(.zoneNotFound), lookup: ck(.networkFailure),
                missing: true),
        ZoneRow(name: "the zone failing otherwise, the lookup saying zoneNotFound", zone: ck(.networkFailure),
                lookup: ck(.zoneNotFound), missing: false),
        ZoneRow(name: "unknownItem on the zone", zone: ck(.unknownItem), lookup: nil, missing: false),
        ZoneRow(name: "networkUnavailable for the whole lookup", zone: nil, lookup: ck(.networkUnavailable), missing: false),
        ZoneRow(name: "notAuthenticated for the whole lookup", zone: nil, lookup: ck(.notAuthenticated), missing: false),
        ZoneRow(name: "a two-zone partial failure for the whole lookup", zone: nil,
                lookup: ModifyOperationScript.partial([ck(.zoneNotFound), ck(.zoneNotFound)]), missing: false),
        ZoneRow(name: "zoneNotFound's code from another domain on the zone",
                zone: NSError(domain: "x", code: CKError.Code.zoneNotFound.rawValue), lookup: nil, missing: false),
        ZoneRow(name: "nothing reported for the zone", zone: nil, lookup: nil, missing: false),
    ]

    /// The lookup asks for the approvals zone alone, at the save's ceilings,
    /// and hands on once whether it is missing.
    @Test(arguments: zoneRows)
    func theLookupSaysMissingOnlyForAMissingZone(_ row: ZoneRow) throws {
        let heard = Notes<Bool>()
        let lookup = CloudKitAlertSource.makeApprovalsZoneLookup { heard.note($0) }
        #expect(lookup.recordZoneIDs == [CloudKitAlertSource.approvalsZoneID])
        #expect(lookup.configuration.qualityOfService == .userInitiated)
        let zoneID = CloudKitAlertSource.approvalsZoneID
        if case .some(let error) = row.zone {
            let perZone = try #require(lookup.perRecordZoneResultBlock, "the lookup reads the zone's own result")
            let zoneResult: Result<CKRecordZone, any Error> = error.map { .failure($0) } ?? .success(CKRecordZone(zoneID: zoneID))
            perZone(zoneID, zoneResult)
        }
        let result: Result<Void, any Error> = row.lookup.map { .failure($0) } ?? .success(())
        lookup.fetchRecordZonesResultBlock?(result)
        #expect(heard.all == [row.missing])
        // The lookup ends once: a second result changes nothing.
        lookup.fetchRecordZonesResultBlock?(.success(()))
        #expect(heard.all == [row.missing])
    }

    /// Why the zone's own result decides: a partial failure handed to the
    /// lookup's result block reaches it as a SUCCESS (CloudKit's Swift
    /// bridge reports each zone's error on the zone alone). Found on the
    /// simulator's CloudKit during S-PAIR-C1.6; if a later SDK changes it,
    /// this row says so, and the lookup above still reads the zone first.
    @Test func aPartialFailureReachesTheLookupAsASuccess() {
        let zoneID = CloudKitAlertSource.approvalsZoneID
        let byZone: [AnyHashable: Any] = [zoneID: Self.ck(.zoneNotFound)]
        let partial = NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue, userInfo: [CKPartialErrorsByItemIDKey: byZone])
        let arrived = Notes<Bool>()
        let lookup = CKFetchRecordZonesOperation(recordZoneIDs: [zoneID])
        lookup.fetchRecordZonesResultBlock = { result in
            if case .success = result { arrived.note(true) } else { arrived.note(false) }
        }
        lookup.fetchRecordZonesResultBlock?(.failure(partial))
        #expect(arrived.all == [true])
        // So a lookup handed only that partial failure finds nothing missing,
        // and its zone's own result is what says the zone is not there.
        let heard = Notes<Bool>()
        let real = CloudKitAlertSource.makeApprovalsZoneLookup { heard.note($0) }
        real.fetchRecordZonesResultBlock?(.failure(partial))
        #expect(heard.all == [false])
    }

    /// The creation saves the approvals zone alone and deletes nothing
    /// (create only), and hands on once it ends, created or not: the
    /// pairing's save runs next either way, and its own result decides.
    @Test(arguments: [nil, ck(.networkUnavailable), ck(.serverRejectedRequest)] as [NSError?])
    func theCreationSavesTheApprovalsZoneAloneAndHandsOn(_ error: NSError?) throws {
        let handedOn = Notes<Bool>()
        let creation = CloudKitAlertSource.makeApprovalsZoneCreation { handedOn.note(true) }
        let zoneID = CloudKitAlertSource.approvalsZoneID
        #expect(creation.recordZonesToSave?.map(\.zoneID) == [zoneID])
        #expect(creation.recordZoneIDsToDelete?.isEmpty ?? true, "create only: no zone is ever deleted")
        #expect(creation.configuration.qualityOfService == .userInitiated)
        // The zone's own save result is only logged: it hands nothing on.
        let perZone = try #require(creation.perRecordZoneSaveBlock, "the creation logs the zone's own failure")
        let zoneResult: Result<CKRecordZone, any Error> = error.map { .failure($0) } ?? .success(CKRecordZone(zoneID: zoneID))
        perZone(zoneID, zoneResult)
        #expect(handedOn.all.isEmpty)
        let result: Result<Void, any Error> = error.map { .failure($0) } ?? .success(())
        creation.modifyRecordZonesResultBlock?(result)
        #expect(handedOn.all == [true])
    }

    /// A save the zone could not be made for fails on its own, closed:
    /// `zoneNotFound` reads as unsent (nothing saved), never a crash.
    @Test func aSaveWithNoZoneReadsAsUnsent() async {
        let database = ScriptedApprovalDatabase(ModifyOperationScript([.saveFailed(0, Self.ck(.zoneNotFound)),
                                                                       .batchFailed(Self.ck(.partialFailure))]))
        #expect(await CloudKitPairingResponseWriter(database: database).write(Self.response) == .failed)
    }

    // MARK: Through the ceremony

    /// The whole phone half over the real record and operation: the
    /// ceremony's one response becomes the one record, field for field, and
    /// CloudKit's answer decides what the phone shows. On a conflict the
    /// pairing fails loudly and shows no code at all.
    @MainActor
    @Test(arguments: [PairingWriteOutcome.saved, .alreadyAnswered])
    func theCeremonysResponseTravelsTheRecordPath(_ outcome: PairingWriteOutcome) async throws {
        let steps: [ModifyOperationScript.Step] = outcome == .saved
            ? [.saved(0), .batchSucceeded] : [.saveFailed(0, Self.ck(.serverRecordChanged)), .batchSucceeded]
        let database = ScriptedApprovalDatabase(ModifyOperationScript(steps))
        let clock = TestClock()
        let keys = PhoneKeyringTests.World()
        let ceremony = PairingCeremony(keyring: keys.keyring, biometrics: ScriptedBiometricGate(),
                                       writer: CloudKitPairingResponseWriter(database: database), clock: { clock.now })
        await ceremony.scanned(ScannedCode(payload: try #require(ApprovalSigning.pairingPayload(nonce: Self.nonce))))
        try #require(database.submitted.count == 1)
        let record = try #require(database.submitted.first?.recordsToSave?.first)
        #expect(record.recordID.recordName == Self.recordName, "named from the scanned code's nonce")
        let publicKey = try #require(record.encryptedValues[Field.publicKey.rawValue] as? Data)
        let mac = try #require(record.encryptedValues[Field.confirmation.rawValue] as? Data)
        let proof = try #require(record.encryptedValues[Field.proof.rawValue] as? Data)
        let confirmation = try #require(ApprovalSigning.pairingConfirmationMessage(wireVersion: ApprovalWire.wireVersion,
                                                                                    publicKey: Array(publicKey)))
        #expect(HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: confirmation, using: SymmetricKey(data: Self.nonce)))
        let proofMessage = try #require(ApprovalSigning.pairingProofMessage(nonce: Self.nonce, publicKey: Array(publicKey)))
        #expect(SignatureCheck.verifies(proof, over: proofMessage, by: Array(publicKey)))
        switch outcome {
        case .saved:
            let fingerprint = try #require(KeyFingerprint(publicKey: Array(publicKey)))
            #expect(ceremony.phase == .waiting(fingerprint, until: clock.now.addingTimeInterval(PairingCeremony.window)))
        default:
            #expect(ceremony.phase == .failed(.alreadyAnswered))
            #expect(keys.provisional() == nil, "the new key is discarded")
        }
    }
}

/// Plays the live approvals database's refusal exactly as it is pinned
/// (`RecordPathStructureTests` lock 6c): the operation is never run, and its
/// own result block is told `invalidArguments`.
final class RefusingApprovalDatabase: CloudKitApprovalDatabase, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var refused: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func submit(_ operation: CKModifyRecordsOperation) {
        lock.lock()
        count += 1
        lock.unlock()
        operation.modifyRecordsResultBlock?(.failure(CKError(.invalidArguments)))
    }
}
