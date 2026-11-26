import Foundation
import NapCatWire

/// What the phone sends the Mac for one request: the prompt, the owner's
/// answer, when, and the paired key's signature over exactly that (CL-1,
/// slice S-PAIR-B). A REQUEST to the Mac, never a verdict: the Mac counts
/// it only when the signature verifies with the key it paired, over the
/// message it rebuilds from its own copy of the prompt. Built in the app by
/// `DecisionSigner` only (lint-locked).
struct PhoneDecision: Equatable, Sendable {
    let promptID: PromptID
    let verdict: ApprovalWire.Verdict
    /// This phone's clock, in whole seconds: the signed line has no
    /// fraction, and the Mac refuses one. (The Mac judges freshness on its
    /// own clock.)
    let decidedAt: Date
    /// ECDSA P-256 over SHA-256 of the canonical decision message
    /// (`ApprovalSigning.decisionMessage`), in its raw form: exactly 64
    /// bytes.
    let signature: Data

    /// nil unless `decidedAt` is a whole, non-negative second a Double
    /// holds exactly, and `signature` is exactly 64 bytes.
    init?(promptID: PromptID, verdict: ApprovalWire.Verdict, decidedAt: Date, signature: Data) {
        let seconds = decidedAt.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, seconds <= DecisionSigner.latestDecidedAt, seconds == seconds.rounded(.down),
              signature.count == ApprovalSigning.signatureByteCount else { return nil }
        self.promptID = promptID
        self.verdict = verdict
        self.decidedAt = decidedAt
        self.signature = signature
    }
}

/// What writing one decision came to.
enum DecisionWriteOutcome: String, Equatable, Sendable {
    /// iCloud saved it.
    case saved
    /// A decision for this prompt is saved already (an earlier attempt from
    /// this phone landed, or another device answered): nothing new was
    /// written, and this one is not sent.
    case alreadyAnswered
    /// Nothing was saved.
    case failed
    /// It may or may not have been saved. Answering again is safe: there is
    /// one decision record per prompt, so a second save is refused as
    /// already answered rather than written twice.
    case unconfirmed
}

/// THE seam behind Allow and Deny: it writes a decision already signed. The
/// CloudKit one, `CloudKitDecisionWriter`, is built by no app source yet
/// (lint-locked): a fixture launch writes to `FixtureDecisionWriter` and a
/// live launch to `UnsentDecisionWriter`.
protocol DecisionWriter: Sendable {
    func write(_ decision: PhoneDecision) async -> DecisionWriteOutcome
}

/// The live inbox's writer until the answer path is armed: nothing is
/// written, and every answer would read as unsent. A live launch does
/// receive prompts (#194), so while this is its writer the inbox is read
/// only (`RequestInbox.isReadOnly`, the writer's type and nothing else): the
/// prompt screen offers no answer, saying to answer on the Mac, and the
/// inbox refuses one before asking for a match.
struct UnsentDecisionWriter: DecisionWriter {
    func write(_ decision: PhoneDecision) async -> DecisionWriteOutcome { .failed }
}
