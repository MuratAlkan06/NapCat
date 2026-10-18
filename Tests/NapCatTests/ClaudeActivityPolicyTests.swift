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
        // Name-primary: the executable NAME (proc_pidinfo pbi_name) is the main
        // signal — readable even when proc_pidpath ESRCHes (B1.2).
        #expect(ClaudeActivityPolicy.classifyProcess(name: "claude", path: "/usr/local/bin/claude") == .confirmed)
        #expect(ClaudeActivityPolicy.classifyProcess(name: "claude", path: "/Users/x/.claude/local/node_modules/.bin/claude") == .confirmed)
        // The standard npm install resolves the running worker to basename
        // claude.exe (B1.1); pbi_name reports it directly.
        #expect(ClaudeActivityPolicy.classifyProcess(name: "claude.exe", path: "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe") == .confirmed,
                "npm launcher name claude.exe confirms")
        #expect(ClaudeActivityPolicy.classifyProcess(name: "node", path: "/opt/homebrew/bin/node") == .inconclusive)
        #expect(ClaudeActivityPolicy.classifyProcess(name: "claude-utils", path: "/opt/claude-tools/bin/claude-utils") == .inconclusive,
                "name/path mention claude but basename claude-utils is not an exact launcher → inconclusive, NOT confirmed")
        // Best-effort SECONDARY path tier (proc_pidpath): a non-claude NAME
        // whose readable image path still mentions claude stays inconclusive.
        #expect(ClaudeActivityPolicy.classifyProcess(name: "helper", path: "/opt/claude-runtime/bin/helper") == .inconclusive,
                "path-contains-claude secondary tier keeps doubt even when the name is unremarkable")
        #expect(ClaudeActivityPolicy.classifyProcess(name: "vim", path: "/usr/bin/vim") == .none)
        #expect(ClaudeActivityPolicy.classifyProcess(name: "bash", path: "/bin/bash") == .none)
        #expect(ClaudeActivityPolicy.classifyProcess(name: "nodejs", path: "/usr/local/bin/nodejs") == .none,
                "basename 'nodejs' is not 'node' and has no claude in name or path")
        #expect(ClaudeActivityPolicy.classifyProcess(name: nil, path: nil) == .inconclusive, "unreadable pid → inconclusive, never none")
        #expect(ClaudeActivityPolicy.classifyProcess(name: "", path: "") == .inconclusive)
    }

    // B1.2 CANARY — the exact hardware failure at the classifier. The Claude
    // worker's hardened-runtime image makes proc_pidpath return ESRCH
    // (path == nil), yet proc_pidinfo pbi_name reads "claude.exe". Name-primary
    // classification must CONFIRM it. Under the OLD proc_pidpath-only classifier
    // the same worker (path nil) fell through to inconclusive — accidental
    // correctness that rendered "Keeping Mac awake: no". Reverting
    // classifyProcess to ignore `name` makes this #expect fail.
    @Test func claudeWorkerWithUnreadablePathIsConfirmedByName() {
        #expect(ClaudeActivityPolicy.classifyProcess(name: "claude.exe", path: nil) == .confirmed,
                "hardened-runtime claude.exe (proc_pidpath ESRCH) confirmed via pbi_name")
        #expect(ClaudeActivityPolicy.classifyProcess(name: "claude", path: nil) == .confirmed)
    }

    // MARK: Shared claude-executable predicate (B1.1 single source of truth)

    @Test func claudeExecutablePredicate() {
        #expect(ClaudeActivityPolicy.isClaudeExecutable(basename: "claude"), "direct binary")
        #expect(ClaudeActivityPolicy.isClaudeExecutable(basename: "claude.exe"), "npm symlink-resolved launcher")
        #expect(!ClaudeActivityPolicy.isClaudeExecutable(basename: "node"))
        #expect(!ClaudeActivityPolicy.isClaudeExecutable(basename: "claude-utils"), "prefix is not an exact launcher name")
        #expect(!ClaudeActivityPolicy.isClaudeExecutable(basename: "claudexyz"), "substring is not an exact launcher name")
        #expect(!ClaudeActivityPolicy.isClaudeExecutable(basename: "bash"))
        #expect(!ClaudeActivityPolicy.isClaudeExecutable(basename: ""))
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

    // B1.1: the reader keys its isClaude closure off the executable basename
    // via isClaudeExecutable, so an ancestor whose image resolves to the npm
    // launcher `claude.exe` must be attributed to Claude. These mirror the
    // reader's wiring (basename → predicate) so they canary the exact gap the
    // H3 spike found: with the old basename-exactly-`claude` match these fail.
    @Test func ancestryReachesClaudeExeAncestor() {
        // caffeinate(42) ← claude.exe(7) ← launchd(1)
        let parents = [42: 7, 7: 1]
        let basenames = [42: "caffeinate", 7: "claude.exe", 1: "launchd"]
        #expect(ClaudeActivityPolicy.ancestryReachesClaude(
            fromPID: 42,
            isClaude: { ClaudeActivityPolicy.isClaudeExecutable(basename: basenames[$0] ?? "") },
            parentOf: { parents[$0] }),
            "a claude.exe ancestor holding the assertion counts as Claude keeping the Mac awake")
    }

    @Test func ancestryNoClaudeExecutableIsNotAttributed() {
        // caffeinate(42) ← bash(9) ← superconductor(3) ← launchd(1): no
        // claude/claude.exe basename anywhere → not attributed to Claude.
        let parents = [42: 9, 9: 3, 3: 1]
        let basenames = [42: "caffeinate", 9: "bash", 3: "superconductor", 1: "launchd"]
        #expect(!ClaudeActivityPolicy.ancestryReachesClaude(
            fromPID: 42,
            isClaude: { ClaudeActivityPolicy.isClaudeExecutable(basename: basenames[$0] ?? "") },
            parentOf: { parents[$0] }))
    }

    // B1.2 CANARY — assertion ancestry for the same unreadable-path worker.
    // caffeinate(42) holds PreventUserIdleSystemSleep ← claude worker(7) ←
    // launchd(1). pbi_name for pid 7 is "claude.exe"; proc_pidpath ESRCHes → "".
    // The reader now keys isClaude off pbi_name, so the assertion is attributed
    // to Claude ("Keeping Mac awake: yes"). The OLD proc_pidpath-basename wiring
    // saw "" and missed it ("no"). Both wirings run on the SAME chain here.
    @Test func ancestryAttributesClaudeWorkerWithUnreadablePath() {
        let parents = [42: 7, 7: 1]
        let pbiName = [42: "caffeinate", 7: "claude.exe", 1: "launchd"]   // proc_pidinfo (readable)
        let pidpathBasename = [42: "caffeinate", 7: "", 1: "launchd"]     // proc_pidpath ESRCH → ""

        #expect(!ClaudeActivityPolicy.ancestryReachesClaude(
            fromPID: 42,
            isClaude: { ClaudeActivityPolicy.isClaudeExecutable(basename: pidpathBasename[$0] ?? "") },
            parentOf: { parents[$0] }),
            "OLD proc_pidpath-basename wiring cannot see the hardened-runtime claude worker")

        #expect(ClaudeActivityPolicy.ancestryReachesClaude(
            fromPID: 42,
            isClaude: { ClaudeActivityPolicy.isClaudeExecutable(basename: pbiName[$0] ?? "") },
            parentOf: { parents[$0] }),
            "NEW pbi_name wiring attributes the assertion to the claude worker → Keeping Mac awake: yes")
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

    /// Migrated 1:1 from the old `claudeTaskLine` + `claudeAwakeLine` pair
    /// (2026-10-18 redesign merged them into the single top-level row).
    @Test func statusLineCoversTheOldTaskFacts() {
        #expect(MenuStateModel.claudeStatusLine(inFlight: true, holdingAwake: false, paused: false)
                == PanelLine(text: "Claude: running", severity: .nominal))
        #expect(MenuStateModel.claudeStatusLine(inFlight: false, holdingAwake: false, paused: false)
                == PanelLine(text: "Claude: idle", severity: .nominal))
        #expect(MenuStateModel.claudeStatusLine(inFlight: true, holdingAwake: true, paused: true).text
                == "Detection paused", "pause takes precedence over running")
    }

    /// The sleep-assertion reader is NOT the busy signal: "keeping Mac awake"
    /// is reported whether or not a task is in flight, and never invented.
    @Test func statusLineCoversTheOldAwakeFacts() {
        #expect(MenuStateModel.claudeStatusLine(inFlight: true, holdingAwake: true, paused: false).text
                == "Claude: running — keeping Mac awake")
        #expect(MenuStateModel.claudeStatusLine(inFlight: false, holdingAwake: true, paused: false).text
                == "Claude: idle — keeping Mac awake")
        for inFlight in [true, false] {
            #expect(!MenuStateModel.claudeStatusLine(inFlight: inFlight, holdingAwake: false, paused: false)
                .text.contains("awake"))
        }
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
