import Darwin

/// READER FILE (structural-isolation boundary): the ONLY place `proc_listpids`
/// may appear; `proc_pidpath` is confined here and `proc_pidinfo` here and in
/// SleepAssertionReader (ClaudeDetectionStructureTests enforces this).
/// Enumerates the current user's processes in-process and UNPRIVILEGED — no
/// subprocess, no `ps`. Classification itself is the pure
/// `ClaudeActivityPolicy.classifyProcess`, so this file is only the syscall
/// shim.
@MainActor
protocol ClaudeProcessProber: AnyObject {
    /// One enumeration pass. Never throws; enumeration failure is reported in
    /// the result, not by returning a false "none".
    func probe() -> ProcessProbe
}

@MainActor
final class LibprocProcessProber: ClaudeProcessProber {
    /// `PROC_PIDPATHINFO_MAXSIZE` (4 * MAXPATHLEN) is not bridged into Swift
    /// (the macro is marked unavailable), so its value is inlined here.
    private static let pathBufferSize = 4 * 1024

    func probe() -> ProcessProbe {
        let stride = MemoryLayout<pid_t>.stride

        // Size the buffer from the kernel, then read with headroom for pids
        // that appear between the two calls.
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else {
            return ProcessProbe(enumerationSucceeded: false, confirmedCount: 0, inconclusiveCount: 0)
        }
        let capacity = Int(needed) / stride + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let got = pids.withUnsafeMutableBufferPointer { buffer -> Int32 in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count * stride))
        }
        guard got > 0 else {
            return ProcessProbe(enumerationSucceeded: false, confirmedCount: 0, inconclusiveCount: 0)
        }

        let count = min(Int(got) / stride, pids.count)
        var confirmed = 0
        var inconclusive = 0
        var pathBuffer = [CChar](repeating: 0, count: Self.pathBufferSize)
        for i in 0..<count {
            let pid = pids[i]
            if pid <= 0 { continue }
            // PRIMARY: the accounting NAME via proc_pidinfo pbi_name — readable
            // even for the hardened-runtime Claude worker where proc_pidpath
            // returns ESRCH (B1.2).
            let name = Self.processName(ofPID: pid)
            // BEST-EFFORT SECONDARY: the resolved image path for the
            // path-mentions-claude fail-open tier. ESRCH ⇒ nil; the pid is
            // still classified on its name.
            let n = proc_pidpath(pid, &pathBuffer, UInt32(Self.pathBufferSize))
            // proc_pidpath returns the byte length written (no NUL); decode
            // exactly that (String(cString:) is deprecated).
            let path: String? = n > 0
                ? pathBuffer.prefix(Int(n)).withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
                : nil
            switch ClaudeActivityPolicy.classifyProcess(name: name, path: path) {
            case .confirmed: confirmed += 1
            case .inconclusive: inconclusive += 1
            case .none: break
            }
        }
        return ProcessProbe(enumerationSucceeded: true, confirmedCount: confirmed, inconclusiveCount: inconclusive)
    }

    /// The process accounting NAME via `proc_pidinfo(PROC_PIDTBSDINFO)`
    /// `pbi_name` (falling back to `pbi_comm`) — the B1.2 primary classifier
    /// input. `nil` when the read fails (folded into inconclusive by the pure
    /// classifier, never "none").
    private static func processName(ofPID pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let rc = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard rc == size else { return nil }
        return cName(info.pbi_name) ?? cName(info.pbi_comm)
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
