// Pure Track B decision logic — no I/O, no subprocess, no syscalls. This file
// has NO import statements at all (only the implicitly available standard
// library), mirroring DebugPowerSimulator's isolation: the process/IOKit
// readers are elsewhere, and a structural test (ClaudeDetectionStructureTests)
// keeps every proc_* / IOPM* symbol out of this file. Table-driven tests
// (ClaudeActivityPolicyTests) exercise the mappings like HysteresisEngine.

/// One parsed `v1` marker line (`ts`, `event`, `pid`, `src`). The session id
/// is the FILE NAME, not part of the line, so it is not carried here. `src`
/// is DEBUG-ONLY and never influences any decision.
struct BusyMarker: Equatable, Sendable {
    let ts: Int
    let event: String
    let pid: Int
    let src: String
}

/// How one enumerated process classifies against "is this Claude Code?".
enum ClaudeProcessClassification: Equatable, Sendable {
    /// Executable basename is exactly `claude`.
    case confirmed
    /// Basename `node`, or the path mentions claude but the basename is not
    /// exactly `claude`, or the pid's path could not be read — anything that
    /// leaves doubt.
    case inconclusive
    /// Definitely not Claude.
    case none
}

/// Aggregate result of one process enumeration pass (see ClaudeProcessProber).
/// `enumerationSucceeded` records whether `proc_listpids` returned pids
/// without error; a per-pid path failure is folded into `inconclusiveCount`,
/// never counted as "none".
struct ProcessProbe: Equatable, Sendable {
    let enumerationSucceeded: Bool
    let confirmedCount: Int
    let inconclusiveCount: Int
}

enum ClaudeActivityPolicy {
    /// Wiring predicate (ADR §8 mirror): in debugBattery mode the detection
    /// subsystem is STRUCTURALLY absent — never constructed. Unit-tested; the
    /// app's only construction site is gated on this.
    static func detectionMayBeConstructed(debugBattery: Bool) -> Bool {
        !debugBattery
    }

    // MARK: Marker parsing (grammar: `v1 ts=<n> event=<e> pid=<n> src=<s>`)

    /// Parse one marker line. Valid iff it is exactly the five-token `v1`
    /// grammar with a non-negative numeric `ts` and numeric `pid`. Wrong
    /// version, missing/non-numeric ts, or extra tokens ⇒ nil (ignored, never
    /// counted busy).
    static func parseMarker(_ raw: String) -> BusyMarker? {
        let fields = raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        guard fields.count == 5 else { return nil }
        guard fields[0] == ClaudeBusyConstants.markerVersion else { return nil }
        guard fields[1].hasPrefix("ts="), let ts = Int(fields[1].dropFirst(3)), ts >= 0 else { return nil }
        guard fields[2].hasPrefix("event=") else { return nil }
        let event = String(fields[2].dropFirst("event=".count))
        guard !event.isEmpty else { return nil }
        guard fields[3].hasPrefix("pid="), let pid = Int(fields[3].dropFirst(4)) else { return nil }
        guard fields[4].hasPrefix("src=") else { return nil }
        let src = String(fields[4].dropFirst(4))
        guard !src.isEmpty else { return nil }
        return BusyMarker(ts: ts, event: event, pid: pid, src: src)
    }

    // MARK: Freshness + busy decision

    /// A marker counts only within `[now-12h, now]` — a stale (>12h) or
    /// future-dated marker is not fresh.
    static func markerIsFresh(ts: Int, now: Int) -> Bool {
        let age = now - ts
        return age >= 0 && age <= ClaudeBusyConstants.freshnessCapSeconds
    }

    /// FAIL-OPEN suppressor: busy is forced false ONLY when the enumeration
    /// succeeded AND found zero confirmed AND zero inconclusive Claude
    /// processes. Any doubt (enumeration failed, or any confirmed/inconclusive
    /// hit) leaves the markers standing.
    static func suppressed(_ proc: ProcessProbe) -> Bool {
        proc.enumerationSucceeded && proc.confirmedCount == 0 && proc.inconclusiveCount == 0
    }

    /// A turn is in flight iff any fresh marker exists AND the prober did not
    /// affirmatively suppress it.
    static func isTaskInFlight(markers: [BusyMarker], now: Int, proc: ProcessProbe) -> Bool {
        let hasFreshMarker = markers.contains { markerIsFresh(ts: $0.ts, now: now) }
        return hasFreshMarker && !suppressed(proc)
    }

    // MARK: Process classification

    /// Pure classifier. `nil` path = the pid's `proc_pidpath` read failed ⇒
    /// inconclusive (never "none" — a pid we cannot read is doubt, not
    /// absence).
    static func classifyProcess(path: String?) -> ClaudeProcessClassification {
        guard let path, !path.isEmpty else { return .inconclusive }
        let base = lastPathComponent(path)
        if base == "claude" { return .confirmed }
        if base == "node" { return .inconclusive }
        if path.contains("claude") { return .inconclusive }
        return .none
    }

    /// Basename of a "/"-separated path (stdlib-only; no Foundation).
    static func lastPathComponent(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return parts.last.map(String.init) ?? path
    }

    // MARK: Sleep-assertion ancestry (secondary menu line only, NOT the busy
    // signal). Pure walk with injected syscalls so it is testable headlessly;
    // the real closures live in SleepAssertionReader.

    /// Does the assertion-holder pid, or any ancestor within `maxHops`, have a
    /// basename-`claude` executable? Stops at ppid 1/0/self.
    static func ancestryReachesClaude(
        fromPID pid: Int,
        isClaude: (Int) -> Bool,
        parentOf: (Int) -> Int?,
        maxHops: Int = 10
    ) -> Bool {
        var current = pid
        var hops = 0
        while hops <= maxHops {
            if isClaude(current) { return true }
            guard let parent = parentOf(current),
                  parent != current, parent != 0, parent != 1 else { return false }
            current = parent
            hops += 1
        }
        return false
    }

    // MARK: Presentation helpers

    /// Coarse relative-time label for the hook-liveness line (stdlib-only).
    static func relativeTime(seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "just now" }
        if s < 3_600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3_600)h ago" }
        return "\(s / 86_400)d ago"
    }
}
