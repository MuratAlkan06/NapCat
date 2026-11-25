import Foundation
import NapCatWire

/// The phone's one answer to a pairing code (F4 slice S-PAIR-B, #161):
/// what the Mac fetches by name during its ceremony window and checks
/// before it stores anything. Design: design/remote-approvals.md, "Slice
/// S-PAIR".
///
/// - `recordName`: SHA-256 of `napcat-pair-name-v1` and the nonce, as 64
///   lowercase hex digits (`ApprovalSigning.pairingRecordName`), so the Mac
///   finds it without a query.
/// - `publicKey`: the phone's new key, x9.63 (65 bytes).
/// - `confirmation`: HMAC-SHA256 keyed by the nonce over the confirmation
///   message (`ApprovalSigning.pairingConfirmationMessage`): only a holder
///   of the code on the Mac's screen can make it.
/// - `proof`: the new key's ECDSA signature over the proof message
///   (`ApprovalSigning.pairingProofMessage`), raw 64 bytes: the key the
///   record names can sign.
///
/// No fingerprint travels: each device computes its own from the key.
/// The nonce itself is never written.
struct PairingResponse: Equatable, Sendable {
    let recordName: String
    let wireVersion: Int
    let publicKey: Data
    let confirmation: Data
    let proof: Data

    /// nil unless every value has its wire shape.
    init?(recordName: String, wireVersion: Int, publicKey: Data, confirmation: Data, proof: Data) {
        let hex = Set("0123456789abcdef".utf8)
        guard recordName.utf8.count == ApprovalSigning.recordNameHexDigits, recordName.utf8.allSatisfy(hex.contains),
              wireVersion == ApprovalWire.wireVersion,
              publicKey.count == ApprovalSigning.publicKeyByteCount, publicKey.first == 0x04,
              confirmation.count == ApprovalSigning.digestByteCount,
              proof.count == ApprovalSigning.signatureByteCount else { return nil }
        self.recordName = recordName
        self.wireVersion = wireVersion
        self.publicKey = publicKey
        self.confirmation = confirmation
        self.proof = proof
    }
}

/// What writing the pairing response came to.
enum PairingWriteOutcome: String, Equatable, Sendable {
    /// iCloud saved it.
    case saved
    /// A response for this code is saved already. The phone never adopts
    /// it, and never shows anything derived from it: the pairing fails,
    /// loudly (S-PAIR amendment 1).
    case alreadyAnswered
    /// Nothing was saved.
    case failed
    /// It may or may not have been saved. Not retried: the Mac freezes on
    /// the first response it fetches, so the pairing starts over.
    case unconfirmed
}

/// THE seam behind the pairing's one write. Its record (a new record type
/// in the approvals zone, every value but the version encrypted) is
/// written by `CloudKitPairingResponseWriter` (slice S-PAIR-C1.5), create
/// only, the one conformer outside the fixtures (lint-locked to its
/// declaration's line). No app source builds that writer yet, so a fixture
/// launch writes to a fixture and nothing a pairing does leaves the phone.
protocol PairingResponseWriter: Sendable {
    func write(_ response: PairingResponse) async -> PairingWriteOutcome
}
