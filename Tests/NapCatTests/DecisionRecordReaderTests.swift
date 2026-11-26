// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import CloudKit
import NapCatWire
import Testing
@testable import NapCat

/// F4 slice S3: the Mac's PromptDecision reader. A decision record is
/// parsed, validated and logged — and that is all: a reading is a claim,
/// never a verdict (since S-PAIR-C2 its evidence goes to the verifier).
struct DecisionRecordReaderTests {
    static let promptID = PromptID(high: 0xfeed_face_cafe_beef, low: 0x0000_0000_0000_0042)!
    static let decidedAt = Date(timeIntervalSince1970: 1_800_000_123)
    typealias Field = ApprovalWire.DecisionField

    /// A decision record exactly as the phone writes one (the wire's fields;
    /// the content encrypted; no signature before pairing), with overrides.
    static func phoneRecord(
        type: String = ApprovalWire.RecordType.decision.rawValue,
        zone: String = ApprovalWire.zoneName,
        name: String = "decision-record",
        wireVersion: NSObject? = ApprovalWire.wireVersion as NSNumber,
        promptID: NSObject? = DecisionRecordReaderTests.promptID.hex as NSString,
        verdict: NSObject? = "allow" as NSString,
        decidedAt: NSObject? = DecisionRecordReaderTests.decidedAt as NSDate,
        signature: NSObject? = nil
    ) -> CKRecord {
        let zoneID = CKRecordZone.ID(zoneName: zone, ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
        record[Field.wireVersion.rawValue] = wireVersion as? CKRecordValue
        record.encryptedValues[Field.promptID.rawValue] = promptID as? CKRecordValue
        record.encryptedValues[Field.verdict.rawValue] = verdict as? CKRecordValue
        record[Field.decidedAt.rawValue] = decidedAt as? CKRecordValue
        record.encryptedValues[Field.signature.rawValue] = signature as? CKRecordValue
        return record
    }

    // MARK: - A well-formed record is a claim

    @Test(arguments: ApprovalWire.Verdict.allCases)
    func aPhoneDecisionIsAnUnsignedClaim(_ verdict: ApprovalWire.Verdict) {
        let reading = DecisionRecordReader.reading(of: Self.phoneRecord(verdict: verdict.rawValue as NSString))
        #expect(reading == .claim(DecisionClaim(recordName: "decision-record", promptID: Self.promptID,
                                                claimedVerdict: verdict, decidedAt: Self.decidedAt, signature: Data())))
    }

    /// S-PAIR-C2: the signature's bytes are carried, unchecked, into the
    /// evidence the verifier is handed, with every other field as read.
    @Test func aSignatureIsCarriedUncheckedForTheVerifier() {
        let reading = DecisionRecordReader.reading(of: Self.phoneRecord(verdict: "deny" as NSString,
                                                                        signature: Data([1, 2, 3]) as NSData))
        guard case .claim(let claim) = reading else {
            Issue.record("not a claim: \(reading)")
            return
        }
        #expect(claim.signature == Data([1, 2, 3]))
        let evidence = claim.evidence
        #expect(evidence.wireVersion == ApprovalWire.wireVersion && evidence.promptID == Self.promptID.hex)
        #expect(evidence.verdict == "deny" && evidence.decidedAt == Self.decidedAt && evidence.signature == Data([1, 2, 3]))
    }

    /// There is no verified reading to reach: the signature is bytes nobody
    /// checked yet, and a claim holds no flag that could say otherwise.
    @Test func noReadingIsAVerdict() {
        let claim = DecisionClaim(recordName: "r", promptID: Self.promptID, claimedVerdict: .allow,
                                  decidedAt: Self.decidedAt, signature: Data([1]))
        let fields = Mirror(reflecting: claim).children.map { $0.label ?? "" }
        #expect(fields == ["recordName", "promptID", "claimedVerdict", "decidedAt", "signature"])
        #expect(!Mirror(reflecting: claim).children.contains { $0.value is Bool }, "no verified flag")
        // #146: the intake's record store takes a claim and hands nothing
        // back; the claim's record only joins its prompt's retraction.
        let database = ScriptedApprovalDatabase()
        let store = CloudKitApprovalRecords(writer: ApprovalRecordWriter(database: database, audit: { _ in }))
        store.save(Self.promptID, tool: .bash, inputPreview: #"{"command":"git status"}"#, expiresAt: 0)
        store.noteRead(claim)
        #expect(database.submitted.count == 1, "a claim writes nothing")
        store.retract(Self.promptID)
        #expect(database.submitted.last?.recordIDsToDelete?.map(\.recordName) == [Self.promptID.hex, "r"])
    }

    // MARK: - Malformed records are not even claims

    struct FaultRow: CustomTestStringConvertible, Sendable {
        let name: String
        let record: @Sendable () -> CKRecord
        let fault: DecisionRecordFault
        var testDescription: String { name }
    }

    static let faultRows: [FaultRow] = [
        FaultRow(name: "a prompt record", record: { phoneRecord(type: ApprovalWire.RecordType.prompt.rawValue) },
                 fault: .wrongRecordType),
        FaultRow(name: "an alert record", record: { phoneRecord(type: AlertWire.recordType) }, fault: .wrongRecordType),
        FaultRow(name: "the default zone", record: { phoneRecord(zone: CKRecordZone.ID.defaultZoneName) }, fault: .wrongZone),
        FaultRow(name: "an extra field", record: {
            let record = phoneRecord()
            record["sessionId"] = "x" as NSString
            return record
        }, fault: .unknownField),
        FaultRow(name: "an extra encrypted field", record: {
            let record = phoneRecord()
            record.encryptedValues["note"] = "x" as NSString
            return record
        }, fault: .unknownField),
        FaultRow(name: "the prompt ID in the clear", record: {
            let record = phoneRecord(promptID: nil)
            record[Field.promptID.rawValue] = promptID.hex as NSString
            return record
        }, fault: .unencryptedField),
        FaultRow(name: "the verdict in the clear", record: {
            let record = phoneRecord(verdict: nil)
            record[Field.verdict.rawValue] = "allow" as NSString
            return record
        }, fault: .unencryptedField),
        FaultRow(name: "a signature in the clear", record: {
            let record = phoneRecord()
            record[Field.signature.rawValue] = Data([1]) as NSData
            return record
        }, fault: .unencryptedField),
        FaultRow(name: "the version encrypted", record: {
            let record = phoneRecord(wireVersion: nil)
            record.encryptedValues[Field.wireVersion.rawValue] = 1 as NSNumber
            return record
        }, fault: .misplacedField),
        FaultRow(name: "version 2", record: { phoneRecord(wireVersion: 2 as NSNumber) }, fault: .wrongWireVersion),
        FaultRow(name: "no version", record: { phoneRecord(wireVersion: nil) }, fault: .wrongWireVersion),
        FaultRow(name: "a version as text", record: { phoneRecord(wireVersion: "1" as NSString) }, fault: .wrongWireVersion),
        FaultRow(name: "no prompt ID", record: { phoneRecord(promptID: nil) }, fault: .malformedPromptID),
        FaultRow(name: "an uppercase prompt ID", record: { phoneRecord(promptID: promptID.hex.uppercased() as NSString) },
                 fault: .malformedPromptID),
        FaultRow(name: "a short prompt ID", record: { phoneRecord(promptID: "abc" as NSString) }, fault: .malformedPromptID),
        FaultRow(name: "the all-zero prompt ID", record: { phoneRecord(promptID: String(repeating: "0", count: 32) as NSString) },
                 fault: .malformedPromptID),
        FaultRow(name: "no verdict", record: { phoneRecord(verdict: nil) }, fault: .unknownVerdict),
        FaultRow(name: "an unknown verdict", record: { phoneRecord(verdict: "approve" as NSString) }, fault: .unknownVerdict),
        FaultRow(name: "a capitalised verdict", record: { phoneRecord(verdict: "Allow" as NSString) }, fault: .unknownVerdict),
        FaultRow(name: "no decision time", record: { phoneRecord(decidedAt: nil) }, fault: .missingDecidedAt),
        FaultRow(name: "an empty signature", record: { phoneRecord(signature: Data() as NSData) }, fault: .malformedSignature),
        FaultRow(name: "a signature as text", record: { phoneRecord(signature: "sig" as NSString) }, fault: .malformedSignature),
    ]

    @Test(arguments: faultRows)
    func aMalformedRecordIsNotEvenAClaim(_ row: FaultRow) {
        #expect(DecisionRecordReader.reading(of: row.record()) == .malformed(row.fault))
    }

    @Test func everyFaultIsReachable() {
        #expect(Set(Self.faultRows.map(\.fault)) == Set(DecisionRecordFault.allCases))
    }

    // MARK: - Logged, closed vocabulary, nothing else

    @Test func aReadingIsLoggedInAClosedVocabulary() {
        var lines: [String] = []
        _ = DecisionRecordReader.read(Self.phoneRecord()) { lines.append($0.code) }
        _ = DecisionRecordReader.read(Self.phoneRecord(verdict: "deny" as NSString, signature: Data([9]) as NSData)) {
            lines.append($0.code)
        }
        _ = DecisionRecordReader.read(Self.phoneRecord(verdict: "secret-verdict-text" as NSString)) { lines.append($0.code) }
        #expect(lines == ["prompt=\(Self.promptID.hex) decision.unsigned claim=allow",
                          "prompt=\(Self.promptID.hex) decision.signed claim=deny",
                          "decision.malformed.unknownVerdict"])
        for fault in DecisionRecordFault.allCases {
            #expect(ApprovalRecordAudit.decision(.malformed(fault)).code == "decision.malformed.\(fault.rawValue)")
        }
    }

    /// The writer's retraction takes the claim's record name: the decision
    /// is deleted with its prompt, in the approvals zone.
    @Test func aClaimNamesTheRecordARetractionDeletes() throws {
        let record = Self.phoneRecord(name: "decision-for-retraction")
        guard case .claim(let claim) = DecisionRecordReader.reading(of: record) else {
            Issue.record("not a claim")
            return
        }
        let database = ScriptedApprovalDatabase()
        ApprovalRecordWriter(database: database, audit: { _ in }).retract(claim.promptID, decisions: [claim.recordName]) { _ in }
        let deleted = try #require(database.submitted.first?.recordIDsToDelete)
        #expect(deleted.last == record.recordID)
    }
}
