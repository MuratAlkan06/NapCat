import Foundation
import NapCatSeam
import NapCatWire
import os

// F4 slice S1: NapCat's end of the seam — the authenticated listener and the
// intake behind it. Design: design/remote-approvals.md.
//
// NOTHING CONSTRUCTS IT YET. It is started by the Mac toggle and stopped by
// the kill switch, both a later slice; until then no socket exists, a channel
// server finds nothing to connect to, and every prompt stays local (dark by
// default). Its queue is the intake's: every frame, close and event runs
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
    let queue = DispatchQueue(label: "com.muratalkan.napcat.approvals.seam")
    private let listener: SeamListener
    private let audit: (ApprovalAuditEvent) -> Void
    private var connections: [ApprovalIntake.ConnectionKey: SeamConnection] = [:]
    private var nextKey = 0
    private var intake: ApprovalIntake?

    /// `peerReader` is injectable so tests can present a foreign peer.
    init(socketPath: String, armed: @escaping () -> Bool, secrets: @escaping () -> [String],
         records: ApprovalRecordSink, audit: @escaping (ApprovalAuditEvent) -> Void = ApprovalAuditLog.record,
         newPromptID: @escaping () -> PromptID? = ApprovalSources.randomPromptID,
         now: @escaping () -> Int = ApprovalSources.monotonicSeconds,
         peerReader: @escaping (Int32) -> SeamPeer? = SeamSocket.peer(of:)) {
        listener = SeamListener(socketPath: socketPath, queue: queue, peerReader: peerReader)
        self.audit = audit
        intake = ApprovalIntake(armed: armed, secrets: secrets, newPromptID: newPromptID, now: now, records: records,
                                sendFrame: { [unowned self] key, line in connections[key]?.send(line) },
                                closeConnection: { [unowned self] key in connections[key]?.close() },
                                audit: audit)
    }

    /// Starts listening (from any queue). False when the seam's directory or
    /// socket path is unusable; nothing then listens.
    func start() -> Bool {
        queue.sync {
            listener.start(onConnection: { [unowned self] in accept($0) },
                           onRefused: { [unowned self] in audit(.peerRefused) })
        }
    }

    /// The kill switch (from any queue): every open prompt is withdrawn,
    /// every server is disconnected, and the socket is removed.
    func stop() {
        queue.sync {
            intake?.killSwitch()
            let open = Array(connections.values)
            connections.removeAll()
            for connection in open { connection.close() }
            listener.stop()
        }
    }

    /// Runs `body` with the intake on the seam's queue (how the later slices
    /// deliver CloudKit's answers and the phone's decisions).
    func withIntake<Result>(_ body: (ApprovalIntake) -> Result) -> Result? {
        queue.sync { intake.map(body) }
    }

    private func accept(_ connection: SeamConnection) {
        nextKey += 1
        let key = nextKey
        connections[key] = connection
        connection.start(onLine: { [unowned self] in intake?.receive($0, from: key) },
                         onClose: { [unowned self] in
                             connections[key] = nil
                             intake?.connectionClosed(key)
                         })
    }
}
