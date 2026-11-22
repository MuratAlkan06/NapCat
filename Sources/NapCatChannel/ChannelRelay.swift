import NapCatWire

/// F4 slice S1: everything `napcat-channel` does between Claude Code (its
/// stdio) and NapCat. Its I/O is injected, so tests drive it line by line;
/// `main.swift` wires the real descriptors. Design: design/remote-approvals.md.
///
/// It answers the MCP handshake and reads the relay's permission requests.
/// Nothing it receives ever becomes a verdict on its own: the local dialog
/// stays open and fully answerable whatever happens here.
///
/// Confined to the server's one serial queue (hence `@unchecked Sendable`).
final class ChannelRelay: @unchecked Sendable {
    private let emit: (String) -> Void

    /// Whether `initialize` was answered. A permission request before that is
    /// dropped.
    private var initialized = false
    /// Every request ID seen this session. Claude Code drops any verdict for
    /// an ID it issued twice, so a repeated ID is never relayed.
    private var seen: Set<ChannelRequestID> = []

    /// `emit` writes one MCP line to Claude Code (the newline is the
    /// writer's).
    init(emit: @escaping (String) -> Void) {
        self.emit = emit
    }

    /// One complete line from Claude Code.
    func receive(stdinLine line: [UInt8]) {
        switch ApprovalChannel.message(line) {
        case .initialize(let id, let version):
            initialized = true
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

    /// The skeleton keeps every prompt local: the seam to NapCat is the next
    /// part of this slice.
    private func relay(_ request: ChannelPermissionRequest) {
        guard initialized, seen.insert(request.requestID).inserted else { return }
    }
}
