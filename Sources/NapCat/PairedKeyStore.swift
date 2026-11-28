import CryptoKit
import Foundation
import NapCatWire

// F4 slice S-PAIR-C1 (#168, Refs #161): the Mac's ONE paired-phone slot.
// Design: design/remote-approvals.md, "Slice S-PAIR".
//
// What the Mac keeps of a pairing is the phone's PUBLIC key, its code and
// when it was paired: one keychain item (`KeychainItemName.pairedPhone`),
// through the same store the ntfy topic uses — the login keychain, this Mac
// only, never synchronized (the item asks for no synchronization, and the
// file-based login keychain does not sync through iCloud at all), so no
// other device on the account can write a key into it. The frozen design
// named the data-protection keychain "consistent with the topic store"; the
// topic store is the login keychain because an ad-hoc `make` build carries
// no keychain entitlement, and the never-synchronized property the design
// needed holds there (KeychainTopicStoreTests lint-locks both).
//
// ONE SLOT, swapped whole: a pairing replaces the item in place (one keychain
// update, or one add when there is none), so the Mac holds the old key or the
// new one, never a mix and never two. Unpair asks the keychain to delete
// it. `commit` is reached from the ceremony's Codes Match alone
// (PairingStructureTests).
//
// NOTHING ARMS here. Since S-PAIR-C2 (#181) the decision verifier reads this
// slot at each verification, its one reader on the decision path (`read()`
// pinned whole, DecisionSinkStructureTests), and nothing in the app hands
// the verifier a decision yet.
// UNPRIVILEGED — no sudo, no PLAN §4 command, no subprocess.

/// The paired phone as the Mac keeps it: its public key, its code (the
/// first 48 bits of SHA-256 over that key, computed here) and when it was
/// paired, in whole seconds.
struct PairedPhone: Equatable, Sendable {
    /// x9.63, 65 bytes.
    let publicKey: [UInt8]
    let fingerprint: PairingFingerprint
    let pairedAt: Date

    /// nil unless `publicKey` is a P-256 public key in its x9.63 form.
    init?(publicKey: [UInt8], pairedAt: Date) {
        guard publicKey.count == ApprovalSigning.publicKeyByteCount, publicKey.first == 0x04,
              (try? P256.Signing.PublicKey(x963Representation: publicKey)) != nil,
              let fingerprint = PairingFingerprint(digest: Array(SHA256.hash(data: publicKey))),
              pairedAt.timeIntervalSince1970.isFinite, pairedAt.timeIntervalSince1970 >= 0 else { return nil }
        self.publicKey = publicKey
        self.fingerprint = fingerprint
        self.pairedAt = Date(timeIntervalSince1970: pairedAt.timeIntervalSince1970.rounded(.down))
    }
}

/// What one read of the slot found.
enum PairedPhoneRead: Equatable, Sendable {
    case paired(PairedPhone)
    case notPaired
    /// The keychain refused, or the item is not a pairing this build reads.
    /// Counts as no pairing (fail-dark); a new pairing replaces it.
    case unreadable
}

/// The paired-phone slot over a keychain text item (`TopicStore`: the app
/// hands it `KeychainTopicStore.pairedPhoneKeychain`; tests a fake).
struct PairedKeyStore: Sendable {
    /// Private (the C1 security review's R3): nothing but the slot's own
    /// `read`, `commit` and `unpair` reaches the item — no alias of it and no
    /// key path to it (PairingStructureTests).
    private let items: any TopicStore

    init(items: any TopicStore) {
        self.items = items
    }

    /// The stored text's first line.
    static let header = "napcat-paired-v1"

    func read() -> PairedPhoneRead {
        switch items.read() {
        case .found(let text): return Self.phone(from: text).map(PairedPhoneRead.paired) ?? .unreadable
        case .notFound: return .notPaired
        case .failed: return .unreadable
        }
    }

    /// THE one write: `phone` becomes the paired phone, replacing any
    /// earlier pairing in one step. True only when the keychain reported
    /// success; on false the slot is as it was.
    func commit(_ phone: PairedPhone) -> Bool {
        items.write(Self.text(of: phone))
    }

    /// Deletes the slot. True when it is gone — deleted now, or never there.
    func unpair() -> Bool {
        items.delete()
    }

    // MARK: - The stored text (pure, read strictly)

    /// Four lines, each ending in a line feed:
    ///
    ///     napcat-paired-v1
    ///     key:<130 lowercase hex digits>
    ///     fingerprint:<12 lowercase hex digits>
    ///     paired:<unix seconds, base 10, no leading zeros>
    static func text(of phone: PairedPhone) -> String {
        [header, "key:" + ApprovalSigning.lowercaseHex(phone.publicKey), "fingerprint:" + phone.fingerprint.lowercaseHex,
         "paired:" + String(Int(phone.pairedAt.timeIntervalSince1970))].map { $0 + "\n" }.joined()
    }

    /// The phone `text` holds, or nil for anything but exactly that form —
    /// and for a stored code that is not the key's own.
    static func phone(from text: String) -> PairedPhone? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count == 5, lines[0] == header, lines[4].isEmpty,
              let keyHex = value(lines[1], "key:"), let key = bytes(fromLowercaseHex: keyHex),
              let codeHex = value(lines[2], "fingerprint:"), let code = PairingFingerprint(lowercaseHex: codeHex),
              let secondsText = value(lines[3], "paired:"), let seconds = Int(secondsText), seconds >= 0,
              String(seconds) == secondsText,
              let phone = PairedPhone(publicKey: key, pairedAt: Date(timeIntervalSince1970: TimeInterval(seconds))),
              phone.fingerprint == code else { return nil }
        return phone
    }

    private static func value(_ line: String, _ label: String) -> String? {
        line.hasPrefix(label) ? String(line.dropFirst(label.count)) : nil
    }

    /// The bytes of lowercase hex text in its one form (two digits a byte).
    static func bytes(fromLowercaseHex text: String) -> [UInt8]? {
        let digits = Array(text.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        return bytes
    }

    private static func nibble(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return digit - UInt8(ascii: "a") + 10
        default: return nil
        }
    }
}

// MARK: - Never printed, dumped or reflected (S-PAIR-C1.5, the C1.5 security review's R1)

/// The slot's item is the slot's alone (PairingStructureTests locks 1 and 7):
/// the slot prints, debug-prints, dumps and reflects as a fixed word and
/// nothing more, so no print, description or `Mirror`-based walk, from any
/// file and through any wrapper, reaches its private item to write it. It
/// does NOT stop runtime reflection (the Swift runtime's field reader and
/// the ObjC runtime's ivar reader both ignore `CustomReflectable`): lock 7's
/// bans stop them — the Swift one by name, the ObjC one by its C API — not
/// this redaction; raw-pointer reads remain the accepted R-1 residual.
extension PairedKeyStore: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "paired key slot (redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
