import Foundation
import os

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
    func setStayAwake(_ enable: Bool) -> SetStayAwakeOutcome {
        let command: PrivilegedCommand = enable ? .stayAwakeOn : .stayAwakeOff
        switch command.run() {
        case .success:
            break
        case .sudoDenied:
            Self.logger.notice("sudo -n denied for \(command.argv.joined(separator: " "), privacy: .public) — setup required")
            return .sudoDenied
        case .commandFailed(let exitStatus, let stderr):
            let detail = "pmset exited \(exitStatus): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            Self.logger.error("\(detail, privacy: .public)")
            return .commandFailed(detail)
        }
        let observed = refreshObservedState()
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
        let newValue: Bool?
        if let output = Self.readPmsetG() {
            newValue = Self.parseSleepDisabled(fromPmsetG: output) ?? false
        } else {
            Self.logger.error("could not read pmset -g — observed sleep state unknown")
            newValue = nil
        }
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
