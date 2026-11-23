import Darwin
import Dispatch
import NapCatSeam
import NapCatWire
import os

/// F4 slice S1: `napcat-channel`, the channel server Claude Code spawns for a
/// session wired for remote approvals. It speaks MCP over its stdin and
/// stdout (one message per line), reaches NapCat over the authenticated seam
/// (only when a prompt opens; nothing is held while idle), and exits when
/// Claude Code closes its stdin. Everything it decides is in `ChannelRelay`;
/// this file only moves bytes. Registration is the owner's own, by user-run
/// rails (a later slice); nothing here reads or writes any Claude Code
/// configuration.
@main
enum ChannelServer {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "channel")

    static func main() {
        // A closed pipe must surface as a failed write, never kill the server.
        signal(SIGPIPE, SIG_IGN)
        let queue = DispatchQueue(label: "com.muratalkan.napcat.channel")
        let socketPath = SeamPaths.homeDirectory().map(SeamPaths.socketPath(home:))
        let relay = ChannelRelay(emit: StandardStreams.writeLine, connect: { onFrame, onClose in
            guard let socketPath, let connection = SeamClient.connect(socketPath: socketPath, queue: queue) else { return nil }
            connection.start(onLine: onFrame, onClose: onClose)
            return connection
        }, note: { logger.info("relay: \($0.rawValue, privacy: .public)") })
        let input = StandardInput(queue: queue) { relay.receive(stdinLine: $0) }
        input.start()
        dispatchMain()
    }
}

extension SeamConnection: ChannelLink {}

/// Reads stdin on the server's queue and hands over complete lines.
final class StandardInput: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let onLine: ([UInt8]) -> Void
    private var reader = ChannelLineReader(limit: ApprovalChannel.maxLineBytes)

    init(queue: DispatchQueue, onLine: @escaping ([UInt8]) -> Void) {
        self.onLine = onLine
        source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)
    }

    func start() {
        source.setEventHandler { [self] in drain() }
        source.resume()
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count == 0 { exit(0) }
        if count < 0 {
            if errno == EINTR || errno == EAGAIN { return }
            exit(1)
        }
        for piece in reader.feed(Array(buffer[0..<count])) {
            if case .line(let line) = piece { onLine(line) }
        }
    }
}

enum StandardStreams {
    /// Writes one line and its newline to stdout, unbuffered (Claude Code
    /// must see each answer at once). A failed write means Claude Code is
    /// gone, so the server exits.
    static func writeLine(_ line: String) {
        let bytes = Array(line.utf8) + [0x0A]
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR { continue }
                exit(0)
            }
            offset += written
        }
    }
}
