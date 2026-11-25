// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import CloudKit
import NapCatWire
import Testing
@testable import NapCat

/// F4 slice S-PAIR-C1 (#168): the Mac's strict PairingResponse reader, over
/// records built here (no CloudKit operation runs: a CKRecord is a value).
/// Field by field, like the phone's prompt reader: the type, the zone, the
/// name the ceremony derived, the exact field set with every field but the
/// version encrypted, then each value's shape. The first failure wins.
struct PairingResponseReaderTests {
    typealias Field = ApprovalWire.PairingResponseField
    static let name = PhoneHalf.recordName()
    static let key = Data([0x04] + Array(repeating: UInt8(7), count: 64))
    static let mac = Data(Array(repeating: UInt8(9), count: 32))
    static let proof = Data(Array(repeating: UInt8(3), count: 64))

    /// A response exactly as the phone writes one, with overrides; `clear`
    /// stores those fields in the clear instead, `extra` adds a field.
    static func record(type: String = ApprovalWire.RecordType.pairingResponse.rawValue, zone: String = ApprovalWire.zoneName,
                       name: String = name, wireVersion: NSObject? = ApprovalWire.wireVersion as NSNumber,
                       publicKey: NSObject? = key as NSData, confirmation: NSObject? = mac as NSData,
                       proof: NSObject? = proof as NSData, clear: Set<Field> = [], encrypted: Set<Field> = [],
                       extra: String? = nil) -> CKRecord {
        let zoneID = CKRecordZone.ID(zoneName: zone, ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
        let values: [(Field, NSObject?)] = [(.wireVersion, wireVersion), (.publicKey, publicKey), (.confirmation, confirmation),
                                            (.proof, proof)]
        for (field, value) in values {
            let secret = ApprovalWire.encryptedPairingResponseFields.contains(field)
            if (secret && !clear.contains(field)) || encrypted.contains(field) {
                record.encryptedValues[field.rawValue] = value as? CKRecordValue
            } else {
                record[field.rawValue] = value as? CKRecordValue
            }
        }
        if let extra { record.encryptedValues[extra] = "x" as NSString }
        return record
    }

    @Test func thePhonesRecordIsAResponse() {
        let reading = PairingResponseReader.reading(of: Self.record(), expectedName: Self.name)
        #expect(reading == .response(PairingResponseClaim(publicKey: Array(Self.key), confirmation: Array(Self.mac),
                                                          proof: Array(Self.proof))))
    }

    struct Row: Sendable {
        let name: String
        let record: @Sendable () -> CKRecord
        let fault: PairingResponseFault
    }

    static let rows: [Row] = [
        Row(name: "a decision record", record: { record(type: ApprovalWire.RecordType.decision.rawValue) }, fault: .wrongRecordType),
        Row(name: "an alert record", record: { record(type: AlertWire.recordType) }, fault: .wrongRecordType),
        Row(name: "the default zone", record: { record(zone: CKRecordZone.ID.defaultZoneName) }, fault: .wrongZone),
        Row(name: "another ceremony's name", record: { record(name: PhoneHalf.recordName(PhoneHalf.otherNonce)) },
            fault: .wrongRecordName),
        Row(name: "a name in capitals", record: { record(name: name.uppercased()) }, fault: .wrongRecordName),
        Row(name: "a fingerprint field", record: { record(extra: "fingerprint") }, fault: .unknownField),
        Row(name: "a nonce field", record: { record(extra: "nonce") }, fault: .unknownField),
        Row(name: "the key in the clear", record: { record(clear: [.publicKey]) }, fault: .unencryptedField),
        Row(name: "the MAC in the clear", record: { record(clear: [.confirmation]) }, fault: .unencryptedField),
        Row(name: "the proof in the clear", record: { record(clear: [.proof]) }, fault: .unencryptedField),
        Row(name: "the version encrypted", record: { record(encrypted: [.wireVersion]) }, fault: .misplacedField),
        Row(name: "no version", record: { record(wireVersion: nil) }, fault: .missingField),
        Row(name: "no key", record: { record(publicKey: nil) }, fault: .missingField),
        Row(name: "no MAC", record: { record(confirmation: nil) }, fault: .missingField),
        Row(name: "no proof", record: { record(proof: nil) }, fault: .missingField),
        Row(name: "version 2", record: { record(wireVersion: 2 as NSNumber) }, fault: .wrongWireVersion),
        Row(name: "the version as text", record: { record(wireVersion: "1" as NSString) }, fault: .wrongWireVersion),
        Row(name: "a compressed key", record: { record(publicKey: Data([0x02] + Array(repeating: UInt8(7), count: 32)) as NSData) },
            fault: .malformedPublicKey),
        Row(name: "a key one byte short", record: { record(publicKey: Data(Self.key.dropLast()) as NSData) }, fault: .malformedPublicKey),
        Row(name: "a key not opening 0x04", record: { record(publicKey: Data([0x03] + Array(repeating: UInt8(7), count: 64)) as NSData) },
            fault: .malformedPublicKey),
        Row(name: "the key as text", record: { record(publicKey: "04ab" as NSString) }, fault: .malformedPublicKey),
        Row(name: "a short MAC", record: { record(confirmation: Data(Self.mac.dropLast()) as NSData) }, fault: .malformedConfirmation),
        Row(name: "a long MAC", record: { record(confirmation: Data(Self.mac + [0]) as NSData) }, fault: .malformedConfirmation),
        Row(name: "a DER proof's length", record: { record(proof: Data(Array(repeating: UInt8(3), count: 70)) as NSData) },
            fault: .malformedProof),
        Row(name: "an empty proof", record: { record(proof: Data() as NSData) }, fault: .malformedProof),
    ]

    @Test func everyOtherShapeIsRefusedByItsFault() {
        for row in Self.rows {
            #expect(PairingResponseReader.reading(of: row.record(), expectedName: Self.name) == .malformed(row.fault), "\(row.name)")
        }
        let covered = Set(Self.rows.map(\.fault))
        #expect(covered == Set(PairingResponseFault.allCases), "every fault has a row: missing \(Set(PairingResponseFault.allCases).subtracting(covered))")
    }

    /// The first failure wins: a record wrong in every way is refused on its
    /// type, then (type right) on its zone, and so on.
    @Test func theFirstFailureWins() {
        let bad = Self.record(type: "PromptRequest", zone: "elsewhere", name: "x", wireVersion: 9 as NSNumber, clear: [.publicKey])
        #expect(PairingResponseReader.reading(of: bad, expectedName: Self.name) == .malformed(.wrongRecordType))
        let typed = Self.record(zone: "elsewhere", name: "x", clear: [.publicKey])
        #expect(PairingResponseReader.reading(of: typed, expectedName: Self.name) == .malformed(.wrongZone))
        let zoned = Self.record(name: "x", clear: [.publicKey])
        #expect(PairingResponseReader.reading(of: zoned, expectedName: Self.name) == .malformed(.wrongRecordName))
        let named = Self.record(wireVersion: 9 as NSNumber, clear: [.publicKey])
        #expect(PairingResponseReader.reading(of: named, expectedName: Self.name) == .malformed(.unencryptedField))
    }

    /// A reading carries bytes only — nothing that could pass for a key the
    /// Mac trusts, a fingerprint, or a verified state.
    @Test func aReadingIsBytesNothingMore() {
        let labels = Mirror(reflecting: PairingResponseClaim(publicKey: [], confirmation: [], proof: [])).children.compactMap(\.label)
        #expect(labels == ["publicKey", "confirmation", "proof"])
    }
}
