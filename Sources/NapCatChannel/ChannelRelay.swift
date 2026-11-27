import NapCatWire

/// The server's link to NapCat (in production a `SeamConnection`, whose
/// peer check confirms the listener's user, not which program it is; in
/// tests a fake).
protocol ChannelLink: AnyObject {
    /// Sends one frame; false when the link failed (it is then closed).
    func send(_ line: String) -> Bool
    func close()
}

/// What the relay did, for the server's log: a closed vocabulary that never
/// carries prompt text or a request ID.
enum ChannelNote: String, CaseIterable, Sendable {
    /// A permission request before `initialize` was answered.
    case heldBeforeInitialize
    /// A permission request in a session whose client is not one of
    /// `ApprovalChannel.confirmedClients` (or did not name itself).
    case heldUnconfirmedClient
    /// Claude Code reused a request ID: its verdicts would be dropped.
    case heldRepeatedID
    /// `ApprovalChannel.maxOpenRequests` already wait for a verdict.
    case heldTooManyOpen
    /// The prompt frame would be longer than `ApprovalChannel.maxFrameBytes`.
    case heldTooLarge
    /// NapCat is not listening, or failed the peer check.
    case heldNoSeam
    /// The frame could not be sent.
    case heldSendFailed
    case relayed
    /// A verdict frame the strict reader accepted, dropped: the server
    /// passes no answer back to Claude Code while
    /// `ApprovalChannel.passesAnswersBack` is false (#221). Nothing is
    /// written, the link stays, and any open request stays open.
    case verdictWithheld
    /// A verdict for a request this server relayed and still holds open.
    case verdictRelayed
    /// A verdict for a request that is not open here: dropped.
    case verdictIgnored
    /// A frame the strict reader refused (or a prompt frame from NapCat): the
    /// link is closed.
    case frameRefused
    /// The link closed; every open request stays local.
    case seamClosed
}

/// F4 slice S1: everything `napcat-channel` does between Claude Code (its
/// stdio) and NapCat (the seam). Its I/O is injected, so tests drive it line
/// by line; `ChannelServer.swift` wires the real descriptors. Design:
/// design/remote-approvals.md.
///
/// It answers the MCP handshake and relays each permission request to NapCat
/// as a prompt frame (only when the session's client is a confirmed Claude
/// Code build, which the frame names, so NapCat checks it again: #150). It
/// passes no verdict back to Claude Code while the seam does not check which
/// program listens (`ApprovalChannel.passesAnswersBack`, #221); once it
/// does, it relays NapCat's verdict — but only for a request it relayed and
/// that is still open, once. Nothing it receives ever becomes a verdict on
/// its own, and a missing or failed seam only keeps prompts local: the
/// terminal dialog stays open and fully answerable whatever happens here.
///
/// Confined to the server's one serial queue (hence `@unchecked Sendable`).
final class ChannelRelay: @unchecked Sendable {
    /// Opens the link to NapCat, or nil. The relay hands over its own frame
    /// and close handlers.
    typealias Connector = (_ onFrame: @escaping ([UInt8]) -> Void, _ onClose: @escaping () -> Void) -> ChannelLink?

    private let emit: (String) -> Void
    private let connect: Connector
    private let note: (ChannelNote) -> Void

    /// Nil until `initialize` is answered (a permission request before that
    /// is held local); then whether every `initialize` so far named a
    /// confirmed client (`ApprovalChannel.confirms`). Once false it stays
    /// false: that session's prompts all stay local.
    private var clientConfirmed: Bool?
    /// The client the latest `initialize` named. Each prompt frame carries it
    /// (frame version 2), and only while `clientConfirmed` holds, so it is
    /// always a confirmed one.
    private var client: ChannelClient?
    /// Every request ID seen this session. Claude Code drops any verdict for
    /// an ID it issued twice, so a repeated ID is never relayed.
    private var seen: Set<ChannelRequestID> = []
    /// Relayed requests still waiting for a verdict.
    private var open: Set<ChannelRequestID> = []
    private var link: ChannelLink?
    /// Tells a closing link from a later one.
    private var linkGeneration = 0

    /// `emit` writes one MCP line to Claude Code (the newline is the
    /// writer's).
    init(emit: @escaping (String) -> Void, connect: @escaping Connector, note: @escaping (ChannelNote) -> Void = { _ in }) {
        self.emit = emit
        self.connect = connect
        self.note = note
    }

    /// One complete line from Claude Code.
    func receive(stdinLine line: [UInt8]) {
        switch ApprovalChannel.message(line) {
        case .initialize(let id, let version, let client):
            clientConfirmed = (clientConfirmed ?? true) && ApprovalChannel.confirms(client)
            self.client = client
            emit(ApprovalChannel.initializeResult(id: id, requestedVersion: version))
        case .ping(let id):
            emit(ApprovalChannel.pingResult(id: id))
        case .refused(let id, let code):
            emit(ApprovalChannel.errorResponse(id: id, code: code))
        case .permissionRequest(let request):
            relay(request)
        case .ignored, .malformed:
            break
        }
    }

    /// One complete frame from NapCat. Anything the strict reader refuses
    /// closes the link. Every verdict is withheld while the server passes no
    /// answer back (#221): nothing is written to Claude Code, the link stays
    /// and the request stays open, so its dialog is answered in the
    /// terminal. Past that guard, only a verdict for an open request does
    /// anything.
    func receive(seamLine line: [UInt8]) {
        guard case .verdict(let requestID, let verdict)? = ApprovalChannel.frame(line) else {
            note(.frameRefused)
            link?.close()
            return
        }
        guard ApprovalChannel.passesAnswersBack else {
            note(.verdictWithheld)
            return
        }
        guard open.remove(requestID) != nil else {
            note(.verdictIgnored)
            return
        }
        emit(ApprovalChannel.verdictNotification(requestID: requestID, verdict: verdict))
        note(.verdictRelayed)
    }

    private func relay(_ request: ChannelPermissionRequest) {
        guard let confirmed = clientConfirmed else { return note(.heldBeforeInitialize) }
        guard confirmed, let client else { return note(.heldUnconfirmedClient) }
        guard seen.insert(request.requestID).inserted else { return note(.heldRepeatedID) }
        guard open.count < ApprovalChannel.maxOpenRequests else { return note(.heldTooManyOpen) }
        guard let frame = ApprovalChannel.promptFrame(request, client: client) else { return note(.heldTooLarge) }
        guard let link = link ?? openLink() else { return note(.heldNoSeam) }
        guard link.send(frame) else { return note(.heldSendFailed) }
        open.insert(request.requestID)
        note(.relayed)
    }

    private func openLink() -> ChannelLink? {
        linkGeneration += 1
        let generation = linkGeneration
        link = connect({ [weak self] in self?.receive(seamLine: $0) },
                       { [weak self] in self?.linkClosed(generation) })
        return link
    }

    /// Every open request stays local; the next prompt reconnects.
    private func linkClosed(_ generation: Int) {
        guard generation == linkGeneration, link != nil else { return }
        link = nil
        open.removeAll()
        note(.seamClosed)
    }
}
