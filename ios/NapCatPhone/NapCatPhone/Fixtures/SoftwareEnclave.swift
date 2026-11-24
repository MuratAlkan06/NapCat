import CryptoKit
import Foundation

/// Software P-256 keys behind the enclave seam, for fixture launches and
/// tests (F4 slice S-PAIR-B, #161): the simulator and CI have no Secure
/// Enclave, and the protocol above the seam is the same either way. Built
/// only by fixtures and tests, never by a live path (lint-locked). A key's
/// stored block is its raw private key, and it never leaves memory: the
/// fixtures keep keys in a `MemorySigningKeyStore`.
///
/// It keeps the enclave's one rule about matches: a match signs once, and
/// is invalidated by the signature whatever happens.
struct SoftwareEnclave: SigningEnclave {
    var isAvailable: Bool { true }

    func makeKey() -> MadeKey? {
        let key = P256.Signing.PrivateKey()
        return MadeKey(keyData: key.rawRepresentation, publicKey: Array(key.publicKey.x963Representation))
    }

    func sign(_ message: [UInt8], with keyData: Data, match: any BiometricMatch) -> SigningOutcome {
        defer { match.invalidate() }
        guard match.isValid else { return .notAuthorized }
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: keyData),
              let signature = try? key.signature(for: SHA256.hash(data: message)) else { return .keyUnusable }
        return .signed(signature.rawRepresentation)
    }
}

/// Key items in memory, for fixture launches and tests: nothing reaches
/// the keychain.
final class MemorySigningKeyStore: SigningKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [KeySlot: StoredSigningKey]

    init(_ items: [KeySlot: StoredSigningKey] = [:]) {
        self.items = items
    }

    func read(_ slot: KeySlot) -> SigningKeyRead {
        lock.lock()
        defer { lock.unlock() }
        return items[slot].map(SigningKeyRead.found) ?? .notFound
    }

    func write(_ key: StoredSigningKey, to slot: KeySlot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        items[slot] = key
        return true
    }

    func delete(_ slot: KeySlot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        items[slot] = nil
        return true
    }
}

/// A fixed enrollment hash, for fixture launches and tests.
struct FixedEnrollment: EnrollmentState {
    let hash: Data?

    func current() -> Data? { hash }
}
