import CryptoKit
import Foundation
import NapCatWire
import Observation

/// The phone's half of the pairing ceremony (F4 slice S-PAIR-B, #161).
/// Design: design/remote-approvals.md, "Slice S-PAIR".
///
/// The Mac shows a single-use code (`napcat-pair-v1:` and a 256-bit nonce)
/// for five minutes; the phone scans it ONCE and:
///
/// 1. reads it strictly (`ApprovalSigning.pairingNonce`): any other text is
///    refused, and the ceremony is over;
/// 2. makes a new key, PROVISIONAL (S-PAIR amendment 3): the committed key,
///    if there is one, keeps signing until the owner's confirm;
/// 3. asks for the ceremony's one biometric match, which signs the proof;
/// 4. writes ONE pairing response (`PairingResponse`) through the seam;
/// 5. shows its own key's fingerprint and waits ("Waiting — confirm the code
///    on your Mac"): never "Paired" before the owner's confirm here;
/// 6. on the owner's confirm that both devices show the same code, commits
///    the key. A cancel, a timeout or any failure discards the provisional
///    key and leaves the committed one as it was.
///
/// The nonce lives in one call's locals and is never stored, logged or
/// written. A response already saved for the code fails the ceremony:
/// nothing of it is adopted or shown. The window is five minutes from the
/// scan (the Mac's own window ends no later, and burns the nonce).
///
/// No scan is taken while the match cannot happen (no biometrics enrolled,
/// locked out, or none at all): the ceremony stays at its start, makes and
/// asks for nothing, and the screen says why (`biometry`), so a phone with
/// no Face ID never reaches a match it cannot pass.
///
/// Identifiable by the object itself (#178): Settings' pairing sheet is
/// presented by its ceremony, so each new ceremony opens it afresh.
@MainActor
@Observable
final class PairingCeremony: Identifiable {
    enum Phase: Equatable, Sendable {
        /// Waiting for the one scan.
        case scanning
        /// The scanned text is not a NapCat pairing code. Final.
        case refused
        /// The ceremony's one biometric match is under way.
        case confirming
        /// The one response is being written.
        case saving
        /// The response is saved; the key is provisional until the owner
        /// confirms the codes match, before `until`.
        case waiting(KeyFingerprint, until: Date)
        /// Confirmed: the key is the committed one. Final.
        case paired(KeyFingerprint)
        /// Final; the provisional key is gone.
        case failed(Failure)
        /// The owner closed it. Final; the provisional key is gone.
        case cancelled
        /// The window closed first. Final; the provisional key is gone.
        case expired

        var isFinal: Bool {
            switch self {
            case .scanning, .confirming, .saving, .waiting: return false
            case .refused, .paired, .failed, .cancelled, .expired: return true
            }
        }
    }

    enum Failure: Equatable, Sendable, CaseIterable {
        /// No key could be made (no Secure Enclave, or the keychain refused).
        case noKey
        /// The biometric match did not happen.
        case notConfirmed
        /// The new key did not sign its proof.
        case notSigned
        /// A response for this code was saved already.
        case alreadyAnswered
        /// Nothing was saved.
        case unsent
        /// iCloud did not confirm the save.
        case unconfirmed
        /// The confirm came, but the key could not be kept.
        case notKept
        /// The camera's scanner would not start: nothing was scanned.
        case noCamera
    }

    /// The window from the scan: the Mac's code lives five minutes.
    nonisolated static let window: TimeInterval = 300

    /// What the biometric prompt says the match is for. Fixed words.
    nonisolated static let reason = "Confirm it's you to pair this iPhone with your Mac."

    private(set) var phase = Phase.scanning
    /// When the ceremony's window closes; nil before the scan.
    private(set) var deadline: Date?
    /// Whether the ceremony's match can happen here, as last read.
    private(set) var biometry: BiometricAvailability
    @ObservationIgnored private let keyring: PhoneKeyring
    @ObservationIgnored private let biometrics: any BiometricGate
    @ObservationIgnored private let writer: any PairingResponseWriter
    @ObservationIgnored private let clock: () -> Date

    init(keyring: PhoneKeyring, biometrics: any BiometricGate, writer: any PairingResponseWriter,
         clock: @escaping () -> Date = Date.init) {
        self.keyring = keyring
        self.biometrics = biometrics
        self.writer = writer
        self.clock = clock
        self.biometry = biometrics.availability()
    }

    /// Re-reads whether the match can happen, asking for nothing (the sheet
    /// does, as it appears and as the app returns to the foreground: the
    /// owner may have set up Face ID meanwhile).
    func refreshBiometry() {
        let current = biometrics.availability()
        if current != biometry { biometry = current }
    }

    /// The one scan. Anything after the first is ignored, and so is a scan
    /// while no match can happen: it is not taken, and the ceremony waits
    /// at its start. The code comes from the camera alone (`ScannedCode`,
    /// S-PAIR-C1.6), or from a fixture launch's own code.
    func scanned(_ code: ScannedCode) async {
        guard phase == .scanning else { return }
        refreshBiometry()
        guard case .available = biometry else { return }
        deadline = clock().addingTimeInterval(Self.window)
        guard let nonce = ApprovalSigning.pairingNonce(fromPayload: code.payload) else {
            phase = .refused
            return
        }
        guard let publicKey = keyring.makeProvisional(), let fingerprint = KeyFingerprint(publicKey: publicKey) else {
            end(.failed(.noKey))
            return
        }
        phase = .confirming
        guard case .confirmed(let match) = await biometrics.confirm(reason: Self.reason) else {
            if phase == .confirming { end(.failed(.notConfirmed)) }
            return
        }
        guard phase == .confirming, isOpen else {
            match.invalidate()
            if !phase.isFinal { end(.expired) }
            return
        }
        guard let response = Self.response(nonce: nonce, publicKey: publicKey, keyring: keyring, match: match) else {
            end(.failed(.notSigned))
            return
        }
        phase = .saving
        let outcome = await writer.write(response)
        guard phase == .saving else { return }
        guard isOpen else {
            end(.expired)
            return
        }
        switch outcome {
        case .saved: phase = .waiting(fingerprint, until: deadline ?? clock())
        case .alreadyAnswered: end(.failed(.alreadyAnswered))
        case .failed: end(.failed(.unsent))
        case .unconfirmed: end(.failed(.unconfirmed))
        }
    }

    /// The owner saw the same code on both devices: the key is committed,
    /// replacing any earlier pairing. Only while waiting, inside the window.
    func confirmCodesMatch() {
        guard case .waiting(let fingerprint, _) = phase else { return }
        guard isOpen else {
            end(.expired)
            return
        }
        guard keyring.commitProvisional() else {
            end(.failed(.notKept))
            return
        }
        phase = .paired(fingerprint)
    }

    /// The live scanner would not start (the camera can't be used): the
    /// ceremony ends at its start, so the screen says why and offers Scan
    /// Again instead of a dark viewfinder. Only before the scan.
    func scannerFailed() {
        guard phase == .scanning else { return }
        end(.failed(.noCamera))
    }

    /// The owner closed the ceremony: the provisional key goes, the
    /// committed one stays.
    func cancel() {
        guard !phase.isFinal else { return }
        end(.cancelled)
    }

    /// Ends the ceremony once its window has closed.
    func tick() {
        guard !phase.isFinal, phase != .scanning, !isOpen else { return }
        end(.expired)
    }

    /// A new ceremony, after one that ended without pairing: one scan each.
    func restart() {
        switch phase {
        case .refused, .failed, .cancelled, .expired:
            deadline = nil
            phase = .scanning
        case .scanning, .confirming, .saving, .waiting, .paired:
            return
        }
    }

    private var isOpen: Bool {
        guard let deadline else { return false }
        return clock() < deadline
    }

    private func end(_ final: Phase) {
        keyring.discardProvisional()
        phase = final
    }

    /// The response for `nonce` and the new key: its record name, the
    /// confirmation MAC keyed by the nonce, and the proof signed with the
    /// provisional key under `match`, which is spent whatever happens.
    static func response(nonce: [UInt8], publicKey: [UInt8], keyring: PhoneKeyring, match: any BiometricMatch) -> PairingResponse? {
        guard let proofMessage = ApprovalSigning.pairingProofMessage(nonce: nonce, publicKey: publicKey),
              let confirmationMessage = ApprovalSigning.pairingConfirmationMessage(wireVersion: ApprovalWire.wireVersion,
                                                                                    publicKey: publicKey),
              let nameInput = ApprovalSigning.pairingRecordNameInput(nonce: nonce),
              let recordName = ApprovalSigning.pairingRecordName(digest: Array(SHA256.hash(data: nameInput))) else {
            match.invalidate()
            return nil
        }
        guard case .signed(let proof) = keyring.signProvisional(proofMessage, match: match) else { return nil }
        let confirmation = Data(HMAC<SHA256>.authenticationCode(for: confirmationMessage, using: SymmetricKey(data: nonce)))
        return PairingResponse(recordName: recordName, wireVersion: ApprovalWire.wireVersion, publicKey: Data(publicKey),
                               confirmation: confirmation, proof: proof)
    }
}
