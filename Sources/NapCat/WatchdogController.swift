import Foundation
import os

/// Crash-failsafe layer (b) per ADR §6: spawns Resources/napcat-watchdog.sh
/// only while stay-awake is enabled. The script polls the app PID (passed
/// explicitly as $1 — NOT $PPID, children get reparented to launchd) every 5s
/// and reverts `disablesleep` if the app dies without a clean disable.
@MainActor
final class WatchdogController {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "watchdog")

    /// Must stay in sync with PIDFILE in Resources/napcat-watchdog.sh
    /// ($HOME/Library/Application Support/NapCat/watchdog.pid) — locked by a
    /// unit test.
    nonisolated static var pidfileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/NapCat/watchdog.pid")
    }

    private var process: Process?

    /// Spawns the watchdog for the given app PID and records its PID in the
    /// pidfile. No-op if a watchdog from this session is already running.
    func start(appPID: pid_t) {
        if let process, process.isRunning { return }
        guard let script = Bundle.main.url(forResource: "napcat-watchdog", withExtension: "sh") else {
            Self.logger.error("napcat-watchdog.sh missing from app bundle — crash failsafe layer (b) inactive")
            return
        }
        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/bash")
        watchdog.arguments = [script.path, String(appPID)]
        watchdog.standardInput = FileHandle.nullDevice
        watchdog.standardOutput = FileHandle.nullDevice
        watchdog.standardError = FileHandle.nullDevice
        do {
            try watchdog.run()
        } catch {
            Self.logger.error("failed to spawn watchdog: \(error.localizedDescription, privacy: .public)")
            return
        }
        process = watchdog
        writePidfile(watchdog.processIdentifier)
        Self.logger.notice("watchdog started (pid \(Int(watchdog.processIdentifier))) for app pid \(Int(appPID))")
    }

    /// Clean-path teardown: SIGTERM the watchdog (so it never runs its
    /// revert) and delete the pidfile.
    func stop() {
        if let process, process.isRunning {
            process.terminate() // SIGTERM
            Self.logger.notice("watchdog stopped (pid \(Int(process.processIdentifier)))")
        }
        process = nil
        try? FileManager.default.removeItem(at: Self.pidfileURL)
    }

    /// Launch-time stale-watchdog detection (ADR §6): if the pidfile names a
    /// PID that is still alive AND whose command line matches the watchdog
    /// script, SIGTERM it before any new spawn — otherwise a leftover
    /// watchdog from a killed instance could revert a fresh enable
    /// (kill-9 → relaunch → enable race). Always removes the pidfile.
    func reapStaleWatchdog() {
        let pidfile = Self.pidfileURL
        guard let contents = try? String(contentsOf: pidfile, encoding: .utf8) else { return }
        if let stalePID = Self.stalePID(
            pidfileContents: contents,
            isProcessAlive: { kill($0, 0) == 0 },
            commandLine: Self.commandLine(ofPID:)
        ) {
            kill(stalePID, SIGTERM)
            Self.logger.notice("terminated stale watchdog (pid \(Int(stalePID))) from a previous session")
        }
        try? FileManager.default.removeItem(at: pidfile)
    }

    /// Pure stale-watchdog decision (unit-tested with injected lookups).
    /// Returns the PID to SIGTERM, or nil when there is nothing to reap:
    /// pidfile missing/garbage, PID dead, or PID reused by an unrelated
    /// process (command line does not mention the watchdog script).
    nonisolated static func stalePID(
        pidfileContents: String?,
        isProcessAlive: (pid_t) -> Bool,
        commandLine: (pid_t) -> String?
    ) -> pid_t? {
        guard let trimmed = pidfileContents?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = pid_t(trimmed), pid > 0 else { return nil }
        guard isProcessAlive(pid) else { return nil }
        guard let command = commandLine(pid), command.contains("napcat-watchdog") else { return nil }
        return pid
    }

    /// `ps -o command= -p <pid>` — nil if the process is gone.
    private nonisolated static func commandLine(ofPID pid: pid_t) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "command=", "-p", String(pid)]
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
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writePidfile(_ pid: pid_t) {
        let pidfile = Self.pidfileURL
        do {
            try FileManager.default.createDirectory(
                at: pidfile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("\(pid)\n".utf8).write(to: pidfile, options: .atomic)
        } catch {
            Self.logger.error("failed to write watchdog pidfile: \(error.localizedDescription, privacy: .public)")
        }
    }
}
