// NapCatWire — F4 remote approvals: the pairing code both devices show (CL-1,
// slice S-PAIR-C1, issue #168). Design: design/remote-approvals.md, "Slice
// S-PAIR".
//
// PURE — no imports, no I/O: text assembly only. The digest it is cut from
// (SHA-256 over the phone key's x9.63 form) is taken in each app, with
// CryptoKit, from the key that app holds: the phone from the key it made, the
// Mac from the key it fetched. No fingerprint ever travels on the wire.
// `PairingFingerprintVectorTests` pins the rendering on BOTH devices, row for
// row, and the phone's own code (`KeyFingerprint`) against it.

/// The code the owner compares at the end of a pairing: the first 48 bits of
/// the key's digest, as 12 hex digits in three groups of four, shown
/// uppercase (`8A2C 854A A45C`), and read out one character at a time with a
/// pause between the groups, so a code is compared character by character,
/// never heard as a word or a number.
public struct PairingFingerprint: Equatable, Sendable {
    /// How many bytes of the digest the code shows (48 bits).
    public static let byteCount = 6
    /// ... as this many hex digits.
    public static let hexDigitCount = 12
    /// ... in groups of this many.
    public static let groupLength = 4

    /// The 12 digits, lowercase: the form a test or a store compares.
    public let lowercaseHex: String

    /// nil unless `lowercaseHex` is exactly 12 characters of `0-9a-f`.
    public init?(lowercaseHex: String) {
        let bytes = Array(lowercaseHex.utf8)
        guard bytes.count == Self.hexDigitCount, bytes.allSatisfy(Self.isLowercaseHexDigit) else { return nil }
        self.lowercaseHex = lowercaseHex
    }

    /// The code of a key's SHA-256 digest: its first six bytes. nil unless
    /// the digest is exactly 32 bytes.
    public init?(digest: [UInt8]) {
        guard digest.count == ApprovalSigning.digestByteCount,
              let fingerprint = PairingFingerprint(
                lowercaseHex: ApprovalSigning.lowercaseHex(Array(digest.prefix(Self.byteCount)))) else { return nil }
        self = fingerprint
    }

    /// The groups of four, uppercase.
    public var groups: [String] {
        let upper = lowercaseHex.utf8.map(Self.uppercased)
        return stride(from: 0, to: upper.count, by: Self.groupLength).map {
            String(decoding: upper[$0..<$0 + Self.groupLength], as: UTF8.self)
        }
    }

    /// As shown: `8A2C 854A A45C`.
    public var grouped: String { groups.joined(separator: " ") }

    /// As VoiceOver reads it: every character on its own, a pause (a comma)
    /// between the groups: `8 A 2 C, 8 5 4 A, A 4 5 C`.
    public var spoken: String {
        groups.map { $0.map(String.init).joined(separator: " ") }.joined(separator: ", ")
    }

    static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
    }

    /// `a`-`f` to `A`-`F`; a digit as it is.
    static func uppercased(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte) ? byte - 0x20 : byte
    }
}
