import CloudKit
import Foundation
import NapCatWire
import os

/// THE ONE CloudKit FILE of the receiver: the only file that imports
/// CloudKit and the only place a container is built (`makeLive()`, behind
/// `LiveCapability`). `CloudKitStructureTests` locks both.
///
/// It reads what the Mac's `CloudKitMessageSender` writes: one record per
/// alert in the owner's PRIVATE database, default zone of
/// `AlertWire.containerIdentifier`, record type `AlertWire.recordType`,
/// exactly the three `AlertWire.Field`s, named `<lane>-<epoch milliseconds>`.
///
/// The phone OWNS the one push subscription (the frozen F3 ADR; the Mac
/// refuses to create it in Production). Its shape is the F3 spike's,
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

    // MARK: - AlertSource

    func connect() async -> AccountAvailability {
        let availability: AccountAvailability
        do {
            availability = Self.availability(try await database.accountStatus())
        } catch {
            Self.logger.error("account check failed (code \(Self.code(of: error)))")
            availability = .unavailable
        }
        if availability == .available, !subscriptionReady {
            subscriptionReady = await ensureSubscription()
        }
        return availability
    }

    func fetchRecent() async throws -> [PhoneAlert] {
        let records = try await database.records(matching: Self.makeQuery(), resultsLimit: AlertFeed.listLimit)
        let alerts = records.compactMap(Self.alert(from:))
        if alerts.count != records.count {
            Self.logger.info("skipped \(records.count - alerts.count) malformed record(s)")
        }
        return alerts
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
/// save, and the alert query. Production is `LiveCloudKitAlertDatabase`
/// (built only by `CloudKitAlertSource.makeLive()`); tests inject a fixture.
protocol CloudKitAlertDatabase: Sendable {
    func accountStatus() async throws -> CKAccountStatus
    /// Throws `unknownItem` when the server has no subscription with that ID.
    func subscription(for subscriptionID: CKSubscription.ID) async throws -> CKSubscription
    func save(_ subscription: CKSubscription) async throws
    /// The matching records; a record that failed to load individually is
    /// left out.
    func records(matching query: CKQuery, resultsLimit: Int) async throws -> [CKRecord]
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
}
