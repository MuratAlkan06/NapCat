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
    /// Executable basename is a Claude Code launcher — exactly `claude` (direct
    /// binary) or exactly `claude.exe` (the npm install symlinks
    /// `/opt/homebrew/bin/claude` at the resolved
    /// `@anthropic-ai/claude-code/bin/claude.exe`, and `proc_pidpath` resolves
    /// the symlink). See `ClaudeActivityPolicy.isClaudeExecutable`.
    case confirmed
    /// Name/basename `node`, or the image mentions claude but the basename is
    /// not exactly `claude`, or the pid's name AND path could not be read —
    /// anything that leaves doubt.
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

    /// How many sessions are busy right now (one fresh marker = one session).
    /// B2 puts this COUNT — and nothing else from any session — into the
    /// lid-close message body.
    static func freshMarkerCount(markers: [BusyMarker], now: Int) -> Int {
        markers.filter { markerIsFresh(ts: $0.ts, now: now) }.count
    }

    // MARK: Process classification

    /// The two real basenames a RUNNING Claude Code worker's executable
    /// resolves to: `claude` (a direct binary) and `claude.exe` (the launcher
    /// the standard npm install's `/opt/homebrew/bin/claude` symlink points at
    /// — `proc_pidpath`/`lsof txt` report the resolved image, not the symlink).
    /// SINGLE SOURCE OF TRUTH for both `classifyProcess` and the
    /// `SleepAssertionReader` ancestry match, so the set is never duplicated.
    static let claudeExecutableNames: Set<String> = ["claude", "claude.exe"]

    /// True iff `basename` is EXACTLY one of the Claude Code launcher names.
    /// Deliberately not a prefix/substring test: `claude-utils` / `claudexyz`
    /// must NOT confirm here (they may still land as `inconclusive` via the
    /// path-contains branch — the safe, fail-open direction).
    static func isClaudeExecutable(basename: String) -> Bool {
        claudeExecutableNames.contains(basename)
    }

    /// Pure classifier. `name` is the process accounting NAME (`proc_pidinfo`
    /// `pbi_name`), which is readable even for hardened-runtime images where
    /// `proc_pidpath` returns ESRCH (the real Claude Code worker — B1.2); it is
    /// the PRIMARY signal. `path` is the best-effort `proc_pidpath` image (may
    /// be `nil` when introspection failed) used only for the fail-open
    /// path-mentions-claude tier. If NEITHER is readable ⇒ inconclusive (never
    /// "none" — a pid we cannot read is doubt, not absence).
    static func classifyProcess(name: String?, path: String?) -> ClaudeProcessClassification {
        let name = name.flatMap { $0.isEmpty ? nil : $0 }
        let pathBase = path.flatMap { $0.isEmpty ? nil : lastPathComponent($0) }
        // Unreadable pid: neither introspection call yielded anything.
        guard name != nil || pathBase != nil else { return .inconclusive }
        if let name, isClaudeExecutable(basename: name) { return .confirmed }
        if let pathBase, isClaudeExecutable(basename: pathBase) { return .confirmed }
        if name == "node" || pathBase == "node" { return .inconclusive }
        // Basename is not an exact launcher, but the image (or truncated name)
        // still mentions claude — leave doubt rather than claim absence.
        if let path, path.contains("claude") { return .inconclusive }
        if let name, name.contains("claude") { return .inconclusive }
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
    /// Claude Code executable (see `isClaudeExecutable`: `claude` or
    /// `claude.exe`)? Stops at ppid 1/0/self.
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
