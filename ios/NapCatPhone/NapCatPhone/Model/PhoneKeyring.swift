import Foundation

/// The phone's signing keys (F4 slice S-PAIR-B, #161): ONE committed slot,
/// the paired key, the only one that signs a decision; and one provisional
/// slot, a pairing's new key until the owner confirms the codes match.
///
/// - A pairing makes its key provisional; only `commitProvisional` (the
///   owner's confirm) moves it into the committed slot, replacing the old
///   key there. A cancel or a timeout discards it, and the committed key
///   keeps signing (S-PAIR amendment 3): a stale or stray code cannot
///   destroy a working pairing.
/// - The phone unpairs ITSELF only when the committed key would not sign
///   after a good match (`keyUnusable`) AND the enrolled biometrics changed
///   since the key was made. A cancel, a lockout, or a failure while the
///   enrollment is unchanged never unpairs.
/// - `health()` reads the enrollment hash with no prompt, so a changed
///   enrollment shows before anything is answered; it is a hint, and the
///   enclave alone decides. When a key still signs after the hash changed
///   (a system update can change it), the stored hash is brought up to date.
@MainActor
final class PhoneKeyring {
    /// Where this phone's pairing stands, as last read.
    enum Health: Equatable, Sendable {
        /// A committed key, made under the biometrics enrolled now.
        case paired
        /// A committed key, but the enrolled biometrics changed since it was
        /// made: answering will likely fail, and the phone will then unpair
        /// itself. Answers stay on offer (the enclave decides).
        case enrollmentChanged
        case unpaired(UnpairedReason)
    }

    enum UnpairedReason: Equatable, Sendable {
        /// No committed key: this phone was never paired, or not since it
        /// was set up or restored (enclave keys never leave their device).
        case neverPaired
        /// This phone unpaired itself: the biometrics changed and the key
        /// stopped signing.
        case enrollmentChanged
        /// The keychain would not say.
        case unreadable
    }

    /// What signing with the committed key came to.
    enum Signing: Equatable, Sendable {
        /// Exactly 64 bytes.
        case signed(Data)
        /// There is no committed key; nothing was signed.
        case unpaired
        /// Not signed; the key stays (a cancel, a lockout, or a failure with
        /// the enrollment unchanged).
        case notSigned
        /// Not signed, and the phone unpaired itself: the key would not sign
        /// and the enrolled biometrics had changed.
        case selfUnpaired
    }

    private let store: any SigningKeyStore
    private let enclave: any SigningEnclave
    private let enrollment: any EnrollmentState
    /// Set when this phone unpaired itself, so its words can say why (for
    /// this launch; afterwards the phone simply reads as unpaired).
    private var unpairedItself = false

    init(store: any SigningKeyStore, enclave: any SigningEnclave, enrollment: any EnrollmentState) {
        self.store = store
        self.enclave = enclave
        self.enrollment = enrollment
    }

    /// Whether the enrollment moved on from the one a key was made under:
    /// only a hash that was read then and reads differently now (or reads
    /// as nothing now: every face or finger removed). A hash that could not
    /// be read when the key was made proves no change.
    nonisolated static func enrollmentChanged(from stored: Data?, to current: Data?) -> Bool {
        guard let stored else { return false }
        return stored != current
    }

    /// Reads the committed slot and the enrollment; asks for nothing.
    func health() -> Health {
        switch store.read(.committed) {
        case .notFound:
            return .unpaired(unpairedItself ? .enrollmentChanged : .neverPaired)
        case .failed:
            return .unpaired(.unreadable)
        case .found(let key):
            return Self.enrollmentChanged(from: key.enrollment, to: enrollment.current()) ? .enrollmentChanged : .paired
        }
    }

    // MARK: The committed key

    /// One signature over `message` with the committed key, authorized by
    /// `match`, which is spent whatever happens.
    func sign(_ message: [UInt8], match: any BiometricMatch) -> Signing {
        guard case .found(let key) = store.read(.committed) else {
            match.invalidate()
            return .unpaired
        }
        switch enclave.sign(message, with: key.keyData, match: match) {
        case .signed(let signature):
            let now = enrollment.current()
            if Self.enrollmentChanged(from: key.enrollment, to: now) {
                _ = store.write(StoredSigningKey(keyData: key.keyData, enrollment: now), to: .committed)
            }
            return .signed(signature)
        case .notAuthorized:
            return .notSigned
        case .keyUnusable:
            guard Self.enrollmentChanged(from: key.enrollment, to: enrollment.current()) else { return .notSigned }
            _ = store.delete(.committed)
            unpairedItself = true
            return .selfUnpaired
        }
    }

    // MARK: The provisional key (a pairing)

    /// A new provisional key, replacing any earlier provisional one (never
    /// the committed one): its public half, or nil when none could be made
    /// or stored.
    func makeProvisional() -> [UInt8]? {
        discardProvisional()
        guard enclave.isAvailable, let made = enclave.makeKey(),
              store.write(StoredSigningKey(keyData: made.keyData, enrollment: enrollment.current()), to: .provisional) else {
            return nil
        }
        return made.publicKey
    }

    /// One signature over `message` with the provisional key (the pairing's
    /// proof), authorized by `match`, which is spent whatever happens.
    func signProvisional(_ message: [UInt8], match: any BiometricMatch) -> SigningOutcome {
        guard case .found(let key) = store.read(.provisional) else {
            match.invalidate()
            return .keyUnusable
        }
        return enclave.sign(message, with: key.keyData, match: match)
    }

    /// The owner confirmed the codes match: the provisional key becomes the
    /// paired one, replacing any. True once the committed slot holds it.
    func commitProvisional() -> Bool {
        guard case .found(let key) = store.read(.provisional), store.write(key, to: .committed) else { return false }
        _ = store.delete(.provisional)
        unpairedItself = false
        return true
    }

    /// A pairing that ended without the confirm: its key goes; the committed
    /// one stays as it is.
    func discardProvisional() {
        _ = store.delete(.provisional)
    }
}
