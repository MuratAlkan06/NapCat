// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCatSeam

/// One frame, one deadline: a peer that reads a little at a time can no
/// longer stretch a write out by letting each write call make a bit of
/// progress before its own timeout. Both ends in this process, over a
/// socket pair configured like a real seam connection.
struct ApprovalSeamDeadlineTests {
    /// The far end, reading `chunk` bytes every `interval` until `stopAfter`,
    /// then closing — so even a broken deadline ends the test in bounded
    /// time.
    final class Reader: @unchecked Sendable {
        let descriptor: Int32
        private let done = DispatchSemaphore(value: 0)
        private(set) var received = 0

        init(descriptor: Int32, chunk: Int, interval: Double, stopAfter: Double) {
            self.descriptor = descriptor
            Thread.detachNewThread { [self] in
                let stop = Date().addingTimeInterval(stopAfter)
                var buffer = [UInt8](repeating: 0, count: chunk)
                while Date() < stop {
                    let count = read(descriptor, &buffer, chunk)
                    if count > 0 { received += count }
                    if count == 0 { break }
                    if interval > 0 { Thread.sleep(forTimeInterval: interval) }
                }
                close(descriptor)
                done.signal()
            }
        }

        func wait() { done.wait() }
    }

    /// A connected pair: our end configured as the seam configures it
    /// (non-blocking, no SIGPIPE), small buffers on both, and the far end
    /// left blocking for the reader thread.
    static func pair() throws -> (ours: Int32, theirs: Int32) {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        try #require(SeamSocket.configureConnected(pair[0]))
        var small: Int32 = 4_096
        _ = setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &small, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(pair[1], SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout<Int32>.size))
        return (pair[0], pair[1])
    }

    static func connection(_ descriptor: Int32, queue: DispatchQueue, sendTimeout: Double) -> SeamConnection {
        SeamConnection(descriptor: descriptor, peer: SeamPeer(uid: geteuid(), tokenUID: geteuid(), pid: getpid()),
                       queue: queue, sendTimeout: sendTimeout)
    }

    /// A slow reader: the frame is given up at its deadline and the
    /// connection closed — not dragged out write call by write call.
    @Test func aSlowReaderCannotStretchAFramePastItsDeadline() throws {
        let (ours, theirs) = try Self.pair()
        let reader = Reader(descriptor: theirs, chunk: 1_024, interval: 0.15, stopAfter: 8)
        let queue = DispatchQueue(label: "test.deadline.slow")
        let connection = Self.connection(ours, queue: queue, sendTimeout: 0.6)
        let frame = String(repeating: "a", count: 256 * 1_024)
        let started = Date()
        let sent = queue.sync { connection.send(frame) }
        let elapsed = Date().timeIntervalSince(started)
        #expect(!sent, "the frame missed its deadline")
        #expect(elapsed < 3, "given up at the frame's deadline (0.6 s), not stretched out: \(elapsed) s")
        #expect(queue.sync { !connection.isOpen }, "and the connection is closed")
        reader.wait()
        #expect(reader.received < frame.utf8.count, "vacuity: the reader really was slow")
    }

    /// A reader that keeps up gets the whole frame inside the deadline.
    @Test func aReaderThatKeepsUpGetsTheWholeFrame() throws {
        let (ours, theirs) = try Self.pair()
        let reader = Reader(descriptor: theirs, chunk: 65_536, interval: 0, stopAfter: 5)
        let queue = DispatchQueue(label: "test.deadline.fast")
        // A deadline no loaded CI VM can miss: this row proves the path
        // that finishes, not the clock.
        let connection = Self.connection(ours, queue: queue, sendTimeout: 30)
        let frame = String(repeating: "b", count: 128 * 1_024)
        #expect(queue.sync { connection.send(frame) })
        queue.sync { connection.close() }
        reader.wait()
        #expect(reader.received == frame.utf8.count + 1, "every byte and the newline")
    }
}
