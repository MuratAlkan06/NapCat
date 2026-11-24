import Foundation

// F4 slice S-PAIR-B (#161): the phone's signing key, as seams. Design:
// design/remote-approvals.md, "Slice S-PAIR".
//
// The phone holds the only private key of the pairing: a P-256 key in its
// Secure Enclave, usable only after a match of the biometrics enrolled now,
// with no passcode fallback (CL-3). Everything that decides anything about
// the key (which slot signs, when the phone unpairs itself, what is stored)
// is written against the seams below, so it runs on the simulator and on CI
// over software keys: neither has a Secure Enclave. The enclave's own
// conformer (`SecureEnclaveSigner`) is thin, and what it does is proven on
// the owner's device only.

/// One biometric match, good for ONE signature (S-PAIR amendment 2). The
/// live one carries the context the match was made in; the signer restores
/// the key with it, signs once and invalidates it. A match is never stored
/// and never reused: once invalid it authorizes nothing.
@MainActor
protocol BiometricMatch: AnyObject, Sendable {
    /// Whether it can still authorize a signature.
    var isValid: Bool { get }
    /// Ends it, whatever it did. Invalidating twice changes nothing.
    func invalidate()
}

/// The phone's two key items.
enum KeySlot: String, CaseIterable, Sendable {
    /// The paired key: the only one that ever signs a decision.
    case committed
    /// A pairing's new key, from the scan until the owner confirms that the
    /// two devices show the same code (S-PAIR amendment 3). Discarded on
    /// cancel or timeout; it never signs a decision.
    case provisional

    /// The keychain item's account name.
    var account: String {
        switch self {
        case .committed: return "signing-key"
        case .provisional: return "signing-key-provisional"
        }
    }
}

/// A signing key as the keychain keeps it.
struct StoredSigningKey: Equatable, Sendable {
    /// The enclave's encrypted block for the key (its `dataRepresentation`):
    /// only this phone's Secure Enclave can restore a key from it, and the
    /// private key itself never leaves the enclave. (A software key's raw
    /// form for the fixtures and the tests.)
    let keyData: Data
    /// The enrolled biometrics' state hash when the key was made; nil when
    /// it could not be read then.
    let enrollment: Data?
}

/// What one read of a key item found.
enum SigningKeyRead: Equatable, Sendable {
    case found(StoredSigningKey)
    case notFound
    /// The keychain answered with an error (`status`, a number), or with an
    /// item that holds no key.
    case failed(status: Int32)
}

/// THE seam over the phone's key items: generic passwords in the device's
/// data-protection keychain, readable only while the phone is unlocked,
/// never synchronized and never restored onto another device. The
/// app's conformer is `KeychainSigningKeyStore.phoneKeychain`; fixtures and
/// tests keep keys in memory and never reach the keychain (lint-locked).
protocol SigningKeyStore: Sendable {
    func read(_ slot: KeySlot) -> SigningKeyRead
    /// Creates or replaces the item. True only when the keychain said so.
    func write(_ key: StoredSigningKey, to slot: KeySlot) -> Bool
    /// True when the item is gone: deleted now, or never there.
    func delete(_ slot: KeySlot) -> Bool
}

/// A new key: what is stored, and its public half.
struct MadeKey: Equatable, Sendable {
    let keyData: Data
    /// The public key in its x9.63 form: 0x04, then x and y (65 bytes).
    let publicKey: [UInt8]
}

/// What one signature came to.
enum SigningOutcome: Equatable, Sendable {
    /// ECDSA P-256 over SHA-256 of the message, in its raw form (r, then
    /// s): exactly 64 bytes.
    case signed(Data)
    /// Not signed, and the key is not to blame: the match was already spent,
    /// or a prompt was cancelled or locked out. Never a reason to unpair.
    case notAuthorized
    /// The key would not sign although the match was good: the error class
    /// a key invalidated by a biometric enrollment change raises.
    case keyUnusable
}

/// THE seam over the Secure Enclave. The app's conformer is
/// `SecureEnclaveSigner` (unavailable on the simulator and on CI, so
/// verified on the owner's device); fixtures and tests use software P-256
/// keys (`SoftwareEnclave`), so every rule above it runs everywhere.
@MainActor
protocol SigningEnclave {
    /// Whether this device can hold an enclave key at all.
    var isAvailable: Bool { get }
    /// A new key, usable only after a match of the biometrics enrolled now,
    /// on this device only, while it is unlocked. Making it asks nothing;
    /// nil when it could not be made.
    func makeKey() -> MadeKey?
    /// One signature over SHA-256 of `message` with the key `keyData`
    /// restores, authorized by `match` — which this call invalidates
    /// whatever happens, so a match can never sign twice.
    func sign(_ message: [UInt8], with keyData: Data, match: any BiometricMatch) -> SigningOutcome
}

/// THE seam over the enrolled biometrics' state: a hash that changes when
/// a face or a finger is added or removed (and, rarely, across a major
/// system update). Read with no prompt. A hint only — the enclave alone
/// decides whether a key still signs.
@MainActor
protocol EnrollmentState {
    /// The current hash; nil when none is enrolled or it cannot be read.
    func current() -> Data?
}
