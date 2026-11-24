import CryptoKit
import Foundation
import LocalAuthentication
@testable import NapCatPhone
import Testing

/// A biometric match played by a test: valid until invalidated, every
/// invalidation counted. Never a real context.
@MainActor
final class TestMatch: BiometricMatch {
    private(set) var invalidations = 0

    var isValid: Bool { invalidations == 0 }

    func invalidate() { invalidations += 1 }
}

/// The enclave seam over software keys, with what a test needs on top: it
/// can be made unavailable, a key can be "killed" the way an enrollment
/// change kills an enclave key, and an outcome can be forced. Every
/// signature request is counted.
@MainActor
final class TestEnclave: SigningEnclave {
    var isAvailable = true
    /// Keys that no longer sign: `keyUnusable`, after a good match.
    var killed: Set<Data> = []
    /// Forced instead of a signature (after the match checks).
    var forced: SigningOutcome?
    private(set) var signed: [[UInt8]] = []
    private let software = SoftwareEnclave()

    func makeKey() -> MadeKey? { isAvailable ? software.makeKey() : nil }

    func sign(_ message: [UInt8], with keyData: Data, match: any BiometricMatch) -> SigningOutcome {
        signed.append(message)
        guard match.isValid else { return software.sign(message, with: keyData, match: match) }
        if killed.contains(keyData) {
            match.invalidate()
            return .keyUnusable
        }
        if let forced {
            match.invalidate()
            return forced
        }
        return software.sign(message, with: keyData, match: match)
    }
}

/// Signing checks as the Mac's verifier makes them: ECDSA P-256 over
/// SHA-256 of the canonical bytes, the signature in its 64-byte raw form,
/// the key in its x9.63 form.
enum SignatureCheck {
    static func verifies(_ signature: Data, over message: [UInt8], by publicKey: [UInt8]) -> Bool {
        guard signature.count == 64, let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.isValidSignature(parsed, for: SHA256.hash(data: message))
    }
}

/// The phone's key slots and the rules over them (F4 slice S-PAIR-B):
/// provisional until the owner's confirm, the committed key the only one
/// that signs, and the phone unpairing itself only when the key fails
/// after a good match AND the enrollment changed. Software keys only: the
/// simulator has no Secure Enclave, so nothing here reaches one.
@MainActor
@Suite struct PhoneKeyringTests {
    static let before = Data("enrolled-before".utf8)
    static let after = Data("enrolled-after".utf8)
    static let message = Array("napcat-decision-v1\nwire:1\n".utf8)

    /// A keyring over memory and software keys, enrolled as `enrollment`.
    @MainActor
    final class World {
        let store = MemorySigningKeyStore()
        let enclave = TestEnclave()
        var enrolled: Data?
        private(set) lazy var keyring = PhoneKeyring(store: store, enclave: enclave, enrollment: Enrollment(world: self))

        init(enrolled: Data? = PhoneKeyringTests.before) {
            self.enrolled = enrolled
        }

        /// Pairs: a provisional key, committed. Its public half.
        func pair() throws -> [UInt8] {
            let publicKey = try #require(keyring.makeProvisional())
            #expect(keyring.commitProvisional())
            return publicKey
        }

        func committed() -> StoredSigningKey? {
            if case .found(let key) = store.read(.committed) { return key }
            return nil
        }

        func provisional() -> StoredSigningKey? {
            if case .found(let key) = store.read(.provisional) { return key }
            return nil
        }
    }

    @MainActor
    struct Enrollment: EnrollmentState {
        let world: World
        func current() -> Data? { world.enrolled }
    }

    // MARK: Provisional until the confirm

    /// A pairing's new key never signs a decision before the owner's
    /// confirm: the committed slot stays empty, and the phone unpaired.
    @Test func aProvisionalKeyNeverSignsADecision() throws {
        let world = World()
        let publicKey = try #require(world.keyring.makeProvisional())
        #expect(publicKey.count == 65 && publicKey.first == 0x04)
        #expect(world.committed() == nil)
        #expect(world.keyring.health() == .unpaired(.neverPaired))
        let match = TestMatch()
        #expect(world.keyring.sign(Self.message, match: match) == .unpaired)
        #expect(!match.isValid, "the match is spent even when nothing could sign")
        #expect(world.enclave.signed.isEmpty)
    }

    /// The confirm moves the provisional key into the committed slot; it
    /// then signs, verifiably by the key the pairing showed.
    @Test func theConfirmCommitsTheProvisionalKey() throws {
        let world = World()
        let publicKey = try world.pair()
        #expect(world.provisional() == nil)
        #expect(world.keyring.health() == .paired)
        guard case .signed(let signature) = world.keyring.sign(Self.message, match: TestMatch()) else {
            Issue.record("the committed key did not sign")
            return
        }
        #expect(SignatureCheck.verifies(signature, over: Self.message, by: publicKey))
    }

    /// A cancelled or timed-out pairing discards its key and leaves the
    /// working one signing (S-PAIR amendment 3).
    @Test func aDiscardedPairingKeepsTheCommittedKey() throws {
        let world = World()
        let paired = try world.pair()
        let stray = try #require(world.keyring.makeProvisional())
        world.keyring.discardProvisional()
        #expect(world.provisional() == nil)
        guard case .signed(let signature) = world.keyring.sign(Self.message, match: TestMatch()) else {
            Issue.record("the committed key stopped signing")
            return
        }
        #expect(SignatureCheck.verifies(signature, over: Self.message, by: paired))
        #expect(!SignatureCheck.verifies(signature, over: Self.message, by: stray))
    }

    /// One slot: a confirmed new pairing replaces the old key.
    @Test func aNewPairingReplacesTheOldKeyOnTheConfirm() throws {
        let world = World()
        let old = try world.pair()
        let new = try world.pair()
        guard case .signed(let signature) = world.keyring.sign(Self.message, match: TestMatch()) else {
            Issue.record("the new key did not sign")
            return
        }
        #expect(SignatureCheck.verifies(signature, over: Self.message, by: new))
        #expect(!SignatureCheck.verifies(signature, over: Self.message, by: old))
    }

    /// A second scan replaces an earlier provisional key, never the
    /// committed one.
    @Test func aNewProvisionalKeyReplacesOnlyTheProvisionalSlot() throws {
        let world = World()
        _ = try world.pair()
        let committed = world.committed()
        _ = try #require(world.keyring.makeProvisional())
        let first = world.provisional()
        _ = try #require(world.keyring.makeProvisional())
        #expect(world.provisional() != first)
        #expect(world.committed() == committed)
    }

    @Test func noEnclaveMeansNoKey() {
        let world = World()
        world.enclave.isAvailable = false
        #expect(world.keyring.makeProvisional() == nil)
        #expect(world.provisional() == nil)
        #expect(!world.keyring.commitProvisional(), "nothing to commit")
    }

    /// The enrollment the key was made under is stored with it, and travels
    /// with it into the committed slot.
    @Test func theKeyRemembersItsEnrollment() throws {
        let world = World()
        _ = try #require(world.keyring.makeProvisional())
        #expect(world.provisional()?.enrollment == Self.before)
        world.enrolled = Self.after
        #expect(world.keyring.commitProvisional())
        #expect(world.committed()?.enrollment == Self.before)
    }

    // MARK: Health, with no prompt

    @Test func healthReadsTheSlotAndTheEnrollment() throws {
        let world = World()
        #expect(world.keyring.health() == .unpaired(.neverPaired))
        _ = try world.pair()
        #expect(world.keyring.health() == .paired)
        world.enrolled = Self.after
        #expect(world.keyring.health() == .enrollmentChanged)
        world.enrolled = nil
        #expect(world.keyring.health() == .enrollmentChanged, "every face removed")
        #expect(world.enclave.signed.isEmpty, "reading health signs nothing")
    }

    @Test func anUnreadableKeychainIsNotAPairing() {
        let keyring = PhoneKeyring(store: FailingStore(), enclave: TestEnclave(), enrollment: FixedEnrollment(hash: Self.before))
        #expect(keyring.health() == .unpaired(.unreadable))
        #expect(keyring.sign(Self.message, match: TestMatch()) == .unpaired)
    }

    struct FailingStore: SigningKeyStore {
        func read(_ slot: KeySlot) -> SigningKeyRead { .failed(status: -34018) }
        func write(_ key: StoredSigningKey, to slot: KeySlot) -> Bool { false }
        func delete(_ slot: KeySlot) -> Bool { false }
    }

    /// Only a hash read at creation and reading differently now is a change.
    @Test func whatCountsAsAChangedEnrollment() {
        #expect(!PhoneKeyring.enrollmentChanged(from: Self.before, to: Self.before))
        #expect(PhoneKeyring.enrollmentChanged(from: Self.before, to: Self.after))
        #expect(PhoneKeyring.enrollmentChanged(from: Self.before, to: nil))
        #expect(!PhoneKeyring.enrollmentChanged(from: nil, to: Self.after), "unknown then proves nothing")
        #expect(!PhoneKeyring.enrollmentChanged(from: nil, to: nil))
    }

    // MARK: Unpairing itself: a dead key AND a changed enrollment, only

    struct UnpairRow: CustomTestStringConvertible, Sendable {
        let name: String
        let changed: Bool
        /// nil: the key is killed (an enrollment change's error class).
        let forced: SigningOutcome?
        let expected: PhoneKeyring.Signing
        let keyStays: Bool
        var testDescription: String { name }
    }

    nonisolated static let unpairRows: [UnpairRow] = [
        UnpairRow(name: "a dead key, the enrollment changed", changed: true, forced: nil, expected: .selfUnpaired, keyStays: false),
        UnpairRow(name: "a dead key, the enrollment unchanged", changed: false, forced: nil, expected: .notSigned, keyStays: true),
        UnpairRow(name: "a cancel or a lockout, the enrollment changed", changed: true, forced: .notAuthorized,
                  expected: .notSigned, keyStays: true),
        UnpairRow(name: "a cancel or a lockout, the enrollment unchanged", changed: false, forced: .notAuthorized,
                  expected: .notSigned, keyStays: true),
    ]

    @Test(arguments: unpairRows)
    func thePhoneUnpairsItselfOnlyForADeadKeyAndAChangedEnrollment(_ row: UnpairRow) throws {
        let world = World()
        _ = try world.pair()
        let key = try #require(world.committed())
        if let forced = row.forced { world.enclave.forced = forced } else { world.enclave.killed = [key.keyData] }
        if row.changed { world.enrolled = Self.after }
        let match = TestMatch()
        #expect(world.keyring.sign(Self.message, match: match) == row.expected)
        #expect(!match.isValid)
        #expect((world.committed() != nil) == row.keyStays)
        if !row.keyStays {
            #expect(world.keyring.health() == .unpaired(.enrollmentChanged))
        }
    }

    /// A key that still signs after the hash changed (a system update can
    /// change it) is trusted: the enclave decides, and the stored hash is
    /// brought up to date, so the phone stops warning.
    @Test func aKeyThatStillSignsHealsAChangedHash() throws {
        let world = World()
        _ = try world.pair()
        world.enrolled = Self.after
        #expect(world.keyring.health() == .enrollmentChanged)
        guard case .signed = world.keyring.sign(Self.message, match: TestMatch()) else {
            Issue.record("the key did not sign")
            return
        }
        #expect(world.committed()?.enrollment == Self.after)
        #expect(world.keyring.health() == .paired)
    }

    /// A new pairing after the phone unpaired itself reads as paired again.
    @Test func reparingAfterUnpairingItself() throws {
        let world = World()
        _ = try world.pair()
        world.enclave.killed = [try #require(world.committed()).keyData]
        world.enrolled = Self.after
        #expect(world.keyring.sign(Self.message, match: TestMatch()) == .selfUnpaired)
        world.enclave.killed = []
        _ = try world.pair()
        #expect(world.keyring.health() == .paired)
    }

    // MARK: One match, one signature

    /// Every signature spends its match, and a spent match signs nothing.
    @Test func aMatchSignsOnce() throws {
        let world = World()
        _ = try world.pair()
        let match = TestMatch()
        guard case .signed = world.keyring.sign(Self.message, match: match) else {
            Issue.record("the first signature failed")
            return
        }
        #expect(match.invalidations == 1)
        #expect(world.keyring.sign(Self.message, match: match) == .notSigned, "a spent match authorizes nothing")
        #expect(world.committed() != nil, "and costs the pairing nothing")
    }

    /// The provisional key's proof spends its match too, and a pairing that
    /// lost its key signs nothing.
    @Test func theProvisionalKeySignsOncePerMatch() throws {
        let world = World()
        let publicKey = try #require(world.keyring.makeProvisional())
        let match = TestMatch()
        guard case .signed(let signature) = world.keyring.signProvisional(Self.message, match: match) else {
            Issue.record("the provisional key did not sign")
            return
        }
        #expect(SignatureCheck.verifies(signature, over: Self.message, by: publicKey))
        #expect(!match.isValid)
        #expect(world.keyring.signProvisional(Self.message, match: match) == .notAuthorized)
        world.keyring.discardProvisional()
        let late = TestMatch()
        #expect(world.keyring.signProvisional(Self.message, match: late) == .keyUnusable)
        #expect(!late.isValid)
    }

    /// The software key's signature has the wire's shape: 64 raw bytes over
    /// SHA-256, as the Mac checks it.
    @Test func aSignatureHasTheWiresShape() throws {
        let world = World()
        let publicKey = try world.pair()
        guard case .signed(let signature) = world.keyring.sign(Self.message, match: TestMatch()) else {
            Issue.record("no signature")
            return
        }
        #expect(signature.count == 64)
        #expect(SignatureCheck.verifies(signature, over: Self.message, by: publicKey))
        #expect(!SignatureCheck.verifies(signature, over: Self.message + [0x0a], by: publicKey))
    }

    // MARK: The live enclave's error classes (pure)

    struct ErrorRow: CustomTestStringConvertible, Sendable {
        let name: String
        let error: @Sendable () -> any Error
        let expected: SigningOutcome
        var testDescription: String { name }
    }

    nonisolated static let errorRows: [ErrorRow] = [
        ErrorRow(name: "user cancel", error: { NSError(domain: LAError.errorDomain, code: LAError.Code.userCancel.rawValue) },
                 expected: .notAuthorized),
        ErrorRow(name: "system cancel", error: { NSError(domain: LAError.errorDomain, code: LAError.Code.systemCancel.rawValue) },
                 expected: .notAuthorized),
        ErrorRow(name: "lockout", error: { NSError(domain: LAError.errorDomain, code: LAError.Code.biometryLockout.rawValue) },
                 expected: .notAuthorized),
        ErrorRow(name: "authentication failed",
                 error: { NSError(domain: LAError.errorDomain, code: LAError.Code.authenticationFailed.rawValue) },
                 expected: .keyUnusable),
        ErrorRow(name: "invalid context", error: { NSError(domain: LAError.errorDomain, code: LAError.Code.invalidContext.rawValue) },
                 expected: .keyUnusable),
        ErrorRow(name: "OSStatus user canceled", error: { NSError(domain: NSOSStatusErrorDomain, code: Int(errSecUserCanceled)) },
                 expected: .notAuthorized),
        ErrorRow(name: "OSStatus auth failed", error: { NSError(domain: NSOSStatusErrorDomain, code: Int(errSecAuthFailed)) },
                 expected: .keyUnusable),
        ErrorRow(name: "CryptoKit over a cancel", error: { CryptoKitError.underlyingCoreCryptoError(error: errSecUserCanceled) },
                 expected: .notAuthorized),
        ErrorRow(name: "CryptoKit over anything else", error: { CryptoKitError.underlyingCoreCryptoError(error: errSecAuthFailed) },
                 expected: .keyUnusable),
        ErrorRow(name: "another domain", error: { NSError(domain: "x", code: 1) }, expected: .keyUnusable),
    ]

    /// A cancel or a lockout is never the key's fault; anything else after a
    /// good match is.
    @Test(arguments: errorRows)
    func theLiveEnclavesErrorsAreClassed(_ row: ErrorRow) {
        #expect(SecureEnclaveSigner.outcome(of: row.error()) == row.expected)
    }
}
