import Foundation
import os

/// SENDER FILE (structural-isolation boundary): the ONLY file in the B2
/// subsystem that may spawn a process, and the only file anywhere that may
/// name `osascript` (`LidGuardStructureTests` enforces both).
///
/// It runs the FIXED AppleScript shipped in the app bundle:
///
///     /usr/bin/osascript <bundled script> <recipient> <body>
///
/// Recipient and body are ARGV. They are never interpolated into script source,
/// so no input can be re-parsed as AppleScript. UNPRIVILEGED — no sudo, no new
/// PLAN §4 command; the only gate is the user's Automation (TCC) grant for
/// Messages.
final class OSAScriptMessageSender: MessageSender, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "lidguard")

    static let osascriptPath = "/usr/bin/osascript"

    private let scriptURL: URL
    /// Serial queue: spawns, the hard-kill timer, and teardown all run here.
    private let queue = DispatchQueue(label: "com.muratalkan.napcat.lidguard.sender")
    private let lock = NSLock()
    /// STRONG reference to the live child. A deallocated `Process` loses its
    /// `terminationHandler` while the child keeps running, so the outcome would
    /// never be classified.
    private var inFlight: Process?
    private var killTimer: DispatchSourceTimer?

    /// Fails to build when the script resource is missing from the bundle
    /// (e.g. a hand-assembled app); the lid guard then simply never arms
    /// instead of spawning something undefined.
    init?(scriptURL: URL? = Bundle.main.url(
        forResource: LidGuardTuning.scriptResourceName,
        withExtension: LidGuardTuning.scriptResourceExtension
    )) {
        guard let scriptURL else {
            Self.logger.error("\(LidGuardTuning.scriptResourceName, privacy: .public) missing from the app bundle — lid guard cannot send")
            return nil
        }
        self.scriptURL = scriptURL
    }

    func send(
        _ kind: LidGuardMessageKind,
        to recipient: String,
        at firedAt: Date,
        completion: @escaping @Sendable (MessageSendOutcome) -> Void
    ) {
        // The body is built HERE, from the closed kind + the event clock time.
        // No caller-supplied text exists anywhere on this path.
        let body = LidGuardPolicy.messageBody(kind: kind, clockTime: LidGuardPolicy.clockTime(firedAt))
        let scriptPath = scriptURL.path
        queue.async { [weak self] in
            self?.spawn(scriptPath: scriptPath, recipient: recipient, body: body, completion: completion)
        }
    }

    // MARK: - Spawn (queue-confined)

    private func spawn(
        scriptPath: String,
        recipient: String,
        body: String,
        completion: @escaping @Sendable (MessageSendOutcome) -> Void
    ) {
        let once = SendCompletionOnce(completion)

        // SINGLE-FLIGHT: never a second child while one is alive.
        lock.lock()
        let busy = inFlight?.isRunning == true
        lock.unlock()
        guard !busy else {
            once.finish(.sendFailed("another message is still being sent"))
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.osascriptPath)
        process.arguments = [scriptPath, recipient, body]
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] finished in
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            self?.clearInFlight(finished)
            once.finish(LidGuardPolicy.classifySend(exitStatus: finished.terminationStatus, stderr: stderr))
        }

        // Tracked BEFORE launching: an extremely short-lived child could
        // otherwise run its termination handler before we recorded it.
        lock.lock()
        inFlight = process
        lock.unlock()

        do {
            try process.run()
        } catch {
            clearInFlight(process)
            once.finish(.sendFailed("failed to launch osascript: \(error.localizedDescription)"))
            return
        }

        // HARD-KILL BACKSTOP on a SUSPENDING clock: DispatchSourceTimer
        // deadlines are `DispatchTime` (mach uptime), which does NOT advance
        // while the Mac is asleep. So a child spawned at lid-close keeps its
        // remaining budget across an overnight sleep instead of being killed
        // the instant the machine wakes. (The cooldown uses the opposite clock
        // — wall time — precisely because it MUST advance across sleep.)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + LidGuardTuning.sendHardKillTimeout)
        timer.setEventHandler { [weak self] in
            if process.isRunning {
                // We genuinely do not know whether Messages accepted it —
                // report unconfirmed FIRST, then stop a child that is stuck
                // (typically an unanswered Automation prompt) rather than
                // leaving it forever.
                once.finish(.timedOutUnconfirmed)
                process.terminate()
            }
            self?.clearInFlight(process)
        }

        lock.lock()
        killTimer?.cancel()
        killTimer = timer
        lock.unlock()
        timer.resume()
    }

    /// Clears tracking ONLY when `process` is still the tracked child. A late
    /// termination handler from a previous send must never drop the strong
    /// reference or the hard-kill timer belonging to a newer one.
    private func clearInFlight(_ process: Process) {
        lock.lock()
        if inFlight === process {
            inFlight = nil
            killTimer?.cancel()
            killTimer = nil
        }
        lock.unlock()
    }
}

/// Guarantees a send completion runs exactly once, whichever of the two racing
/// paths (child exit / hard-kill budget) gets there first.
private final class SendCompletionOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (@Sendable (MessageSendOutcome) -> Void)?

    init(_ completion: @escaping @Sendable (MessageSendOutcome) -> Void) {
        pending = completion
    }

    func finish(_ outcome: MessageSendOutcome) {
        lock.lock()
        let handler = pending
        pending = nil
        lock.unlock()
        handler?(outcome)
    }
}
