// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat
@testable import NapCatSeam
@testable import NapCatWire

/// The seam host's lifetime: nothing it hands out holds it, so a host (or a
/// listener) released without `stop()` leaves nothing behind — no socket file
/// for a server to find, no open link, no timer — instead of crashing on a
/// dangling reference or leaving a socket with nobody behind it.
struct ApprovalSeamHostLifetimeTests {
    /// A server-side link to the scratch socket, on its own queue.
    final class Link: @unchecked Sendable {
        let queue = DispatchQueue(label: "test.lifetime.link")
        let closes = ApprovalsInbox<Void>()
        let connection: SeamConnection?

        init(_ socketPath: String) {
            let queue = self.queue
            let closes = self.closes
            connection = queue.sync {
                let connection = SeamClient.connect(socketPath: socketPath, queue: queue)
                connection?.start(onLine: { _ in }, onClose: { closes.put(()) })
                return connection
            }
        }

        func send(_ line: String) -> Bool { queue.sync { connection?.send(line) ?? false } }
    }

    @Test func aHostReleasedWithoutStopLeavesNothingBehind() throws {
        let scratch = try ApprovalsScratch()
        let audits = ApprovalsInbox<String>()
        var host: ApprovalSeamHost? = ApprovalSeamHost(
            socketPath: scratch.socketPath, armed: { false }, secrets: { [] }, records: FailDarkApprovalRecords(),
            audit: { audits.put($0.code) })
        weak var watched = host
        #expect(host?.start() == true)
        let link = Link(scratch.socketPath)
        #expect(link.send(ApprovalChannel.promptFrame(ChannelPermissionRequest(
            requestID: ChannelRequestID("abcde")!, toolName: "Bash", inputPreview: #"{"command":"ls"}"#),
            client: ApprovalChannel.confirmedClients[0])!))
        #expect(audits.next(where: { $0.hasSuffix("suppressed.notArmed") }) != nil, "the link is live")
        // A barrier: the frame's handler has finished on the host's queue, so
        // nothing there holds the host for a moment longer.
        _ = host?.withIntake { _ in }

        host = nil
        #expect(watched == nil, "nothing the host handed out keeps it alive")
        #expect(!scratch.exists(scratch.socketPath), "its socket is removed with it")
        #expect(link.closes.next() != nil, "and its links close")
        #expect(Link(scratch.socketPath).connection == nil, "a new server finds nothing to connect to")
    }

    @Test func aListenerReleasedWhileListeningRemovesItsSocket() throws {
        let scratch = try ApprovalsScratch()
        let queue = DispatchQueue(label: "test.lifetime.listener")
        var listener: SeamListener? = SeamListener(socketPath: scratch.socketPath, queue: queue)
        #expect(queue.sync { listener?.start(onConnection: { _ in }) } == true)
        #expect(scratch.exists(scratch.socketPath))
        listener = nil
        #expect(!scratch.exists(scratch.socketPath))
        #expect(Link(scratch.socketPath).connection == nil)
    }

    /// A stopped host keeps nothing running either, and may be released.
    @Test func aStoppedHostCanBeReleased() throws {
        let scratch = try ApprovalsScratch()
        var host: ApprovalSeamHost? = ApprovalSeamHost(
            socketPath: scratch.socketPath, armed: { false }, secrets: { [] }, records: FailDarkApprovalRecords())
        weak var watched = host
        #expect(host?.start() == true)
        let link = Link(scratch.socketPath)
        #expect(link.connection != nil)
        host?.stop()
        #expect(link.closes.next() != nil)
        host = nil
        #expect(watched == nil)
    }
}
