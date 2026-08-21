import Darwin
import Foundation
import IOKit.pwr_mgt

/// READER FILE (structural-isolation boundary): the ONLY place
/// `IOPMCopyAssertionsByProcess` / `proc_pidinfo` may appear
/// (ClaudeDetectionStructureTests enforces this). Reports whether Claude Code
/// is currently holding the Mac awake — a SECONDARY menu line only, NEVER the
/// busy signal. All reads are UNPRIVILEGED and in-process; no IOKit sleep
/// NOTIFICATION is registered (that is B2).
@MainActor
protocol SleepAssertionReader: AnyObject {
    func claudeIsHoldingAwake() -> Bool
}

@MainActor
final class IOKitSleepAssertionReader: SleepAssertionReader {
    private static let pathBufferSize = 4 * 1024 // PROC_PIDPATHINFO_MAXSIZE, not bridged to Swift

    func claudeIsHoldingAwake() -> Bool {
        var unmanaged: Unmanaged<CFDictionary>?
        let result = IOPMCopyAssertionsByProcess(&unmanaged)
        guard result == kIOReturnSuccess, let cfDict = unmanaged?.takeRetainedValue() else { return false }
        guard let byProcess = cfDict as? [NSNumber: [[String: Any]]] else { return false }

        let typeKey = kIOPMAssertionTypeKey as String
        let levelKey = kIOPMAssertionLevelKey as String
        let holdTypes: Set<String> = [
            kIOPMAssertionTypePreventUserIdleSystemSleep as String,
            kIOPMAssertionTypePreventSystemSleep as String,
        ]
        let levelOn = Int(kIOPMAssertionLevelOn)

        for (pidNumber, assertions) in byProcess {
            let holdsSleepAwake = assertions.contains { assertion in
                guard let type = assertion[typeKey] as? String, holdTypes.contains(type) else { return false }
                return (assertion[levelKey] as? Int ?? 0) == levelOn
            }
            guard holdsSleepAwake else { continue }
            let holder = pid_t(truncating: pidNumber)
            if Self.ancestryReachesClaude(fromPID: holder) { return true }
        }
        return false
    }

    /// Walk the ppid chain (≤10 hops, stop at 1/0/self) looking for a Claude
    /// Code process. The decision is the pure
    /// `ClaudeActivityPolicy.ancestryReachesClaude`; this shim supplies the two
    /// syscalls it needs. The basename match is the shared
    /// `ClaudeActivityPolicy.isClaudeExecutable` predicate (matches `claude`
    /// AND the npm launcher `claude.exe`), so it never diverges from
    /// `classifyProcess`.
    private static func ancestryReachesClaude(fromPID pid: pid_t) -> Bool {
        ClaudeActivityPolicy.ancestryReachesClaude(
            fromPID: Int(pid),
            isClaude: { ClaudeActivityPolicy.isClaudeExecutable(basename: basename(ofPID: pid_t($0)) ?? "") },
            parentOf: { parentPID(ofPID: pid_t($0)) }
        )
    }

    private static func basename(ofPID pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        let n = proc_pidpath(pid, &buffer, UInt32(pathBufferSize))
        guard n > 0 else { return nil }
        // Decode exactly the returned byte length (String(cString:) is deprecated).
        let path = buffer.prefix(Int(n)).withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        return ClaudeActivityPolicy.lastPathComponent(path)
    }

    private static func parentPID(ofPID pid: pid_t) -> Int? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let rc = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard rc == size else { return nil }
        return Int(info.pbi_ppid)
    }
}
