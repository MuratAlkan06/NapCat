import CryptoKit
import Foundation
import NapCatWire
import os

// F4 slice S-PAIR-A (#161): the Mac's decision verifier (CL-1). Design:
// design/remote-approvals.md, "Slice S-PAIR".
//
// THE ONE PLACE a decision record's reading becomes the S0 decision value
// (lint-locked: this file builds `ApprovalDecision` once, after the signature
// check, and no other Mac source builds it). A reading is a claim. It counts
// only when the paired phone's key signed exactly the canonical decision
// message (`ApprovalSigning.decisionMessage`) the Mac rebuilds from the
// claim and from ITS OWN copy of the forwarded prompt, whose digest is the
// message's `shown` line: the phone signs what it displayed, so a prompt
// record rewritten on its way to the phone cannot be approved either.
//
// The checks run in a fixed order and the first failure wins: the paired
// key; the claim's shape (a known verdict, a whole-second decision time, a
// 64-byte signature — before any cryptography — the wire version, the prompt
// ID's one spelling); the Mac's copy; the signature. A decision that does not
// verify is DROPPED and audited with a closed code
// (`decision.unverified.<reason>`), and nothing else happens: no retry, no
// alert, the local dialog simply stays open. Duplicates and the TTL stay the
// lifecycle's (freshness is judged on the Mac's clock).
//
// SOFTWARE KEYS ONLY: the Mac never holds a private key. This file verifies
// with CryptoKit's P-256 public key and names nothing of the Secure Enclave,
// biometrics, the keychain's calls or iCloud (lint-locked): the paired key
// comes from the slot.
//
// WIRED (S-PAIR-C2, #181): `verify` is the one road from a decision record's
// reading to the intake's `decide` (lint-locked), and it reads the paired
// key from the slot (`PairedKeyStore.read()`) at each verification, here and
// nowhere else, keeping nothing: a verification after an Unpair finds no
// key and refuses — the key is gone, or (#247) the slot reads the Unpair as
// outstanding until its removal goes through, across relaunches. NOTHING
// ARMS: the approval files' one armed literal is still `armed: { false }`,
// so no decision reaches a real session.
// UNPRIVILEGED — no sudo, no PLAN §4 command, no subprocess.

/// A decision record's fields exactly as decoded, before any check: what
/// the verifier is handed. Every one of them is the writer's claim.
struct DecisionEvidence: Sendable {
    let wireVersion: Int
    /// The `promptID` field's text.
    let promptID: String
    /// The `verdict` field's text.
    let verdict: String
    /// The `decidedAt` field (the phone writes whole seconds).
    let decidedAt: Date
    /// The `signature` field: ECDSA P-256 in its raw form (r, then s).
    let signature: Data
}

/// The Mac's own copy of one forwarded prompt: the three fields exactly as
/// it wrote them into the prompt record, byte for byte. (Not Equatable on
/// purpose: Swift compares strings by canonical equivalence, and the digest
/// is over bytes.)
struct ForwardedCopy: Sendable {
    let promptID: PromptID
    let toolName: String
    let inputPreview: String
    let projectLabel: String
}

/// Why a decision did not verify: the closed audit vocabulary,
/// `decision.unverified.<rawValue>`.
enum DecisionUnverifiedReason: String, CaseIterable, Sendable {
    /// No phone is paired, so nothing can verify (#247: nor while an Unpair
    /// of the stored key is outstanding).
    case noPairedKey
    /// The verdict is not exactly `allow` or `deny`.
    case unknownVerdict
    /// The decision time is negative, not finite, or past 2^53 seconds.
    case decidedAtOutOfRange
    /// The decision time is not a whole second (the phone writes whole
    /// seconds, and the signed line has no fraction).
    case fractionalDecidedAt
    /// The signature is not exactly 64 bytes.
    case signatureLength
    case wrongWireVersion
    /// The prompt ID is not exactly 32 lowercase hex digits, or is zero.
    case malformedPromptID
    /// The Mac holds no forwarded copy of this prompt.
    case noForwardedCopy
    /// The signature does not verify over the rebuilt message: another key,
    /// a forgery, any changed field, or a prompt the phone saw otherwise.
    case signatureInvalid
    /// The paired key signed this very decision, but over the Mac's copy in
    /// another Unicode normalization form: the record's text changed form on
    /// its way to the phone. Refused all the same (diagnostic only).
    case shownDigestMismatch
}

/// What the verifier made of one decision.
enum DecisionVerification: Equatable, Sendable {
    /// The paired phone signed exactly this decision over the Mac's copy.
    case verified(ApprovalDecision)
    case unverified(DecisionUnverifiedReason)
}

/// One audit line: the prompt's random ID when the claim spells one, and the
/// closed code. Never a tool name, a preview, a label, a key or a signature.
struct DecisionVerifierAudit: Equatable, Sendable {
    let promptID: PromptID?
    let reason: DecisionUnverifiedReason

    var code: String { (promptID.map { "prompt=\($0.hex) " } ?? "") + "decision.unverified." + reason.rawValue }
}

enum DecisionVerifier {
    /// The latest decision time a Double still holds as an exact whole
    /// number of seconds (2^53).
    static let latestDecidedAt: TimeInterval = 9_007_199_254_740_992

    /// THE verification (S-PAIR-C2): the paired key is the one the slot
    /// holds NOW — read here, at this verification, and never kept — so no
    /// key outlives an Unpair: a key under an outstanding Unpair (#247)
    /// reads as no pairing. A refusal is audited by its code and counts for
    /// nothing; only a `.verified` result reaches a lifecycle.
    static func verify(_ evidence: DecisionEvidence, copy: ForwardedCopy?, keys: PairedKeyStore,
                       audit: (DecisionVerifierAudit) -> Void = DecisionVerifierLog.record) -> DecisionVerification {
        let pairedKey: P256.Signing.PublicKey? = switch keys.read() {
        case .paired(let phone): try? P256.Signing.PublicKey(x963Representation: phone.publicKey)
        case .notPaired, .unreadable, .unpairOutstanding: nil
        }
        let verification = verification(of: evidence, copy: copy, pairedKey: pairedKey)
        if case .unverified(let reason) = verification {
            audit(DecisionVerifierAudit(promptID: PromptID(hex: evidence.promptID), reason: reason))
        }
        return verification
    }

    /// The checks, in order: the first failure wins.
    static func verification(of evidence: DecisionEvidence, copy: ForwardedCopy?,
                             pairedKey: P256.Signing.PublicKey?) -> DecisionVerification {
        guard let pairedKey else { return .unverified(.noPairedKey) }
        guard let verdict = ApprovalWire.Verdict(rawValue: evidence.verdict) else { return .unverified(.unknownVerdict) }
        let seconds = evidence.decidedAt.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, seconds <= latestDecidedAt else { return .unverified(.decidedAtOutOfRange) }
        guard seconds == seconds.rounded(.towardZero) else { return .unverified(.fractionalDecidedAt) }
        guard evidence.signature.count == ApprovalSigning.signatureByteCount else { return .unverified(.signatureLength) }
        guard evidence.wireVersion == ApprovalWire.wireVersion else { return .unverified(.wrongWireVersion) }
        guard let promptID = PromptID(hex: evidence.promptID) else { return .unverified(.malformedPromptID) }
        guard let copy, copy.promptID == promptID else { return .unverified(.noForwardedCopy) }
        let claimed = Claimed(wireVersion: evidence.wireVersion, promptID: promptID, verdict: verdict, decidedAt: Int(seconds))
        guard let message = message(claimed, shown: copy),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: evidence.signature) else {
            return .unverified(.signatureInvalid)
        }
        guard pairedKey.isValidSignature(signature, for: SHA256.hash(data: message)) else {
            return .unverified(signedAnotherForm(claimed, of: copy, signature, pairedKey) ? .shownDigestMismatch : .signatureInvalid)
        }
        return .verified(ApprovalDecision(promptID: promptID, verdict: verdict, wireVersion: evidence.wireVersion, signatureVerified: true))
    }

    /// The claim's signed lines once its shape is checked.
    struct Claimed {
        let wireVersion: Int
        let promptID: PromptID
        let verdict: ApprovalWire.Verdict
        let decidedAt: Int
    }

    /// The canonical bytes the phone signed, rebuilt from the claim and the
    /// copy's three fields as stored (never a displayed form).
    static func message(_ claimed: Claimed, shown copy: ForwardedCopy) -> [UInt8]? {
        let shown = SHA256.hash(data: ApprovalSigning.shownDigestInput(toolName: copy.toolName, inputPreview: copy.inputPreview,
                                                                       projectLabel: copy.projectLabel))
        return ApprovalSigning.decisionMessage(wireVersion: claimed.wireVersion, promptID: claimed.promptID, verdict: claimed.verdict,
                                               decidedAt: claimed.decidedAt, shownDigest: Array(shown))
    }

    /// DIAGNOSTIC ONLY, after the signature has already failed: whether the
    /// paired key signed this same decision over the copy in NFC or NFD (the
    /// form an honest phone ends up with when the record's text changed form
    /// in transit). Its answer only names the refusal; it never accepts.
    static func signedAnotherForm(_ claimed: Claimed, of copy: ForwardedCopy, _ signature: P256.Signing.ECDSASignature,
                                  _ pairedKey: P256.Signing.PublicKey) -> Bool {
        let forms: [(String) -> String] = [{ $0.precomposedStringWithCanonicalMapping }, { $0.decomposedStringWithCanonicalMapping }]
        let stored = ApprovalSigning.shownDigestInput(toolName: copy.toolName, inputPreview: copy.inputPreview,
                                                      projectLabel: copy.projectLabel)
        for form in forms {
            let other = ForwardedCopy(promptID: copy.promptID, toolName: form(copy.toolName), inputPreview: form(copy.inputPreview),
                                      projectLabel: form(copy.projectLabel))
            guard ApprovalSigning.shownDigestInput(toolName: other.toolName, inputPreview: other.inputPreview,
                                                   projectLabel: other.projectLabel) != stored,
                  let message = message(claimed, shown: other) else { continue }
            if pairedKey.isValidSignature(signature, for: SHA256.hash(data: message)) { return true }
        }
        return false
    }
}

enum DecisionVerifierLog {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "approvals")

    static func record(_ event: DecisionVerifierAudit) {
        logger.notice("\(event.code, privacy: .public)")
    }
}
