import Foundation
import os

/// Sendable atomic mirror of the OBSERVED stay-awake state, written
/// synchronously at `SleepStateController`'s single publish choke point.
///
/// Track B / B2 needs this value from the IOKit power-notification queue at the
/// instant the lid closes — including the case the whole feature exists for:
/// the user toggles Stay Awake OFF and closes the lid seconds later. Hopping to
/// the main actor for it would risk reading a stale or delayed value, so the
/// observed state is mirrored here the moment it is published.
final class ObservedStayAwakeMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var observed: Bool?

    /// nil = `pmset -g` unreadable (unknown). B2 treats unknown as "not on"
    /// and fires — deliberate fail-toward-notify.
    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }

    func set(_ newValue: Bool?) {
        lock.lock()
        observed = newValue
        lock.unlock()
    }
}

/// Enables/disables stay-awake (`pmset disablesleep`) and tracks the
/// OBSERVED system state, read back from unprivileged `pmset -g`.
///
/// Per ADR §6 the UI must always render observed state, never cached intent —
/// every mutation is verified by read-back, and `refreshObservedState()` is
/// re-run at launch and on every menu open.
@MainActor
final class SleepStateController {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "sleep")

    /// Last observed system state. nil = unknown (`pmset -g` could not be
    /// run or produced no output). A missing `SleepDisabled` line parses as
    /// false — pmset omits it when sleep is not disabled.
    private(set) var observedSleepDisabled: Bool?

    /// Fired (on the main actor) whenever the observed state changes.
    var onObservedStateChange: ((Bool?) -> Void)?

    /// Thread-safe mirror of `observedSleepDisabled` for the B2 lid guard,
    /// updated on EVERY read (see `applyObservedRead`).
    let observedMirror = ObservedStayAwakeMirror()

    enum SetStayAwakeOutcome: Equatable {
        case success
        /// Sudoers entry missing — user has not run scripts/setup.sh.
        case sudoDenied
        case commandFailed(String)
        /// pmset exited 0 but read-back disagreed — never report a false
        /// success (ADR §2 spirit applied to sleep state).
        case verificationFailed(String)
    }

    /// Runs the exact privileged command, then VERIFIES by re-reading
    /// `pmset -g` (unprivileged). Publishes the observed state either way.
    /// Synchronous (blocks on two subprocesses) — used by the shutdown
    /// revert and launch reconciliation, which cannot await. The menu
    /// toggle uses `setStayAwakeAsync` so the open menu never blocks.
    func setStayAwake(_ enable: Bool) -> SetStayAwakeOutcome {
        let command: PrivilegedCommand = enable ? .stayAwakeOn : .stayAwakeOff
        if let failure = failureOutcome(afterRunning: command, result: command.run()) {
            return failure
        }
        return verifiedOutcome(enable: enable, observed: refreshObservedState())
    }

    /// Identical semantics to `setStayAwake(_:)`, but both subprocess runs
    /// (sudo pmset + the pmset -g read-back) execute OFF the main actor, so
    /// the menu-tracking runloop stays responsive while the command runs
    /// (2026-07-10 menu-stays-open fix). The observed state is published on
    /// the main actor when the read-back returns.
    func setStayAwakeAsync(_ enable: Bool) async -> SetStayAwakeOutcome {
        let command: PrivilegedCommand = enable ? .stayAwakeOn : .stayAwakeOff
        let runResult = await Task.detached(priority: .userInitiated) { command.run() }.value
        if let failure = failureOutcome(afterRunning: command, result: runResult) {
            return failure
        }
        let output = await Task.detached(priority: .userInitiated) { Self.readPmsetG() }.value
        return verifiedOutcome(enable: enable, observed: applyObservedRead(output))
    }

    /// Shared by the sync and async paths: classifies a privileged-command
    /// result into an early-return outcome, or nil when the write succeeded
    /// and the caller should proceed to read-back verification.
    private func failureOutcome(
        afterRunning command: PrivilegedCommand,
        result: PrivilegedCommandResult
    ) -> SetStayAwakeOutcome? {
        switch result {
        case .success:
            return nil
        case .sudoDenied:
            Self.logger.notice("sudo -n denied for \(command.argv.joined(separator: " "), privacy: .public) — setup required")
            return .sudoDenied
        case .commandFailed(let exitStatus, let stderr):
            let detail = "pmset exited \(exitStatus): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            Self.logger.error("\(detail, privacy: .public)")
            return .commandFailed(detail)
        }
    }

    /// Shared read-back verification: pmset exited 0, so the observed state
    /// must now match the requested one — anything else is a verification
    /// failure, never a false success (ADR §2 spirit).
    private func verifiedOutcome(enable: Bool, observed: Bool?) -> SetStayAwakeOutcome {
        guard observed == enable else {
            let detail = "pmset exited 0 but pmset -g reports SleepDisabled=\(observed.map { $0 ? "1" : "0" } ?? "unknown")"
            Self.logger.error("\(detail, privacy: .public)")
            return .verificationFailed(detail)
        }
        Self.logger.notice("stay-awake \(enable ? "enabled" : "disabled", privacy: .public) and verified via pmset -g")
        return .success
    }

    /// Re-reads `pmset -g` and publishes the observed state.
    @discardableResult
    func refreshObservedState() -> Bool? {
        applyObservedRead(Self.readPmsetG())
    }

    /// Parses a `pmset -g` read and publishes the observed state (fires
    /// `onObservedStateChange` on change). Factored out so the async path
    /// can read off the main actor and publish here.
    private func applyObservedRead(_ output: String?) -> Bool? {
        let newValue: Bool?
        if let output {
            newValue = Self.parseSleepDisabled(fromPmsetG: output) ?? false
        } else {
            Self.logger.error("could not read pmset -g — observed sleep state unknown")
            newValue = nil
        }
        // THE choke point: every observed-state publication updates the
        // Sendable mirror synchronously, so the B2 lid guard reads a fresh
        // value from the power-notification queue without a main-actor hop.
        observedMirror.set(newValue)
        if newValue != observedSleepDisabled {
            observedSleepDisabled = newValue
            onObservedStateChange?(newValue)
        }
        return newValue
    }

    /// Pure parser for `pmset -g` output. Returns the value of the
    /// `SleepDisabled` line, or nil when the line is missing or malformed
    /// (pmset omits the line when sleep is not disabled on some systems —
    /// callers treat nil as "not disabled").
    nonisolated static func parseSleepDisabled(fromPmsetG output: String) -> Bool? {
        for line in output.split(whereSeparator: \.isNewline) {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard tokens.first == "SleepDisabled", tokens.count >= 2 else { continue }
            switch tokens[1] {
            case "1": return true
            case "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// Unprivileged read of system power settings. nil if pmset could not be
    /// run or produced unreadable output.
    private nonisolated static func readPmsetG() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let stdoutPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
