// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import CloudKit
import NapCatWire
import Testing
@testable import NapCat

/// F3 stage 1 privacy ceiling: what reaches iCloud is a CLOSED schema
/// carrying a CLOSED vocabulary.
///
/// - SCHEMA: an alert record is type `Alert`, in the private database's
///   default zone, with exactly the fields {body, lane, firedAt} — any other
///   field fails here, at runtime and in the source.
/// - NO FREE TEXT: mirroring the ntfy design (`theSenderApiCannotCarryFreeText`),
///   nothing on the phone path accepts a String: the senders expose only the
///   byte-locked `send(_ kind:to:at:completion:)`, the CloudKit seam takes a
///   payload, and the payload's body is built in one place from the closed
///   kind by `LidGuardPolicy.messageBody` — byte-for-byte the ntfy body.
///
/// CKRecord values are built in memory only; nothing here talks to iCloud
/// or constructs a container.
struct PhoneTransportSchemaTests {
    static let firedAt = Date(timeIntervalSince1970: 1_800_000_321.25)

    static let everyKind: [LidGuardMessageKind] = [
        .lidAlert(busySessionCount: 2),
        .test,
        .sessionFinished(minutes: 42, folded: 1, stillWorking: 1),
        .needsAttention(minutes: 12, stillWorking: 0),
        .connectionRestored(minutes: 14, deliveredLate: 2, dropped: 0, lidMissed: 1),
    ]

    static let allowedFields: Set<String> = ["body", "lane", "firedAt"]

    /// Every way a record can break the schema.
    static func schemaFailures(_ record: CKRecord) -> [String] {
        var failures: [String] = []
        let keys = Set(record.allKeys())
        for extra in keys.subtracting(allowedFields).sorted() {
            failures.append("field '\(extra)' is outside the {body, lane, firedAt} schema")
        }
        for missing in allowedFields.subtracting(keys).sorted() {
            failures.append("field '\(missing)' is missing")
        }
        if record.recordType != AlertWire.recordType { failures.append("record type '\(record.recordType)'") }
        if record.recordID.zoneID != CKRecordZone.ID.default { failures.append("not the default zone") }
        if !(record[AlertWire.Field.body.rawValue] is String) { failures.append("body is not a String") }
        if !(record[AlertWire.Field.lane.rawValue] is String) { failures.append("lane is not a String") }
        if !(record[AlertWire.Field.firedAt.rawValue] is Date) { failures.append("firedAt is not a Date") }
        return failures
    }

    // MARK: - Schema (runtime)

    @Test func everyKindProducesExactlyTheWireSchema() throws {
        for kind in Self.everyKind {
            let payload = CloudKitMessageSender.makePayload(kind: kind, firedAt: Self.firedAt)
            let record = CloudKitMessageSender.makeRecord(payload)
            #expect(Self.schemaFailures(record).isEmpty, "\(kind): \(Self.schemaFailures(record))")
            #expect(record.allKeys().count == 3)
            #expect(Set(record.allKeys()) == Set(AlertWire.Field.allCases.map(\.rawValue)))
            #expect(record[AlertWire.Field.body.rawValue] as? String == payload.body)
            #expect(record[AlertWire.Field.lane.rawValue] as? String == payload.lane.rawValue)
            #expect(record[AlertWire.Field.firedAt.rawValue] as? Date == Self.firedAt)
            #expect(record.recordID.recordName == payload.recordName)
        }
    }

    /// The schema check is not vacuous: an extra field, a missing one, a
    /// wrong type or a wrong zone each trip it.
    @Test func theSchemaCheckCatchesMutants() {
        func fresh() -> CKRecord {
            CloudKitMessageSender.makeRecord(CloudKitMessageSender.makePayload(kind: .test, firedAt: Self.firedAt))
        }
        let extra = fresh()
        extra["sessionId"] = "abc" as NSString
        let missing = fresh()
        missing[AlertWire.Field.lane.rawValue] = nil
        let retyped = fresh()
        retyped[AlertWire.Field.firedAt.rawValue] = "22:49" as NSString
        let zoned = CKRecord(recordType: AlertWire.recordType,
                             recordID: CKRecord.ID(recordName: "lid-1", zoneID: CKRecordZone.ID(zoneName: "Other")))
        for key in AlertWire.Field.allCases.map(\.rawValue) { zoned[key] = fresh()[key] }
        for (name, record) in [("extra field", extra), ("missing field", missing),
                               ("wrong type", retyped), ("wrong zone", zoned)] {
            #expect(!Self.schemaFailures(record).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    /// Record names are `<lane>-<epoch ms>`: deterministic, lane + time
    /// only — never a session id, never the topic.
    @Test func recordNamesAreLanePlusEpochOnly() throws {
        let pattern = try Regex("^(lid|session)-[0-9]+$")
        for kind in Self.everyKind {
            let name = CloudKitMessageSender.makePayload(kind: kind, firedAt: Self.firedAt).recordName
            #expect(name.wholeMatch(of: pattern) != nil, "\(name)")
            #expect(name == CloudKitMessageSender.makePayload(kind: kind, firedAt: Self.firedAt).recordName,
                    "deterministic")
        }
        #expect(CloudKitMessageSender.recordName(lane: .lid, firedAt: Self.firedAt) == "lid-1800000321250")
        #expect(CloudKitMessageSender.makePayload(kind: .test, firedAt: Self.firedAt).lane == .lid)
        #expect(CloudKitMessageSender.makePayload(kind: .needsAttention(minutes: 1, stillWorking: 0),
                                                  firedAt: Self.firedAt).lane == .session)
    }

    // MARK: - Schema (source)

    static let cloudKitFile = "CloudKitMessageSender.swift"

    static func code(_ file: String) throws -> String {
        LidGuardStructureTests.codeOnly(try String(
            contentsOf: LidGuardStructureTests.sourcesDir().appendingPathComponent(file), encoding: .utf8))
    }

    /// The record is written in ONE function with exactly three keyed writes,
    /// each through an `AlertWire.Field` — no literal key, no bulk setter, no
    /// encrypted side channel.
    static func recordWriteFailures(_ code: String) -> [String] {
        var failures: [String] = []
        let writes = code.components(separatedBy: "record[").count - 1
        if writes != 3 { failures.append("\(writes) record[…] writes — the schema has exactly three fields") }
        for field in ["body", "lane", "firedAt"] where !code.contains("record[AlertWire.Field.\(field).rawValue] = ") {
            failures.append("the '\(field)' write must go through AlertWire.Field.\(field)")
        }
        for token in ["setObject(", "setValuesForKeys", "setValue(", "encryptedValues", "record[\"",
                      "CKAsset", "CKRecord.Reference"] where code.contains(token) {
            failures.append("'\(token)' — the record is written only through the three AlertWire.Field keys")
        }
        if code.components(separatedBy: "CKRecord(recordType:").count - 1 != 1 {
            failures.append("a record must be constructed in exactly one place (makeRecord)")
        }
        return failures
    }

    @Test func theRecordIsWrittenOnlyThroughTheThreeWireFields() throws {
        let code = try Self.code(Self.cloudKitFile)
        #expect(Self.recordWriteFailures(code).isEmpty, "\(Self.recordWriteFailures(code))")
        let anchor = "record[AlertWire.Field.firedAt.rawValue] = payload.firedAt as NSDate"
        #expect(code.contains(anchor), "vacuity: the firedAt write is the anchor")
        let mutants: [(String, String)] = [
            ("a fourth field", anchor + "\n        record[\"sessionId\"] = \"x\" as NSString"),
            ("a bulk setter", anchor + "\n        record.setValuesForKeys([:])"),
            ("an encrypted side channel", anchor + "\n        record.encryptedValues[\"x\"] = \"y\""),
            ("a literal key", "record[\"firedAt\"] = payload.firedAt as NSDate"),
        ]
        for (name, replacement) in mutants {
            let mutant = code.replacingOccurrences(of: anchor, with: replacement)
            #expect(mutant != code)
            #expect(!Self.recordWriteFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - No free text

    /// The payload is built in ONE place and its body only from the closed
    /// kind; for every kind it is byte-for-byte what the ntfy sender
    /// publishes (`LidGuardPolicy.messageBody` at the event clock time).
    @Test func thePayloadBodyIsTheNtfyTemplateForEveryKind() {
        for kind in Self.everyKind {
            let payload = CloudKitMessageSender.makePayload(kind: kind, firedAt: Self.firedAt)
            #expect(payload.body == LidGuardPolicy.messageBody(kind: kind,
                                                               clockTime: LidGuardPolicy.clockTime(Self.firedAt)))
            #expect(payload.firedAt == Self.firedAt)
            #expect(payload.lane == CloudKitMessageSender.wireLane(LidGuardPolicy.lane(for: kind)))
        }
        // The dry-run ntfy sender renders the same bodies — one template.
        let recording = RecordingMessageSender()
        let destination = NtfyDestination(server: "https://ntfy.sh", topic: "napcat-schema")
        for kind in Self.everyKind { recording.send(kind, to: destination, at: Self.firedAt) { _ in } }
        let clock = LidGuardPolicy.clockTime(Self.firedAt)
        #expect(recording.bodies(clockTime: clock)
                == Self.everyKind.map { CloudKitMessageSender.makePayload(kind: $0, firedAt: Self.firedAt).body })
        // Closed-set lock: a sixth kind will not compile until it is added here.
        for kind in Self.everyKind {
            switch kind {
            case .lidAlert, .test, .sessionFinished, .needsAttention, .connectionRestored: break
            }
        }
    }

    /// End to end through the seam: what the store is asked to save is
    /// exactly `makePayload` of the kind sent — the topic and server never
    /// reach it.
    @Test func whatTheStoreSavesIsTheBuiltPayload() {
        let store = FakeAlertStore()
        let sender = CloudKitMessageSender(isEntitled: { true }, makeStore: { store })
        let destination = NtfyDestination(server: "https://ntfy.example.com", topic: "napcat-secret-topic-77")
        for (offset, kind) in Self.everyKind.enumerated() {
            sender.send(kind, to: destination, at: Self.firedAt.addingTimeInterval(Double(offset) * 60)) { _ in }
        }
        #expect(store.saved == Self.everyKind.enumerated().map { offset, kind in
            CloudKitMessageSender.makePayload(kind: kind, firedAt: Self.firedAt.addingTimeInterval(Double(offset) * 60))
        })
        for payload in store.saved {
            for secret in ["napcat-secret-topic-77", "ntfy.example.com"] {
                #expect(!payload.body.contains(secret) && !payload.recordName.contains(secret))
            }
        }
    }

    /// The payload can never grow a field silently.
    @Test func thePayloadHasExactlyTheWireFieldsPlusItsName() {
        let payload = CloudKitMessageSender.makePayload(kind: .test, firedAt: Self.firedAt)
        #expect(Mirror(reflecting: payload).children.map(\.label) == ["recordName", "body", "lane", "firedAt"])
    }

    /// Source half of the no-free-text rule:
    /// - the CloudKit seam protocol is byte-locked and takes no String;
    /// - `CloudKitAlertPayload(` is constructed once, in `makePayload`, with
    ///   the body from `LidGuardPolicy.messageBody`;
    /// - every `func send(` on the phone path is the byte-locked protocol
    ///   signature, and no other function there takes a String (the one
    ///   exception is the probe's private entitlement-name lookup).
    static func freeTextFailures(cloudKit: String, composite: String) -> [String] {
        var failures: [String] = []
        let seam = [
            "protocol CloudKitAlertStore: AnyObject, Sendable {",
            "    func accountStatus(completion: @escaping @Sendable (CKAccountStatus, (any Error)?) -> Void)",
            "    func save(_ payload: CloudKitAlertPayload, completion: @escaping @Sendable ((any Error)?) -> Void)",
            "}",
        ].joined(separator: "\n")
        if !cloudKit.contains(seam) { failures.append("the CloudKit seam protocol changed — re-review the free-text guarantee") }

        if cloudKit.components(separatedBy: "CloudKitAlertPayload(").count - 1 != 1 {
            failures.append("CloudKitAlertPayload( must be constructed exactly once (makePayload)")
        }
        if !cloudKit.contains(
            "body: LidGuardPolicy.messageBody(kind: kind, clockTime: LidGuardPolicy.clockTime(firedAt)),") {
            failures.append("the payload body must come from LidGuardPolicy.messageBody")
        }

        let signature = [
            "    func send(",
            "        _ kind: LidGuardMessageKind,",
            "        to destination: NtfyDestination,",
            "        at firedAt: Date,",
            "        completion: @escaping @Sendable (MessageSendOutcome) -> Void",
            "    )",
        ].joined(separator: "\n")
        for (name, code) in [("CloudKitMessageSender.swift", cloudKit), ("CompositeMessageSender.swift", composite)] {
            let sends = code.components(separatedBy: "func send(").count - 1
            let locked = code.components(separatedBy: signature).count - 1
            if sends != 1 || locked != 1 {
                failures.append("\(name): \(sends) send entry point(s), \(locked) with the locked signature — expected 1/1")
            }
            for line in code.split(separator: "\n") where line.contains("func ") && line.contains(": String") {
                if line.contains("private static func entitlementValue(_ key: String) -> Any?") { continue }
                failures.append("\(name): a function takes a String — \(line.trimmingCharacters(in: .whitespaces))")
            }
            for label in ["body:", "text:", "message:", "subject:"] {
                for line in code.split(separator: "\n") where line.contains("func ") && line.contains(label) {
                    failures.append("\(name): '\(label)' parameter — \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return failures
    }

    @Test func nothingOnThePhonePathAcceptsFreeText() throws {
        let cloudKit = try Self.code(Self.cloudKitFile)
        let composite = try Self.code("CompositeMessageSender.swift")
        let failures = Self.freeTextFailures(cloudKit: cloudKit, composite: composite)
        #expect(failures.isEmpty, "\(failures)")

        let mutants: [(String, String, String)] = [
            ("a text overload on the composite", "composite",
             "\n    func send(text: String) {}\n"),
            ("a String on the seam", "cloudKit",
             "\n    func save(body: String, completion: @escaping @Sendable ((any Error)?) -> Void)\n"),
            ("a second payload site", "cloudKit",
             "\nlet stray = CloudKitAlertPayload(recordName: \"x\", body: \"y\", lane: .lid, firedAt: Date())\n"),
        ]
        for (name, file, injected) in mutants {
            let mutated = file == "composite"
                ? Self.freeTextFailures(cloudKit: cloudKit, composite: composite + injected)
                : Self.freeTextFailures(cloudKit: cloudKit + injected, composite: composite)
            #expect(!mutated.isEmpty, "canary '\(name)' was NOT caught")
        }
        let bodyFromElsewhere = cloudKit.replacingOccurrences(
            of: "body: LidGuardPolicy.messageBody(kind: kind, clockTime: LidGuardPolicy.clockTime(firedAt)),",
            with: "body: String(describing: kind),")
        #expect(bodyFromElsewhere != cloudKit)
        #expect(!Self.freeTextFailures(cloudKit: bodyFromElsewhere, composite: composite).isEmpty,
                "canary 'body from elsewhere' was NOT caught")
    }

    /// Logs on the phone path carry outcome categories and fixed words only —
    /// never a body, a payload or a record (on top of the B2 log lint, which
    /// already bans the topic and URLs in these files).
    @Test func phoneLogLinesNeverCarryRecordContent() throws {
        var scanned = 0
        for file in [Self.cloudKitFile, "CompositeMessageSender.swift"] {
            let code = try Self.code(file)
            for call in LidGuardStructureTests.logCalls(in: code) {
                scanned += 1
                for token in ["payload", "body", "record", "kind", "destination"] where call.text.contains(token) {
                    Issue.record("\(file):\(call.line): a log call names '\(token)': \(call.text)")
                }
            }
        }
        #expect(scanned >= 2, "vacuity: the phone files log")
    }
}
