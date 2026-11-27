// NapCatWire — the remote-approvals (F4) half of the wire contract between
// NapCat on the Mac (writes prompts, reads decisions) and NapCat Phone (reads
// prompts, writes decisions). Design: design/remote-approvals.md.
//
// Constants ONLY, like AlertWire.swift: zero import statements and no I/O, so
// the same target builds for macOS and iOS and neither app can drift from the
// other. `WireContractTests` pins every value.

/// The CloudKit contract for one forwarded permission prompt and its answer.
///
/// Both records live in the PRIVATE database of the alert container, in the
/// dedicated custom zone `zoneName` (never the default zone the alerts use).
/// A prompt record's name is its random 128-bit prompt ID written as
/// `promptIDHexDigits` lowercase hex digits; nothing about the Claude Code
/// session (its request id, its session id, its description) is ever written.
public enum ApprovalWire {
    /// The same owner's container the alerts use (spelled once, in AlertWire).
    public static let containerIdentifier = AlertWire.containerIdentifier

    /// The dedicated custom zone both record types live in. Versioned like the
    /// subscription, so a later schema gets a fresh zone instead of a mix.
    public static let zoneName = "napcat-approvals-v1"

    /// The phone's ONE query subscription for new prompts (firesOnRecordCreation
    /// in `zoneName`). Distinct from the alert subscription, so the two never
    /// buzz for each other's records.
    public static let promptSubscriptionID = "napcat-prompt-created-v1"

    /// The record shape version every record carries in its `wireVersion`
    /// field. A reader ignores any record with another value.
    public static let wireVersion = 1

    /// How long a forwarded prompt may be answered from the phone (10 minutes).
    /// It only bounds the remote side: when it ends the record is retracted
    /// and the local dialog stays open, never answered automatically. It is
    /// the window a prompt gets when none is given, inside the bounds below.
    public static let promptTimeToLiveSeconds = 600

    /// The shortest window a prompt may be given (5 minutes): a shorter one
    /// is raised to this.
    public static let minPromptTimeToLiveSeconds: Int = 300

    /// The longest window a prompt may be given (1 hour): a longer one is
    /// lowered to this. No record is answerable for longer.
    public static let maxPromptTimeToLiveSeconds: Int = 3_600

    /// A prompt ID is 128 random bits.
    public static let promptIDByteCount = 16

    /// ... written as exactly this many lowercase hex digits (the record name).
    public static let promptIDHexDigits = 32

    /// The three record types, and nothing else.
    public enum RecordType: String, CaseIterable, Sendable {
        /// Mac → phone: one open permission dialog that passed the gate.
        case prompt = "PromptRequest"
        /// Phone → Mac: the owner's one-shot answer to one prompt.
        case decision = "PromptDecision"
        /// Phone → Mac: the phone's one answer to a pairing code (CL-1,
        /// slice S-PAIR-C1). Named from the code's nonce
        /// (`ApprovalSigning.pairingRecordName`), so the Mac fetches it by
        /// name; not in the Production schema until the owner deploys it.
        case pairingResponse = "PairingResponse"
    }

    /// A prompt record's fields — the complete set. There is no description
    /// field: classification and display rely on the tool name and the input
    /// preview only (the description is often the tool's generic text).
    public enum PromptField: String, CaseIterable, Sendable {
        /// `wireVersion` (Int).
        case wireVersion
        /// The Claude Code tool name, e.g. `Bash` (String).
        case toolName
        /// The tool's arguments exactly as the gate classified them (String).
        case inputPreview
        /// The originating project's label (String).
        case projectLabel
        /// When the Mac forwarded it (Date).
        case createdAt
        /// `createdAt` + `promptTimeToLiveSeconds` (Date).
        case expiresAt
    }

    /// A decision record's fields — the complete set.
    public enum DecisionField: String, CaseIterable, Sendable {
        /// `wireVersion` (Int).
        case wireVersion
        /// The answered prompt's ID, as its record name (String).
        case promptID
        /// One of `Verdict` (String).
        case verdict
        /// When the owner answered, on the phone's clock (Date). Signed; the
        /// Mac checks only that it is a whole second in range, and does not
        /// log it: freshness is judged on the Mac's clock against the
        /// prompt's TTL.
        case decidedAt
        /// The paired phone's Secure Enclave signature over the decision
        /// (CL-1, Bytes). A decision that does not verify is ignored.
        case signature
    }

    /// The fields stored as CloudKit encrypted values. Everything a person
    /// could read is encrypted; the version and the timestamps are not.
    public static let encryptedPromptFields: [PromptField] = [.toolName, .inputPreview, .projectLabel]

    /// See `encryptedPromptFields`.
    public static let encryptedDecisionFields: [DecisionField] = [.promptID, .verdict, .signature]

    /// A pairing response record's fields — the complete set (CL-1, slice
    /// S-PAIR-C1). No fingerprint and no nonce: each device computes its
    /// code from the key, and the nonce never leaves the Mac's screen.
    public enum PairingResponseField: String, CaseIterable, Sendable {
        /// `wireVersion` (Int).
        case wireVersion
        /// The phone's new public key, x9.63: 65 bytes (Bytes).
        case publicKey
        /// HMAC-SHA256 keyed by the nonce over
        /// `ApprovalSigning.pairingConfirmationMessage`: 32 bytes (Bytes).
        case confirmation
        /// The new key's ECDSA signature over
        /// `ApprovalSigning.pairingProofMessage`, raw: 64 bytes (Bytes).
        case proof
    }

    /// Every pairing response field but the version is encrypted.
    public static let encryptedPairingResponseFields: [PairingResponseField] = [.publicKey, .confirmation, .proof]

    /// The two answers. One-shot: neither changes any later prompt.
    public enum Verdict: String, CaseIterable, Sendable {
        /// The phone's in-app, biometric-only Allow (CL-3).
        case allow
        /// The phone's Deny: in-app and biometric-only like Allow (the
        /// uniform-signing ruling); the prompt push carries no action.
        case deny
    }
}
