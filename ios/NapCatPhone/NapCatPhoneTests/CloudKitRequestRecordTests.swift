import CloudKit
import Foundation
import NapCatWire
@testable import NapCatPhone
import Testing

/// F4 slice S3: a PromptRequest record (as the Mac's writer builds it) and a
/// prompt push, as the phone reads them; since S-PAIR-B (whole prompts
/// only), a record missing any field is refused, field by field. CKRecords
/// are plain values here; nothing talks to iCloud.
@Suite struct CloudKitRequestRecordTests {
    static let id = RequestFixtures.id(0x42)
    static let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
    static let preview = #"{"command":"git status --short"}"#
    typealias Field = ApprovalWire.PromptField

    /// A prompt record exactly as the Mac writes one (its type and zone, the
    /// prompt ID as its name, every wire field, the readable ones
    /// encrypted), with overrides. `clear` moves an encrypted field into the
    /// clear; `hidden` encrypts a clear one.
    static func macRecord(
        type: String = ApprovalWire.RecordType.prompt.rawValue,
        zone: String = ApprovalWire.zoneName,
        name: String = CloudKitRequestRecordTests.id.hex,
        values: [Field: NSObject?] = [:],
        clear: Field? = nil,
        hidden: Field? = nil,
        extra: String? = nil
    ) -> CKRecord {
        let zoneID = CKRecordZone.ID(zoneName: zone, ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
        let defaults: [Field: NSObject] = [
            .wireVersion: ApprovalWire.wireVersion as NSNumber, .toolName: "Bash" as NSString,
            .inputPreview: preview as NSString, .projectLabel: "napcat" as NSString,
            .createdAt: createdAt as NSDate, .expiresAt: createdAt.addingTimeInterval(PendingRequest.timeToLive) as NSDate,
        ]
        for field in Field.allCases {
            let value = (values.keys.contains(field) ? values[field]! : defaults[field]) as? CKRecordValue
            let encrypted = ApprovalWire.encryptedPromptFields.contains(field)
            if (encrypted && field != clear) || field == hidden {
                record.encryptedValues[field.rawValue] = value
            } else {
                record[field.rawValue] = value
            }
        }
        if let extra { record[extra] = "x" as NSString }
        return record
    }

    @Test func theMacsRecordIsAPendingRequest() throws {
        let request = try #require(CloudKitAlertSource.pendingRequest(from: Self.macRecord()))
        #expect(request.id == Self.id)
        #expect(request.toolName == "Bash")
        #expect(request.inputPreview == Self.preview)
        #expect(request.projectLabel == "napcat")
        #expect(request.createdAt == Self.createdAt)
        #expect(request.expiresAt == Self.createdAt.addingTimeInterval(PendingRequest.timeToLive))
    }

    struct Row: CustomTestStringConvertible, Sendable {
        let name: String
        let record: @Sendable () -> CKRecord
        var testDescription: String { name }
    }

    static let malformed: [Row] = [
        Row(name: "a decision record") { macRecord(type: ApprovalWire.RecordType.decision.rawValue) },
        Row(name: "an alert record") { macRecord(type: AlertWire.recordType) },
        Row(name: "the default zone") { macRecord(zone: CKRecordZone.ID.defaultZoneName) },
        Row(name: "a name that is not a prompt ID") { macRecord(name: "session-1790000000123") },
        Row(name: "an uppercase prompt ID") { macRecord(name: id.hex.uppercased()) },
        Row(name: "the preview in the clear") { macRecord(clear: .inputPreview) },
        Row(name: "the tool in the clear") { macRecord(clear: .toolName) },
        Row(name: "the project in the clear") { macRecord(clear: .projectLabel) },
        Row(name: "the expiry encrypted") { macRecord(hidden: .expiresAt) },
        Row(name: "an extra field") { macRecord(extra: "description") },
        Row(name: "version 2") { macRecord(values: [.wireVersion: 2 as NSNumber]) },
        Row(name: "no version") { macRecord(values: [.wireVersion: nil]) },
        Row(name: "no tool") { macRecord(values: [.toolName: nil]) },
        Row(name: "an empty tool") { macRecord(values: [.toolName: "" as NSString]) },
        Row(name: "a preview that is not text") { macRecord(values: [.inputPreview: 7 as NSNumber]) },
        Row(name: "no preview") { macRecord(values: [.inputPreview: nil]) },
        Row(name: "no project") { macRecord(values: [.projectLabel: nil]) },
        Row(name: "no creation time") { macRecord(values: [.createdAt: nil]) },
        Row(name: "an expiry as text") { macRecord(values: [.expiresAt: "soon" as NSString]) },
        Row(name: "no expiry") { macRecord(values: [.expiresAt: nil]) },
        Row(name: "a window past the TTL") {
            macRecord(values: [.expiresAt: createdAt.addingTimeInterval(PendingRequest.timeToLive + 1) as NSDate])
        },
        Row(name: "a window that ends first") { macRecord(values: [.expiresAt: createdAt.addingTimeInterval(-1) as NSDate]) },
    ]

    @Test(arguments: malformed)
    func aMalformedRecordIsNotARequest(_ row: Row) {
        #expect(CloudKitAlertSource.pendingRequest(from: row.record()) == nil)
    }

    // MARK: Whole prompts only: a record missing any field is never shown or answered

    /// S-PAIR-B (whole prompts only): the phone signs what it shows, so it
    /// shows only a whole prompt. A record missing ANY of the wire's fields,
    /// each one in turn, is not a request: nothing of it is drawn, and
    /// nothing can answer it.
    @Test(arguments: Field.allCases)
    func aRecordMissingAnyFieldIsNotARequest(_ field: Field) {
        let record = Self.macRecord(values: [field: nil])
        #expect(!Set(record.allKeys()).contains(field.rawValue), "vacuity: the field really is missing")
        #expect(Set(record.allKeys()).count == Field.allCases.count - 1)
        #expect(CloudKitAlertSource.pendingRequest(from: record) == nil, "a record without \(field.rawValue) was read")
    }

    /// Any two fields missing, and a record holding nothing at all.
    @Test func aRecordMissingSeveralFieldsIsNotARequest() {
        for first in Field.allCases {
            for second in Field.allCases where second != first {
                #expect(CloudKitAlertSource.pendingRequest(from: Self.macRecord(values: [first: nil, second: nil])) == nil,
                        "\(first.rawValue) and \(second.rawValue) missing")
            }
        }
        let empty = CKRecord(recordType: ApprovalWire.RecordType.prompt.rawValue,
                             recordID: CKRecord.ID(recordName: Self.id.hex,
                                                   zoneID: CKRecordZone.ID(zoneName: ApprovalWire.zoneName,
                                                                           ownerName: CKCurrentUserDefaultName)))
        #expect(CloudKitAlertSource.pendingRequest(from: empty) == nil)
    }

    /// Nothing reaches the inbox, and so the screen, but through the strict
    /// reader: every malformed or incomplete record leaves it empty.
    @MainActor
    @Test func noIncompleteRecordReachesTheInbox() {
        let inbox = RequestFixtures.inbox(TestClock())
        let records = Self.malformed.map { $0.record() } + Field.allCases.map { Self.macRecord(values: [$0: nil]) }
        inbox.receive(records.compactMap(CloudKitAlertSource.pendingRequest(from:)))
        #expect(inbox.requests.isEmpty)
        inbox.receive([Self.macRecord()].compactMap(CloudKitAlertSource.pendingRequest(from:)))
        #expect(inbox.requests.map(\.id) == [Self.id], "vacuity: a whole record is read")
    }

    /// In the app, a request is built only by the strict reader (and by the
    /// fixtures): no other source can put a partial prompt on screen.
    /// AMENDED (#166): and no app source has an implicit `.init(`, which
    /// builds one with no `PendingRequest(` to count (the security review's
    /// B9).
    static func requestBuilders(_ app: [CloudKitStructureTests.Source]) -> [String] {
        app.compactMap { path, text in
            let code = RecordPathStructureTests.constructionSpelling(CloudKitStructureTests.codeOnly(text))
            let count = CloudKitStructureTests.occurrences(of: "PendingRequest(", in: code)
            let allowed = [CloudKitStructureTests.cloudKitFile, "\(CloudKitStructureTests.appDir)/Fixtures/FixtureRequests.swift"]
            return count == (allowed.contains(path) ? 1 : 0) ? nil : "\(path) builds a request \(count) time(s)"
        } + RecordPathStructureTests.implicitInitFailures(app, rule: "a request is built only by the strict reader and the fixtures")
    }

    @Test func onlyTheStrictReaderBuildsARequest() throws {
        let app = try CloudKitStructureTests.swiftFiles(under: CloudKitStructureTests.appDir)
        #expect(Self.requestBuilders(app).isEmpty, "\(Self.requestBuilders(app))")
        let inbox = "\(CloudKitStructureTests.appDir)/Model/RequestInbox.swift"
        let fixture = "\(CloudKitStructureTests.appDir)/Fixtures/FixtureRequests.swift"
        for (path, plant) in [
            (inbox, "let r = PendingRequest(id: i, toolName: t, inputPreview: \"\", projectLabel: \"\", createdAt: c, expiresAt: e)"),
            (inbox, "let r = PendingRequest.init(id: i, toolName: t, inputPreview: p, projectLabel: l, createdAt: c, expiresAt: e)"),
            // #166: the security review's B9, as planted, and its neighbours:
            // returned, as an argument, split over two lines, and a second
            // one in the fixtures (which may build exactly one, by name).
            (inbox, "func spareRequest(i: PromptID, c: Date) -> PendingRequest? { let r: PendingRequest? = .init(id: i, toolName: \"Bash\", "
                + "inputPreview: \"\", projectLabel: \"\", createdAt: c, expiresAt: c); return r }"),
            (inbox, "func spare(i: PromptID, c: Date) -> PendingRequest? {\n    return .init(id: i, toolName: t, inputPreview: p, "
                + "projectLabel: l, createdAt: c, expiresAt: c)\n}"),
            (inbox, "func spare(i: PromptID, c: Date) { show(.init(id: i, toolName: t, inputPreview: p, projectLabel: l, createdAt: c, expiresAt: c)) }"),
            (inbox, "let r: PendingRequest? =\n    .init(id: i, toolName: t, inputPreview: p, projectLabel: l, createdAt: c, expiresAt: e)"),
            (fixture, "let spare: PendingRequest? = .init(id: i, toolName: t, inputPreview: p, projectLabel: l, createdAt: c, expiresAt: e)"),
        ] {
            let mutant: [CloudKitStructureTests.Source] = app.map { $0.path == path ? ($0.path, $0.text + "\n" + plant) : $0 }
            #expect(mutant.map(\.text) != app.map(\.text), "canary '\(plant)' did not apply")
            #expect(!Self.requestBuilders(mutant).isEmpty, "canary '\(plant)' was NOT caught")
        }
        // A doc comment may name the implicit init it rules out.
        #expect(Self.requestBuilders(app.map {
            $0.path == inbox ? ($0.path, $0.text + "\n/// never let r: PendingRequest? = .init(…) here") : $0
        }).isEmpty)
    }

    // MARK: The prompt push

    static func promptPush(recordName: String? = id.hex, subscriptionID: String = ApprovalWire.promptSubscriptionID,
                           zoneName: String = ApprovalWire.zoneName) -> [AnyHashable: Any] {
        CloudKitAlertSourceTests.pushPayload(recordName: recordName, subscriptionID: subscriptionID, zoneName: zoneName)
    }

    @Test func thePromptSubscriptionsPushNamesItsPrompt() {
        #expect(CloudKitAlertSource.pushedPromptID(in: Self.promptPush()) == Self.id)
    }

    /// Only the prompt subscription's push, for an approvals-zone record
    /// named by a prompt ID, names a prompt; and it is never an alert.
    @Test func otherPushesNameNoPrompt() {
        #expect(CloudKitAlertSource.pushedPromptID(in: Self.promptPush(subscriptionID: AlertWire.subscriptionID)) == nil)
        #expect(CloudKitAlertSource.pushedPromptID(in: Self.promptPush(zoneName: CKRecordZone.ID.defaultZoneName)) == nil)
        #expect(CloudKitAlertSource.pushedPromptID(in: Self.promptPush(recordName: nil)) == nil)
        #expect(CloudKitAlertSource.pushedPromptID(in: Self.promptPush(recordName: "session-1790000000124")) == nil)
        #expect(CloudKitAlertSource.pushedPromptID(in: CloudKitAlertSourceTests.pushPayload()) == nil)
        #expect(CloudKitAlertSource.pushedPromptID(in: [:]) == nil)
        #expect(CloudKitAlertSource.pushedRecordName(in: Self.promptPush()) == nil, "a prompt push is no alert")
    }
}
