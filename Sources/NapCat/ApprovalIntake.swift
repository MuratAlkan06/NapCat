import NapCatWire

// F4 slice S1: where a relayed permission prompt meets the S0 core on the
// Mac. Design: design/remote-approvals.md.
//
// Every prompt frame from a channel server is read by the strict frame reader
// (ApprovalChannel.frame), checked again for the server's version and its
// confirmed client (#150), and classified by the category gate
// (ApprovalGate.classify, with the alert topic, under the listed commands
// alone: `ApprovalForwardingSet.listedOnly`) BEFORE its
// lifecycle opens; the lifecycle (ApprovalLifecycle) alone decides what
// happens next, and this type only performs the effects it returns. The ONE
// verdict frame it ever writes is the lifecycle's `.deliverVerdict` — the
// acceptance of a valid, signed remote decision inside the TTL (lint-locked).
// Pure over injected I/O: no socket, no CloudKit, no clock of its own.

/// Where NapCat writes a forwarded prompt's record: CloudKit, through the
/// record path's store (`CloudKitApprovalRecords`, slice S3, built only by
/// tests in that slice). Nothing reaches it while the feature is unarmed,
/// which every build is: arming is the Mac's decision, and it waits on the
/// Mac's live record path and the seam's check of which program listens
/// (still owed; #221 holds every answer until then), among the items owed
/// before arming (the S2 host is built never armed, with a sink that writes
/// nothing).
protocol ApprovalRecordSink: AnyObject {
    /// Write the prompt record: the tool the gate forwarded and the gate's
    /// own copy of the preview (`ApprovalGate.forwardedPreview`: no
    /// description, never the relayed text), nothing else from the session.
    func save(_ id: PromptID, tool: ApprovalTool, inputPreview: String, expiresAt: Int)
    /// Delete the prompt record (and its decision, if any).
    func retract(_ id: PromptID)
    /// The forward was accepted. That alone drops no plain waiting alert:
    /// the alert lane drops one only for a change holding one waiting write
    /// whose read finds exactly one new prompt, with evidence that the
    /// phone's prompt push (fixed text, no action) covers it: its record
    /// accepted, the prompt still open on the phone, and the phone's prompt
    /// subscription found (`ApprovalIntake.Entry.hasPushEvidence`).
    func supersedeWaitingAlert(_ id: PromptID)
}

/// One audit-log event: a closed vocabulary. It carries the random prompt ID
/// and never any prompt text, request ID, session ID or topic.
enum ApprovalAuditEvent: Equatable, Sendable {
    case lifecycle(PromptID, ApprovalAudit)
    /// A frame the strict reader refused, or a verdict frame from a server:
    /// that connection is closed.
    case frameRefused
    /// A prompt frame from a server of another version than NapCat's own
    /// (`ApprovalChannel.serverVersion`): that connection is closed, before
    /// the gate (#150).
    case serverVersionRefused
    /// A prompt frame naming a client that is not a confirmed Claude Code
    /// build (`ApprovalChannel.confirms`): that connection is closed, before
    /// the gate (#150).
    case clientRefused
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
        case .serverVersionRefused: return "seam.serverVersionRefused"
        case .clientRefused: return "seam.clientRefused"
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

/// Where one waiting alert's read of the intake left off
/// (`ApprovalIntake.waitingPromptRead`): the intake's own clock at that
/// read and how many prompts of that second the read saw, never a prompt's
/// ID. Its storage is private to this file: elsewhere a mark comes only
/// from a read, and the caller keeps it and hands it back. A read also
/// accepts no mark at all (nil), and then every prompt in its window is new
/// to it.
struct PromptRelayMark: Equatable, Sendable {
    fileprivate let second: Int
    fileprivate let seen: Int
}

/// What one waiting alert reads of the intake: tool kinds and counts only,
/// never a prompt's ID, preview, request or session.
struct WaitingPromptRead: Equatable, Sendable {
    /// The tools of the prompts the gate would forward that opened in the
    /// window the read was given, from sessions still connected: what the
    /// waiting push counts.
    let recent: [ApprovalTool]
    /// Of `recent`, over the same window, the tools of those with evidence
    /// that the phone's own prompt push covers them
    /// (`ApprovalIntake.Entry.hasPushEvidence`).
    let recentWithEvidence: [ApprovalTool]
    /// The prompts relayed after the read that left the mark this read was
    /// given, and in the last `ApprovalIntake.newPromptSeconds`, whatever the
    /// gate made of them.
    let newPrompts: Int
    /// Of `newPrompts`, the ones known to have that evidence. One of the
    /// mark's own second that the earlier read did not see is new here but
    /// never counted as having it: the mark cannot say which of that second's
    /// prompts it is.
    let newPromptsWithEvidence: Int
    /// Where this read left off: the next read is handed it.
    let mark: PromptRelayMark
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
        /// Whether the Mac found the phone's prompt subscription when it
        /// saved this prompt's record: the record path's finding, set through
        /// `noteSubscriptionFound`. Nothing in the app calls that yet (the
        /// record path is not live), so in the app it stays false.
        var subscriptionFound = false

        /// The evidence that the phone's own prompt push covers this prompt:
        /// CloudKit accepted its record (the lifecycle is `.forwarded`) and
        /// the Mac found the phone's prompt subscription. A prompt the gate
        /// keeps, one not armed, a save that failed or is still in flight,
        /// and one answered, expired or withdrawn have none.
        var hasPushEvidence: Bool { subscriptionFound && lifecycle.phase == .forwarded }
    }

    /// Slice S2: how far back a waiting buzz looks for the prompts that
    /// caused it. The hook's waiting marker and the relayed prompt come from
    /// the same dialog within a second; the buzz is folded after the finish
    /// alert's 2 s debounce.
    static let waitingContextSeconds = 30
    /// How far back a waiting alert looks for the prompts relayed since its
    /// previous read: the ones its waiting write may stand for. A starting
    /// value, a third of the counts' window.
    static let newPromptSeconds = 10

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

    /// `armed`: whether forwarding is armed, which the Mac alone decides (its
    /// toggle, a paired iPhone and a live record path; the iPhone's own
    /// switch tells the Mac nothing). The app builds its host with
    /// `armed: { false }`: no build arms it yet. `secrets`: strings that
    /// must never leave the Mac (the alert topic) — nil while an alert-topic
    /// item exists that holds no valid value NapCat could read, or the launch
    /// could not finish moving the topic into the keychain, and then every
    /// prompt stays local (fail closed). `now`: monotonic seconds.
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
    /// accepts, from a server of NapCat's own version relaying for a client
    /// NapCat confirms (checked again here, #150), opens a lifecycle, and
    /// only after the gate classified it.
    func receive(_ line: [UInt8], from connection: ConnectionKey) {
        guard case .prompt(let request, let server, let client)? = ApprovalChannel.frame(line) else {
            audit(.frameRefused)
            closeConnection(connection)
            return
        }
        // Before the gate, and before anything is held: another server
        // version, or a client NapCat has not confirmed, closes the connection
        // as a refused frame does.
        guard server == ApprovalChannel.serverVersion else {
            audit(.serverVersionRefused)
            closeConnection(connection)
            return
        }
        guard ApprovalChannel.confirms(client) else {
            audit(.clientRefused)
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
                                                   topic: Self.floorTopic(known), policy: .listedOnly).failingClosed(secretsKnown: known != nil)
                                                   .requiringCopy(copy)
        let opened = ApprovalLifecycle.open(id: id, classification: classification, armed: armed(), now: now())
        prompts[id] = Entry(connection: connection, request: request.requestID, lifecycle: opened.lifecycle,
                            forwardable: classification.forwardedTool)
        perform(opened.transition, for: id, classified: (classification, copy))
    }

    /// One event for one prompt (CloudKit's answers arrive this way in a
    /// later slice; the phone's decisions only through `decide`).
    func apply(_ event: ApprovalEvent, to id: PromptID) {
        guard var item = prompts[id] else { return audit(.unknownPrompt) }
        let transition = item.lifecycle.apply(event, now: now())
        prompts[id] = item
        perform(transition, for: id)
    }

    /// S-PAIR-C2 (#181): a decision record as the record store read it — its
    /// fields as decoded, and the Mac's own copy of its prompt. The verifier
    /// judges it against the paired key `keys` holds at this very moment
    /// (read there, never kept), and only its result reaches `decide`: the
    /// one road from a reading to a lifecycle (lint-locked). A refusal is
    /// audited by its code (`refusals`) and counts for nothing.
    func receiveDecision(_ evidence: DecisionEvidence, copy: ForwardedCopy?, keys: PairedKeyStore,
                         refusals: (DecisionVerifierAudit) -> Void = DecisionVerifierLog.record) {
        decide(DecisionVerifier.verify(evidence, copy: copy, keys: keys, audit: refusals))
    }

    /// The verifier's result, and nothing else: only a verified decision
    /// reaches its prompt's lifecycle.
    func decide(_ verification: DecisionVerification) {
        guard case .verified(let decision) = verification else { return }
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
    /// buzz may count. Kinds only, never a preview. The `recent` of a read
    /// handed no mark, so it counts exactly as `waitingPromptRead` does.
    func recentForwardableTools(within seconds: Int) -> [ApprovalTool] {
        waitingPromptRead(after: nil, within: seconds).recent
    }

    /// One waiting alert's read (`WaitingPromptRead`), at one reading of the
    /// clock. Of the prompts that opened in the last `seconds`: the tools of
    /// those the gate would forward, from sessions still connected, and of
    /// those the tools of the ones with evidence (`Entry.hasPushEvidence`).
    /// Of the prompts relayed after the read that left `mark` (nil: any) and
    /// in the last `newPromptSeconds`, whatever the gate made of them and
    /// whether or not their session is still connected: how many, and how
    /// many of them are known to have evidence. The mark holds that read's
    /// second and how many prompts of it the read saw, so the rest of that
    /// second, relayed after it, is new to this read; which of that second's
    /// prompts they are the mark cannot say, so they count as new and never
    /// as having evidence (they can keep an alert, never fold one). So, each
    /// read handed the mark the one before it returned, a prompt is new to
    /// one read at most. The read changes nothing here: the caller keeps the
    /// mark it returns.
    func waitingPromptRead(after mark: PromptRelayMark?, within seconds: Int) -> WaitingPromptRead {
        let moment = now()
        let after: Int = mark?.second ?? Int.min
        let recent = prompts.values.filter { moment - $0.lifecycle.createdAt <= seconds && $0.forwardable != nil }
        let window = prompts.values.filter { moment - $0.lifecycle.createdAt <= Self.newPromptSeconds }
        let relayed = window.filter { $0.lifecycle.createdAt > after }
        // None once the mark's second is past the window.
        let rest: Int = max(0, window.filter { $0.lifecycle.createdAt == after }.count - (mark?.seen ?? 0))
        return WaitingPromptRead(recent: recent.compactMap(\.forwardable),
                                 recentWithEvidence: recent.filter(\.hasPushEvidence).compactMap(\.forwardable),
                                 newPrompts: relayed.count + rest, newPromptsWithEvidence: relayed.filter(\.hasPushEvidence).count,
                                 mark: PromptRelayMark(second: moment, seen: window.filter { $0.lifecycle.createdAt == moment }.count))
    }

    /// The record path's finding for one held prompt: the Mac found the
    /// phone's prompt subscription when it saved the prompt's record. With
    /// CloudKit's acceptance it is that prompt's evidence for a waiting alert
    /// (`Entry.hasPushEvidence`); it changes nothing else. Nothing in the
    /// app calls it yet: the record path that will is not live.
    func noteSubscriptionFound(_ id: PromptID) {
        prompts[id]?.subscriptionFound = true
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

    /// The alert topic as the gate's floor reads it, from the secrets the
    /// lid guard gave (`secrets`): nil (an item that holds no valid value
    /// NapCat could read, or a launch that could not finish moving the topic
    /// into the keychain) is `unreadable`, none (no item) is `absent`, one
    /// is its value (the lid guard gives exactly the value the alerts are
    /// sent to; an empty one the floor reads as unreadable), and more than
    /// one, which no single check covers, is `unreadable`.
    static func floorTopic(_ secrets: [String]?) -> ApprovalFloorTopic {
        guard let secrets else { return .unreadable }
        guard let topic = secrets.first else { return .absent }
        return secrets.count == 1 ? .value(Array(topic.utf8)) : .unreadable
    }
}
