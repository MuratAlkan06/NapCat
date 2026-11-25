// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import CloudKit
import NapCatWire
import Testing
@testable import NapCat

/// Plays CloudKit's part on a REAL `CKFetchRecordsOperation`, as
/// `ModifyOperationScript` does for the record path's modify operation: the
/// operation is built by the code under test, then its own callbacks are
/// fired by hand in CloudKit's documented order — the record's own result,
/// then the batch result. No container, no database, nothing leaves the
/// process.
struct FetchOperationScript: Sendable {
    enum Step: Sendable {
        /// CloudKit answered the operation's one record ID with this record.
        case fetched(CKRecord)
        case fetchFailed(NSError)
        case batchSucceeded
        case batchFailed(NSError)
    }

    let steps: [Step]

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func run(on operation: CKFetchRecordsOperation) {
        guard let id = operation.recordIDs?.first else {
            Issue.record("the operation asks for no record")
            return
        }
        for step in steps {
            switch step {
            case .fetched(let record): operation.perRecordResultBlock?(id, .success(record))
            case .fetchFailed(let error): operation.perRecordResultBlock?(id, .failure(error))
            case .batchSucceeded: operation.fetchRecordsResultBlock?(.success(()))
            case .batchFailed(let error): operation.fetchRecordsResultBlock?(.failure(error))
            }
        }
    }
}

/// The pairing record's database, played by a test: keeps every operation it
/// is handed and plays CloudKit's part on it at once, from its script.
/// Nothing reaches iCloud.
final class ScriptedPairingDatabase: PairingRecordDatabase, @unchecked Sendable {
    private let lock = NSLock()
    private let fetchScript: FetchOperationScript
    private let deleteScript: ModifyOperationScript
    private var fetchOperations: [CKFetchRecordsOperation] = []
    private var deleteOperations: [CKModifyRecordsOperation] = []

    init(fetch: [FetchOperationScript.Step] = [], delete: [ModifyOperationScript.Step] = []) {
        fetchScript = FetchOperationScript(fetch)
        deleteScript = ModifyOperationScript(delete)
    }

    func submit(_ operation: CKFetchRecordsOperation) {
        lock.lock()
        fetchOperations.append(operation)
        lock.unlock()
        fetchScript.run(on: operation)
    }

    func submit(_ operation: CKModifyRecordsOperation) {
        lock.lock()
        deleteOperations.append(operation)
        lock.unlock()
        deleteScript.run(on: operation)
    }

    var fetches: [CKFetchRecordsOperation] { lock.lock(); defer { lock.unlock() }; return fetchOperations }
    var deletions: [CKModifyRecordsOperation] { lock.lock(); defer { lock.unlock() }; return deleteOperations }
}

/// Counts how often the source asks for its database.
final class DatabaseFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = 0
    let database: ScriptedPairingDatabase?

    init(_ database: ScriptedPairingDatabase?) {
        self.database = database
    }

    func make() -> (any PairingRecordDatabase)? {
        lock.lock()
        asked += 1
        lock.unlock()
        return database
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return asked }
}

/// F4 slice S-PAIR-C1.5 (#170): the Mac's live pairing record source over
/// the real fetch and delete operations, their callbacks fired by hand. It
/// fetches one record by its ID (the approvals zone, the derived name),
/// reads what it finds strictly with that same name, maps every other
/// answer to a closed outcome, and deletes that one record.
struct CloudKitPairingRecordsTests {
    static let name = PhoneHalf.recordName()

    static func ck(_ code: CKError.Code, underlying: NSError? = nil) -> NSError {
        CloudKitMessageSenderTests.ck(code, underlying: underlying)
    }

    static func source(_ database: ScriptedPairingDatabase?) -> (CloudKitPairingRecords, DatabaseFactory) {
        let factory = DatabaseFactory(database)
        return (CloudKitPairingRecords(database: { factory.make() }), factory)
    }

    // MARK: The fetch: one record, by its ID

    @Test func aFetchAsksForOneRecordByItsIDAlone() async throws {
        let database = ScriptedPairingDatabase(fetch: [.fetchFailed(Self.ck(.unknownItem)), .batchSucceeded])
        let (source, _) = Self.source(database)
        #expect(await source.fetch(recordName: Self.name) == .nothing)
        let operation = try #require(database.fetches.first)
        #expect(database.fetches.count == 1 && database.deletions.isEmpty)
        #expect(operation.recordIDs == [CKRecord.ID(recordName: Self.name, zoneID: ApprovalRecordWriter.zoneID)])
        #expect(operation.recordIDs?.first?.zoneID.zoneName == ApprovalWire.zoneName)
        #expect(operation.recordIDs?.first?.zoneID.ownerName == CKCurrentUserDefaultName)
        #expect(operation.desiredKeys == nil, "every field: the strict reading needs them all")
        #expect(operation.configuration.qualityOfService == .userInitiated)
        #expect(!operation.configuration.isLongLived)
        #expect(operation.configuration.timeoutIntervalForRequest == LidGuardTuning.requestTimeout)
        #expect(operation.configuration.timeoutIntervalForResource == LidGuardTuning.requestTimeout)
    }

    /// A record read is read strictly, with the very name asked for.
    @Test func aRecordReadIsReadStrictlyWithTheNameAskedFor() async throws {
        let response = try PhoneHalf.response()
        let record = PairingResponseReaderTests.record(name: Self.name, publicKey: Data(response.publicKey) as NSData,
                                                       confirmation: Data(response.confirmation) as NSData,
                                                       proof: Data(response.proof) as NSData)
        let (source, _) = Self.source(ScriptedPairingDatabase(fetch: [.fetched(record), .batchSucceeded]))
        #expect(await source.fetch(recordName: Self.name) == .found(.response(response)))
    }

    struct Stranger: CustomTestStringConvertible, Sendable {
        let name: String
        let record: @Sendable () -> CKRecord
        let fault: PairingResponseFault
        var testDescription: String { name }
    }

    /// CloudKit answering with a record of another name, zone or type (or a
    /// tampered one) is no response: the reading, with the name asked for,
    /// refuses it, and the ceremony with it.
    static let strangers: [Stranger] = [
        Stranger(name: "another name", record: { PairingResponseReaderTests.record(name: PhoneHalf.recordName(PhoneHalf.otherNonce)) },
                 fault: .wrongRecordName),
        Stranger(name: "another zone", record: { PairingResponseReaderTests.record(zone: CKRecordZone.ID.defaultZoneName) },
                 fault: .wrongZone),
        Stranger(name: "another type", record: { PairingResponseReaderTests.record(type: ApprovalWire.RecordType.decision.rawValue) },
                 fault: .wrongRecordType),
        Stranger(name: "the key in the clear", record: { PairingResponseReaderTests.record(clear: [.publicKey]) },
                 fault: .unencryptedField),
        Stranger(name: "a field added", record: { PairingResponseReaderTests.record(extra: "note") }, fault: .unknownField),
    ]

    @Test(arguments: strangers)
    func aRecordThatIsNotTheResponseIsRefused(_ stranger: Stranger) async {
        let (source, _) = Self.source(ScriptedPairingDatabase(fetch: [.fetched(stranger.record()), .batchSucceeded]))
        #expect(await source.fetch(recordName: Self.name) == .found(.malformed(stranger.fault)))
    }

    // MARK: The closed mapping

    struct Row: CustomTestStringConvertible, Sendable {
        let name: String
        let steps: [FetchOperationScript.Step]
        let expected: PairingFetch
        var testDescription: String { name }
    }

    static let rows: [Row] = [
        Row(name: "no record by that ID", steps: [.fetchFailed(ck(.unknownItem)), .batchSucceeded], expected: .nothing),
        // CloudKit's Result overlay hands a batch partial failure to the
        // result block as SUCCESS (issue #139), so the record's own result
        // carries the answer: here, no record.
        Row(name: "no record, the batch's partial failure arriving as success",
            steps: [.fetchFailed(ck(.unknownItem)), .batchFailed(CloudKitMessageSenderTests.partial([ck(.unknownItem)]))],
            expected: .nothing),
        Row(name: "a batch partial failure and no record result (it arrives as success)",
            steps: [.batchFailed(CloudKitMessageSenderTests.partial([ck(.unknownItem)]))], expected: .unreachable),
        Row(name: "no record, said by the batch alone", steps: [.batchFailed(ck(.unknownItem))], expected: .nothing),
        Row(name: "no network", steps: [.fetchFailed(ck(.networkUnavailable)), .batchSucceeded], expected: .unreachable),
        Row(name: "iCloud unreachable", steps: [.batchFailed(ck(.networkFailure))], expected: .unreachable),
        Row(name: "a timeout", steps: [.batchFailed(ck(.networkFailure, underlying: NSError(domain: NSURLErrorDomain,
                                                                                           code: URLError.timedOut.rawValue)))],
            expected: .unreachable),
        Row(name: "the response lost", steps: [.batchFailed(ck(.serverResponseLost))], expected: .unreachable),
        Row(name: "rate-limited", steps: [.fetchFailed(ck(.requestRateLimited)), .batchSucceeded], expected: .unreachable),
        Row(name: "not signed in", steps: [.batchFailed(ck(.notAuthenticated))], expected: .unreachable),
        Row(name: "no approvals zone yet", steps: [.fetchFailed(ck(.zoneNotFound)), .batchSucceeded], expected: .unreachable),
        Row(name: "no schema yet (an unknown record type)", steps: [.fetchFailed(ck(.serverRejectedRequest)), .batchSucceeded],
            expected: .unreachable),
        Row(name: "no container", steps: [.batchFailed(ck(.badContainer))], expected: .unreachable),
        Row(name: "no entitlement", steps: [.batchFailed(ck(.missingEntitlement))], expected: .unreachable),
        Row(name: "permission refused", steps: [.fetchFailed(ck(.permissionFailure)), .batchSucceeded], expected: .unreachable),
        Row(name: "an internal error", steps: [.batchFailed(ck(.internalError))], expected: .unreachable),
        Row(name: "another domain", steps: [.batchFailed(NSError(domain: "x", code: 1))], expected: .unreachable),
        Row(name: "a partial failure of another kind", steps: [.batchFailed(CloudKitMessageSenderTests.partial([ck(.zoneNotFound)]))],
            expected: .unreachable),
        Row(name: "a batch success with no record at all", steps: [.batchSucceeded], expected: .unreachable),
    ]

    @Test(arguments: rows)
    func everyAnswerMapsToAClosedOutcome(_ row: Row) async {
        let (source, _) = Self.source(ScriptedPairingDatabase(fetch: row.steps))
        #expect(await source.fetch(recordName: Self.name) == row.expected)
    }

    /// The mapping itself, on the shapes the overlay never lets reach the
    /// result block: a raw partial failure around exactly one missing record
    /// is that record missing; around anything else, unreachable.
    @Test func theMappingReadsARawPartialFailureByItsOneItem() {
        let missing = CloudKitMessageSenderTests.partial([Self.ck(.unknownItem)])
        #expect(CloudKitPairingRecords.fetchOutcome(recordName: Self.name, record: nil, batch: .failure(missing)) == .nothing)
        #expect(CloudKitPairingRecords.fetchOutcome(recordName: Self.name, record: .failure(missing), batch: .success(())) == .nothing)
        for other in [CloudKitMessageSenderTests.partial([Self.ck(.zoneNotFound)]),
                      CloudKitMessageSenderTests.partial([Self.ck(.unknownItem), Self.ck(.unknownItem)]), Self.ck(.partialFailure)] {
            #expect(CloudKitPairingRecords.fetchOutcome(recordName: Self.name, record: nil, batch: .failure(other)) == .unreachable)
        }
    }

    /// The record's own result decides; the outcome is decided once.
    @Test func theRecordsOwnResultDecidesOnce() async throws {
        let response = try PhoneHalf.response()
        let record = PairingResponseReaderTests.record(name: Self.name, publicKey: Data(response.publicKey) as NSData,
                                                       confirmation: Data(response.confirmation) as NSData,
                                                       proof: Data(response.proof) as NSData)
        let read = ScriptedPairingDatabase(fetch: [.fetched(record), .fetchFailed(Self.ck(.unknownItem)),
                                                   .batchFailed(Self.ck(.networkFailure)), .batchSucceeded])
        #expect(await Self.source(read).0.fetch(recordName: Self.name) == .found(.response(response)))
        let missing = ScriptedPairingDatabase(fetch: [.fetchFailed(Self.ck(.unknownItem)), .batchFailed(Self.ck(.networkFailure))])
        #expect(await Self.source(missing).0.fetch(recordName: Self.name) == .nothing)
    }

    // MARK: Only a pairing record's name; no iCloud, no harm

    static let malformedNames = ["", String(name.dropLast()), name + "0", name.uppercased(), name + "\n",
                                 String(name.dropLast()) + "g", " " + String(name.dropFirst()), String(name.prefix(32)),
                                 String(name.prefix(32)) + "-decision", "../" + String(name.dropFirst(3))]

    /// Nothing is fetched or deleted by a name of any other shape: no
    /// database is even asked for.
    @Test(arguments: malformedNames)
    func aNameOfAnyOtherShapeIsNeverSent(_ recordName: String) async {
        let database = ScriptedPairingDatabase()
        let (source, factory) = Self.source(database)
        #expect(await source.fetch(recordName: recordName) == .unreachable)
        #expect(await source.delete(recordName: recordName) == false)
        #expect(factory.calls == 0 && database.fetches.isEmpty && database.deletions.isEmpty)
    }

    /// A build with no iCloud entitlement has no database: every fetch is
    /// unreachable (the sheet's "still trying") and nothing is deleted, and
    /// the database is asked for once, on first use, never at construction.
    @Test func noDatabaseFailsDark() async {
        let (source, factory) = Self.source(nil)
        #expect(factory.calls == 0, "construction does no I/O")
        #expect(await source.fetch(recordName: Self.name) == .unreachable)
        #expect(await source.delete(recordName: Self.name) == false)
        #expect(await source.fetch(recordName: Self.name) == .unreachable)
        #expect(factory.calls == 1, "asked once, then kept")
    }

    @Test func theDatabaseIsBuiltOnFirstUseThenKept() async {
        let database = ScriptedPairingDatabase(fetch: [.fetchFailed(Self.ck(.unknownItem)), .batchSucceeded],
                                               delete: [.deleted(0), .batchSucceeded])
        let (source, factory) = Self.source(database)
        #expect(factory.calls == 0)
        _ = await source.fetch(recordName: Self.name)
        _ = await source.fetch(recordName: Self.name)
        _ = await source.delete(recordName: Self.name)
        #expect(factory.calls == 1 && database.fetches.count == 2 && database.deletions.count == 1)
    }

    // MARK: The deletion: that one record, nothing saved

    @Test func aDeletionDeletesThatOneRecordAndSavesNothing() async throws {
        let database = ScriptedPairingDatabase(delete: [.deleted(0), .batchSucceeded])
        let (source, _) = Self.source(database)
        #expect(await source.delete(recordName: Self.name))
        let operation = try #require(database.deletions.first)
        #expect(database.deletions.count == 1 && database.fetches.isEmpty)
        #expect(operation.recordIDsToDelete == [CKRecord.ID(recordName: Self.name, zoneID: ApprovalRecordWriter.zoneID)])
        #expect(operation.recordsToSave?.isEmpty ?? true, "a deletion saves nothing")
        #expect(operation.configuration.qualityOfService == .userInitiated)
    }

    @Test(arguments: [
        ("deleted", [ModifyOperationScript.Step.deleted(0), .batchSucceeded], true),
        ("already gone", [.deleteFailed(0, ModifyOperationScript.ck(.unknownItem)), .batchSucceeded], true),
        ("refused", [.deleteFailed(0, ModifyOperationScript.ck(.permissionFailure)), .batchSucceeded], false),
        ("no network", [.batchFailed(ModifyOperationScript.ck(.networkUnavailable))], false),
        ("unconfirmed", [.batchFailed(ModifyOperationScript.ck(.serverResponseLost))], false),
        ("no result for the record", [.batchSucceeded], false),
    ])
    func aDeletionIsGoneOnlyWhenTheRecordIs(_ name: String, _ steps: [ModifyOperationScript.Step], _ gone: Bool) async {
        let (source, _) = Self.source(ScriptedPairingDatabase(delete: steps))
        #expect(await source.delete(recordName: Self.name) == gone, "\(name)")
    }

    // MARK: Through the ceremony

    /// The Mac's whole half over the real operations: the controller fetches
    /// by name, freezes on the phone's response, and after Codes Match the
    /// key is kept and that same record is deleted.
    @MainActor
    @Test func aCeremonyTravelsTheLiveTransport() async throws {
        let response = try PhoneHalf.response()
        let record = PairingResponseReaderTests.record(name: Self.name, publicKey: Data(response.publicKey) as NSData,
                                                       confirmation: Data(response.confirmation) as NSData,
                                                       proof: Data(response.proof) as NSData)
        let database = ScriptedPairingDatabase(fetch: [.fetched(record), .batchSucceeded], delete: [.deleted(0), .batchSucceeded])
        let items = FakeTopicStore()
        var remembered: String?
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let factory = DatabaseFactory(database)
        let controller = PairingController(
            source: CloudKitPairingRecords(database: { factory.make() }), keys: PairedKeyStore(items: items),
            readRemembered: { remembered }, writeRemembered: { remembered = $0 }, makeNonce: { PhoneHalf.nonce },
            clock: { clock }, killSwitch: {}, audit: { _ in }, makeTicker: { _ in ManualPairingTicker({}, cancelled: {}) })
        controller.begin()
        clock = clock.addingTimeInterval(PairingCeremonyState.pollInterval)
        controller.tick()
        await controller.settle()
        guard case .comparing(let candidate) = controller.state.phase else {
            Issue.record("not comparing: \(controller.state.phase)")
            return
        }
        #expect(candidate.response == response)
        controller.codesMatch()
        await controller.settle()
        #expect(items.storedValue != nil, "the key is kept")
        #expect(database.fetches.first?.recordIDs?.map(\.recordName) == [Self.name])
        #expect(database.deletions.first?.recordIDsToDelete?.map(\.recordName) == [Self.name])
        #expect(remembered == nil, "the name is forgotten once the record is gone")
    }
}
