import Foundation
import os

/// Which SMC key family controls charging on this machine (ADR §2 probe).
enum SMCKeyFamily: Equatable, Sendable {
    /// Sequoia+ Apple Silicon: CHTE (`01000000` disable / `00000000` enable).
    case chte
    /// Older Apple Silicon: CH0B + CH0C (`02` disable / `00` enable, both).
    case ch0bc
}

/// UNPRIVILEGED reads of SMC keys via the user-installed helper at
/// `/usr/local/napcat/smc` (ADR §2: key-family probe + write read-back
/// verification). Reading SMC keys needs no root.
///
/// This file NEVER uses sudo — privileged writes go exclusively through
/// `PrivilegedCommand`. It is reached only from `IOKitPowerSource`, which is
/// never constructed in debug-simulator mode, so the ADR §8 isolation
/// guarantee ("simulated mode can never invoke the smc binary") holds.
enum SMCKeyReader {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "smcread")

    /// Runtime path of the helper — root-owned, installed by the USER-RUN
    /// scripts/setup.sh. Must match PrivilegedCommand.executablePath for the
    /// smc cases and the sudoers entries in PLAN.md §4.
    static let helperPath = "/usr/local/napcat/smc"

    /// Outcome of one `smc -k KEY -r` invocation.
    enum ReadOutcome: Equatable, Sendable {
        /// Key exists and has data; bytes normalized to lowercase hex with
        /// no separators (e.g. "01000000" for CHTE, "02" for CH0B).
        case value(bytesHex: String)
        /// The vendored smc prints "no data" when the key does not exist on
        /// this machine → probe falls back to the next key family (ADR §2).
        case noData
        /// Helper missing, unlaunchable, non-zero exit, or unparseable
        /// output.
        case failed(String)
    }

    /// True when the helper is installed (setup.sh has been run).
    /// Absence → charge-limit feature state "setup required"; battery reads
    /// are IOKit-only and unaffected.
    static func helperInstalled() -> Bool {
        FileManager.default.isExecutableFile(atPath: helperPath)
    }

    /// Pure classification of the helper's output (fixture-tested).
    ///
    /// Vendored smc (third_party/smc, printVal):
    /// - key with data:  `  CHTE  [ui32]  0 (bytes 00 00 00 00)`
    /// - key w/o data:   `  CHTE  [    ]  no data`
    /// - failures:       `Error: ...` lines and/or non-zero exit.
    nonisolated static func classify(exitStatus: Int32, output: String) -> ReadOutcome {
        if output.contains("no data") { return .noData }
        if exitStatus == 0, let bytes = parseBytesHex(output) {
            return .value(bytesHex: bytes)
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed("smc read exited \(exitStatus): \(trimmed.isEmpty ? "no output" : trimmed)")
    }

    /// Pure extraction of the `(bytes xx xx ...)` suffix printed by the
    /// vendored smc, normalized to contiguous lowercase hex. nil when absent
    /// or malformed.
    nonisolated static func parseBytesHex(_ output: String) -> String? {
        guard let open = output.range(of: "(bytes"),
              let close = output.range(of: ")", range: open.upperBound..<output.endIndex)
        else { return nil }
        let pairs = output[open.upperBound..<close.lowerBound]
            .split(separator: " ")
        guard !pairs.isEmpty,
              pairs.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) })
        else { return nil }
        return pairs.joined().lowercased()
    }

    /// True when a key's bytes mean "charging inhibited" (any non-zero byte;
    /// enable values are all-zero for both families).
    nonisolated static func indicatesInhibited(bytesHex: String) -> Bool {
        bytesHex.contains { $0 != "0" }
    }

    /// Runs `\(helperPath) -k <key> -r` unprivileged and classifies the
    /// result. Blocking; the helper answers in milliseconds.
    static func readKey(_ key: String) -> ReadOutcome {
        guard helperInstalled() else {
            return .failed("helper not installed at \(helperPath)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperPath)
        process.arguments = ["-k", key, "-r"]
        let stdoutPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failed("could not launch \(helperPath): \(error.localizedDescription)")
        }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        let outcome = classify(exitStatus: process.terminationStatus, output: output)
        logger.debug("read \(key, privacy: .public) → \(String(describing: outcome), privacy: .public)")
        return outcome
    }
}
