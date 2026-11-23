import NapCatWire

// F4 slice S1: where a relayed permission prompt meets the S0 core on the
// Mac. Design: design/remote-approvals.md.
//
// Every prompt frame from a channel server is read by the strict frame reader
// (ApprovalChannel.frame) and classified by the category gate
// (ApprovalGate.classify, with the alert topic as a secret) BEFORE its
// lifecycle opens; the lifecycle (ApprovalLifecycle) alone decides what
// happens next, and this type only performs the effects it returns. The ONE
// verdict frame it ever writes is the lifecycle's `.deliverVerdict` — the
// acceptance of a valid, signed remote decision inside the TTL (lint-locked).
// Pure over injected I/O: no socket, no CloudKit, no clock of its own.

/// Where NapCat writes a forwarded prompt's record: CloudKit, through the
/// record path's store (`CloudKitApprovalRecords`, slice S3, built only by
/// tests in that slice). Nothing reaches it while the feature is unarmed,
/// which it always is until the iPhone half lands (the S2 host is built never
/// armed, with a sink that writes nothing).
protocol ApprovalRecordSink: AnyObject {
    /// Write the prompt record: the tool the gate forwarded and the gate's
    /// own copy of the preview (`ApprovalGate.forwardedPreview`: no
    /// description, never the relayed text), nothing else from the session.
    func save(_ id: PromptID, tool: ApprovalTool, inputPreview: String, expiresAt: Int)
    /// Delete the prompt record (and its decision, if any).
    func retract(_ id: PromptID)
    /// The forward was accepted: the actionable push replaces this episode's
    /// plain waiting alert.
    func supersedeWaitingAlert(_ id: PromptID)
}

/// One audit-log event: a closed vocabulary. It carries the random prompt ID
/// and never any prompt text, request ID, session ID or topic.
enum ApprovalAuditEvent: Equatable, Sendable {
    case lifecycle(PromptID, ApprovalAudit)
    /// A frame the strict reader refused, or a verdict frame from a server:
    /// that connection is closed.
    case frameRefused
    /// A server sent the same request twice while it was still held.
    case duplicateRequest
    /// `ApprovalIntake.maxPrompts` are held already: the prompt stays local.
    case capacityReached
    /// `ApprovalIntake.maxPromptsPerConnection` are held for this server
    /// already: the prompt stays local.
    case connectionPromptLimit
    /// No prompt ID could be drawn: the prompt stays local.
    case promptIDUnavailable
    /// An event for a prompt that is not held (never, or no longer).
    case unknownPrompt
    /// A peer failed the seam's check and was closed unread.
    case peerRefused
    /// The Mac toggle went on and the seam is listening (slice S2).
    case listening
    /// The Mac toggle is on but the seam's socket could not be opened:
    /// nothing listens and every prompt stays local.
    case listenFailed
    /// The kill switch: the Mac toggle went off (or NapCat quit).
    case stopped
    /// `ApprovalSeamHost.Limits.maxConnections` servers are connected
    /// already: the new one is closed unread, and its prompts stay local.
    case connectionLimit

    /// The log line's text.
    var code: String {
        switch self {
        case .lifecycle(let id, let audit): return "prompt=\(id.hex) " + Self.code(audit)
        case .frameRefused: return "seam.frameRefused"
        case .duplicateRequest: return "seam.duplicateRequest"
        case .capacityReached: return "seam.capacityReached"
        case .connectionPromptLimit: return "seam.connectionPromptLimit"
        case .promptIDUnavailable: return "seam.promptIDUnavailable"
        case .unknownPrompt: return "seam.unknownPrompt"
        case .peerRefused: return "seam.peerRefused"
        case .listening: return "seam.listening"
        case .listenFailed: return "seam.listenFailed"
        case .stopped: return "seam.stopped"
        case .connectionLimit: return "seam.connectionLimit"
        }
    }

    static func code(_ audit: ApprovalAudit) -> String {
        switch audit {
        case .suppressed(.gate(let suppression)): return "suppressed.gate." + suppression.auditCode
        case .suppressed(.notArmed): return "suppressed.notArmed"
        case .forwarded: return "forwarded"
        case .forwardFailed: return "forwardFailed"
        case .decided(.remote(let verdict)): return "decided.remote." + verdict.rawValue
        case .decided(.local): return "decided.local"
        case .ignored(let reason): return "ignored." + reason.rawValue
        case .expired: return "expired"
        case .retracted(let reason): return "retracted." + reason.rawValue
        }
    }
}

extension ApprovalClassification {
    /// Fail closed: without the secrets the gate must look for, every prompt
    /// is kept on the Mac as secret access.
    func failingClosed(secretsKnown: Bool) -> ApprovalClassification {
        secretsKnown ? self : .suppress(.forbidden(.secretAccess))
    }

    /// The tool the gate forwards this prompt as, or nil when it keeps it.
    var forwardedTool: ApprovalTool? {
        if case .forward(let tool) = self { return tool }
        return nil
    }

    /// Fail closed: a prompt leaves the Mac only as the gate's own copy of
    /// its preview; without one (never expected once the gate forwards) it
    /// stays local.
    func requiringCopy(_ copy: String?) -> ApprovalClassification {
        forwardedTool == nil || copy != nil ? self : .suppress(.unclassifiable(.previewNotStrictJSON))
    }
}

/// The prompts relayed over the seam, one lifecycle each. Confined to the
/// seam's queue (the host's).
final class ApprovalIntake {
    /// Which seam connection (which channel server) a prompt came from.
    typealias ConnectionKey = Int

    struct Entry: Equatable {
        let connection: ConnectionKey
        let request: ChannelRequestID
        var lifecycle: ApprovalLifecycle
        /// The tool the gate would forward this prompt as, or nil (kept on
        /// the Mac, or its session has ended). Slice S2: what a waiting buzz
        /// may count — never its preview.
        var forwardable: ApprovalTool? = nil
    }

    /// Slice S2: how far back a waiting buzz looks for the prompts that
    /// caused it. The hook's waiting marker and the relayed prompt come from
    /// the same dialog within a second; the buzz is folded after the finish
    /// alert's 2 s debounce.
    static let waitingContextSeconds = 30

    /// Prompts held at once, finished ones included until their TTL ends;
    /// a prompt beyond them stays local.
    static let maxPrompts = 256
    /// Of those, the most one server may hold, so one session cannot take
    /// every slot: twice the requests a server keeps open at once, leaving
    /// room for prompts answered at the terminal inside one TTL (NapCat does
    /// not see those answers).
    static let maxPromptsPerConnection = 2 * ApprovalChannel.maxOpenRequests

    private let armed: () -> Bool
    private let secrets: () -> [String]?
    private let newPromptID: () -> PromptID?
    private let now: () -> Int
    private let records: ApprovalRecordSink
    private let sendFrame: (ConnectionKey, String) -> Void
    private let closeConnection: (ConnectionKey) -> Void
    private let audit: (ApprovalAuditEvent) -> Void

    /// Every held prompt. A finished one stays until its TTL ends, so a
    /// late or duplicate decision is ignored by its own lifecycle (and
    /// logged with the reason) instead of as unknown.
    private(set) var prompts: [PromptID: Entry] = [:]

    /// `armed`: whether the feature is enabled on both devices (always false
    /// until the iPhone half lands). `secrets`: strings that must never leave the
    /// Mac (the alert topic) — nil while one exists that could not be read,
    /// and then every prompt stays local (fail closed). `now`: monotonic
    /// seconds.
    init(armed: @escaping () -> Bool, secrets: @escaping () -> [String]?, newPromptID: @escaping () -> PromptID?,
         now: @escaping () -> Int, records: ApprovalRecordSink, sendFrame: @escaping (ConnectionKey, String) -> Void,
         closeConnection: @escaping (ConnectionKey) -> Void, audit: @escaping (ApprovalAuditEvent) -> Void) {
        self.armed = armed
        self.secrets = secrets
        self.newPromptID = newPromptID
        self.now = now
        self.records = records
        self.sendFrame = sendFrame
        self.closeConnection = closeConnection
        self.audit = audit
    }

    /// One frame from a channel server. Only a prompt frame the strict reader
    /// accepts opens a lifecycle, and only after the gate classified it.
    func receive(_ line: [UInt8], from connection: ConnectionKey) {
        guard case .prompt(let request)? = ApprovalChannel.frame(line) else {
            audit(.frameRefused)
            closeConnection(connection)
            return
        }
        prune()
        guard !prompts.values.contains(where: { $0.connection == connection && $0.request == request.requestID }) else {
            return audit(.duplicateRequest)
        }
        guard prompts.values.filter({ $0.connection == connection }).count < Self.maxPromptsPerConnection else {
            return audit(.connectionPromptLimit)
        }
        guard prompts.count < Self.maxPrompts else { return audit(.capacityReached) }
        guard let id = newPromptID(), prompts[id] == nil else { return audit(.promptIDUnavailable) }
        // What may leave is the gate's copy of the preview, never the relayed
        // text (which carries the model's own description).
        let copy = ApprovalGate.forwardedPreview(toolName: request.toolName, inputPreview: request.inputPreview)
        // A secret that exists but could not be read is one the gate cannot
        // look for: the prompt is then secret access, whatever it is.
        let known = secrets()
        let classification = ApprovalGate.classify(toolName: request.toolName, inputPreview: request.inputPreview,
                                                   secrets: known ?? []).failingClosed(secretsKnown: known != nil)
                                                   .requiringCopy(copy)
        let opened = ApprovalLifecycle.open(id: id, classification: classification, armed: armed(), now: now())
        prompts[id] = Entry(connection: connection, request: request.requestID, lifecycle: opened.lifecycle,
                            forwardable: classification.forwardedTool)
        perform(opened.transition, for: id, classified: (classification, copy))
    }

    /// One event for one prompt (CloudKit's answers and the phone's decisions
    /// arrive this way in the later slices).
    func apply(_ event: ApprovalEvent, to id: PromptID) {
        guard var item = prompts[id] else { return audit(.unknownPrompt) }
        let transition = item.lifecycle.apply(event, now: now())
        prompts[id] = item
        perform(transition, for: id)
    }

    /// A decision record as the Mac read it (signature already checked).
    func decide(_ decision: ApprovalDecision) {
        apply(.remoteDecision(decision), to: decision.promptID)
    }

    /// The server went away: its session ended, so its open prompts are
    /// withdrawn (never answered), and none of its prompts counts for a
    /// waiting buzz any more.
    func connectionClosed(_ connection: ConnectionKey) {
        for (id, item) in prompts where item.connection == connection {
            prompts[id]?.forwardable = nil
            if !item.lifecycle.phase.isTerminal { apply(.sessionEnded, to: id) }
        }
    }

    /// Slice S2: the tools of the prompts the gate would forward that opened
    /// in the last `seconds`, from sessions still connected — what a waiting
    /// buzz may count. Kinds only, never a preview.
    func recentForwardableTools(within seconds: Int) -> [ApprovalTool] {
        let moment = now()
        return prompts.values.filter { moment - $0.lifecycle.createdAt <= seconds }.compactMap(\.forwardable)
    }

    /// The Mac toggle went off: every open prompt is withdrawn.
    func killSwitch() {
        for (id, item) in prompts where !item.lifecycle.phase.isTerminal {
            apply(.killSwitch, to: id)
        }
    }

    /// Whether a prompt from this server still waits on the phone: its link
    /// must stay up (closing it would withdraw the prompt).
    func holdsOpenPrompt(from connection: ConnectionKey) -> Bool {
        prompts.values.contains { $0.connection == connection && !$0.lifecycle.phase.isTerminal }
    }

    /// Lets the TTL run out, then forgets finished prompts past it.
    func tick() {
        for (id, item) in prompts where !item.lifecycle.phase.isTerminal {
            apply(.tick, to: id)
        }
        prune()
    }

    private func prune() {
        let moment = now()
        prompts = prompts.filter { !$0.value.lifecycle.phase.isTerminal || moment < $0.value.lifecycle.expiresAt }
    }

    /// Logs the transition, then performs its effects. `classified` is the
    /// gate's answer and its copy of the preview (nil unless it forwards),
    /// present only when the prompt just opened (the one moment a record can
    /// be saved).
    private func perform(_ transition: ApprovalTransition, for id: PromptID,
                         classified: (ApprovalClassification, String?)? = nil) {
        for entry in transition.audit { audit(.lifecycle(id, entry)) }
        guard let item = prompts[id] else { return }
        for effect in transition.effects {
            switch effect {
            case .saveRecord:
                guard case .forward(let tool)? = classified?.0, let preview = classified?.1 else { continue }
                records.save(id, tool: tool, inputPreview: preview, expiresAt: item.lifecycle.expiresAt)
            case .supersedeWaitingAlert:
                records.supersedeWaitingAlert(id)
            case .deliverVerdict(let verdict):
                sendFrame(item.connection, ApprovalChannel.verdictFrame(item.request, verdict))
            case .retractRecord:
                records.retract(id)
            }
        }
    }
}
