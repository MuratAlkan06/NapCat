// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import CryptoKit
import NapCatWire
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

/// The phone runs the very same rows: the region between the markers is
/// byte-identical in both files (like the signing vectors' twins), so a row
/// changed on one device alone fails here, and the phone's run of the rows
/// proves its CryptoKit takes the same digests. The phone's file also holds
/// one test outside the region: its own `KeyFingerprint` renders every row
/// exactly as the shared renderer does.
struct PairingFingerprintVectorTwinTests {
    static let macFile = "Tests/NapCatTests/PairingFingerprintVectorTests.swift"
    static let phoneFile = "ios/NapCatPhone/NapCatPhoneTests/PairingFingerprintVectorTests.swift"
    static let opening = "\n// MARK: - BEGIN FINGERPRINT VECTORS\n"
    static let closing = "\n// MARK: - END FINGERPRINT VECTORS\n"

    /// The one region from the opening marker line through the closing one,
    /// or nil when either marker is missing or doubled.
    static func region(_ text: String) -> String? {
        guard ApprovalChannelStructureTests.count(opening, in: text) == 1, ApprovalChannelStructureTests.count(closing, in: text) == 1,
              let start = text.range(of: opening), let end = text.range(of: closing, range: start.upperBound..<text.endIndex)
        else { return nil }
        return String(text[start.lowerBound..<end.upperBound])
    }

    static func file(_ path: String) throws -> String {
        try String(contentsOf: LidGuardStructureTests.repoRoot().appendingPathComponent(path), encoding: .utf8)
    }

    @Test func thePhoneRunsTheSameVectors() throws {
        let mac = try #require(Self.region(try Self.file(Self.macFile)))
        let phone = try #require(Self.region(try Self.file(Self.phoneFile)))
        #expect(mac.contains("@Suite struct PairingFingerprintVectorTests {") && mac.contains("static let keys: [KeyRow] = [")
                && mac.count > 4_000, "vacuity: the whole suite is compared")
        #expect(mac == phone, "the phone's fingerprint vectors drifted from the Mac's — keep the twins alike")
        // The comparison bites: one changed digit, and a second region.
        let digit = mac.replacingOccurrences(of: "8A2C 854A A45C", with: "8A2C 854A A45D")
        #expect(digit != mac && digit != phone)
        #expect(Self.region("x" + Self.opening + "a" + Self.closing + Self.opening + "b" + Self.closing) == nil)
        #expect(Self.region("x" + Self.opening + "a") == nil)
        // The phone's own code is held to the rows outside the region.
        let phoneFile = try Self.file(Self.phoneFile)
        #expect(phoneFile.contains("KeyFingerprint(publicKey: row.key)"), "vacuity: the phone compares its own code to the rows")
    }
}
