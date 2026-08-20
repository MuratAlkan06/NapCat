import Darwin

/// READER FILE (structural-isolation boundary): the ONLY place `proc_listpids`
/// / `proc_pidpath` may appear (ClaudeDetectionStructureTests enforces this).
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
            let n = proc_pidpath(pid, &pathBuffer, UInt32(Self.pathBufferSize))
            // proc_pidpath returns the byte length written (no NUL); decode
            // exactly that (String(cString:) is deprecated).
            let path: String? = n > 0
                ? pathBuffer.prefix(Int(n)).withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
                : nil
            switch ClaudeActivityPolicy.classifyProcess(path: path) {
            case .confirmed: confirmed += 1
            case .inconclusive: inconclusive += 1
            case .none: break
            }
        }
        return ProcessProbe(enumerationSucceeded: true, confirmedCount: confirmed, inconclusiveCount: inconclusive)
    }
}
