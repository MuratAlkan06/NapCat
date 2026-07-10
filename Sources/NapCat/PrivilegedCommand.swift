import Foundation

/// The complete, closed set of privileged commands NapCat may ever execute.
///
/// Each case's argv MUST byte-match one exact-argument entry in
/// `/etc/sudoers.d/napcat` (PLAN.md §4). sudo matches the full command line
/// verbatim, so any drift in argument order, spelling, or spacing breaks
/// NOPASSWD matching. The strings are locked by PrivilegedCommandTests —
/// change them only together with scripts/setup.sh and PLAN.md §4.
///
/// Execution model: `/usr/bin/sudo -n <executablePath> <arguments...>` via
/// Process. `-n` (non-interactive) makes sudo fail fast instead of prompting
/// when the sudoers entry is missing — that failure is surfaced as
/// `.sudoDenied` so the UI can show the "Setup Required" path.
enum PrivilegedCommand: CaseIterable, Sendable {
    // MARK: Phase 2 — stay awake (pmset)

    /// `/usr/bin/pmset -a disablesleep 1`
    case stayAwakeOn
    /// `/usr/bin/pmset -a disablesleep 0`
    case stayAwakeOff

    // MARK: Phase 3 — charge limiting (smc) — UNUSED until P3.
    // Defined now so the argv strings are frozen alongside the sudoers plan;
    // /usr/local/napcat/smc does not exist until the user runs the P5 setup.

    /// `/usr/local/napcat/smc -k CH0B -w 02` (disable charging, older AS keys)
    case chargingDisableCH0B
    /// `/usr/local/napcat/smc -k CH0C -w 02` (disable charging, older AS keys)
    case chargingDisableCH0C
    /// `/usr/local/napcat/smc -k CHTE -w 01000000` (disable charging, Sequoia+)
    case chargingDisableCHTE
    /// `/usr/local/napcat/smc -k CH0B -w 00` (enable charging, older AS keys)
    case chargingEnableCH0B
    /// `/usr/local/napcat/smc -k CH0C -w 00` (enable charging, older AS keys)
    case chargingEnableCH0C
    /// `/usr/local/napcat/smc -k CHTE -w 00000000` (enable charging, Sequoia+)
    case chargingEnableCHTE

    static let sudoPath = "/usr/bin/sudo"

    var executablePath: String {
        switch self {
        case .stayAwakeOn, .stayAwakeOff:
            return "/usr/bin/pmset"
        case .chargingDisableCH0B, .chargingDisableCH0C, .chargingDisableCHTE,
             .chargingEnableCH0B, .chargingEnableCH0C, .chargingEnableCHTE:
            return "/usr/local/napcat/smc"
        }
    }

    var arguments: [String] {
        switch self {
        case .stayAwakeOn: return ["-a", "disablesleep", "1"]
        case .stayAwakeOff: return ["-a", "disablesleep", "0"]
        case .chargingDisableCH0B: return ["-k", "CH0B", "-w", "02"]
        case .chargingDisableCH0C: return ["-k", "CH0C", "-w", "02"]
        case .chargingDisableCHTE: return ["-k", "CHTE", "-w", "01000000"]
        case .chargingEnableCH0B: return ["-k", "CH0B", "-w", "00"]
        case .chargingEnableCH0C: return ["-k", "CH0C", "-w", "00"]
        case .chargingEnableCHTE: return ["-k", "CHTE", "-w", "00000000"]
        }
    }

    /// The exact argv the sudoers entry must match (executable + args).
    var argv: [String] { [executablePath] + arguments }

    /// Full argv actually executed: `/usr/bin/sudo -n <argv...>`.
    var sudoArgv: [String] { [Self.sudoPath, "-n"] + argv }

    /// Runs the command via `sudo -n`. Blocking; the privileged commands are
    /// all sub-100ms. Never prompts (`-n` + null stdin).
    func run() -> PrivilegedCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sudoPath)
        process.arguments = ["-n"] + argv
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return .commandFailed(exitStatus: -1, stderr: "failed to launch sudo: \(error.localizedDescription)")
        }
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return Self.classify(exitStatus: process.terminationStatus, stderr: stderr)
    }

    /// Pure classification of a `sudo -n` outcome (unit-tested with real sudo
    /// stderr fixtures):
    /// - exit 0 → success
    /// - non-zero + stderr showing sudo itself refused ("a password is
    ///   required" from `-n` with no NOPASSWD rule, or "not allowed to
    ///   execute" when the rule doesn't cover the command) → sudoDenied
    ///   (setup missing/incomplete)
    /// - anything else → the underlying command failed
    static func classify(exitStatus: Int32, stderr: String) -> PrivilegedCommandResult {
        if exitStatus == 0 { return .success }
        if stderr.contains("a password is required") || stderr.contains("not allowed to execute") {
            return .sudoDenied
        }
        return .commandFailed(exitStatus: exitStatus, stderr: stderr)
    }
}

enum PrivilegedCommandResult: Equatable, Sendable {
    case success
    /// `sudo -n` refused — the sudoers entry is missing (setup not run).
    case sudoDenied
    /// sudo ran the command but the command itself failed.
    case commandFailed(exitStatus: Int32, stderr: String)
}
