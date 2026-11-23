import CloudKit
import Foundation
import NapCatWire
@testable import NapCatPhone
import Testing

/// F4 slice S3: a PromptRequest record (as the Mac's writer builds it) and a
/// prompt push, as the phone reads them. CKRecords are plain values here;
/// nothing talks to iCloud.
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
        Row(name: "no project") { macRecord(values: [.projectLabel: nil]) },
        Row(name: "no creation time") { macRecord(values: [.createdAt: nil]) },
        Row(name: "an expiry as text") { macRecord(values: [.expiresAt: "soon" as NSString]) },
        Row(name: "a window past the TTL") {
            macRecord(values: [.expiresAt: createdAt.addingTimeInterval(PendingRequest.timeToLive + 1) as NSDate])
        },
        Row(name: "a window that ends first") { macRecord(values: [.expiresAt: createdAt.addingTimeInterval(-1) as NSDate]) },
    ]

    @Test(arguments: malformed)
    func aMalformedRecordIsNotARequest(_ row: Row) {
        #expect(CloudKitAlertSource.pendingRequest(from: row.record()) == nil)
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
