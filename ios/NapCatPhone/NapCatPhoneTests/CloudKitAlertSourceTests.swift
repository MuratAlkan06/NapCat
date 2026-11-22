import CloudKit
import Foundation
import NapCatWire
@testable import NapCatPhone
import Testing

/// The live source's logic against a FIXTURE database: the subscription's
/// shape and idempotent creation, the account probe, the query, and how a
/// record becomes an alert. No test builds a container or talks to iCloud
/// (`CloudKitStructureTests` locks that); `CKRecord` and `CKQuerySubscription`
/// are plain values.
@Suite struct CloudKitAlertSourceTests {
    static let firedAt = Date(timeIntervalSince1970: 1_790_000_000.123)
    static let body = "A Claude session finished after 23 min — none still working"

    /// A record exactly as the Mac's `CloudKitMessageSender.makeRecord`
    /// writes it (type, default zone, three fields), with overrides.
    static func macRecord(
        name: String = "session-1790000000123",
        type: String = AlertWire.recordType,
        body: NSObject? = body as NSString,
        lane: NSObject? = "session" as NSString,
        firedAt: NSObject? = firedAt as NSDate
    ) -> CKRecord {
        let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: CKRecordZone.ID.default))
        record.setObject(body as? CKRecordValue, forKey: AlertWire.Field.body.rawValue)
        record.setObject(lane as? CKRecordValue, forKey: AlertWire.Field.lane.rawValue)
        record.setObject(firedAt as? CKRecordValue, forKey: AlertWire.Field.firedAt.rawValue)
        return record
    }

    // MARK: The subscription: the spike's shape, exactly

    @Test func theSubscriptionIsTheSpikesShape() throws {
        let subscription = CloudKitAlertSource.makeSubscription()
        #expect(subscription.subscriptionID == AlertWire.subscriptionID)
        #expect(subscription.recordType == AlertWire.recordType)
        #expect(subscription.predicate.predicateFormat == NSPredicate(value: true).predicateFormat)
        #expect(subscription.querySubscriptionOptions == [.firesOnRecordCreation])
        #expect(subscription.zoneID == nil)
        let info = try #require(subscription.notificationInfo)
        #expect(info.title == "NapCat")
        #expect(info.alertLocalizationKey == "%1$@")
        #expect(info.alertLocalizationArgs == [AlertWire.Field.body.rawValue])
        #expect(info.soundName == "default")
        // The system renders it: no silent wake, no badge, no extension.
        #expect(!info.shouldSendContentAvailable)
        #expect(!info.shouldSendMutableContent)
        #expect(!info.shouldBadge)
    }

    // MARK: Idempotent ensure-create (fetch first)

    @Test func anExistingSubscriptionIsNeverSavedAgain() async {
        let database = FixtureDatabase(existing: CloudKitAlertSource.makeSubscription())
        let source = CloudKitAlertSource(database: database)
        #expect(await source.connect() == .available)
        #expect(await source.connect() == .available)
        #expect(await database.saved.isEmpty)
        // Known to exist after the first check: not even fetched again.
        #expect(await database.subscriptionFetches == [AlertWire.subscriptionID])
    }

    @Test func aMissingSubscriptionIsCreatedOnceWithTheFixedID() async {
        let database = FixtureDatabase()
        let source = CloudKitAlertSource(database: database)
        _ = await source.connect()
        _ = await source.connect()
        _ = await source.connect()
        #expect(await database.saved.map(\.subscriptionID) == [AlertWire.subscriptionID])
        #expect(await database.subscriptionFetches == [AlertWire.subscriptionID])
    }

    /// The F3 spike's Production refusal (CKError 12, "attempting to create
    /// a subscription in a production container"): logged, not fatal, and
    /// tried again on the next connect, fetching first again.
    @Test func aRefusedCreationIsRetriedOnTheNextConnect() async {
        let database = FixtureDatabase(saveError: CKError(.invalidArguments))
        let source = CloudKitAlertSource(database: database)
        #expect(await source.connect() == .available)
        #expect(await source.connect() == .available)
        #expect(await database.saved.isEmpty)
        #expect(await database.saveAttempts == 2)
        #expect(await database.subscriptionFetches.count == 2)
        await database.clearSaveError()
        _ = await source.connect()
        _ = await source.connect()
        #expect(await database.saved.count == 1)
        #expect(await database.subscriptionFetches.count == 3)
    }

    /// A failed CHECK (not "missing") never creates: that could make a
    /// second subscription if the first is merely unreachable.
    @Test func aFailedCheckDoesNotCreate() async {
        let database = FixtureDatabase(fetchError: CKError(.networkUnavailable))
        let source = CloudKitAlertSource(database: database)
        #expect(await source.connect() == .available)
        #expect(await database.saveAttempts == 0)
    }

    @Test func missingMeansUnknownItemOnly() {
        #expect(CloudKitAlertSource.isMissing(CKError(.unknownItem)))
        let wrapped = NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue, userInfo: [
            CKPartialErrorsByItemIDKey: [AlertWire.subscriptionID: CKError(.unknownItem) as NSError],
        ])
        #expect(CloudKitAlertSource.isMissing(wrapped))
        #expect(!CloudKitAlertSource.isMissing(CKError(.networkFailure)))
        #expect(!CloudKitAlertSource.isMissing(CKError(.invalidArguments)))
        #expect(!CloudKitAlertSource.isMissing(NSError(domain: NSURLErrorDomain, code: CKError.Code.unknownItem.rawValue)))
    }

    // MARK: The account probe

    @Test(arguments: [CKAccountStatus.noAccount, .restricted, .couldNotDetermine, .temporarilyUnavailable])
    func noUsableAccountMeansUnavailableAndNoSubscriptionWork(_ status: CKAccountStatus) async {
        let database = FixtureDatabase(status: status)
        let source = CloudKitAlertSource(database: database)
        #expect(await source.connect() == .unavailable)
        #expect(await database.subscriptionFetches.isEmpty)
        #expect(await database.saveAttempts == 0)
    }

    @Test func aFailedAccountCheckMeansUnavailable() async {
        let database = FixtureDatabase(statusError: CKError(.networkUnavailable))
        #expect(await CloudKitAlertSource(database: database).connect() == .unavailable)
        #expect(await database.subscriptionFetches.isEmpty)
    }

    @Test func onlyAnAvailableAccountIsAvailable() {
        #expect(CloudKitAlertSource.availability(.available) == .available)
        for status in [CKAccountStatus.noAccount, .restricted, .couldNotDetermine, .temporarilyUnavailable] {
            #expect(CloudKitAlertSource.availability(status) == .unavailable)
        }
    }

    // MARK: The fetch

    /// The spike's proven query: every Alert, newest first, capped.
    @Test func theQueryIsEveryAlertNewestFirst() async throws {
        let database = FixtureDatabase(records: [Self.macRecord()])
        _ = try await CloudKitAlertSource(database: database).fetchRecent()
        let (query, limit) = try #require(await database.queries.first)
        #expect(query.recordType == AlertWire.recordType)
        #expect(query.predicate.predicateFormat == NSPredicate(value: true).predicateFormat)
        #expect(query.sortDescriptors == [NSSortDescriptor(key: AlertWire.Field.firedAt.rawValue, ascending: false)])
        #expect(limit == AlertFeed.listLimit)
    }

    @Test func aFetchMapsWellFormedRecordsAndSkipsTheRest() async throws {
        let good = Self.macRecord()
        let spike = Self.macRecord(name: "spike-1763649725-0", lane: "spike" as NSString)
        let database = FixtureDatabase(records: [good, spike])
        let alerts = try await CloudKitAlertSource(database: database).fetchRecent()
        #expect(alerts.map(\.id) == ["session-1790000000123"])
    }

    @Test func aFailedQueryThrows() async {
        let database = FixtureDatabase(queryError: CKError(.networkFailure))
        await #expect(throws: (any Error).self) {
            _ = try await CloudKitAlertSource(database: database).fetchRecent()
        }
    }

    // MARK: Record → alert

    /// The Mac's record becomes exactly its three fields, keeping the
    /// record's OWN name (the dedupe key), not one derived on the phone.
    @Test func theMacsRecordBecomesAnAlert() throws {
        let alert = try #require(CloudKitAlertSource.alert(from: Self.macRecord(name: "session-1790000000122")))
        #expect(alert.id == "session-1790000000122")
        #expect(alert.body == Self.body)
        #expect(alert.lane == .session)
        #expect(alert.firedAt == Self.firedAt)
        let lid = try #require(CloudKitAlertSource.alert(from: Self.macRecord(name: "lid-1", lane: "lid" as NSString)))
        #expect(lid.lane == .lid)
    }

    struct Malformed: CustomTestStringConvertible, Sendable {
        let name: String
        let make: @Sendable () -> CKRecord
        var testDescription: String { name }
    }

    static let malformed: [Malformed] = [
        Malformed(name: "another record type") { macRecord(type: "Note") },
        Malformed(name: "no body") { macRecord(body: nil) },
        Malformed(name: "empty body") { macRecord(body: "" as NSString) },
        Malformed(name: "body not a string") { macRecord(body: 42 as NSNumber) },
        Malformed(name: "no lane") { macRecord(lane: nil) },
        Malformed(name: "unknown lane (the spike's test records)") { macRecord(lane: "spike" as NSString) },
        Malformed(name: "lane not a string") { macRecord(lane: 1 as NSNumber) },
        Malformed(name: "no firedAt") { macRecord(firedAt: nil) },
        Malformed(name: "firedAt not a date") { macRecord(firedAt: "22:49" as NSString) },
    ]

    @Test(arguments: malformed)
    func aMalformedRecordIsSkipped(_ row: Malformed) {
        #expect(CloudKitAlertSource.alert(from: row.make()) == nil)
    }

    /// Two fetches of one record are one row (deterministic names).
    @Test @MainActor func aRecordSeenTwiceIsOneRow() async throws {
        let database = FixtureDatabase(records: [Self.macRecord(), Self.macRecord()])
        let feed = AlertFeed(source: CloudKitAlertSource(database: database),
                             notifications: FixedNotificationGate(connection: .connected), isLive: true)
        await feed.refresh()
        await feed.refresh()
        #expect(feed.alerts.map(\.id) == ["session-1790000000123"])
    }
}

/// A fixture `CloudKitAlertDatabase`: scripted answers and recorded calls.
actor FixtureDatabase: CloudKitAlertDatabase {
    private let status: CKAccountStatus
    private let statusError: CKError?
    private var existing: CKSubscription?
    private let fetchError: CKError?
    private var saveError: CKError?
    private let records: [CKRecord]
    private let queryError: CKError?

    private(set) var subscriptionFetches: [CKSubscription.ID] = []
    private(set) var saveAttempts = 0
    private(set) var saved: [CKSubscription] = []
    private(set) var queries: [(CKQuery, Int)] = []

    init(
        status: CKAccountStatus = .available,
        statusError: CKError? = nil,
        existing: CKSubscription? = nil,
        fetchError: CKError? = nil,
        saveError: CKError? = nil,
        records: [CKRecord] = [],
        queryError: CKError? = nil
    ) {
        self.status = status
        self.statusError = statusError
        self.existing = existing
        self.fetchError = fetchError
        self.saveError = saveError
        self.records = records
        self.queryError = queryError
    }

    func clearSaveError() { saveError = nil }

    func accountStatus() async throws -> CKAccountStatus {
        if let statusError { throw statusError }
        return status
    }

    func subscription(for subscriptionID: CKSubscription.ID) async throws -> CKSubscription {
        subscriptionFetches.append(subscriptionID)
        if let fetchError { throw fetchError }
        guard let existing, existing.subscriptionID == subscriptionID else { throw CKError(.unknownItem) }
        return existing
    }

    func save(_ subscription: CKSubscription) async throws {
        saveAttempts += 1
        if let saveError { throw saveError }
        saved.append(subscription)
        existing = subscription
    }

    func records(matching query: CKQuery, resultsLimit: Int) async throws -> [CKRecord] {
        queries.append((query, resultsLimit))
        if let queryError { throw queryError }
        return records
    }
}
