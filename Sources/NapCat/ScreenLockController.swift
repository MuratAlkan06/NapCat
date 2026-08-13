import CoreGraphics
import Foundation
import os

/// One-click "Lock Screen": locks the login session AND turns the display
/// off, while the machine keeps running. Primary use is with Stay Awake on —
/// walk away (or close the lid) without interrupting the work in progress.
///
/// Mechanism (frozen 2026-08-13, see PLAN.md decision log):
/// 1. `SACLockScreenImmediate` from login.framework, resolved at RUNTIME via
///    dlopen/dlsym. The framework has no on-disk binary on Sequoia (it lives
///    in the dyld shared cache), so there is nothing to link against with
///    Command Line Tools; runtime resolution is also the graceful-degrade
///    path — a future macOS that drops the symbol renders the menu row
///    disabled instead of breaking.
/// 2. VERIFY the lock by polling the PUBLIC `CGSessionCopyCurrentDictionary()`
///    for `CGSSessionScreenIsLocked` (the same read-back doctrine the rest of
///    the app applies to `pmset -g`).
/// 3. ONLY after a verified lock, run `/usr/bin/pmset displaysleepnow`
///    (unprivileged, plain Process) to turn the display off.
///
/// The order lock → verify → dark is deliberate: a failure must never produce
/// a dark screen on an UNLOCKED Mac, so any failure alert is always presented
/// on a lit one.
///
/// This file is the ONLY place that touches dlopen/login.framework or spawns
/// the display-sleep subprocess (same confinement rule the privileged-command
/// and key-reader files follow). It adds ZERO privileged surface: nothing here
/// elevates, and PLAN.md §4 is unchanged.
@MainActor
final class ScreenLockController {
    private nonisolated static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "lock")

    // MARK: - Frozen constants (locked byte-for-byte by ScreenLockControllerTests)

    /// Private framework holding the lock entry point. Never linked — only
    /// dlopen'd (there is no on-disk binary to link on Sequoia).
    nonisolated static let loginFrameworkPath =
        "/System/Library/PrivateFrameworks/login.framework/Versions/A/login"

    /// The private symbol; `@convention(c) () -> Void`, return ignored.
    nonisolated static let lockSymbolName = "SACLockScreenImmediate"

    /// Public CoreGraphics session-dictionary key used to VERIFY the lock.
    /// Absent from the dictionary while the screen is unlocked.
    nonisolated static let sessionScreenIsLockedKey = "CGSSessionScreenIsLocked"

    /// Unprivileged display-off command — the P4-proven path (it is what the
    /// animation display-sleep verification uses). Never elevated.
    nonisolated static let displaySleepArgv = ["/usr/bin/pmset", "displaysleepnow"]

    /// Lock verification budget: poll every 50ms for at most 2s.
    nonisolated static let verificationTimeout: TimeInterval = 2.0
    nonisolated static let verificationPollInterval: TimeInterval = 0.05

    typealias LockFunction = @convention(c) () -> Void

    enum Outcome: Equatable {
        /// Locked (verified) and the display was put to sleep.
        case success
        /// The symbol does not resolve on this OS — the row is disabled, so
        /// this is a belt-and-braces outcome, never a normal one.
        case unavailable
        /// The lock call returned but the session never reported as locked
        /// within the deadline. The screen is still LIT and unlocked —
        /// display sleep is deliberately skipped and the failure is surfaced.
        case lockNotVerified(String)
        /// Locked (verified) but `pmset displaysleepnow` failed. The Mac is
        /// safe; only the display stayed on. Logged, not alerted.
        case lockedButDisplaySleepFailed(String)
    }

    // MARK: - Symbol resolution

    /// Resolved once per process. The dlopen handle is deliberately never
    /// dlclose'd — the function pointer must stay valid for the process
    /// lifetime. Swift's lazy static initialization makes this thread-safe.
    private nonisolated static let cachedLockFunction: LockFunction? = {
        guard let handle = dlopen(loginFrameworkPath, RTLD_NOW) else {
            let detail = dlerror().map { String(cString: $0) } ?? "unknown error"
            logger.error("dlopen(\(loginFrameworkPath, privacy: .public)) failed: \(detail, privacy: .public) — Lock Screen unavailable")
            return nil
        }
        guard let symbol = dlsym(handle, lockSymbolName) else {
            logger.error("\(lockSymbolName, privacy: .public) not found in login.framework — Lock Screen unavailable")
            return nil
        }
        return unsafeBitCast(symbol, to: LockFunction.self)
    }()

    /// Resolves the private lock entry point (cached). SIDE-EFFECT-FREE:
    /// resolving never locks anything, which is what lets the unit-test
    /// canary call it — the returned function itself is never invoked by
    /// tests (same doctrine as never calling SMAppService.register).
    nonisolated static func resolveLockFunction() -> LockFunction? {
        cachedLockFunction
    }

    /// Whether the mechanism exists on this OS. Fixed for the process
    /// lifetime — the menu row is enabled/disabled from this.
    nonisolated var isAvailable: Bool { Self.resolveLockFunction() != nil }

    // MARK: - Lock verification (pure parser + live wrapper)

    /// Pure parser for a CoreGraphics session dictionary.
    /// nil dictionary → nil (unreadable, never guessed); key true → true;
    /// key absent or false → false (macOS omits the key while unlocked).
    nonisolated static func screenIsLocked(in session: [String: Any]?) -> Bool? {
        guard let session else { return nil }
        return (session[sessionScreenIsLockedKey] as? Bool) ?? false
    }

    /// Thin live wrapper over the PUBLIC CoreGraphics session dictionary.
    nonisolated static func liveScreenIsLocked() -> Bool? {
        screenIsLocked(in: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    // MARK: - The sequence

    /// Locks, verifies, then darkens. The verification poll and the
    /// display-sleep subprocess both run OFF the main actor (`Task.detached`
    /// hops, same shape as the stay-awake async path) so nothing blocks the
    /// UI while the sequence runs.
    func lockScreen() async -> Outcome {
        guard let lock = Self.resolveLockFunction() else {
            Self.logger.error("lock requested but \(Self.lockSymbolName, privacy: .public) does not resolve on this system")
            return .unavailable
        }

        // Return value deliberately ignored — the private entry point's
        // result is not a documented contract; the session read-back is.
        lock()

        let locked = await Task.detached(priority: .userInitiated) { Self.waitForVerifiedLock() }.value
        guard locked else {
            let detail = "The screen did not report as locked within \(Int(Self.verificationTimeout)) seconds, so the display was left on."
            Self.logger.error("lock NOT verified within \(Self.verificationTimeout, privacy: .public)s — display sleep skipped")
            return .lockNotVerified(detail)
        }
        Self.logger.notice("screen lock verified via CGSessionCopyCurrentDictionary")

        let displaySleepFailure = await Task.detached(priority: .userInitiated) { Self.runDisplaySleep() }.value
        if let failure = displaySleepFailure {
            // The Mac is locked, which is the part that matters — surface
            // this in the log only (a modal on a locked screen is pointless).
            Self.logger.error("locked, but display sleep failed: \(failure, privacy: .public)")
            return .lockedButDisplaySleepFailed(failure)
        }
        Self.logger.notice("display sleep requested after verified lock")
        return .success
    }

    /// Blocking poll (runs in a detached task): true as soon as the session
    /// reports locked, false when the deadline passes.
    private nonisolated static func waitForVerifiedLock() -> Bool {
        let deadline = Date().addingTimeInterval(verificationTimeout)
        while Date() < deadline {
            if liveScreenIsLocked() == true { return true }
            Thread.sleep(forTimeInterval: verificationPollInterval)
        }
        return liveScreenIsLocked() == true
    }

    /// Runs `/usr/bin/pmset displaysleepnow` UNPRIVILEGED (plain Process — no
    /// elevation, no helper). Returns a failure detail, or nil on success.
    private nonisolated static func runDisplaySleep() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: displaySleepArgv[0])
        process.arguments = Array(displaySleepArgv.dropFirst())
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return "could not run \(displaySleepArgv.joined(separator: " ")): \(error.localizedDescription)"
        }
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = (String(data: stderrData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(displaySleepArgv.joined(separator: " ")) exited \(process.terminationStatus)\(stderr.isEmpty ? "" : ": \(stderr)")"
        }
        return nil
    }
}
