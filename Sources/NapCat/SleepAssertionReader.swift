import Darwin
import Foundation
import IOKit.pwr_mgt

/// READER FILE (structural-isolation boundary): the ONLY place
/// `IOPMCopyAssertionsByProcess` may appear, and (with ClaudeProcessProber) one
/// of two places `proc_pidinfo` may appear (ClaudeDetectionStructureTests
/// enforces this). Reports whether Claude Code is currently holding the Mac
/// awake — a SECONDARY menu line only, NEVER the busy signal. All reads are
/// UNPRIVILEGED and in-process; no IOKit sleep NOTIFICATION is registered
/// (that is B2).
@MainActor
protocol SleepAssertionReader: AnyObject {
    func claudeIsHoldingAwake() -> Bool
}

@MainActor
final class IOKitSleepAssertionReader: SleepAssertionReader {
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
    /// syscalls it needs from ONE `proc_pidinfo(PROC_PIDTBSDINFO)` per hop —
    /// `pbi_name` (the executable NAME) feeds the isClaude predicate and
    /// `pbi_ppid` feeds the walk. `pbi_name` is readable even for the
    /// hardened-runtime Claude worker, where `proc_pidpath` returns ESRCH and
    /// so the old basename read silently missed it (B1.2). A per-walk memo
    /// keeps it to one syscall per distinct pid. The name match is the shared
    /// `ClaudeActivityPolicy.isClaudeExecutable` predicate (matches `claude`
    /// AND the npm launcher `claude.exe`), so it never diverges from
    /// `classifyProcess`.
    private static func ancestryReachesClaude(fromPID pid: pid_t) -> Bool {
        var memo: [Int: (name: String?, ppid: Int?)] = [:]
        func info(_ p: Int) -> (name: String?, ppid: Int?) {
            if let hit = memo[p] { return hit }
            let v = bsdInfo(ofPID: pid_t(p))
            memo[p] = v
            return v
        }
        return ClaudeActivityPolicy.ancestryReachesClaude(
            fromPID: Int(pid),
            isClaude: { ClaudeActivityPolicy.isClaudeExecutable(basename: info($0).name ?? "") },
            parentOf: { info($0).ppid }
        )
    }

    /// One `proc_pidinfo(PROC_PIDTBSDINFO)` yields BOTH the executable NAME
    /// (`pbi_name`, falling back to `pbi_comm`) and the parent pid (`pbi_ppid`).
    /// Reading the NAME here — not `proc_pidpath` — is the B1.2 fix.
    private static func bsdInfo(ofPID pid: pid_t) -> (name: String?, ppid: Int?) {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let rc = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard rc == size else { return (nil, nil) }
        let name = cName(info.pbi_name) ?? cName(info.pbi_comm)
        return (name, Int(info.pbi_ppid))
    }

    /// Decode a fixed-size C `char[]` field (imported as a Swift tuple) up to
    /// its first NUL as UTF-8; `nil` if empty. `String(cString:)` is deprecated.
    private static func cName<T>(_ field: T) -> String? {
        withUnsafeBytes(of: field) { raw -> String? in
            let bytes = raw.prefix { $0 != 0 }
            return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
        }
    }
}
