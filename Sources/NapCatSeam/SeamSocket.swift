import Darwin
import Dispatch
import NapCatWire

// F4 slice S1: the authenticated Unix-socket seam between `napcat-channel`
// and NapCat (the frozen design's technical ruling: verdicts are a control
// plane, so they travel over an authenticated socket, never a file).
// Design: design/remote-approvals.md.
//
// NapCat listens; each channel server connects. BOTH ends check the peer
// before a single byte is read: the peer must run as this very user, by its
// socket credentials (LOCAL_PEERCRED) and by its audit token (LOCAL_PEERTOKEN)
// alike. A peer that fails, or whose credentials cannot be read, is closed.
// The socket lives in a directory only this user can enter (0700), and the
// listener only ever replaces a stale socket of its own, never another kind
// of file. Frames are lines (see ApprovalChannel): this file moves bytes and
// splits lines, and never interprets them.
//
// Every socket call of the seam is in this file (lint-locked).

/// Where the seam's socket lives, relative to the user's home.
public enum SeamPaths {
    public static let directoryRelativePath = "Library/Application Support/NapCat/approvals"
    public static let socketName = "seam.sock"

    /// The user's home from the user database, never from `$HOME`: the
    /// server inherits Claude Code's environment and NapCat launchd's, and
    /// both must land on the same socket.
    public static func homeDirectory() -> String? {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4096)
        guard getpwuid_r(geteuid(), &record, &buffer, buffer.count, &result) == 0, result != nil,
              let directory = record.pw_dir else { return nil }
        return String(cString: directory)
    }

    public static func socketPath(home: String) -> String {
        home + "/" + directoryRelativePath + "/" + socketName
    }
}

/// Who is on the other end of a connected seam socket.
public struct SeamPeer: Equatable, Sendable {
    /// The user ID from the socket's credentials.
    public let uid: uid_t
    /// The effective user ID in the peer's audit token: the race-free
    /// identity a later code-signing check can build on.
    public let tokenUID: uid_t
    /// The peer's process ID, from the audit token (for the audit log only).
    public let pid: pid_t

    public init(uid: uid_t, tokenUID: uid_t, pid: pid_t) {
        self.uid = uid
        self.tokenUID = tokenUID
        self.pid = pid
    }
}

/// The one decision about a peer.
public enum SeamPeerPolicy {
    /// The design's floor: the peer runs as this user, by its credentials
    /// AND its audit token. Unreadable credentials are a refusal.
    public static func accepts(_ peer: SeamPeer?, ownUID: uid_t) -> Bool {
        guard let peer else { return false }
        return peer.uid == ownUID && peer.tokenUID == ownUID
    }
}

/// The seam's socket calls.
public enum SeamSocket {
    /// How long a write may wait for the peer to read before the connection
    /// is given up (a stuck peer can never hold NapCat's queue).
    public static let sendTimeoutSeconds = 2
    /// How long part of a frame may sit unfinished before the connection is
    /// given up: a peer writes a frame at once, so a stalled one holds a
    /// buffer and a slot for nothing.
    public static let stallTimeoutSeconds: Double = 5
    static let listenBacklog: Int32 = 8

    /// The credentials of the peer of a connected socket, or nil.
    public static func peer(of descriptor: Int32) -> SeamPeer? {
        var credentials = xucred()
        var credentialsLength = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &credentialsLength) == 0,
              credentialsLength == socklen_t(MemoryLayout<xucred>.size),
              credentials.cr_version == UInt32(XUCRED_VERSION) else { return nil }
        var token = audit_token_t()
        var tokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLength) == 0,
              tokenLength == socklen_t(MemoryLayout<audit_token_t>.size) else { return nil }
        // The audit token's layout (libbsm): val[1] is the effective user ID,
        // val[5] the process ID.
        return SeamPeer(uid: credentials.cr_uid, tokenUID: token.val.1, pid: pid_t(bitPattern: token.val.5))
    }

    /// `path` as a socket address, or nil when it does not fit.
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    /// A fresh stream socket, close-on-exec (no child process inherits it).
    static func makeSocket() -> Int32? {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }

    /// A connected socket's options: close-on-exec, blocking, no SIGPIPE on
    /// a closed peer, and the send timeout.
    static func configureConnected(_ descriptor: Int32) -> Bool {
        var on: Int32 = 1
        var timeout = timeval(tv_sec: sendTimeoutSeconds, tv_usec: 0)
        let flags = fcntl(descriptor, F_GETFL)
        return fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
            && flags >= 0 && fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0
            && setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
            && setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
    }

    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        return String(path[..<slash])
    }

    static func lstatInfo(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }

    static func isDirectory(_ info: stat) -> Bool { info.st_mode & S_IFMT == S_IFDIR }
    static func isSocket(_ info: stat) -> Bool { info.st_mode & S_IFMT == S_IFSOCK }

    /// Whether `path` is a socket of this user's inside a directory of this
    /// user's that nobody else can enter (what the server connects to).
    static func isPrivateSocket(_ path: String, ownUID: uid_t) -> Bool {
        guard let directory = lstatInfo(directory(of: path)), isDirectory(directory), directory.st_uid == ownUID,
              directory.st_mode & 0o077 == 0,
              let socket = lstatInfo(path), isSocket(socket), socket.st_uid == ownUID else { return false }
        return true
    }

    /// Creates the socket's directory (0700) when missing; refuses one that
    /// is not a real directory of this user's, and tightens its mode to 0700.
    static func prepareDirectory(_ directory: String, ownUID: uid_t) -> Bool {
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { return false }
        guard let info = lstatInfo(directory), isDirectory(info), info.st_uid == ownUID else { return false }
        return info.st_mode & 0o077 == 0 || chmod(directory, 0o700) == 0
    }

    static func connect(_ descriptor: Int32, to address: sockaddr_un) -> Bool {
        var address = address
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    static func bind(_ descriptor: Int32, to address: sockaddr_un) -> Bool {
        var address = address
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    /// Whether something is accepting connections at `address` right now.
    static func isLive(_ address: sockaddr_un) -> Bool {
        guard let probe = makeSocket() else { return false }
        defer { Darwin.close(probe) }
        return connect(probe, to: address)
    }

    /// Removes a stale socket of this user's at `path`; refuses to touch any
    /// other kind of file, another user's socket, or a live listener's.
    static func clearStaleSocket(_ path: String, address: sockaddr_un, ownUID: uid_t) -> Bool {
        guard let info = lstatInfo(path) else { return errno == ENOENT }
        guard isSocket(info), info.st_uid == ownUID, !isLive(address) else { return false }
        return unlink(path) == 0
    }
}

/// One authenticated seam connection: lines in, lines out. Every method must
/// be called on the connection's queue, where its handlers also run.
public final class SeamConnection: @unchecked Sendable {
    private let descriptor: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var reader = ChannelLineReader(limit: ApprovalChannel.maxFrameBytes)
    private var onLine: (([UInt8]) -> Void)?
    private var onClose: (() -> Void)?
    /// Runs while part of a frame is buffered (`stallTimeout`).
    private var stallTimer: DispatchSourceTimer?
    private let stallTimeout: Double
    public private(set) var isOpen = true
    /// Who connected (checked before this object existed).
    public let peer: SeamPeer

    init(descriptor: Int32, peer: SeamPeer, queue: DispatchQueue, stallTimeout: Double = SeamSocket.stallTimeoutSeconds) {
        self.descriptor = descriptor
        self.peer = peer
        self.queue = queue
        self.stallTimeout = stallTimeout
    }

    deinit {
        stallTimer?.cancel()
        // An owner that drops an open connection must not leak the descriptor.
        guard isOpen else { return }
        if let source {
            source.cancel()
        } else {
            Darwin.close(descriptor)
        }
    }

    /// Starts reading. Each complete line goes to `onLine`; an over-long
    /// frame, part of a frame left unfinished for `stallTimeout`, end of
    /// stream or a read error closes the connection, and `onClose` runs once,
    /// whoever closed it.
    public func start(onLine: @escaping ([UInt8]) -> Void, onClose: @escaping () -> Void) {
        guard isOpen, source == nil else { return }
        self.onLine = onLine
        self.onClose = onClose
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        let descriptor = self.descriptor
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { Darwin.close(descriptor) }
        self.source = source
        source.resume()
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = read(descriptor, &buffer, buffer.count)
        if count < 0 && (errno == EINTR || errno == EAGAIN) { return }
        guard count > 0 else {
            close()
            return
        }
        for piece in reader.feed(Array(buffer[0..<count])) {
            guard isOpen else { return }
            switch piece {
            case .line(let line): onLine?(line)
            case .overlong: close()
            }
        }
        guard isOpen else { return }
        if reader.hasPartialLine {
            armStallTimer()
        } else {
            stallTimer?.cancel()
            stallTimer = nil
        }
    }

    /// Armed once per unfinished frame: the clock starts when the frame
    /// does, and only finishing it stops it.
    private func armStallTimer() {
        guard stallTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.close() }
        timer.schedule(deadline: .now() + stallTimeout)
        stallTimer = timer
        timer.resume()
    }

    /// Writes one line and its newline. A failed or timed-out write closes
    /// the connection and returns false.
    @discardableResult
    public func send(_ line: String) -> Bool {
        guard isOpen else { return false }
        let bytes = Array(line.utf8) + [0x0A]
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else {
                close()
                return false
            }
            offset += written
        }
        return true
    }

    /// Closes the connection (idempotent).
    public func close() {
        guard isOpen else { return }
        isOpen = false
        stallTimer?.cancel()
        stallTimer = nil
        if let source {
            source.cancel()
        } else {
            Darwin.close(descriptor)
        }
        let handler = onClose
        onLine = nil
        onClose = nil
        handler?()
    }
}

/// NapCat's end: listens at one path and hands over every connection whose
/// peer passed the check. Call it on its queue.
public final class SeamListener: @unchecked Sendable {
    private let path: String
    private let queue: DispatchQueue
    private let peerReader: (Int32) -> SeamPeer?
    private let ownUID: uid_t
    private let stallTimeout: Double
    private var source: DispatchSourceRead?

    /// `peerReader` and `ownUID` are injectable so tests can present a
    /// foreign peer; production uses the real credentials. `stallTimeout`
    /// applies to every accepted connection.
    public init(socketPath: String, queue: DispatchQueue, peerReader: @escaping (Int32) -> SeamPeer? = SeamSocket.peer(of:),
                ownUID: uid_t = geteuid(), stallTimeout: Double = SeamSocket.stallTimeoutSeconds) {
        self.path = socketPath
        self.queue = queue
        self.peerReader = peerReader
        self.ownUID = ownUID
        self.stallTimeout = stallTimeout
    }

    public var isListening: Bool { source != nil }

    /// Starts listening. False (and nothing listening) when the directory is
    /// not this user's own, something other than a stale socket of this
    /// user's is at the path, another listener is live there, or a socket
    /// call fails. `onConnection` runs on the queue for each accepted peer;
    /// `onRefused` for each peer closed by the check.
    public func start(onConnection: @escaping (SeamConnection) -> Void, onRefused: @escaping () -> Void = {}) -> Bool {
        guard source == nil else { return true }
        guard let address = SeamSocket.address(path),
              SeamSocket.prepareDirectory(SeamSocket.directory(of: path), ownUID: ownUID),
              SeamSocket.clearStaleSocket(path, address: address, ownUID: ownUID),
              let descriptor = SeamSocket.makeSocket() else { return false }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              SeamSocket.bind(descriptor, to: address), chmod(path, 0o600) == 0,
              Darwin.listen(descriptor, SeamSocket.listenBacklog) == 0 else {
            Darwin.close(descriptor)
            return false
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        let peerReader = self.peerReader
        let ownUID = self.ownUID
        let queue = self.queue
        let stallTimeout = self.stallTimeout
        source.setEventHandler {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            let peer = peerReader(client)
            guard SeamSocket.configureConnected(client), SeamPeerPolicy.accepts(peer, ownUID: ownUID), let peer else {
                Darwin.close(client)
                onRefused()
                return
            }
            onConnection(SeamConnection(descriptor: client, peer: peer, queue: queue, stallTimeout: stallTimeout))
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        self.source = source
        source.resume()
        return true
    }

    /// Stops listening and removes the socket file, so a server's next
    /// connect fails at once. Open connections are the owner's to close.
    public func stop() {
        guard let source else { return }
        self.source = nil
        source.cancel()
        if let info = SeamSocket.lstatInfo(path), SeamSocket.isSocket(info), info.st_uid == ownUID {
            unlink(path)
        }
    }
}

/// The server's end: connects to NapCat's socket and checks the listener.
public enum SeamClient {
    /// An authenticated connection, or nil when the socket is missing, is not
    /// this user's (or sits in a directory others can enter), nothing
    /// listens, or the listener fails the peer check. Call it on `queue`.
    public static func connect(socketPath: String, queue: DispatchQueue,
                               peerReader: (Int32) -> SeamPeer? = SeamSocket.peer(of:),
                               ownUID: uid_t = geteuid()) -> SeamConnection? {
        guard SeamSocket.isPrivateSocket(socketPath, ownUID: ownUID), let address = SeamSocket.address(socketPath),
              let descriptor = SeamSocket.makeSocket() else { return nil }
        let peer = SeamSocket.connect(descriptor, to: address) ? peerReader(descriptor) : nil
        guard SeamSocket.configureConnected(descriptor), SeamPeerPolicy.accepts(peer, ownUID: ownUID), let peer else {
            Darwin.close(descriptor)
            return nil
        }
        return SeamConnection(descriptor: descriptor, peer: peer, queue: queue)
    }
}
