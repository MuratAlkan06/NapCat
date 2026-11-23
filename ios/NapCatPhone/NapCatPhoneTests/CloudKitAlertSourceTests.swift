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
    /// Until it is created, the account works but nothing is pushed.
    @Test func aRefusedCreationIsRetriedOnTheNextConnect() async {
        let database = FixtureDatabase(saveError: CKError(.invalidArguments))
        let source = CloudKitAlertSource(database: database)
        #expect(await source.connect() == .availableWithoutPush)
        #expect(await source.connect() == .availableWithoutPush)
        #expect(await database.saved.isEmpty)
        #expect(await database.saveAttempts == 2)
        #expect(await database.subscriptionFetches.count == 2)
        await database.clearSaveError()
        #expect(await source.connect() == .available)
        #expect(await source.connect() == .available)
        #expect(await database.saved.count == 1)
        #expect(await database.subscriptionFetches.count == 3)
    }

    /// A failed CHECK (not "missing") never creates: that could make a
    /// second subscription if the first is merely unreachable. Unconfirmed
    /// is not "set up" either.
    @Test func aFailedCheckDoesNotCreate() async {
        let database = FixtureDatabase(fetchError: CKError(.networkUnavailable))
        let source = CloudKitAlertSource(database: database)
        #expect(await source.connect() == .availableWithoutPush)
        #expect(await database.saveAttempts == 0)
    }

    /// The F3 spike's error-12 refusal reaches the pill: never "Connected"
    /// while nothing would be pushed, yet the alerts still load.
    @Test @MainActor func aRefusedSubscriptionShowsInThePillAndAlertsStillLoad() async {
        #expect(CKError.Code.invalidArguments.rawValue == 12)
        let database = FixtureDatabase(saveError: CKError(.invalidArguments), records: [Self.macRecord()])
        let feed = AlertFeed(source: CloudKitAlertSource(database: database),
                             notifications: FixedNotificationGate(connection: .connected), isLive: true)
        #expect(feed.connection == .checking)
        await feed.refresh()
        #expect(feed.connection == .pushNotSetUp)
        #expect(feed.alerts.map(\.id) == ["session-1790000000123"])
        await database.clearSaveError()
        await feed.refresh()
        #expect(feed.connection == .connected)
    }

    /// "Connected — no push" gets a retry by hand: a pull re-probes the
    /// subscription (fetch first, then create), and the pill follows.
    @Test @MainActor func aPullReprobesAnUnconfirmedPushSubscription() async {
        let database = FixtureDatabase(saveError: CKError(.invalidArguments), records: [Self.macRecord()])
        let feed = AlertFeed(source: CloudKitAlertSource(database: database),
                             notifications: FixedNotificationGate(connection: .connected), isLive: true)
        await feed.refresh()
        #expect(feed.connection == .pushNotSetUp)
        #expect(await database.subscriptionFetches.count == 1)
        await database.clearSaveError()
        await feed.pullToRefresh()
        #expect(await database.subscriptionFetches.count == 2)
        #expect(await database.saved.map(\.subscriptionID) == [AlertWire.subscriptionID])
        #expect(feed.connection == .connected)
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

    // MARK: The push payload

    /// A push payload as CloudKit delivers the alert subscription's: the
    /// system-rendered `aps` part plus CloudKit's `ck` part, whose query
    /// notification names the subscription and the created record.
    static func pushPayload(
        recordName: String? = "session-1790000000124",
        subscriptionID: String = AlertWire.subscriptionID,
        zoneName: String = CKRecordZone.ID.defaultZoneName
    ) -> [AnyHashable: Any] {
        var query: [String: Any] = [
            "dbs": CKDatabase.Scope.private.rawValue,
            "fo": CKQuerySubscription.Options.firesOnRecordCreation.rawValue,
            "sid": subscriptionID,
            "zid": zoneName,
            "zoid": CKCurrentUserDefaultName,
        ]
        query["rid"] = recordName
        return [
            "aps": ["alert": ["title": "NapCat", "body": body], "sound": "default"],
            "ck": ["ce": 2, "cid": AlertWire.containerIdentifier, "nid": UUID().uuidString, "qry": query],
        ]
    }

    /// The payload shape above is one CloudKit itself parses as the alert
    /// subscription's query notification (so the name tests below are not
    /// testing a made-up shape).
    @Test func cloudKitParsesThePayloadAsTheSubscriptionsQueryNotification() throws {
        let notification = try #require(
            CKNotification(fromRemoteNotificationDictionary: Self.pushPayload()) as? CKQueryNotification)
        #expect(notification.subscriptionID == AlertWire.subscriptionID)
        #expect(notification.queryNotificationReason == .recordCreated)
        #expect(notification.recordID?.recordName == "session-1790000000124")
        #expect(notification.recordID?.zoneID.zoneName == CKRecordZone.ID.defaultZoneName)
    }

    @Test func theAlertSubscriptionsPushNamesItsRecord() {
        #expect(CloudKitAlertSource.pushedRecordName(in: Self.pushPayload()) == "session-1790000000124")
    }

    /// Anything but the alert subscription's push for a default-zone record
    /// names nothing, and the query alone catches up.
    @Test func otherPushesNameNoRecord() {
        #expect(CloudKitAlertSource.pushedRecordName(in: Self.pushPayload(subscriptionID: "another-subscription")) == nil)
        #expect(CloudKitAlertSource.pushedRecordName(in: Self.pushPayload(recordName: nil)) == nil)
        #expect(CloudKitAlertSource.pushedRecordName(in: Self.pushPayload(zoneName: "Elsewhere")) == nil)
        #expect(CloudKitAlertSource.pushedRecordName(in: ["aps": ["alert": "not CloudKit"]]) == nil)
        #expect(CloudKitAlertSource.pushedRecordName(in: [:]) == nil)
    }

    /// The pushed record is fetched BY ID in the default zone and mapped
    /// like any other; a malformed one is skipped.
    @Test func aPushedRecordIsFetchedByIDInTheDefaultZone() async throws {
        let pushed = Self.macRecord(name: "session-1790000000124")
        let spike = Self.macRecord(name: "spike-1", lane: "spike" as NSString)
        let database = FixtureDatabase(stored: [pushed, spike])
        let source = CloudKitAlertSource(database: database)
        #expect(try await source.fetchAlert(named: "session-1790000000124")?.id == "session-1790000000124")
        #expect(try await source.fetchAlert(named: "spike-1") == nil)
        #expect(await database.recordFetches == [
            CKRecord.ID(recordName: "session-1790000000124", zoneID: .default),
            CKRecord.ID(recordName: "spike-1", zoneID: .default),
        ])
        await #expect(throws: (any Error).self) { _ = try await source.fetchAlert(named: "session-0") }
    }

    /// THE race the direct fetch closes: the push names a record the query
    /// (its index lagging) does not return yet, and the row still appears.
    @Test @MainActor func aPushedRecordAppearsEvenWhenTheQueryOmitsIt() async throws {
        let older = Self.macRecord(name: "session-1790000000100")
        let newest = Self.macRecord(name: "session-1790000000124")
        let database = FixtureDatabase(existing: CloudKitAlertSource.makeSubscription(),
                                       records: [older], stored: [older, newest])
        let feed = AlertFeed(source: CloudKitAlertSource(database: database),
                             notifications: FixedNotificationGate(connection: .connected), isLive: true)
        await feed.refresh()
        #expect(feed.alerts.map(\.id) == ["session-1790000000100"])

        let name = feed.pushedRecordName(in: Self.pushPayload(recordName: "session-1790000000124"))
        #expect(await feed.receivePush(recordName: name))
        #expect(Set(feed.alerts.map(\.id)) == ["session-1790000000100", "session-1790000000124"])
        #expect(await database.recordFetches == [CKRecord.ID(recordName: "session-1790000000124", zoneID: .default)])
        #expect(await database.queries.count == 2)
    }

    /// Without a usable ID the push falls back to the query alone: no
    /// direct fetch, and a record the query omits stays out until it shows.
    @Test @MainActor func aPushWithoutAUsableIDFallsBackToTheQuery() async throws {
        let newest = Self.macRecord(name: "session-1790000000124")
        let database = FixtureDatabase(existing: CloudKitAlertSource.makeSubscription(), records: [], stored: [newest])
        let feed = AlertFeed(source: CloudKitAlertSource(database: database),
                             notifications: FixedNotificationGate(connection: .connected), isLive: true)
        let name = feed.pushedRecordName(in: Self.pushPayload(subscriptionID: "another-subscription"))
        #expect(name == nil)
        #expect(await feed.receivePush(recordName: name) == false)
        #expect(feed.alerts.isEmpty)
        #expect(await database.recordFetches.isEmpty)
        #expect(await database.queries.count == 1)
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
    /// What a fetch by ID finds; the query (`records`) may lag it.
    private let stored: [CKRecord]

    private(set) var subscriptionFetches: [CKSubscription.ID] = []
    private(set) var saveAttempts = 0
    private(set) var saved: [CKSubscription] = []
    private(set) var queries: [(CKQuery, Int)] = []
    private(set) var recordFetches: [CKRecord.ID] = []

    init(
        status: CKAccountStatus = .available,
        statusError: CKError? = nil,
        existing: CKSubscription? = nil,
        fetchError: CKError? = nil,
        saveError: CKError? = nil,
        records: [CKRecord] = [],
        queryError: CKError? = nil,
        stored: [CKRecord] = []
    ) {
        self.status = status
        self.statusError = statusError
        self.existing = existing
        self.fetchError = fetchError
        self.saveError = saveError
        self.records = records
        self.queryError = queryError
        self.stored = stored
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

    func record(for recordID: CKRecord.ID) async throws -> CKRecord {
        recordFetches.append(recordID)
        guard let record = stored.first(where: { $0.recordID == recordID }) else { throw CKError(.unknownItem) }
        return record
    }
}
