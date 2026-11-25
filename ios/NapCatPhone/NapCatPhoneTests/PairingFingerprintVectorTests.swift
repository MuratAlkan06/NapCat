import CryptoKit
import Foundation
import NapCatWire
@testable import NapCatPhone
import Testing

// MARK: - BEGIN FINGERPRINT VECTORS
// This region is byte-identical in Tests/NapCatTests/PairingFingerprintVectorTests.swift
// and ios/NapCatPhone/NapCatPhoneTests/PairingFingerprintVectorTests.swift: the Mac's
// `PairingFingerprintVectorTwinTests` compares the two, so both devices run these
// exact rows against the one shared renderer (NapCatWire's `PairingFingerprint`).

/// F4 slice S-PAIR-C1 (#168): the code both devices show at the end of a
/// pairing, pinned row for row on BOTH devices. The pinned values come from
/// an independent reference (another SHA-256 implementation over the same
/// bytes, the first 12 hex digits uppercased and grouped by hand), not from
/// the code under test. The digest is CryptoKit's, as each app takes it;
/// the grouping and the spoken form are the shared renderer's.
@Suite struct PairingFingerprintVectorTests {
    struct KeyRow: Sendable {
        let name: String
        /// An x9.63 P-256 public key's bytes (0x04, then x and y).
        let key: [UInt8]
        /// SHA-256 of `key`, as 64 lowercase hex digits.
        let digest: String
        let grouped: String
        let spoken: String
    }

    static let keys: [KeyRow] = [
        KeyRow(name: "0x04 then 64 × 0xab", key: [0x04] + Array(repeating: 0xab, count: 64),
               digest: "8a2c854aa45ce7ef17ba7719a6f59010f549b0e66ad0343787e9381ce2b60248",
               grouped: "8A2C 854A A45C", spoken: "8 A 2 C, 8 5 4 A, A 4 5 C"),
        KeyRow(name: "0x04 then 1 … 64", key: [0x04] + Array(1...64),
               digest: "0ed3a6ab957ff6f59a9630a473d31a7d04fcb46548b89016196980c7e96584f6",
               grouped: "0ED3 A6AB 957F", spoken: "0 E D 3, A 6 A B, 9 5 7 F"),
        KeyRow(name: "0x04 then 64 zero bytes", key: [0x04] + Array(repeating: 0x00, count: 64),
               digest: "59ef1a5a00f35b1a722da56ca70b52a721f33998634d4fa4259301f170f7b6bd",
               grouped: "59EF 1A5A 00F3", spoken: "5 9 E F, 1 A 5 A, 0 0 F 3"),
        KeyRow(name: "0x04 then 64 × 0xff", key: [0x04] + Array(repeating: 0xff, count: 64),
               digest: "d58c8c884d9f4d5ff86dec198c55bb5896c6711453cc4a482c3cb21684dda1ec",
               grouped: "D58C 8C88 4D9F", spoken: "D 5 8 C, 8 C 8 8, 4 D 9 F"),
    ]

    struct TextRow: Sendable {
        let text: String
        /// nil: the text is refused.
        let grouped: String?
        let spoken: String?
    }

    /// The 12-digit text form, read strictly: exactly 12 of `0-9a-f`.
    static let texts: [TextRow] = [
        TextRow(text: "0123456789ab", grouped: "0123 4567 89AB", spoken: "0 1 2 3, 4 5 6 7, 8 9 A B"),
        TextRow(text: "a1b2c3d4e5f6", grouped: "A1B2 C3D4 E5F6", spoken: "A 1 B 2, C 3 D 4, E 5 F 6"),
        TextRow(text: "ffffffffffff", grouped: "FFFF FFFF FFFF", spoken: "F F F F, F F F F, F F F F"),
        TextRow(text: "000000000000", grouped: "0000 0000 0000", spoken: "0 0 0 0, 0 0 0 0, 0 0 0 0"),
        TextRow(text: "A1B2C3D4E5F6", grouped: nil, spoken: nil),
        TextRow(text: "a1b2c3d4e5f", grouped: nil, spoken: nil),
        TextRow(text: "a1b2c3d4e5f6a", grouped: nil, spoken: nil),
        TextRow(text: "a1b2 c3d4e5f", grouped: nil, spoken: nil),
        TextRow(text: "a1b2c3d4e5fg", grouped: nil, spoken: nil),
        TextRow(text: "a1b2c3d4e5f\u{0666}", grouped: nil, spoken: nil),
        TextRow(text: "", grouped: nil, spoken: nil),
    ]

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    @Test func aKeysCodeIsTheFirstSixBytesOfItsDigest() throws {
        for row in Self.keys {
            let digest = Array(SHA256.hash(data: row.key))
            #expect(Self.hex(digest) == row.digest, "\(row.name): the digest")
            let fingerprint = try #require(PairingFingerprint(digest: digest), "\(row.name)")
            #expect(fingerprint.lowercaseHex == String(row.digest.prefix(12)), "\(row.name): the first 48 bits")
            #expect(fingerprint.grouped == row.grouped, "\(row.name): shown")
            #expect(fingerprint.spoken == row.spoken, "\(row.name): spoken")
            #expect(fingerprint.groups == row.grouped.split(separator: " ").map(String.init), "\(row.name): the groups")
        }
    }

    @Test func theTextFormIsReadStrictly() {
        for row in Self.texts {
            let fingerprint = PairingFingerprint(lowercaseHex: row.text)
            #expect(fingerprint?.grouped == row.grouped, "'\(row.text)' shown")
            #expect(fingerprint?.spoken == row.spoken, "'\(row.text)' spoken")
            if row.grouped != nil { #expect(fingerprint?.lowercaseHex == row.text) }
        }
    }

    @Test func onlyAWholeDigestHasACode() {
        let digest = Array(SHA256.hash(data: Self.keys[0].key))
        #expect(PairingFingerprint(digest: Array(digest.dropLast())) == nil)
        #expect(PairingFingerprint(digest: digest + [0]) == nil)
        #expect(PairingFingerprint(digest: Array(digest.prefix(6))) == nil)
        #expect(PairingFingerprint(digest: []) == nil)
        #expect(PairingFingerprint.byteCount == 6 && PairingFingerprint.hexDigitCount == 12 && PairingFingerprint.groupLength == 4)
    }

    /// Never a wrap inside a group: the shown form has exactly two spaces,
    /// between the groups, and the spoken form one pause per group boundary.
    @Test func theShownAndSpokenShapesAreFixed() throws {
        for row in Self.keys {
            let fingerprint = try #require(PairingFingerprint(digest: Array(SHA256.hash(data: row.key))))
            #expect(fingerprint.grouped.count == 14 && fingerprint.grouped.filter { $0 == " " }.count == 2)
            #expect(fingerprint.spoken.filter { $0 == "," }.count == 2)
            #expect(fingerprint.spoken.replacingOccurrences(of: ", ", with: " ").split(separator: " ").map(String.init)
                    == fingerprint.grouped.replacingOccurrences(of: " ", with: "").map(String.init), "every character on its own")
        }
    }
}
// MARK: - END FINGERPRINT VECTORS

/// F4 slice S-PAIR-C1 (#168): the phone's own code is the shared one. The
/// phone computes its code in `KeyFingerprint` (S-PAIR-B, unchanged), the
/// Mac with NapCatWire's `PairingFingerprint`; for the owner's comparison to
/// mean anything the two must render every key byte for byte alike, shown
/// and spoken. Outside the twin region: the Mac has no `KeyFingerprint`.
struct PhoneFingerprintParityTests {
    @Test func thePhonesCodeIsTheSharedRenderersForEveryRow() throws {
        for row in PairingFingerprintVectorTests.keys {
            let phone = try #require(KeyFingerprint(publicKey: row.key), "\(row.name)")
            let shared = try #require(PairingFingerprint(digest: Array(SHA256.hash(data: row.key))), "\(row.name)")
            #expect(phone.grouped == row.grouped && phone.grouped == shared.grouped, "\(row.name): shown")
            #expect(phone.spoken == row.spoken && phone.spoken == shared.spoken, "\(row.name): spoken")
            #expect(phone.groups == shared.groups, "\(row.name): the groups")
            #expect(phone.digits == shared.lowercaseHex.uppercased(), "\(row.name): the digits")
        }
    }
}
