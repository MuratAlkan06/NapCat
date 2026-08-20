import Testing
@testable import NapCat

/// Pure Track B decision logic (ClaudeActivityPolicy) + the READ-ONLY menu
/// presentation mappings. Table-driven like HysteresisEngineTests; no I/O,
/// no processes, no IOKit. (Pure stdlib types only — no AppKit/Foundation
/// import needed, matching HysteresisEngineTests.)
struct ClaudeActivityPolicyTests {
    private static let now = 1_000_000
    private static let cap = ClaudeBusyConstants.freshnessCapSeconds

    private static func marker(ts: Int) -> BusyMarker {
        BusyMarker(ts: ts, event: "UserPromptSubmit", pid: 1234, src: "unknown")
    }

    // MARK: isTaskInFlight — markers × proc table

    struct Row: Sendable, CustomTestStringConvertible {
        let id: String
        let markerState: String
        let markers: [BusyMarker]
        let procState: String
        let proc: ProcessProbe
        let expected: Bool

        var testDescription: String {
            "\(id): markers=\(markerState) × proc=\(procState) → \(expected)"
        }
    }

    static let confirmed = ProcessProbe(enumerationSucceeded: true, confirmedCount: 1, inconclusiveCount: 0)
    static let inconclusive = ProcessProbe(enumerationSucceeded: true, confirmedCount: 0, inconclusiveCount: 1)
    static let noneFound = ProcessProbe(enumerationSucceeded: true, confirmedCount: 0, inconclusiveCount: 0)
    static let enumFailed = ProcessProbe(enumerationSucceeded: false, confirmedCount: 0, inconclusiveCount: 0)

    static let fresh = [marker(ts: now - 60)]
    static let validBoundary = [marker(ts: now - cap)]        // exactly 12h old → still valid
    static let stale = [marker(ts: now - cap - 1)]            // >12h → not fresh
    static let future = [marker(ts: now + 60)]                // clock skew → not fresh
    static let absent: [BusyMarker] = []                      // also the "malformed" case (unparseable → not in array)

    static let table: [Row] = [
        // fresh marker × every proc state — suppressor only bites on noneFound
        Row(id: "F-confirmed", markerState: "fresh", markers: fresh, procState: "confirmed", proc: confirmed, expected: true),
        Row(id: "F-inconclusive", markerState: "fresh", markers: fresh, procState: "inconclusive", proc: inconclusive, expected: true),
        Row(id: "F-none", markerState: "fresh", markers: fresh, procState: "none(succeeded,0,0)", proc: noneFound, expected: false),
        Row(id: "F-enumFailed", markerState: "fresh", markers: fresh, procState: "enumeration-failed", proc: enumFailed, expected: true),
        // 12h-boundary marker is still valid
        Row(id: "V-confirmed", markerState: "valid-boundary(12h)", markers: validBoundary, procState: "confirmed", proc: confirmed, expected: true),
        Row(id: "V-none", markerState: "valid-boundary(12h)", markers: validBoundary, procState: "none(succeeded,0,0)", proc: noneFound, expected: false),
        // stale marker never counts, regardless of proc
        Row(id: "S-confirmed", markerState: "stale(>12h)", markers: stale, procState: "confirmed", proc: confirmed, expected: false),
        Row(id: "S-enumFailed", markerState: "stale(>12h)", markers: stale, procState: "enumeration-failed", proc: enumFailed, expected: false),
        // future-dated marker never counts
        Row(id: "U-confirmed", markerState: "future", markers: future, procState: "confirmed", proc: confirmed, expected: false),
        Row(id: "U-enumFailed", markerState: "future", markers: future, procState: "enumeration-failed", proc: enumFailed, expected: false),
        // absent / malformed → no fresh marker
        Row(id: "A-confirmed", markerState: "absent", markers: absent, procState: "confirmed", proc: confirmed, expected: false),
        Row(id: "A-enumFailed", markerState: "absent/malformed", markers: absent, procState: "enumeration-failed", proc: enumFailed, expected: false),
    ]

    @Test(arguments: table)
    func isTaskInFlightRow(_ row: Row) {
        let result = ClaudeActivityPolicy.isTaskInFlight(markers: row.markers, now: Self.now, proc: row.proc)
        #expect(result == row.expected, "\(row.testDescription)")
    }

    // MARK: Suppressor — fires ONLY on (succeeded ∧ 0 confirmed ∧ 0 inconclusive)

    @Test func suppressorFiresOnlyWhenEnumerationSucceededAndZeroBoth() {
        #expect(ClaudeActivityPolicy.suppressed(Self.noneFound))
        #expect(!ClaudeActivityPolicy.suppressed(Self.confirmed))
        #expect(!ClaudeActivityPolicy.suppressed(Self.inconclusive))
        // The fail-open case: enumeration failed with zero/zero must NOT suppress.
        #expect(!ClaudeActivityPolicy.suppressed(Self.enumFailed))
        #expect(!ClaudeActivityPolicy.suppressed(ProcessProbe(enumerationSucceeded: false, confirmedCount: 0, inconclusiveCount: 0)))
    }

    // MARK: Freshness boundaries

    @Test func freshnessBoundaries() {
        #expect(ClaudeActivityPolicy.markerIsFresh(ts: Self.now, now: Self.now))
        #expect(ClaudeActivityPolicy.markerIsFresh(ts: Self.now - Self.cap, now: Self.now), "exactly 12h old is still valid")
        #expect(!ClaudeActivityPolicy.markerIsFresh(ts: Self.now - Self.cap - 1, now: Self.now), ">12h is stale")
        #expect(!ClaudeActivityPolicy.markerIsFresh(ts: Self.now + 1, now: Self.now), "future is not fresh")
    }

    // MARK: Process classification fixtures

    @Test func classificationFixtures() {
        #expect(ClaudeActivityPolicy.classifyProcess(path: "/usr/local/bin/claude") == .confirmed)
        #expect(ClaudeActivityPolicy.classifyProcess(path: "/Users/x/.claude/local/node_modules/.bin/claude") == .confirmed)
        #expect(ClaudeActivityPolicy.classifyProcess(path: "/opt/homebrew/bin/node") == .inconclusive)
        #expect(ClaudeActivityPolicy.classifyProcess(path: "/opt/claude-tools/bin/wrapper") == .inconclusive,
                "path mentions claude but basename is not claude")
        #expect(ClaudeActivityPolicy.classifyProcess(path: "/usr/bin/vim") == .none)
        #expect(ClaudeActivityPolicy.classifyProcess(path: "/usr/local/bin/nodejs") == .none,
                "basename 'nodejs' is not 'node' and has no claude in the path")
        #expect(ClaudeActivityPolicy.classifyProcess(path: nil) == .inconclusive, "unreadable pid → inconclusive, never none")
        #expect(ClaudeActivityPolicy.classifyProcess(path: "") == .inconclusive)
    }

    @Test func lastPathComponentIsStdlibOnly() {
        #expect(ClaudeActivityPolicy.lastPathComponent("/usr/local/bin/claude") == "claude")
        #expect(ClaudeActivityPolicy.lastPathComponent("claude") == "claude")
        #expect(ClaudeActivityPolicy.lastPathComponent("/trailing/") == "trailing")
    }

    // MARK: Sleep-assertion ancestry walk (pure; syscalls injected)

    @Test func ancestryDirectHolderIsClaude() {
        #expect(ClaudeActivityPolicy.ancestryReachesClaude(
            fromPID: 42, isClaude: { $0 == 42 }, parentOf: { _ in 1 }))
    }

    @Test func ancestryParentIsClaude() {
        // caffeinate(42) ← claude(7) ← launchd(1)
        let parents = [42: 7, 7: 1]
        #expect(ClaudeActivityPolicy.ancestryReachesClaude(
            fromPID: 42, isClaude: { $0 == 7 }, parentOf: { parents[$0] }))
    }

    @Test func ancestryNoClaudeStopsAtLaunchd() {
        let parents = [42: 9, 9: 1]
        #expect(!ClaudeActivityPolicy.ancestryReachesClaude(
            fromPID: 42, isClaude: { _ in false }, parentOf: { parents[$0] }))
    }

    @Test func ancestryStopsOnSelfCycleAndHopCap() {
        // self-cycle: parent == self must terminate, not loop
        #expect(!ClaudeActivityPolicy.ancestryReachesClaude(
            fromPID: 5, isClaude: { $0 == 999 }, parentOf: { _ in 5 }))
        // long chain beyond maxHops: claude is 12 hops up, cap is 10 → not found
        #expect(!ClaudeActivityPolicy.ancestryReachesClaude(
            fromPID: 0, isClaude: { $0 == 100 }, parentOf: { $0 < 100 ? $0 + 1 : nil }, maxHops: 10))
    }

    // MARK: Debug-sim wiring predicate

    @Test func detectionAbsentInDebugMode() {
        #expect(ClaudeActivityPolicy.detectionMayBeConstructed(debugBattery: false))
        #expect(!ClaudeActivityPolicy.detectionMayBeConstructed(debugBattery: true))
    }

    // MARK: Presentation fixtures (running / idle / awake / paused / not-installed)

    @Test func relativeTimeBuckets() {
        #expect(ClaudeActivityPolicy.relativeTime(seconds: 0) == "just now")
        #expect(ClaudeActivityPolicy.relativeTime(seconds: 59) == "just now")
        #expect(ClaudeActivityPolicy.relativeTime(seconds: 65) == "1m ago")
        #expect(ClaudeActivityPolicy.relativeTime(seconds: 3_700) == "1h ago")
        #expect(ClaudeActivityPolicy.relativeTime(seconds: 90_000) == "1d ago")
        #expect(ClaudeActivityPolicy.relativeTime(seconds: -5) == "just now", "negative skew clamps")
    }

    @Test func taskLinePresentation() {
        #expect(MenuStateModel.claudeTaskLine(inFlight: true, paused: false) == "Claude task: running")
        #expect(MenuStateModel.claudeTaskLine(inFlight: false, paused: false) == "Claude task: idle")
        #expect(MenuStateModel.claudeTaskLine(inFlight: true, paused: true) == "Claude task: detection paused",
                "pause takes precedence over running")
    }

    @Test func awakeLinePresentation() {
        #expect(MenuStateModel.claudeAwakeLine(holding: true) == "Keeping Mac awake: yes")
        #expect(MenuStateModel.claudeAwakeLine(holding: false) == "Keeping Mac awake: no")
    }

    @Test func hookLinePresentation() {
        #expect(MenuStateModel.claudeHookLine(installed: false, everSeen: false, lastSeenSeconds: nil)
                == "Busy hook: not installed — run scripts/install-claude-busy-hook.sh")
        #expect(MenuStateModel.claudeHookLine(installed: true, everSeen: false, lastSeenSeconds: nil)
                == "Busy hook: not seen yet — run scripts/install-claude-busy-hook.sh")
        #expect(MenuStateModel.claudeHookLine(installed: true, everSeen: true, lastSeenSeconds: 65)
                == "Busy hook: last seen 1m ago")
    }
}
