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

    /// The window a prompt gets when the Mac gives none: the wire's default
    /// (10 minutes).
    static let timeToLive = TimeInterval(ApprovalWire.promptTimeToLiveSeconds)

    /// The longest window a request may claim (#194): the wire's maximum (1
    /// hour). A record claiming a longer one is malformed, never trusted.
    static let longestWindow = TimeInterval(ApprovalWire.maxPromptTimeToLiveSeconds)

    /// nil when it is not fit to show: an empty tool name, or a window that
    /// is not a positive span of at most `longestWindow`.
    init?(id: PromptID, toolName: String, inputPreview: String, projectLabel: String,
          createdAt: Date, expiresAt: Date) {
        let window = expiresAt.timeIntervalSince(createdAt)
        guard !toolName.isEmpty, window > 0, window <= Self.longestWindow else { return nil }
        self.id = id
        self.toolName = toolName
        self.inputPreview = inputPreview
        self.projectLabel = projectLabel
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    /// The record's own window, on the Mac's clock (positive, at most
    /// `longestWindow`).
    var window: TimeInterval { expiresAt.timeIntervalSince(createdAt) }
}

/// THE seam between the inbox and where live prompts come from (F4,
/// #194): the prompt push subscription and one snapshot read of every prompt
/// the Mac offers. Production is `LivePromptSource` (built once, in
/// `RequestInbox.make`, over the live approvals database); tests inject a
/// fake. Nothing here answers anything.
protocol PromptSource: Sendable {
    /// Makes sure the prompt push subscription exists: looked up first,
    /// created only when missing. Whether it exists now.
    func ensureSubscription() async -> Bool
    /// Deletes the prompt push subscription. Whether it is gone now.
    func removeSubscription() async -> Bool
    /// One read of every prompt the Mac offers now; nil when the read
    /// failed, which changes nothing.
    func snapshot() async -> [PendingRequest]?
}
