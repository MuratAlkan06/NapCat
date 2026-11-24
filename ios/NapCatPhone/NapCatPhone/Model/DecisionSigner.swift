import CryptoKit
import Foundation
import NapCatWire

/// THE one place a decision is signed (F4 slice S-PAIR-B, #161; CL-1).
/// Design: design/remote-approvals.md, "Slice S-PAIR".
///
/// It builds the canonical decision message with the shared builder
/// (`ApprovalSigning.decisionMessage`): the wire version, the prompt ID, the
/// verdict, the decision time in whole seconds, and the digest of what the
/// owner was shown. The phone signs what it showed: the `shown` digest is
/// taken over the three fields exactly as the phone DECODED them from the
/// prompt record (S-PAIR amendment 6), never over a displayed form. The
/// request screen draws whitespace as marks, and that drawing is a pure
/// function of these same bytes; hashing the drawing could never match the
/// Mac, which rebuilds the digest from its own copy of the prompt it wrote.
///
/// Allow and Deny are signed alike (the owner's uniform-signing ruling), by
/// the committed key only, with one match each. Lint-locked: no other app
/// source builds the message, takes the digest, or builds a decision.
@MainActor
enum DecisionSigner {
    /// The latest decision time a Double still holds as an exact whole
    /// number of seconds (2^53): the Mac refuses any later one.
    nonisolated static let latestDecidedAt: TimeInterval = 9_007_199_254_740_992

    /// The moment, rounded down to its whole second.
    nonisolated static func wholeSecond(_ moment: Date) -> Date {
        Date(timeIntervalSince1970: moment.timeIntervalSince1970.rounded(.down))
    }

    /// SHA-256 of the shown-digest input over the request's three fields as
    /// received.
    nonisolated static func shownDigest(of request: PendingRequest) -> [UInt8] {
        Array(SHA256.hash(data: ApprovalSigning.shownDigestInput(toolName: request.toolName, inputPreview: request.inputPreview,
                                                                 projectLabel: request.projectLabel)))
    }

    /// The canonical message for `verdict` on `request` at `decidedAt`; nil
    /// for a time that is not a whole second from 1970 to 2^53 seconds.
    nonisolated static func message(_ verdict: ApprovalWire.Verdict, for request: PendingRequest, decidedAt: Date) -> [UInt8]? {
        let seconds = decidedAt.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, seconds <= latestDecidedAt, seconds == seconds.rounded(.down) else { return nil }
        return ApprovalSigning.decisionMessage(wireVersion: ApprovalWire.wireVersion, promptID: request.id, verdict: verdict,
                                               decidedAt: Int(seconds), shownDigest: shownDigest(of: request))
    }

    /// What signing one answer came to.
    enum Outcome: Equatable, Sendable {
        /// Ready to write: the decision and its 64-byte signature.
        case signed(PhoneDecision)
        /// No paired key: nothing was signed.
        case unpaired
        /// Not signed; the key stays (a cancel, a lockout, or a failure
        /// while the enrollment is unchanged).
        case notSigned
        /// Not signed, and the phone unpaired itself (`PhoneKeyring`).
        case selfUnpaired
    }

    /// Signs `verdict` on `request`, decided `now` (in whole seconds), with
    /// the committed key, authorized by `match`, which is spent whatever
    /// happens.
    static func sign(_ verdict: ApprovalWire.Verdict, for request: PendingRequest, at now: Date, with keyring: PhoneKeyring,
                     match: any BiometricMatch) -> Outcome {
        let decidedAt = wholeSecond(now)
        guard let message = message(verdict, for: request, decidedAt: decidedAt) else {
            match.invalidate()
            return .notSigned
        }
        switch keyring.sign(message, match: match) {
        case .signed(let signature):
            guard let decision = PhoneDecision(promptID: request.id, verdict: verdict, decidedAt: decidedAt,
                                               signature: signature) else { return .notSigned }
            return .signed(decision)
        case .unpaired:
            return .unpaired
        case .notSigned:
            return .notSigned
        case .selfUnpaired:
            return .selfUnpaired
        }
    }
}
