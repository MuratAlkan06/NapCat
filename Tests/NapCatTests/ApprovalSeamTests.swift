// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCatSeam
@testable import NapCatWire

/// Collects values delivered on another queue, with a bounded wait.
final class SeamInbox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let arrived = DispatchSemaphore(value: 0)
    private var values: [Value] = []

    func put(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
        arrived.signal()
    }

    /// The next value, or nil after `seconds`.
    func next(within seconds: Double = 5) -> Value? {
        guard arrived.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return values.removeFirst()
    }

    var all: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// A private scratch directory with a seam socket path short enough for
/// `sun_path`. Never the real Application Support directory.
final class SeamFixture {
    let root: URL
    let socketPath: String

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        root = base.appendingPathComponent("ncs-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        socketPath = root.path + "/approvals/seam.sock"
        precondition(socketPath.utf8.count < 104, "the fixture path must fit sun_path: \(socketPath)")
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var directoryPath: String { root.path + "/approvals" }

    func mode(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? nil
    }
}

/// F4 slice S1: the authenticated Unix-socket seam (`NapCatSeam`). Every test
/// runs a real listener and a real client in a private scratch directory;
/// foreign peers are presented through the injectable credential reader,
/// since a test cannot run as another user.
struct ApprovalSeamTests {
    static let ownUID = geteuid()
    static let foreign = SeamPeer(uid: geteuid() &+ 1, tokenUID: geteuid() &+ 1, pid: 1)
    /// How long a test waits to SEE a connection end that reaches it from the
    /// kernel, as end of stream or EPIPE on its socket's read source (both
    /// seam suites use it). On a loaded CI VM that delivery can lag for
    /// seconds: seam tests that take well under a second locally ran 20–22 s
    /// there (#129). A wait returns the moment the close is seen, so a passing
    /// run never pays this deadline.
    static let closeObservationSeconds: Double = 30

    /// A started listener on its own queue, delivering connections and
    /// refusals to inboxes.
    final class Server: @unchecked Sendable {
        let queue = DispatchQueue(label: "test.seam.listener")
        let listener: SeamListener
        let connections = SeamInbox<SeamConnection>()
        let refusals = SeamInbox<Void>()
        let lines = SeamInbox<String>()
        let closes = SeamInbox<Void>()
        /// Keeps every accepted connection alive for the test's duration
        /// (dropping the last reference closes it).
        private let held = SeamInbox<SeamConnection>()

        init(_ fixture: SeamFixture, peerReader: @escaping (Int32) -> SeamPeer? = SeamSocket.peer(of:)) {
            listener = SeamListener(socketPath: fixture.socketPath, queue: queue, peerReader: peerReader)
        }

        func start() -> Bool {
            queue.sync {
                listener.start(onConnection: { [self] connection in
                    connection.start(onLine: { [self] in lines.put(String(decoding: $0, as: UTF8.self)) },
                                     onClose: { [self] in closes.put(()) })
                    held.put(connection)
                    connections.put(connection)
                }, onRefused: { [self] in refusals.put(()) })
            }
        }

        func stop() { queue.sync { listener.stop() } }
    }

    /// A client connection on its own queue.
    final class Client: @unchecked Sendable {
        let queue = DispatchQueue(label: "test.seam.client")
        let lines = SeamInbox<String>()
        let closes = SeamInbox<Void>()
        let connection: SeamConnection?

        init(_ fixture: SeamFixture, peerReader: @escaping (Int32) -> SeamPeer? = SeamSocket.peer(of:)) {
            let queue = self.queue
            let lines = self.lines
            let closes = self.closes
            connection = queue.sync {
                let connection = SeamClient.connect(socketPath: fixture.socketPath, queue: queue, peerReader: peerReader)
                connection?.start(onLine: { lines.put(String(decoding: $0, as: UTF8.self)) }, onClose: { closes.put(()) })
                return connection
            }
        }

        func send(_ line: String) -> Bool { queue.sync { connection?.send(line) ?? false } }
        func sendRaw(_ bytes: [UInt8]) -> Bool {
            queue.sync { connection?.send(String(decoding: bytes, as: UTF8.self)) ?? false }
        }
    }

    // MARK: - The peer check

    @Test func thePolicyNeedsTheCredentialsAndTheTokenToBeThisUser() {
        let me = Self.ownUID
        #expect(SeamPeerPolicy.accepts(SeamPeer(uid: me, tokenUID: me, pid: 42), ownUID: me))
        #expect(!SeamPeerPolicy.accepts(nil, ownUID: me), "unreadable credentials are a refusal")
        #expect(!SeamPeerPolicy.accepts(SeamPeer(uid: me &+ 1, tokenUID: me, pid: 42), ownUID: me))
        #expect(!SeamPeerPolicy.accepts(SeamPeer(uid: me, tokenUID: me &+ 1, pid: 42), ownUID: me))
        #expect(!SeamPeerPolicy.accepts(SeamPeer(uid: 0, tokenUID: 0, pid: 1), ownUID: me), "root is another user")
    }

    /// The real reader sees this very process on the other end of a pair.
    @Test func theRealReaderSeesThisTestRunner() throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        let peer = try #require(SeamSocket.peer(of: pair[0]))
        #expect(peer == SeamPeer(uid: geteuid(), tokenUID: geteuid(), pid: getpid()))
        #expect(SeamSocket.peer(of: -1) == nil, "a bad descriptor has no peer")
    }

    // MARK: - Connecting

    @Test func aSameUserPeerConnectsAndLinesFlowBothWays() throws {
        let fixture = try SeamFixture()
        let server = Server(fixture)
        #expect(server.start())
        defer { server.stop() }
        let client = Client(fixture)
        let clientConnection = try #require(client.connection, "the same user's listener must be accepted")
        #expect(clientConnection.peer.uid == Self.ownUID)
        let serverConnection = try #require(server.connections.next())
        #expect(serverConnection.peer == SeamPeer(uid: geteuid(), tokenUID: geteuid(), pid: getpid()))
        #expect(client.send("{\"hello\":1}"))
        #expect(server.lines.next() == "{\"hello\":1}")
        #expect(server.queue.sync { serverConnection.send("{\"back\":2}") })
        #expect(client.lines.next() == "{\"back\":2}")
        #expect(server.refusals.all.isEmpty)
    }

    /// The listener closes a foreign peer before reading a byte, and never
    /// hands it over.
    ///
    /// Either of two orderings is correct (#129). Usually the client's own
    /// check of the listener (this user) passes first, and the client then
    /// sees the connection end. But the refusal can land between the client's
    /// connect and its read of the listener's audit token, which then fails
    /// (ENOTCONN: the link is already gone). The client then refuses the
    /// unreadable listener in turn and never holds a connection.
    @Test func theListenerRefusesAForeignPeer() throws {
        let fixture = try SeamFixture()
        let server = Server(fixture, peerReader: { _ in Self.foreign })
        #expect(server.start())
        defer { server.stop() }
        let client = Client(fixture)
        #expect(server.refusals.next() != nil, "the listener must refuse the foreign peer")
        if client.connection != nil {
            _ = client.send("{\"hello\":1}")
            #expect(client.closes.next(within: Self.closeObservationSeconds) != nil,
                    "the refused client sees the connection end")
        }
        #expect(server.connections.next(within: 0.3) == nil, "a refused peer is never handed over")
        #expect(server.lines.all.isEmpty)
    }

    @Test func theListenerRefusesUnreadableCredentials() throws {
        let fixture = try SeamFixture()
        let server = Server(fixture, peerReader: { _ in nil })
        #expect(server.start())
        defer { server.stop() }
        _ = Client(fixture)
        #expect(server.refusals.next() != nil)
        #expect(server.connections.next(within: 0.3) == nil)
    }

    /// The server's end checks the listener the same way.
    @Test func theClientRefusesAForeignOrUnreadableListener() throws {
        let fixture = try SeamFixture()
        let server = Server(fixture)
        #expect(server.start())
        defer { server.stop() }
        #expect(Client(fixture, peerReader: { _ in Self.foreign }).connection == nil)
        #expect(Client(fixture, peerReader: { _ in nil }).connection == nil)
        #expect(Client(fixture).connection != nil, "baseline: the real listener passes")
    }

    // MARK: - The socket's home

    @Test func theListenerMakesThePrivateDirectoryAndSocket() throws {
        let fixture = try SeamFixture()
        let server = Server(fixture)
        #expect(server.start())
        defer { server.stop() }
        #expect(fixture.mode(fixture.directoryPath) == 0o700)
        #expect(fixture.mode(fixture.socketPath) == 0o600)
    }

    @Test func theListenerTightensALooseDirectoryOfItsOwn() throws {
        let fixture = try SeamFixture()
        try FileManager.default.createDirectory(atPath: fixture.directoryPath, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        let server = Server(fixture)
        #expect(server.start())
        defer { server.stop() }
        #expect(fixture.mode(fixture.directoryPath) == 0o700)
    }

    /// The server never connects to a socket others could reach or plant.
    @Test func theClientRefusesASocketOutsideAPrivateDirectory() throws {
        let fixture = try SeamFixture()
        let server = Server(fixture)
        #expect(server.start())
        defer { server.stop() }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.directoryPath)
        #expect(Client(fixture).connection == nil, "a directory others can enter is refused")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directoryPath)
        #expect(Client(fixture).connection != nil, "baseline")
    }

    @Test func theClientRefusesAnythingButASocket() throws {
        let fixture = try SeamFixture()
        try FileManager.default.createDirectory(atPath: fixture.directoryPath, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        #expect(FileManager.default.createFile(atPath: fixture.socketPath, contents: Data("x".utf8)))
        #expect(Client(fixture).connection == nil)
        try FileManager.default.removeItem(atPath: fixture.socketPath)
        try FileManager.default.createSymbolicLink(atPath: fixture.socketPath, withDestinationPath: "/dev/null")
        #expect(Client(fixture).connection == nil, "a symlink is not a socket")
        try FileManager.default.removeItem(atPath: fixture.socketPath)
        #expect(Client(fixture).connection == nil, "nothing there: local only")
    }

    /// The listener only ever replaces a stale socket of its own.
    @Test func theListenerNeverReplacesAnotherKindOfFile() throws {
        let fixture = try SeamFixture()
        try FileManager.default.createDirectory(atPath: fixture.directoryPath, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        #expect(FileManager.default.createFile(atPath: fixture.socketPath, contents: Data("keep".utf8)))
        #expect(!Server(fixture).start(), "a regular file at the path is refused")
        #expect(FileManager.default.contents(atPath: fixture.socketPath) == Data("keep".utf8), "and left untouched")
    }

    @Test func theListenerReplacesItsOwnStaleSocketButNotALiveOne() throws {
        let fixture = try SeamFixture()
        let first = Server(fixture)
        #expect(first.start())
        #expect(!Server(fixture).start(), "a live listener is never displaced")
        first.stop()
        // A stale socket: bound, never listened on, closed without unlinking.
        let address = try #require(SeamSocket.address(fixture.socketPath))
        let stale = try #require(SeamSocket.makeSocket())
        #expect(SeamSocket.bind(stale, to: address))
        close(stale)
        #expect(FileManager.default.fileExists(atPath: fixture.socketPath))
        let second = Server(fixture)
        #expect(second.start(), "a stale socket of this user's is replaced")
        defer { second.stop() }
        #expect(Client(fixture).connection != nil)
    }

    @Test func stoppingRemovesTheSocketSoTheNextConnectFailsAtOnce() throws {
        let fixture = try SeamFixture()
        let server = Server(fixture)
        #expect(server.start())
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: fixture.socketPath))
        #expect(Client(fixture).connection == nil)
    }

    @Test func aPathThatDoesNotFitIsRefused() throws {
        let fixture = try SeamFixture()
        let long = fixture.root.path + "/" + String(repeating: "d", count: 120) + "/seam.sock"
        let queue = DispatchQueue(label: "test.seam.long")
        #expect(!queue.sync { SeamListener(socketPath: long, queue: queue).start(onConnection: { _ in }) })
        #expect(queue.sync { SeamClient.connect(socketPath: long, queue: queue) } == nil)
        #expect(SeamSocket.address(long) == nil)
        #expect(SeamSocket.address("") == nil)
    }

    // MARK: - Frames on the connection

    @Test func anOverlongFrameClosesTheConnection() throws {
        let fixture = try SeamFixture()
        let server = Server(fixture)
        #expect(server.start())
        defer { server.stop() }
        let client = Client(fixture)
        _ = try #require(server.connections.next())
        _ = client.sendRaw(Array(repeating: UInt8(ascii: "a"), count: ApprovalChannel.maxFrameBytes + 1))
        #expect(server.closes.next(within: Self.closeObservationSeconds) != nil,
                "the over-long frame must close the connection")
        #expect(server.lines.all.isEmpty, "and none of it is delivered")
    }

    @Test func linesSplitAcrossWritesArriveWhole() throws {
        let fixture = try SeamFixture()
        let server = Server(fixture)
        #expect(server.start())
        defer { server.stop() }
        let client = Client(fixture)
        _ = try #require(server.connections.next())
        let frame = ApprovalChannel.verdictFrame(ChannelRequestID("abcde")!, .deny)
        #expect(client.send(frame + "\n" + frame))
        #expect(server.lines.next() == frame)
        #expect(server.lines.next() == frame)
        #expect(server.lines.next(within: 0.3) == nil)
    }

    @Test func closingIsIdempotentAndReportedOnce() throws {
        let fixture = try SeamFixture()
        let server = Server(fixture)
        #expect(server.start())
        defer { server.stop() }
        let client = Client(fixture)
        let serverConnection = try #require(server.connections.next())
        server.queue.sync {
            serverConnection.close()
            serverConnection.close()
        }
        #expect(server.closes.next() != nil)
        #expect(server.closes.next(within: 0.3) == nil, "onClose runs once")
        #expect(!server.queue.sync { serverConnection.send("x") }, "a closed connection sends nothing")
        #expect(client.closes.next(within: Self.closeObservationSeconds) != nil, "the other end sees the close")
    }
}
