import Foundation
import NapCatSeam
import NapCatWire
import os

// F4 slice S1: NapCat's end of the seam — the authenticated listener and the
// intake behind it. Design: design/remote-approvals.md.
//
// Built and started ONLY behind the Mac toggle (slice S2:
// RemoteApprovalsController, lint-locked) and stopped by its kill switch;
// with the toggle off no socket exists, a channel server finds nothing to
// connect to, and every prompt stays local. The S2 host is built never armed
// (fail-dark). Its queue is the intake's: every frame, close and event runs
// there.

/// The audit trail's log category (`approvals`): one closed-vocabulary line
/// per event, never prompt text, a request ID, a session ID or the topic.
enum ApprovalAuditLog {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "approvals")

    static func record(_ event: ApprovalAuditEvent) {
        logger.notice("\(event.code, privacy: .public)")
    }
}

/// The production sources the intake takes injected.
enum ApprovalSources {
    /// 128 bits from the system's cryptographically secure generator (the
    /// stdlib's, backed by the kernel's CSPRNG on Apple platforms), or nil
    /// for the one all-zero value.
    static func randomPromptID() -> PromptID? {
        var generator = SystemRandomNumberGenerator()
        return PromptID(high: generator.next(), low: generator.next())
    }

    /// Monotonic seconds that keep counting through sleep (the prompt's TTL
    /// is wall time on the phone).
    static func monotonicSeconds() -> Int {
        Int(clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000_000)
    }
}

final class ApprovalSeamHost: @unchecked Sendable {
    /// What one host holds at most, and for how long a server may sit idle.
    struct Limits: Sendable {
        /// Servers connected at once; one more is closed unread.
        var maxConnections = 64
        /// A server that sends nothing for this long while none of its
        /// prompts waits on the phone is disconnected (it reconnects with its
        /// next prompt); while one waits, the TTL is checked instead.
        var idleSeconds: Double = 60
        /// Part of a frame left unfinished this long closes the connection.
        var stallSeconds: Double = SeamSocket.stallTimeoutSeconds

        static let standard = Limits()
    }

    let queue = DispatchQueue(label: "com.muratalkan.napcat.approvals.seam")
    private let listener: SeamListener
    private let audit: (ApprovalAuditEvent) -> Void
    private let limits: Limits
    private var connections: [ApprovalIntake.ConnectionKey: SeamConnection] = [:]
    /// One one-shot timer per connection, re-armed by every frame: there is
    /// nothing scheduled while nobody is connected.
    private var idleTimers: [ApprovalIntake.ConnectionKey: DispatchSourceTimer] = [:]
    private var nextKey = 0
    private var intake: ApprovalIntake?

    /// `peerReader` is injectable so tests can present a foreign peer.
    init(socketPath: String, armed: @escaping () -> Bool, secrets: @escaping () -> [String]?,
         records: ApprovalRecordSink, audit: @escaping (ApprovalAuditEvent) -> Void = ApprovalAuditLog.record,
         newPromptID: @escaping () -> PromptID? = ApprovalSources.randomPromptID,
         now: @escaping () -> Int = ApprovalSources.monotonicSeconds,
         peerReader: @escaping (Int32) -> SeamPeer? = SeamSocket.peer(of:), limits: Limits = .standard) {
        listener = SeamListener(socketPath: socketPath, queue: queue, peerReader: peerReader,
                                stallTimeout: limits.stallSeconds)
        self.audit = audit
        self.limits = limits
        intake = ApprovalIntake(armed: armed, secrets: secrets, newPromptID: newPromptID, now: now, records: records,
                                sendFrame: { [weak self] key, line in self?.connections[key]?.send(line) },
                                closeConnection: { [weak self] key in self?.connections[key]?.close() },
                                audit: audit)
    }

    /// Starts listening (from any queue but the host's own: it waits on
    /// it). False when the seam's directory or socket path is unusable;
    /// nothing then listens.
    func start() -> Bool {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync {
            listener.start(onConnection: { [weak self] in self?.accept($0) },
                           onRefused: { [weak self] in self?.audit(.peerRefused) })
        }
    }

    /// The kill switch (from any queue but the host's own): every open
    /// prompt is withdrawn, every server is disconnected, and the socket is
    /// removed.
    func stop() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            intake?.killSwitch()
            let open = Array(connections.values)
            connections.removeAll()
            for connection in open { connection.close() }
            for timer in idleTimers.values { timer.cancel() }
            idleTimers.removeAll()
            listener.stop()
        }
    }

    /// Runs `body` with the intake on the seam's queue (how the later slices
    /// deliver CloudKit's answers and the phone's decisions). The intake is
    /// bound plainly, never through a member call on the optional, so no
    /// extension can stand in at this door (pinned whole:
    /// DecisionSinkStructureTests).
    func withIntake<Result>(_ body: (ApprovalIntake) -> Result) -> Result? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync {
            guard let intake else { return nil }
            return body(intake)
        }
    }

    /// A host released without `stop()` leaves nothing running: its timers
    /// are cancelled here, its connections close as they are released, and
    /// its listener removes the socket as it goes. (Every closure the host
    /// hands out holds it weakly, so none can outlive it.)
    deinit {
        for timer in idleTimers.values { timer.cancel() }
    }

    private func accept(_ connection: SeamConnection) {
        guard connections.count < limits.maxConnections else {
            connection.close()
            audit(.connectionLimit)
            return
        }
        nextKey += 1
        let key = nextKey
        connections[key] = connection
        connection.start(onLine: { [weak self] in
                             self?.intake?.receive($0, from: key)
                             self?.armIdleTimer(key)
                         },
                         onClose: { [weak self] in
                             self?.idleTimers.removeValue(forKey: key)?.cancel()
                             self?.connections[key] = nil
                             self?.intake?.connectionClosed(key)
                         })
        armIdleTimer(key)
    }

    /// (Re)starts the connection's idle clock.
    private func armIdleTimer(_ key: ApprovalIntake.ConnectionKey) {
        guard connections[key] != nil else { return }
        let timer: DispatchSourceTimer
        if let existing = idleTimers[key] {
            timer = existing
        } else {
            timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.idleTimerFired(key) }
            idleTimers[key] = timer
            timer.resume()
        }
        timer.schedule(deadline: .now() + limits.idleSeconds)
    }

    /// Idle: let the TTL withdraw what it may, then keep the link only while
    /// one of its prompts still waits on the phone.
    private func idleTimerFired(_ key: ApprovalIntake.ConnectionKey) {
        guard let connection = connections[key] else { return }
        intake?.tick()
        if intake?.holdsOpenPrompt(from: key) == true {
            armIdleTimer(key)
        } else {
            connection.close()
        }
    }
}
