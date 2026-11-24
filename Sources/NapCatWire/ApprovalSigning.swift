// NapCatWire — F4 remote approvals: the CANONICAL BYTES of signed decisions
// and of the pairing ceremony (CL-1, slice S-PAIR-A, issue #161). Design:
// design/remote-approvals.md, "Slice S-PAIR".
//
// PURE — no imports, no I/O, no clock, no randomness: byte assembly only.
// The hashing, the HMAC and the ECDSA signing and checking stay in the apps
// (CryptoKit on both devices), so this target keeps building for iOS with no
// import at all. The vector tests on both devices pin the bytes built here
// AND the SHA-256 and HMAC values the apps take of them, row for row.
//
// Every message starts with its own domain string, so a signature or a MAC
// made for one message can never be read as another; a later format gets a
// new domain instead of a variant. A builder REFUSES (nil) any value outside
// its message's alphabet — nothing is ever escaped.

/// The signed-decision and pairing formats, shared byte for byte by the
/// phone (which signs) and the Mac (which rebuilds the bytes and checks).
public enum ApprovalSigning {
    // MARK: - Domains (frozen)

    /// The first line of a decision message.
    public static let decisionDomain = "napcat-decision-v1"
    /// The first line of the digest input of the prompt copy the phone
    /// displayed (the decision's `shown` line).
    public static let shownDomain = "napcat-shown-v1"
    /// The pairing QR payload's prefix (before its `:`).
    public static let pairDomain = "napcat-pair-v1"
    /// The first line of the pairing response's confirmation message (the
    /// HMAC keyed by the pairing nonce).
    public static let pairConfirmDomain = "napcat-pair-confirm-v1"
    /// The first line of the pairing response's proof-of-possession message
    /// (the new key's ECDSA signature).
    public static let pairProofDomain = "napcat-pair-proof-v1"
    /// The label hashed in front of the nonce to name the pairing response's
    /// record: SHA-256(label || nonce), as lowercase hex.
    public static let pairNameLabel = "napcat-pair-name-v1"

    // MARK: - Sizes

    /// An ECDSA P-256 signature's raw form (r then s): exactly 64 bytes.
    public static let signatureByteCount = 64
    /// A SHA-256 digest.
    public static let digestByteCount = 32
    /// The pairing nonce: 256 random bits, shown only on the Mac's screen.
    public static let pairingNonceByteCount = 32
    /// The nonce in the QR payload: base64url, no padding.
    public static let pairingNonceCharacterCount = 43
    /// A P-256 public key in its x9.63 form: 0x04, then x and y.
    public static let publicKeyByteCount = 65
    /// The pairing response's record name: a digest as lowercase hex.
    public static let recordNameHexDigits = 64

    // MARK: - The decision message

    /// The six lines the phone signs and the Mac rebuilds, each ending in a
    /// line feed:
    ///
    ///     napcat-decision-v1
    ///     wire:<wire version>
    ///     prompt:<32 lowercase hex digits>
    ///     verdict:allow|deny
    ///     decided:<unix seconds, base 10, no leading zeros>
    ///     shown:<64 lowercase hex digits>
    ///
    /// `shownDigest` is SHA-256 of `shownDigestInput` over the prompt copy.
    /// nil for a negative version or time (no sign exists in the alphabet)
    /// or a digest that is not exactly 32 bytes.
    public static func decisionMessage(wireVersion: Int, promptID: PromptID, verdict: ApprovalWire.Verdict,
                                       decidedAt: Int, shownDigest: [UInt8]) -> [UInt8]? {
        guard wireVersion >= 0, decidedAt >= 0, shownDigest.count == digestByteCount else { return nil }
        let lines = [decisionDomain, "wire:" + String(wireVersion), "prompt:" + promptID.hex,
                     "verdict:" + verdict.rawValue, "decided:" + String(decidedAt), "shown:" + lowercaseHex(shownDigest)]
        return lines.flatMap { Array($0.utf8) + [lineFeed] }
    }

    // MARK: - The shown-digest input

    /// What the decision's `shown` digest is taken over: the domain line,
    /// then each of the three fields as `<name>:<byte count>\n<bytes>\n`, in
    /// this order. The values are the fields exactly as the phone DECODED
    /// them from the prompt record (and the Mac stored them when it wrote
    /// it) — never a displayed form: the phone's display is a function of
    /// these bytes, not their source. Any bytes at all, newlines included;
    /// the length prefix keeps every field in its place.
    public static func shownDigestInput(toolName: String, inputPreview: String, projectLabel: String) -> [UInt8] {
        typealias Field = ApprovalWire.PromptField
        return lengthPrefixed(shownDomain, [(Field.toolName.rawValue, Array(toolName.utf8)),
                                            (Field.inputPreview.rawValue, Array(inputPreview.utf8)),
                                            (Field.projectLabel.rawValue, Array(projectLabel.utf8))])
    }

    // MARK: - The pairing QR payload

    /// `napcat-pair-v1:` then the nonce as unpadded base64url (43
    /// characters). nil unless the nonce is exactly 32 bytes.
    public static func pairingPayload(nonce: [UInt8]) -> String? {
        guard nonce.count == pairingNonceByteCount else { return nil }
        return pairDomain + ":" + base64URL(nonce)
    }

    /// The nonce a scanned payload carries, read strictly: exactly the
    /// prefix and 43 characters of the base64url alphabet in their one
    /// canonical form, with nothing before, between or after them (no
    /// padding, space or line break). Anything else is nil.
    public static func pairingNonce(fromPayload payload: String) -> [UInt8]? {
        let prefix = Array((pairDomain + ":").utf8)
        let bytes = Array(payload.utf8)
        guard bytes.count == prefix.count + pairingNonceCharacterCount, bytes.starts(with: prefix) else { return nil }
        let encoded = Array(bytes[prefix.count...])
        guard let nonce = base64URLDecoded(encoded), nonce.count == pairingNonceByteCount,
              Array(base64URL(nonce).utf8) == encoded else { return nil }
        return nonce
    }

    // MARK: - The pairing response

    /// The message the pairing response's confirmation is an HMAC-SHA256 of,
    /// keyed by the nonce: the domain line, then `wireVersion` and
    /// `publicKey` length-prefixed like the shown-digest input. nil for a
    /// negative version or a key that is not an x9.63 P-256 public key.
    public static func pairingConfirmationMessage(wireVersion: Int, publicKey: [UInt8]) -> [UInt8]? {
        guard wireVersion >= 0, isPublicKey(publicKey) else { return nil }
        return lengthPrefixed(pairConfirmDomain, [("wireVersion", Array(String(wireVersion).utf8)), ("publicKey", publicKey)])
    }

    /// The message the new key signs to prove it holds the private half:
    /// the domain line, then `nonce` and `publicKey` length-prefixed like the
    /// shown-digest input. nil unless the nonce is 32 bytes and the key an
    /// x9.63 P-256 public key.
    public static func pairingProofMessage(nonce: [UInt8], publicKey: [UInt8]) -> [UInt8]? {
        guard nonce.count == pairingNonceByteCount, isPublicKey(publicKey) else { return nil }
        return lengthPrefixed(pairProofDomain, [("nonce", nonce), ("publicKey", publicKey)])
    }

    /// What the pairing response's record name is the SHA-256 of: the label
    /// then the nonce, with no separator. nil unless the nonce is 32 bytes.
    public static func pairingRecordNameInput(nonce: [UInt8]) -> [UInt8]? {
        guard nonce.count == pairingNonceByteCount else { return nil }
        return Array(pairNameLabel.utf8) + nonce
    }

    /// The record name: that digest as 64 lowercase hex digits. nil unless
    /// the digest is 32 bytes.
    public static func pairingRecordName(digest: [UInt8]) -> String? {
        guard digest.count == digestByteCount else { return nil }
        return lowercaseHex(digest)
    }

    // MARK: - Encodings

    /// Two lowercase hex digits per byte.
    public static func lowercaseHex(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.flatMap { [hexDigits[Int($0 >> 4)], hexDigits[Int($0 & 0x0f)]] }, as: UTF8.self)
    }

    static let lineFeed = UInt8(ascii: "\n")
    static let hexDigits = Array("0123456789abcdef".utf8)
    static let base64URLAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    /// The domain line, then each field as `<name>:<byte count>\n<bytes>\n`.
    static func lengthPrefixed(_ domain: String, _ fields: [(name: String, value: [UInt8])]) -> [UInt8] {
        var bytes = Array(domain.utf8) + [lineFeed]
        for field in fields {
            bytes += Array((field.name + ":" + String(field.value.count)).utf8) + [lineFeed]
            bytes += field.value + [lineFeed]
        }
        return bytes
    }

    /// An uncompressed (x9.63) P-256 public key: 65 bytes, the first 0x04.
    static func isPublicKey(_ bytes: [UInt8]) -> Bool {
        bytes.count == publicKeyByteCount && bytes.first == 0x04
    }

    /// RFC 4648 base64url, without padding.
    static func base64URL(_ bytes: [UInt8]) -> String {
        var characters: [UInt8] = []
        var start = 0
        while start < bytes.count {
            let group = Array(bytes[start..<min(start + 3, bytes.count)]) + [0, 0]
            let bits = UInt32(group[0]) << 16 | UInt32(group[1]) << 8 | UInt32(group[2])
            let used = min(3, bytes.count - start) + 1
            for index in 0..<used {
                characters.append(base64URLAlphabet[Int(bits >> UInt32(18 - 6 * index) & 0x3f)])
            }
            start += 3
        }
        return String(decoding: characters, as: UTF8.self)
    }

    /// The bytes an unpadded base64url text holds, or nil for a character
    /// outside the alphabet. (The caller checks the canonical form.)
    static func base64URLDecoded(_ characters: [UInt8]) -> [UInt8]? {
        var bytes: [UInt8] = []
        var buffer: UInt32 = 0
        var buffered = 0
        for character in characters {
            guard let value = base64URLAlphabet.firstIndex(of: character) else { return nil }
            buffer = buffer << 6 | UInt32(value)
            buffered += 6
            if buffered >= 8 {
                buffered -= 8
                bytes.append(UInt8(truncatingIfNeeded: buffer >> UInt32(buffered)))
                buffer &= (1 << UInt32(buffered)) - 1
            }
        }
        return bytes
    }
}
