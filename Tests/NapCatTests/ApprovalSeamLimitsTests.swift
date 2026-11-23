// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat
@testable import NapCatSeam
@testable import NapCatWire

/// The seam's resource bounds, over real sockets in a scratch directory with
/// short injected timeouts: a cap on connected servers, a cap on the prompts
/// one server may hold, a clock on unfinished frames, and an idle clock that
/// disconnects a quiet server unless one of its prompts still waits on the
/// phone. Every bound only keeps prompts local; none answers anything.
struct ApprovalSeamLimitsTests {
    /// A monotonic clock the test moves by hand (the host's TTL clock).
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds = 1_000
        var now: Int { lock.withLock { seconds } }
        func advance(_ by: Int) { lock.withLock { seconds += by } }
    }

    /// A started host over a scratch socket, with the limits under test.
    final class Host: @unchecked Sendable {
        let scratch: ApprovalsScratch
        let audits = ApprovalsInbox<String>()
        let sink = ApprovalsRecordingSink()
        let clock = Clock()
        let host: ApprovalSeamHost

        init(limits: ApprovalSeamHost.Limits, armed: Bool = false) throws {
            scratch = try ApprovalsScratch()
            let audits = self.audits
            let clock = self.clock
            host = ApprovalSeamHost(socketPath: scratch.socketPath, armed: { armed }, secrets: { [] }, records: sink,
                                    audit: { audits.put($0.code) }, now: { clock.now }, limits: limits)
            precondition(host.start(), "the scratch host must listen")
        }

        deinit { host.stop() }

        /// A raw server-side connection, its lines and its close.
        final class Client: @unchecked Sendable {
            let queue = DispatchQueue(label: "test.limits.client")
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
            func close() { queue.sync { connection?.close() } }
        }

        func client() -> Client { Client(scratch.socketPath) }

        /// A bare socket to the host (no peer check of its own), for writing
        /// frames in pieces.
        final class RawClient {
            let descriptor: Int32

            init?(_ socketPath: String) {
                guard let address = SeamSocket.address(socketPath), let descriptor = SeamSocket.makeSocket() else { return nil }
                guard SeamSocket.connect(descriptor, to: address) else {
                    Darwin.close(descriptor)
                    return nil
                }
                self.descriptor = descriptor
            }

            deinit { Darwin.close(descriptor) }

            func write(_ text: String) -> Bool {
                let bytes = Array(text.utf8)
                return bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) } == bytes.count
            }

            /// Whether the host closed the link within `seconds` (end of
            /// stream on our side).
            func closed(within seconds: Double) -> Bool {
                let deadline = Date().addingTimeInterval(seconds)
                while deadline.timeIntervalSinceNow > 0 {
                    var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&poller, 1, Int32(max(1, deadline.timeIntervalSinceNow * 1000)))
                    guard ready > 0 else { continue }
                    var byte: UInt8 = 0
                    let count = read(descriptor, &byte, 1)
                    if count == 0 || (count < 0 && errno != EINTR && errno != EAGAIN) { return true }
                }
                return false
            }
        }

        func raw() -> RawClient? { RawClient(scratch.socketPath) }

        static func prompt(_ request: String, preview: String = #"{"command":"git status"}"#) -> String {
            ApprovalChannel.promptFrame(ChannelPermissionRequest(requestID: ChannelRequestID(request)!, toolName: "Bash",
                                                                 inputPreview: preview))!
        }
    }

    static let slow = ApprovalSeamHost.Limits(maxConnections: 64, idleSeconds: 600, stallSeconds: 600)

    @Test func theDefaultsAreTheDesignedBounds() {
        let standard = ApprovalSeamHost.Limits.standard
        #expect(standard.maxConnections == 64)
        #expect(standard.idleSeconds == 60)
        #expect(standard.stallSeconds == SeamSocket.stallTimeoutSeconds && SeamSocket.stallTimeoutSeconds == 5)
        #expect(ApprovalIntake.maxPromptsPerConnection == 2 * ApprovalChannel.maxOpenRequests)
        #expect(ApprovalIntake.maxPromptsPerConnection < ApprovalIntake.maxPrompts, "one server never takes every slot")
    }

    // MARK: - Connected servers

    /// One server past the cap is closed unread (its prompts stay local), and
    /// a slot freed by a disconnect is usable again.
    @Test func aServerPastTheCapIsClosedUnread() throws {
        var limits = Self.slow
        limits.maxConnections = 2
        let world = try Host(limits: limits)
        let first = world.client()
        let second = world.client()
        #expect(first.send(Host.prompt("abcde")) && second.send(Host.prompt("bcdef")))
        #expect(world.audits.next(where: { $0.hasSuffix("suppressed.notArmed") }) != nil)
        #expect(world.audits.next(where: { $0.hasSuffix("suppressed.notArmed") }) != nil)

        let third = world.client()
        #expect(world.audits.next(where: { $0 == "seam.connectionLimit" }) != nil, "the third server is refused")
        if third.connection != nil {
            _ = third.send(Host.prompt("cdefg"))
            #expect(third.closes.next() != nil, "and sees its link end")
        }
        #expect(world.audits.next(within: 0.3, where: { $0.hasSuffix("suppressed.notArmed") }) == nil,
                "nothing it sent was read")

        first.close()
        // The host frees the slot once it has seen the close; a loaded CI VM
        // can take a while, so keep trying until a new server is heard.
        let deadline = Date().addingTimeInterval(ApprovalsInbox<String>.arrivalSeconds)
        var served = false
        for request in IntakeHarness.requestIDs(400).dropFirst(10) where !served && deadline.timeIntervalSinceNow > 0 {
            let next = world.client()
            if next.send(Host.prompt(request)) {
                served = world.audits.next(within: 0.5, where: { $0.hasSuffix("suppressed.notArmed") }) != nil
            }
        }
        #expect(served, "a freed slot serves again")
    }

    // MARK: - Prompts per server

    /// One server may hold at most its share; another server is unaffected.
    @Test func oneServerCannotHoldEverySlot() {
        let harness = IntakeHarness()
        let cap = ApprovalIntake.maxPromptsPerConnection
        let ids = IntakeHarness.requestIDs(cap + 2)
        for request in ids.prefix(cap + 1) { harness.receive(request, from: 1) }
        #expect(harness.intake.prompts.count == cap)
        #expect(harness.codes.filter { $0 == "seam.connectionPromptLimit" }.count == 1)
        harness.receive(ids[cap + 1], from: 2)
        #expect(harness.intake.prompts.count == cap + 1, "another server still gets its prompts heard")
        #expect(harness.frames.isEmpty, "a bound never answers anything")
    }

    // MARK: - Unfinished frames

    /// Part of a frame left unfinished closes the connection on the stall
    /// clock; a finished frame stops the clock.
    @Test func anUnfinishedFrameClosesTheConnection() throws {
        // Long enough that a loaded CI VM reads the steady frame's second
        // piece in time; the stalled one still ends within a couple of
        // seconds.
        var limits = Self.slow
        limits.stallSeconds = 1
        let world = try Host(limits: limits)
        let frame = Host.prompt("abcde")
        let steady = try #require(world.raw())
        #expect(steady.write(String(frame.prefix(20))))
        #expect(steady.write(String(frame.dropFirst(20)) + "\n"))
        #expect(world.audits.next(where: { $0.hasSuffix("suppressed.notArmed") }) != nil, "a frame finished in pieces is read")

        let stalled = try #require(world.raw())
        #expect(stalled.write(String(Host.prompt("bcdef").prefix(30))))
        #expect(stalled.closed(within: ApprovalsInbox<String>.arrivalSeconds), "the stalled server is disconnected")
        #expect(!steady.closed(within: 1.5), "the steady one is not")
    }

    /// The same clock on a bare connection, both ends in this process.
    @Test func theStallClockIsTheConnectionsOwn() throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[1]) }
        let queue = DispatchQueue(label: "test.limits.pair")
        let closes = ApprovalsInbox<Void>()
        let lines = ApprovalsInbox<String>()
        let connection = SeamConnection(descriptor: pair[0], peer: SeamPeer(uid: geteuid(), tokenUID: geteuid(), pid: getpid()),
                                        queue: queue, stallTimeout: 1)
        queue.sync {
            connection.start(onLine: { lines.put(String(decoding: $0, as: UTF8.self)) }, onClose: { closes.put(()) })
        }
        func write(_ text: String) {
            let bytes = Array(text.utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(pair[1], $0.baseAddress, $0.count) }
        }
        write("hel")
        write("lo\n")
        #expect(lines.next() == "hello")
        #expect(closes.next(within: 1.5) == nil, "nothing is buffered, so nothing stalls")
        write("half a fra")
        #expect(closes.next() != nil, "an unfinished frame stalls the connection")
        #expect(queue.sync { !connection.isOpen })
    }

    // MARK: - Idle servers

    /// A server that connects and says nothing is disconnected on the idle
    /// clock; so is one whose prompts no longer wait on anything.
    @Test func aQuietServerIsDisconnected() throws {
        var limits = Self.slow
        limits.idleSeconds = 0.3
        let world = try Host(limits: limits)
        let silent = world.client()
        #expect(silent.connection != nil)
        #expect(silent.closes.next() != nil, "a server that sends nothing is let go")

        let done = world.client()
        #expect(done.send(Host.prompt("abcde")))
        #expect(world.audits.next(where: { $0.hasSuffix("suppressed.notArmed") }) != nil)
        #expect(done.closes.next() != nil, "its prompt stayed local and waits on nothing")
    }

    /// While a prompt from a server waits on the phone, its link is kept
    /// (closing it would withdraw the prompt) — until the TTL withdraws it.
    @Test func aServerWhosePromptWaitsOnThePhoneIsKeptUntilTheTTL() throws {
        var limits = Self.slow
        limits.idleSeconds = 0.3
        let world = try Host(limits: limits, armed: true)
        let waiting = world.client()
        #expect(waiting.send(Host.prompt("abcde")))
        let id = try #require(world.sink.saved.next())
        world.host.withIntake { $0.apply(.saveAccepted, to: id) }
        #expect(waiting.closes.next(within: 1.0) == nil, "kept across several idle rounds while it waits")

        world.clock.advance(ApprovalWire.promptTimeToLiveSeconds)
        #expect(world.sink.retracted.next() == id, "the idle round lets the TTL withdraw it")
        #expect(waiting.closes.next() != nil, "then the quiet link is let go")
        #expect(world.audits.all.contains("prompt=\(id.hex) expired"))
    }
}
