import Foundation
import NapCatWire

/// One permission prompt the Mac forwarded, as the phone holds it: exactly
/// the PromptRequest record's fields (`ApprovalWire.PromptField`) and its
/// name, the prompt's random 128-bit ID. There is no description, session or
/// request ID to show: the wire carries none, and the tool name with the
/// input preview is what the owner decides on (F4 design, S-1).
struct PendingRequest: Identifiable, Hashable, Sendable {
    let id: PromptID
    /// The Claude Code tool name, e.g. `Bash`.
    let toolName: String
    /// The tool's arguments exactly as the Mac's gate classified them. Shown
    /// verbatim: the phone never reformats what it asks the owner to allow.
    let inputPreview: String
    /// The originating project's label.
    let projectLabel: String
    /// When the Mac forwarded it, on the Mac's clock.
    let createdAt: Date
    /// When the Mac stops taking an answer, on the Mac's clock.
    let expiresAt: Date

    /// The longest a request may be answered from the phone: the wire's TTL
    /// (10 minutes).
    static let timeToLive = TimeInterval(ApprovalWire.promptTimeToLiveSeconds)

    /// nil when it is not fit to show: an empty tool name, or a window that
    /// is not a positive span of at most the TTL (a record claiming a longer
    /// one is malformed, never trusted).
    init?(id: PromptID, toolName: String, inputPreview: String, projectLabel: String,
          createdAt: Date, expiresAt: Date) {
        let window = expiresAt.timeIntervalSince(createdAt)
        guard !toolName.isEmpty, window > 0, window <= Self.timeToLive else { return nil }
        self.id = id
        self.toolName = toolName
        self.inputPreview = inputPreview
        self.projectLabel = projectLabel
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}
