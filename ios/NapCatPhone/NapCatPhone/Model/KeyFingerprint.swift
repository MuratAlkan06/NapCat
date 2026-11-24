import CryptoKit
import Foundation
import NapCatWire

/// The code both devices show at the end of a pairing (F4 slice S-PAIR-B,
/// S-PAIR amendment 1): the first 48 bits of SHA-256 over the public key's
/// x9.63 form (65 bytes), as 12 hex digits in three groups of four. The
/// phone computes it from its OWN new key only, never from anything it
/// read; the Mac computes it from the key it fetched. No fingerprint
/// travels on the wire. The owner's comparison is mandatory: an attacker
/// cannot predict the phone's code, nor grind a 48-bit match in time.
struct KeyFingerprint: Equatable, Sendable {
    /// How many bytes of the digest are shown (48 bits).
    nonisolated static let byteCount = 6

    /// 12 uppercase hex digits.
    let digits: String

    /// nil unless `publicKey` is an x9.63 P-256 public key.
    init?(publicKey: [UInt8]) {
        guard publicKey.count == ApprovalSigning.publicKeyByteCount, publicKey.first == 0x04 else { return nil }
        let digest = Array(SHA256.hash(data: publicKey).prefix(Self.byteCount))
        digits = ApprovalSigning.lowercaseHex(digest).uppercased()
    }

    /// The groups of four.
    var groups: [String] {
        stride(from: 0, to: digits.count, by: 4).map { start in
            let from = digits.index(digits.startIndex, offsetBy: start)
            return String(digits[from..<digits.index(from, offsetBy: 4)])
        }
    }

    /// As shown: `A1B2 C3D4 E5F6`.
    var grouped: String { groups.joined(separator: " ") }

    /// What VoiceOver reads: every character on its own, a pause between
    /// the groups, so a code is compared character by character, never
    /// read as a word or a number.
    var spoken: String {
        groups.map { $0.map(String.init).joined(separator: " ") }.joined(separator: ", ")
    }
}
