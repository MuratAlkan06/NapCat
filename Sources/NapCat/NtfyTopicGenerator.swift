import Foundation
import Security

/// Issue #103 (audit F-3): what the ntfy settings editor's Generate button
/// fills in. The topic is the feed's only password, so a generated one is
/// `napcat-` + 22 symbols drawn uniformly from base62 (`A–Z a–z 0–9`):
/// 22 × log2(62) ≈ 131 bits, 29 characters — well inside the 1–64 character
/// topic grammar.
///
/// UNBIASED by rejection sampling: a random byte becomes `alphabet[byte % 62]`
/// only when it is below 248 (= 4 × 62), so every symbol owns exactly 4 of
/// the 248 accepted byte values; 248…255 are discarded. A plain `% 62` over
/// all 256 values would favour the first eight symbols (5/256 against
/// 4/256). Bytes come from `SecRandomCopyBytes`, which has two users, each
/// pinned (lint-locked): this file and the pairing controller's
/// `secureNonce`. The pure half takes them injected, so the mapping is tested
/// deterministically.
enum NtfyTopicGenerator {
    static let prefix = "napcat-"
    static let suffixLength = 22
    static let alphabet: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    /// The largest multiple of 62 that fits a byte: bytes at or above it are
    /// rejected.
    static let acceptBelow = 248
    /// Bytes asked for per draw. A byte is kept with p = 248/256, so 32
    /// nearly always yield the 22 symbols; when they do not, the loop draws
    /// again rather than pad.
    static let bytesPerDraw = 32
    /// A source that keeps failing — or keeps answering 248…255 — gets this
    /// many draws, then generation gives up instead of spinning.
    static let maxDraws = 16

    /// One draw's bytes as symbols: each accepted byte maps to one symbol,
    /// in order; each rejected byte is skipped.
    static func symbols(from bytes: [UInt8]) -> [Character] {
        bytes.compactMap { byte in Int(byte) < acceptBelow ? alphabet[Int(byte) % alphabet.count] : nil }
    }

    /// The pure generator over an injected byte source (`count` → exactly
    /// that many bytes, or nil on failure). Nil when the source fails.
    static func topic(randomBytes: (Int) -> [UInt8]?) -> String? {
        var suffix: [Character] = []
        for _ in 0..<maxDraws {
            guard let bytes = randomBytes(bytesPerDraw), bytes.count == bytesPerDraw else { return nil }
            suffix += symbols(from: bytes)
            if suffix.count >= suffixLength {
                return prefix + String(suffix.prefix(suffixLength))
            }
        }
        return nil
    }

    /// A fresh random topic, or nil if the system's random source failed.
    static func generate() -> String? {
        topic(randomBytes: secureRandomBytes)
    }

    /// `count` bytes from the system CSPRNG, or nil when it reports failure.
    static func secureRandomBytes(_ count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        return status == errSecSuccess ? bytes : nil
    }
}
