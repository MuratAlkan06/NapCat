import CloudKit
import Foundation
import NapCatWire
@testable import NapCatPhone
import Testing

/// The prompt path's operations, played by a test (F4, #194): every
/// operation it is handed is kept, by kind, and CloudKit's part is played on
/// it at once by the script for that kind. Record saves are refused, as
/// nothing here writes. Nothing reaches iCloud.
final class ScriptedPromptDatabase: CloudKitApprovalDatabase, @unchecked Sendable {
    private let lock = NSLock()
    private var kinds: [String] = []
    private var lookups: [CKFetchSubscriptionsOperation] = []
    private var changes: [CKModifySubscriptionsOperation] = []
    private var snapshots: [CKFetchRecordZoneChangesOperation] = []
    private var lookupScripts: [@Sendable (CKFetchSubscriptionsOperation) -> Void]
    private let changeScript: @Sendable (CKModifySubscriptionsOperation) -> Void
    private let snapshotScript: @Sendable (CKFetchRecordZoneChangesOperation) -> Void

    /// `lookup` plays each lookup in turn (the last one again once they run
    /// out).
    init(lookup: [@Sendable (CKFetchSubscriptionsOperation) -> Void] = [PromptScript.found],
         change: @escaping @Sendable (CKModifySubscriptionsOperation) -> Void = PromptScript.changed,
         snapshot: @escaping @Sendable (CKFetchRecordZoneChangesOperation) -> Void = PromptScript.records([])) {
        lookupScripts = lookup
        changeScript = change
        snapshotScript = snapshot
    }

    func submit(_ operation: CKModifyRecordsOperation) {
        note("records")
        operation.modifyRecordsResultBlock?(.failure(CKError(.invalidArguments)))
    }

    func submit(_ snapshot: CKFetchRecordZoneChangesOperation) {
        lock.lock()
        kinds.append("snapshot")
        snapshots.append(snapshot)
        lock.unlock()
        snapshotScript(snapshot)
    }

    func submit(_ lookup: CKFetchSubscriptionsOperation) {
        lock.lock()
        kinds.append("lookup")
        lookups.append(lookup)
        let script: @Sendable (CKFetchSubscriptionsOperation) -> Void = lookupScripts.count > 1 ? lookupScripts.removeFirst()
            : lookupScripts[0]
        lock.unlock()
        script(lookup)
    }

    func submit(_ change: CKModifySubscriptionsOperation) {
        lock.lock()
        kinds.append(change.subscriptionIDsToDelete?.isEmpty ?? true ? "save" : "remove")
        changes.append(change)
        lock.unlock()
        changeScript(change)
    }

    private func note(_ kind: String) {
        lock.lock()
        kinds.append(kind)
        lock.unlock()
    }

    /// What it was handed, in order: lookup, save, remove, snapshot, records.
    var handed: [String] {
        lock.lock()
        defer { lock.unlock() }
        return kinds
    }

    var lookupsHanded: [CKFetchSubscriptionsOperation] {
        lock.lock()
        defer { lock.unlock() }
        return lookups
    }

    var changesHanded: [CKModifySubscriptionsOperation] {
        lock.lock()
        defer { lock.unlock() }
        return changes
    }

    var snapshotsHanded: [CKFetchRecordZoneChangesOperation] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots
    }
}

/// CloudKit's part on each prompt operation, in its documented order: each
/// item's own result, then the batch's.
enum PromptScript {
    static let id: CKSubscription.ID = ApprovalWire.promptSubscriptionID

    static func ck(_ code: CKError.Code) -> NSError { ModifyOperationScript.ck(code) }

    /// A batch `partialFailure` around one subscription error.
    static func partial(_ error: NSError) -> NSError {
        NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue,
                userInfo: [CKPartialErrorsByItemIDKey: [id: error] as [AnyHashable: Any]])
    }

    static let found: @Sendable (CKFetchSubscriptionsOperation) -> Void = { lookup in
        lookup.perSubscriptionResultBlock?(id, .success(CloudKitAlertSource.makePromptSubscription()))
        lookup.fetchSubscriptionsResultBlock?(.success(()))
    }

    static func lookupItemFailed(_ error: NSError) -> @Sendable (CKFetchSubscriptionsOperation) -> Void {
        { lookup in
            lookup.perSubscriptionResultBlock?(id, .failure(error))
            lookup.fetchSubscriptionsResultBlock?(.success(()))
        }
    }

    static func lookupFailed(_ error: NSError) -> @Sendable (CKFetchSubscriptionsOperation) -> Void {
        { lookup in lookup.fetchSubscriptionsResultBlock?(.failure(error)) }
    }

    /// Found under the ID, but in another shape: an older build's, or one
    /// changed elsewhere (#194).
    static func foundAs(_ change: @escaping @Sendable (CKQuerySubscription) -> Void) -> @Sendable (CKFetchSubscriptionsOperation) -> Void {
        { lookup in
            let subscription: CKQuerySubscription = CloudKitAlertSource.makePromptSubscription()
            change(subscription)
            lookup.perSubscriptionResultBlock?(id, .success(subscription))
            lookup.fetchSubscriptionsResultBlock?(.success(()))
        }
    }

    static let lookupEmpty: @Sendable (CKFetchSubscriptionsOperation) -> Void = { lookup in
        lookup.fetchSubscriptionsResultBlock?(.success(()))
    }

    /// Each subscription saved or deleted, then the batch.
    static let changed: @Sendable (CKModifySubscriptionsOperation) -> Void = { change in
        for subscription in change.subscriptionsToSave ?? [] {
            change.perSubscriptionSaveBlock?(subscription.subscriptionID, .success(subscription))
        }
        for removed in change.subscriptionIDsToDelete ?? [] {
            change.perSubscriptionDeleteBlock?(removed, .success(()))
        }
        change.modifySubscriptionsResultBlock?(.success(()))
    }

    static func changeItemFailed(_ error: NSError) -> @Sendable (CKModifySubscriptionsOperation) -> Void {
        { change in
            for subscription in change.subscriptionsToSave ?? [] {
                change.perSubscriptionSaveBlock?(subscription.subscriptionID, .failure(error))
            }
            for removed in change.subscriptionIDsToDelete ?? [] {
                change.perSubscriptionDeleteBlock?(removed, .failure(error))
            }
            change.modifySubscriptionsResultBlock?(.success(()))
        }
    }

    static func changeFailed(_ error: NSError) -> @Sendable (CKModifySubscriptionsOperation) -> Void {
        { change in change.modifySubscriptionsResultBlock?(.failure(error)) }
    }

    static let changeEmpty: @Sendable (CKModifySubscriptionsOperation) -> Void = { change in
        change.modifySubscriptionsResultBlock?(.success(()))
    }

    /// Each record changed, in order, then the batch.
    static func records(_ records: [CKRecord]) -> @Sendable (CKFetchRecordZoneChangesOperation) -> Void {
        let kept = RecordBox(records)
        return { snapshot in
            for record in kept.records { snapshot.recordWasChangedBlock?(record.recordID, .success(record)) }
            snapshot.fetchRecordZoneChangesResultBlock?(.success(()))
        }
    }

    static func recordFailed(_ error: NSError) -> @Sendable (CKFetchRecordZoneChangesOperation) -> Void {
        { snapshot in
            let prompt = CloudKitRequestRecordTests.macRecord()
            snapshot.recordWasChangedBlock?(prompt.recordID, .success(prompt))
            snapshot.recordWasChangedBlock?(CKRecord.ID(recordName: "x", zoneID: CloudKitAlertSource.approvalsZoneID), .failure(error))
            snapshot.fetchRecordZoneChangesResultBlock?(.success(()))
        }
    }

    static func zoneFailed(_ error: NSError) -> @Sendable (CKFetchRecordZoneChangesOperation) -> Void {
        { snapshot in
            snapshot.recordZoneFetchResultBlock?(CloudKitAlertSource.approvalsZoneID, .failure(error))
            snapshot.fetchRecordZoneChangesResultBlock?(.success(()))
        }
    }

    static func snapshotFailed(_ error: NSError) -> @Sendable (CKFetchRecordZoneChangesOperation) -> Void {
        { snapshot in snapshot.fetchRecordZoneChangesResultBlock?(.failure(error)) }
    }
}

/// Records handed to a script that runs elsewhere (CKRecord is not Sendable).
final class RecordBox: @unchecked Sendable {
    let records: [CKRecord]
    init(_ records: [CKRecord]) { self.records = records }
}

/// F4, #194: the prompt push subscription, the snapshot read, and the
/// live approvals database's admit list, on real operations whose callbacks
/// are fired by hand. Nothing reaches iCloud.
@Suite struct CloudKitPromptSourceTests {
    typealias Field = ApprovalWire.PromptField

    // MARK: The subscription

    /// Fixed words under the app's title, the default sound, and nothing of
    /// a record: no desired keys, no localization arguments, no action, no
    /// silent wake. On PromptRequest records in the approvals zone, on
    /// creation only, under the wire's one ID.
    @Test func theSubscriptionIsFixedWordsWithNoRecordField() throws {
        let subscription = CloudKitAlertSource.makePromptSubscription()
        #expect(subscription.subscriptionID == ApprovalWire.promptSubscriptionID)
        #expect(subscription.subscriptionID != AlertWire.subscriptionID)
        #expect(subscription.recordType == ApprovalWire.RecordType.prompt.rawValue)
        #expect(subscription.zoneID == CloudKitAlertSource.approvalsZoneID)
        #expect(subscription.querySubscriptionOptions == [.firesOnRecordCreation])
        #expect(subscription.predicate.predicateFormat == "TRUEPREDICATE")
        let info = try #require(subscription.notificationInfo)
        #expect(info.title == "NapCat")
        #expect(info.alertBody == "A permission prompt is waiting on your Mac.")
        #expect(CloudKitAlertSource.promptNotificationBody == "A permission prompt is waiting on your Mac.")
        #expect(info.soundName == "default")
        #expect(info.desiredKeys == nil && info.alertLocalizationKey == nil && info.alertLocalizationArgs == nil)
        #expect(info.titleLocalizationArgs == nil && info.subtitleLocalizationArgs == nil && info.subtitle == nil)
        #expect(info.category == nil && info.collapseIDKey == nil)
        #expect(!info.shouldSendContentAvailable && !info.shouldSendMutableContent && !info.shouldBadge)
        #expect(CloudKitAlertSource.isPromptSubscription(subscription))
    }

    struct Changed: CustomTestStringConvertible, Sendable {
        let name: String
        let change: @Sendable (CKQuerySubscription) -> Void
        var testDescription: String { name }
    }

    /// Any change to the subscription's shape: a record field in the push,
    /// another trigger, type, zone or ID, an action, a silent wake.
    static let changedSubscriptions: [Changed] = [
        Changed(name: "a record field in the payload") { $0.notificationInfo?.desiredKeys = [Field.toolName.rawValue] },
        Changed(name: "a record field as the alert") { $0.notificationInfo?.alertLocalizationArgs = [Field.inputPreview.rawValue] },
        Changed(name: "a record field as the title") { $0.notificationInfo?.titleLocalizationArgs = [Field.projectLabel.rawValue] },
        Changed(name: "a record field as the subtitle") { $0.notificationInfo?.subtitleLocalizationArgs = [Field.toolName.rawValue] },
        Changed(name: "the alert from a key") { $0.notificationInfo?.alertLocalizationKey = "%1$@" },
        Changed(name: "other words") { $0.notificationInfo?.alertBody = "Bash wants to run" },
        Changed(name: "another title") { $0.notificationInfo?.title = "Claude" },
        Changed(name: "no sound") { $0.notificationInfo?.soundName = nil },
        Changed(name: "an action") { $0.notificationInfo?.category = "answer" },
        Changed(name: "a collapse key from a field") { $0.notificationInfo?.collapseIDKey = Field.toolName.rawValue },
        Changed(name: "a silent wake") { $0.notificationInfo?.shouldSendContentAvailable = true },
        Changed(name: "a mutable push") { $0.notificationInfo?.shouldSendMutableContent = true },
        Changed(name: "no push at all") { $0.notificationInfo = nil },
        Changed(name: "the default zone") { $0.zoneID = .default },
        Changed(name: "every zone") { $0.zoneID = nil },
    ]

    @Test(arguments: changedSubscriptions)
    func anyOtherSubscriptionIsNotThePrompts(_ row: Changed) {
        let subscription = CloudKitAlertSource.makePromptSubscription()
        row.change(subscription)
        #expect(!CloudKitAlertSource.isPromptSubscription(subscription))
    }

    /// Another trigger, type or ID; the alert subscription itself.
    @Test func anotherSubscriptionOfAnyKindIsNotThePrompts() {
        let updates = CKQuerySubscription(recordType: ApprovalWire.RecordType.prompt.rawValue, predicate: NSPredicate(value: true),
                                          subscriptionID: ApprovalWire.promptSubscriptionID,
                                          options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        updates.zoneID = CloudKitAlertSource.approvalsZoneID
        updates.notificationInfo = CloudKitAlertSource.makePromptSubscription().notificationInfo
        let decisions = CKQuerySubscription(recordType: ApprovalWire.RecordType.decision.rawValue, predicate: NSPredicate(value: true),
                                            subscriptionID: ApprovalWire.promptSubscriptionID, options: [.firesOnRecordCreation])
        decisions.zoneID = CloudKitAlertSource.approvalsZoneID
        decisions.notificationInfo = CloudKitAlertSource.makePromptSubscription().notificationInfo
        let renamed = CKQuerySubscription(recordType: ApprovalWire.RecordType.prompt.rawValue, predicate: NSPredicate(value: true),
                                          subscriptionID: "napcat-spare", options: [.firesOnRecordCreation])
        renamed.zoneID = CloudKitAlertSource.approvalsZoneID
        renamed.notificationInfo = CloudKitAlertSource.makePromptSubscription().notificationInfo
        let narrowed = CKQuerySubscription(recordType: ApprovalWire.RecordType.prompt.rawValue,
                                           predicate: NSPredicate(value: false), subscriptionID: ApprovalWire.promptSubscriptionID,
                                           options: [.firesOnRecordCreation])
        narrowed.zoneID = CloudKitAlertSource.approvalsZoneID
        narrowed.notificationInfo = CloudKitAlertSource.makePromptSubscription().notificationInfo
        for subscription in [updates, decisions, renamed, narrowed, CloudKitAlertSource.makeSubscription()] {
            #expect(!CloudKitAlertSource.isPromptSubscription(subscription), "\(subscription.subscriptionID)")
        }
    }

    // MARK: Making sure of the subscription

    /// Found: left as it is. A lookup, nothing saved.
    @Test func aFoundSubscriptionIsLeftAsItIs() async {
        let database = ScriptedPromptDatabase(lookup: [PromptScript.found])
        #expect(await LivePromptSource(database: database).ensureSubscription())
        #expect(database.handed == ["lookup"])
        let lookup = database.lookupsHanded.first
        #expect(lookup?.subscriptionIDs == [ApprovalWire.promptSubscriptionID])
    }

    /// Missing: created once, exactly as made; a second ensure finds it and
    /// saves nothing.
    @Test func aMissingSubscriptionIsCreatedOnceAndASecondEnsureSavesNothing() async throws {
        let database = ScriptedPromptDatabase(lookup: [PromptScript.lookupItemFailed(PromptScript.ck(.unknownItem)), PromptScript.found])
        let source = LivePromptSource(database: database)
        #expect(await source.ensureSubscription())
        #expect(database.handed == ["lookup", "save"])
        let save = try #require(database.changesHanded.first)
        #expect(save.subscriptionIDsToDelete == nil)
        #expect(save.subscriptionsToSave?.count == 1)
        #expect(save.subscriptionsToSave?.allSatisfy { CloudKitAlertSource.isPromptSubscription($0) } == true)
        #expect(await source.ensureSubscription())
        #expect(database.handed == ["lookup", "save", "lookup"], "a second ensure saves nothing")
    }

    struct LookupRow: CustomTestStringConvertible, Sendable {
        let name: String
        let lookup: @Sendable (CKFetchSubscriptionsOperation) -> Void
        let handed: [String]
        let exists: Bool
        var testDescription: String { name }
    }

    /// Only a subscription the server does not have is created; a lookup
    /// that failed any other way creates nothing, and is tried again later.
    static let lookupRows: [LookupRow] = [
        LookupRow(name: "found", lookup: PromptScript.found, handed: ["lookup"], exists: true),
        LookupRow(name: "unknownItem on the subscription", lookup: PromptScript.lookupItemFailed(PromptScript.ck(.unknownItem)),
                  handed: ["lookup", "save"], exists: true),
        LookupRow(name: "unknownItem for the whole lookup", lookup: PromptScript.lookupFailed(PromptScript.ck(.unknownItem)),
                  handed: ["lookup", "save"], exists: true),
        // CloudKit's Result overlay hands a batch partialFailure to the
        // result block as a success (the Mac's #139): the subscription's
        // own result is what says it is missing, so a batch alone reads as
        // nothing reported.
        LookupRow(name: "a one-item partial failure for the batch alone",
                  lookup: PromptScript.lookupFailed(PromptScript.partial(PromptScript.ck(.unknownItem))),
                  handed: ["lookup"], exists: false),
        LookupRow(name: "networkUnavailable on the subscription",
                  lookup: PromptScript.lookupItemFailed(PromptScript.ck(.networkUnavailable)), handed: ["lookup"], exists: false),
        LookupRow(name: "notAuthenticated for the whole lookup", lookup: PromptScript.lookupFailed(PromptScript.ck(.notAuthenticated)),
                  handed: ["lookup"], exists: false),
        LookupRow(name: "refused (invalidArguments)", lookup: PromptScript.lookupFailed(PromptScript.ck(.invalidArguments)),
                  handed: ["lookup"], exists: false),
        LookupRow(name: "nothing reported", lookup: PromptScript.lookupEmpty, handed: ["lookup"], exists: false),
    ]

    @Test(arguments: lookupRows)
    func aSubscriptionIsCreatedOnlyWhenMissing(_ row: LookupRow) async {
        let database = ScriptedPromptDatabase(lookup: [row.lookup])
        #expect(await LivePromptSource(database: database).ensureSubscription() == row.exists)
        #expect(database.handed == row.handed)
    }

    /// #194 security review: a subscription found under the prompt ID but
    /// not exactly as made (any change to its shape) is not taken as found:
    /// it reads as missing, and the save that follows replaces it with the
    /// one this build makes; a failed replacement counts as not made sure
    /// of, so the next sync tries again.
    @Test(arguments: changedSubscriptions)
    func aSubscriptionInAnotherShapeIsReplaced(_ row: Changed) async throws {
        let database = ScriptedPromptDatabase(lookup: [PromptScript.foundAs(row.change)])
        #expect(await LivePromptSource(database: database).ensureSubscription())
        #expect(database.handed == ["lookup", "save"])
        let save = try #require(database.changesHanded.first)
        #expect(save.subscriptionIDsToDelete == nil && save.subscriptionsToSave?.count == 1)
        #expect(save.subscriptionsToSave?.allSatisfy { CloudKitAlertSource.isPromptSubscription($0) } == true)
        let refused = ScriptedPromptDatabase(lookup: [PromptScript.foundAs(row.change)],
                                             change: PromptScript.changeItemFailed(PromptScript.ck(.permissionFailure)))
        #expect(await LivePromptSource(database: refused).ensureSubscription() == false)
    }

    struct ChangeRow: CustomTestStringConvertible, Sendable {
        let name: String
        let change: @Sendable (CKModifySubscriptionsOperation) -> Void
        let done: Bool
        var testDescription: String { name }
    }

    /// A creation counts only when the subscription's own save says so.
    static let saveRows: [ChangeRow] = [
        ChangeRow(name: "saved", change: PromptScript.changed, done: true),
        ChangeRow(name: "refused on the subscription", change: PromptScript.changeItemFailed(PromptScript.ck(.permissionFailure)),
                  done: false),
        ChangeRow(name: "the batch failed", change: PromptScript.changeFailed(PromptScript.ck(.networkFailure)), done: false),
        ChangeRow(name: "nothing reported", change: PromptScript.changeEmpty, done: false),
    ]

    @Test(arguments: saveRows)
    func aCreationCountsOnlyWhenSaved(_ row: ChangeRow) async {
        let database = ScriptedPromptDatabase(lookup: [PromptScript.lookupItemFailed(PromptScript.ck(.unknownItem))], change: row.change)
        #expect(await LivePromptSource(database: database).ensureSubscription() == row.done)
        #expect(database.handed == ["lookup", "save"])
    }

    // MARK: Removing it

    /// Gone once its deletion says so, or when it was not there.
    static let removalRows: [ChangeRow] = [
        ChangeRow(name: "deleted", change: PromptScript.changed, done: true),
        ChangeRow(name: "not there (unknownItem)", change: PromptScript.changeItemFailed(PromptScript.ck(.unknownItem)), done: true),
        ChangeRow(name: "not there, for the whole batch", change: PromptScript.changeFailed(PromptScript.ck(.unknownItem)), done: true),
        ChangeRow(name: "refused on the subscription", change: PromptScript.changeItemFailed(PromptScript.ck(.networkFailure)),
                  done: false),
        ChangeRow(name: "the batch failed", change: PromptScript.changeFailed(PromptScript.ck(.networkUnavailable)), done: false),
        ChangeRow(name: "nothing reported", change: PromptScript.changeEmpty, done: false),
    ]

    @Test(arguments: removalRows)
    func aRemovalDeletesTheOneSubscription(_ row: ChangeRow) async throws {
        let database = ScriptedPromptDatabase(change: row.change)
        #expect(await LivePromptSource(database: database).removeSubscription() == row.done)
        #expect(database.handed == ["remove"])
        let removal = try #require(database.changesHanded.first)
        #expect(removal.subscriptionIDsToDelete == [ApprovalWire.promptSubscriptionID])
        #expect(removal.subscriptionsToSave?.isEmpty ?? true, "nothing saved")
    }

    // MARK: The snapshot

    /// A decision and a pairing response as a snapshot hands them over: the
    /// prompt's fields only, so just the version.
    static func other(_ type: ApprovalWire.RecordType, named name: String) -> CKRecord {
        let record = CKRecord(recordType: type.rawValue, recordID: CKRecord.ID(recordName: name, zoneID: CloudKitAlertSource.approvalsZoneID))
        record[Field.wireVersion.rawValue] = ApprovalWire.wireVersion as NSNumber
        return record
    }

    /// Every prompt in the zone is read; every other record, and a prompt
    /// that is not whole, is dropped.
    @Test func aSnapshotReadsEveryPromptAndDropsTheRest() async throws {
        let second = RequestFixtures.id(0x43)
        let records: [CKRecord] = [
            CloudKitRequestRecordTests.macRecord(),
            Self.other(.decision, named: ApprovalWire.decisionRecordName(for: CloudKitRequestRecordTests.id)),
            CloudKitRequestRecordTests.macRecord(name: second.hex),
            Self.other(.pairingResponse, named: String(repeating: "c", count: 64)),
            CloudKitRequestRecordTests.macRecord(name: RequestFixtures.id(0x44).hex, values: [.toolName: nil]),
        ]
        let database = ScriptedPromptDatabase(snapshot: PromptScript.records(records))
        let prompts = try #require(await LivePromptSource(database: database).snapshot())
        #expect(prompts.map(\.id) == [CloudKitRequestRecordTests.id, second])
        #expect(database.handed == ["snapshot"])
    }

    @Test func anEmptyZoneOffersNothing() async {
        let database = ScriptedPromptDatabase(snapshot: PromptScript.records([]))
        #expect(await LivePromptSource(database: database).snapshot() == [])
    }

    struct FailedRead: CustomTestStringConvertible, Sendable {
        let name: String
        let snapshot: @Sendable (CKFetchRecordZoneChangesOperation) -> Void
        var testDescription: String { name }
    }

    /// Any part of the read failing fails all of it: a record that did not
    /// load could be a prompt still offered, so no partial list is read.
    static let failedReads: [FailedRead] = [
        FailedRead(name: "a record failed to load", snapshot: PromptScript.recordFailed(PromptScript.ck(.networkFailure))),
        FailedRead(name: "the zone failed", snapshot: PromptScript.zoneFailed(PromptScript.ck(.zoneNotFound))),
        FailedRead(name: "the read failed", snapshot: PromptScript.snapshotFailed(PromptScript.ck(.networkUnavailable))),
        FailedRead(name: "refused (invalidArguments)", snapshot: PromptScript.snapshotFailed(PromptScript.ck(.invalidArguments))),
    ]

    @Test(arguments: failedReads)
    func aFailedReadReadsNothing(_ row: FailedRead) async {
        let database = ScriptedPromptDatabase(snapshot: row.snapshot)
        #expect(await LivePromptSource(database: database).snapshot() == nil)
    }

    /// The read the source builds: the approvals zone from the start, every
    /// change, the prompt's six fields and no other.
    @Test func theSnapshotAsksForThePromptsFieldsAlone() async throws {
        let database = ScriptedPromptDatabase()
        _ = await LivePromptSource(database: database).snapshot()
        let snapshot = try #require(database.snapshotsHanded.first)
        #expect(snapshot.recordZoneIDs == [CloudKitAlertSource.approvalsZoneID])
        #expect(snapshot.fetchAllChanges)
        let zone = try #require(snapshot.configurationsByRecordZoneID?[CloudKitAlertSource.approvalsZoneID])
        #expect(zone.previousServerChangeToken == nil)
        #expect(Set(zone.desiredKeys ?? []) == Set(Field.allCases.map(\.rawValue)))
        #expect(zone.desiredKeys?.count == Field.allCases.count)
        #expect(snapshot.configuration.qualityOfService == .userInitiated)
    }

    // MARK: The live database's admit list

    /// What the source hands over is exactly what the live database runs.
    @Test func everyOperationTheSourceBuildsIsAdmitted() async throws {
        let database = ScriptedPromptDatabase(lookup: [PromptScript.lookupItemFailed(PromptScript.ck(.unknownItem))])
        let source = LivePromptSource(database: database)
        _ = await source.ensureSubscription()
        _ = await source.removeSubscription()
        _ = await source.snapshot()
        #expect(database.handed == ["lookup", "save", "remove", "snapshot"])
        #expect(database.lookupsHanded.allSatisfy { CloudKitAlertSource.isPromptSubscriptionLookup($0) })
        #expect(database.changesHanded.count == 2)
        #expect(database.changesHanded.allSatisfy { CloudKitAlertSource.isPromptSubscriptionChange($0) })
        #expect(database.snapshotsHanded.allSatisfy { CloudKitAlertSource.isPromptSnapshot($0) })
    }

    /// A snapshot of anything else: another zone or more zones, no fields
    /// named (every field), another field or one missing, a partial fetch.
    @Test func everyOtherReadIsRefused() {
        let zone = CloudKitAlertSource.approvalsZoneID
        let keys = CloudKitAlertSource.promptKeys
        func read(_ zones: [CKRecordZone.ID], _ desired: [CKRecord.FieldKey]?, all: Bool = true) -> CKFetchRecordZoneChangesOperation {
            var configurations: [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration] = [:]
            for id in zones {
                let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
                configuration.desiredKeys = desired
                configurations[id] = configuration
            }
            let snapshot = CKFetchRecordZoneChangesOperation(recordZoneIDs: zones, configurationsByRecordZoneID: configurations)
            snapshot.fetchAllChanges = all
            return snapshot
        }
        let other = CKRecordZone.ID(zoneName: ApprovalWire.zoneName, ownerName: "_someoneElse")
        let decisionKeys: [CKRecord.FieldKey] = ApprovalWire.DecisionField.allCases.map(\.rawValue)
        let more: [CKRecord.FieldKey] = keys + [ApprovalWire.DecisionField.verdict.rawValue]
        let fewer: [CKRecord.FieldKey] = Array(keys.dropLast())
        let twice: [CKRecord.FieldKey] = fewer + [keys[0]]
        let refused: [(String, CKFetchRecordZoneChangesOperation)] = [
            ("the default zone", read([.default], keys)),
            ("another owner's approvals zone", read([other], keys)),
            ("two zones", read([zone, .default], keys)),
            ("every field (none named)", read([zone], nil)),
            ("a decision's fields", read([zone], decisionKeys)),
            ("one field more", read([zone], more)),
            ("one field fewer", read([zone], fewer)),
            ("a field twice, one missing", read([zone], twice)),
            ("a partial fetch", read([zone], keys, all: false)),
            ("no configuration", CKFetchRecordZoneChangesOperation(recordZoneIDs: [zone], configurationsByRecordZoneID: nil)),
        ]
        #expect(CloudKitAlertSource.isPromptSnapshot(read([zone], keys)), "vacuity: the right shape is admitted")
        for (name, snapshot) in refused {
            #expect(!CloudKitAlertSource.isPromptSnapshot(snapshot), "\(name)")
        }
    }

    /// A lookup of anything but the prompt subscription by its one ID.
    @Test func everyOtherLookupIsRefused() {
        #expect(CloudKitAlertSource.isPromptSubscriptionLookup(CKFetchSubscriptionsOperation(subscriptionIDs: [PromptScript.id])))
        let refused: [(String, CKFetchSubscriptionsOperation)] = [
            ("every subscription", CKFetchSubscriptionsOperation.fetchAllSubscriptionsOperation()),
            ("the alert subscription", CKFetchSubscriptionsOperation(subscriptionIDs: [AlertWire.subscriptionID])),
            ("both", CKFetchSubscriptionsOperation(subscriptionIDs: [PromptScript.id, AlertWire.subscriptionID])),
            ("none", CKFetchSubscriptionsOperation(subscriptionIDs: [])),
        ]
        for (name, lookup) in refused {
            #expect(!CloudKitAlertSource.isPromptSubscriptionLookup(lookup), "\(name)")
        }
    }

    /// A change of anything else: another subscription saved or deleted, a
    /// save and a deletion together, two saves, nothing at all.
    @Test func everyOtherChangeIsRefused() {
        let prompt = CloudKitAlertSource.makePromptSubscription()
        let leaky = CloudKitAlertSource.makePromptSubscription()
        leaky.notificationInfo?.desiredKeys = [Field.inputPreview.rawValue]
        let save = CKModifySubscriptionsOperation(subscriptionsToSave: [prompt], subscriptionIDsToDelete: nil)
        let removal = CKModifySubscriptionsOperation(subscriptionsToSave: nil, subscriptionIDsToDelete: [PromptScript.id])
        #expect(CloudKitAlertSource.isPromptSubscriptionChange(save) && CloudKitAlertSource.isPromptSubscriptionChange(removal),
                "vacuity: the two right shapes are admitted")
        let refused: [(String, CKModifySubscriptionsOperation)] = [
            ("the alert subscription saved", CKModifySubscriptionsOperation(subscriptionsToSave: [CloudKitAlertSource.makeSubscription()],
                                                                             subscriptionIDsToDelete: nil)),
            ("a leaky prompt subscription saved", CKModifySubscriptionsOperation(subscriptionsToSave: [leaky], subscriptionIDsToDelete: nil)),
            ("two saved", CKModifySubscriptionsOperation(subscriptionsToSave: [prompt, CloudKitAlertSource.makePromptSubscription()],
                                                         subscriptionIDsToDelete: nil)),
            ("the alert subscription deleted", CKModifySubscriptionsOperation(subscriptionsToSave: nil,
                                                                              subscriptionIDsToDelete: [AlertWire.subscriptionID])),
            ("both deleted", CKModifySubscriptionsOperation(subscriptionsToSave: nil,
                                                            subscriptionIDsToDelete: [PromptScript.id, AlertWire.subscriptionID])),
            ("a save beside a deletion", CKModifySubscriptionsOperation(subscriptionsToSave: [prompt], subscriptionIDsToDelete: [PromptScript.id])),
            ("nothing", CKModifySubscriptionsOperation(subscriptionsToSave: nil, subscriptionIDsToDelete: nil)),
        ]
        for (name, change) in refused {
            #expect(!CloudKitAlertSource.isPromptSubscriptionChange(change), "\(name)")
        }
    }

    /// A refusal, as the live database makes it (lock 6c): never run, its
    /// own result block told `invalidArguments`. The source reads a closed
    /// failure each time and never hangs: no subscription, none removed, no
    /// read.
    @Test func aRefusalIsAClosedFailureToTheSource() async {
        let database = RefusingApprovalDatabase()
        let source = LivePromptSource(database: database)
        #expect(await source.ensureSubscription() == false)
        #expect(await source.removeSubscription() == false)
        #expect(await source.snapshot() == nil)
        #expect(database.refused == 3, "the lookup, the removal and the read; nothing saved after a refused lookup")
    }

    // MARK: Decisions (admitted, written by nothing yet)

    static let decision = CloudKitDecisionWriterTests.decision

    /// The decision writer's own save is what the live database admits.
    @Test func theDecisionWritersOwnSaveIsAdmitted() async throws {
        let database = ScriptedApprovalDatabase(ModifyOperationScript([.saved(0), .batchSucceeded]))
        _ = await CloudKitDecisionWriter(database: database).write(Self.decision)
        let operation = try #require(database.submitted.first)
        #expect(CloudKitAlertSource.isDecisionCreation(operation))
        #expect(!CloudKitAlertSource.isPairingResponseCreation(operation))
    }

    /// Every other shape: another record type or zone, a name the record's
    /// own prompt ID does not give, a prompt ID missing or in the clear, a
    /// deletion, an overwrite, more records or none.
    @Test func everyOtherDecisionShapeIsRefused() {
        func operation(_ records: [CKRecord]?, deleting ids: [CKRecord.ID]? = nil,
                       policy: CKModifyRecordsOperation.RecordSavePolicy = .ifServerRecordUnchanged) -> CKModifyRecordsOperation {
            let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: ids)
            operation.savePolicy = policy
            return operation
        }
        let right = CloudKitAlertSource.makeDecisionRecord(Self.decision)
        let other = PhoneDecision(promptID: RequestFixtures.id(0x79), verdict: .deny, decidedAt: Self.decision.decidedAt,
                                  signature: Self.decision.signature)!
        let misnamed = CKRecord(recordType: ApprovalWire.RecordType.decision.rawValue,
                                recordID: CloudKitAlertSource.decisionRecordID(for: other.promptID))
        for key in right.allKeys() { misnamed[key] = right[key] }
        for key in right.encryptedValues.allKeys() { misnamed.encryptedValues[key] = right.encryptedValues[key] }
        let unnamed = CloudKitAlertSource.makeDecisionRecord(Self.decision)
        unnamed.encryptedValues[ApprovalWire.DecisionField.promptID.rawValue] = nil
        let clear = CloudKitAlertSource.makeDecisionRecord(Self.decision)
        clear.encryptedValues[ApprovalWire.DecisionField.promptID.rawValue] = nil
        clear[ApprovalWire.DecisionField.promptID.rawValue] = Self.decision.promptID.hex as NSString
        let elsewhere = CKRecord(recordType: ApprovalWire.RecordType.decision.rawValue,
                                 recordID: CKRecord.ID(recordName: right.recordID.recordName, zoneID: .default))
        elsewhere.encryptedValues[ApprovalWire.DecisionField.promptID.rawValue] = Self.decision.promptID.hex as NSString
        let prompt = CloudKitRequestRecordTests.macRecord()
        let refused: [(String, CKModifyRecordsOperation)] = [
            ("a prompt", operation([prompt])),
            ("a pairing response", operation([CloudKitPairingWriterTests.record()])),
            ("named for another prompt", operation([misnamed])),
            ("no prompt ID", operation([unnamed])),
            ("the prompt ID in the clear", operation([clear])),
            ("the default zone", operation([elsewhere])),
            ("a deletion beside it", operation([right], deleting: [prompt.recordID])),
            ("a deletion alone", operation(nil, deleting: [right.recordID])),
            ("an overwrite (all keys)", operation([right], policy: .allKeys)),
            ("an overwrite (changed keys)", operation([right], policy: .changedKeys)),
            ("two decisions", operation([right, CloudKitAlertSource.makeDecisionRecord(other)])),
            ("no record", operation([])),
        ]
        #expect(CloudKitAlertSource.isDecisionCreation(operation([right])), "vacuity: the right shape is admitted")
        for (name, candidate) in refused {
            #expect(!CloudKitAlertSource.isDecisionCreation(candidate), "\(name)")
        }
    }

    /// A refused decision is a definite failure to its writer, never
    /// "may have landed".
    @Test func aRefusedDecisionReadsFailed() async {
        let database = RefusingApprovalDatabase()
        #expect(await CloudKitDecisionWriter(database: database).write(Self.decision) == .failed)
        #expect(database.refused == 1)
    }
}
