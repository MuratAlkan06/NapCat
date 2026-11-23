import Foundation
import NapCatWire

/// What the phone sends the Mac for one request: the prompt, the owner's
/// answer and when. A REQUEST to the Mac, never a verdict: before pairing
/// (CL-1) it carries no signature, and the Mac reads an unsigned decision
/// as a claim it does not act on.
struct PhoneDecision: Equatable, Sendable {
    let promptID: PromptID
    let verdict: ApprovalWire.Verdict
    /// This phone's clock (the Mac judges freshness on its own).
    let decidedAt: Date
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

/// THE seam behind Allow and Deny. The CloudKit one, `CloudKitDecisionWriter`,
/// is built by no app source in this slice (lint-locked): a fixture launch
/// writes to `FixtureDecisionWriter` and a live launch to `UnsentDecisionWriter`.
protocol DecisionWriter: Sendable {
    func write(_ decision: PhoneDecision) async -> DecisionWriteOutcome
}

/// A live launch's writer in this slice: there is no record path to the Mac
/// yet (its iCloud schema is not deployed), so nothing is written and every
/// answer reads as unsent. A live launch has no requests to answer anyway.
struct UnsentDecisionWriter: DecisionWriter {
    func write(_ decision: PhoneDecision) async -> DecisionWriteOutcome { .failed }
}
