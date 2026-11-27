import Foundation

// Pure Track C decision logic for the Claude finish alert and the waiting
// buzz: marker-set diffing, the hook v7 episode-start check, the run floor
// (60 s by default, user-adjustable — issue #34), the 12 h stale cap, the
// batch digest, the outbox and retry tables,
// and the arming/display predicates — plus alert-channel healing (issue #23):
// the offline-hold state machine, its arming predicate, the held digest's max
// age and the lost-connection restore push — and the F4 rule for when a
// waiting buzz yields to the phone's own prompt push (counts only).
// I/O-free by construction — no filesystem, no timers, no network, no
// subprocess, no logging, no defaults reads. `FinishAlertStructureTests` locks
// that (canary-proven), and `FinishAlertPolicyTests` exercises every rule as a
// table row like `HysteresisEngine`. The only `import` is Foundation (for
// `TimeInterval`).
//
// Session ids are INTERNAL DIFF KEYS: they key the tracked map and nothing
// else. Every value that leaves this file toward a message is an Int count or
// minutes (`FinishAlertEvent`, `FinishAlertDigest`, `LidGuardMessageKind`).

/// Track C tunables. CODE CONSTANTS, not UserDefaults keys — Track C persists
/// only the `claudeFinishAlertEnabled` toggle and the run floor
/// (`finishAlertMinimumRunSeconds`, issue #34), whose DEFAULT and bounds live
/// here.
enum FinishAlertTuning {
    /// Run-length floor DEFAULT (user ruling): a run shorter than the floor
    /// never alerts — neither a finish nor a waiting buzz (you are still
    /// looking). Raised from 30 to 60 on 2026-10-23 by user ruling; a run of
    /// exactly 60 s with an exact anchor reads "1 min"
    /// (`minutes(duration:exact:)`). Since issue #34 the LIVE floor is the
    /// user's `finishAlertMinimumRunSeconds` setting, read through
    /// `FinishAlertPolicy.minimumRunSeconds(stored:)` and passed to `observe`;
    /// this is what an unset or unusable stored value reads as.
    static let minimumRunSeconds = 60
    /// Issue #34: the adjustable floor's bounds (30 s – 10 min). A stored value
    /// outside them is clamped on read.
    static let minimumRunSecondsRange = 30...600
    /// One-shot debounce armed ONLY by a filesystem event — never periodic
    /// (B1 amendment, PLAN.md Track C).
    static let debounceSeconds: TimeInterval = 2
    /// After a send, further events fold into one digest for this long.
    static let batchWindowSeconds: TimeInterval = 30
    /// The single retry of a `.sendFailed` publish waits this long.
    static let retryDelaySeconds: TimeInterval = 30
    /// A retry whose originating event is older than this is dropped.
    static let retryMaxAgeSeconds: TimeInterval = 300
    /// B-1: after ntfy answers a session send with HTTP 429, the batch window
    /// is held open this long — later events fold into ONE digest that goes
    /// out when the hold ends (the lid lane has no hold).
    static let rateLimitHoldSeconds: TimeInterval = 600
    /// A disappearance whose last-known marker ts is older than this is the
    /// hook's sweep, not a finish (same 12 h cap as marker freshness).
    static let staleCapSeconds = ClaudeBusyConstants.freshnessCapSeconds
}

/// What the watcher remembers about one present session between two
/// observations. Keyed by session id in a `[String: TrackedSession]` map.
struct TrackedSession: Equatable, Sendable {
    /// Epoch seconds anchoring the current busy EPISODE's start: set when the
    /// id first appears and never moved while it stays present (C3 rule 2).
    /// Hook v7: the marker's valid `ep` when it has one, else its own ts.
    var firstSeen: Int
    /// True iff `firstSeen` came from a valid hook v7 `ep` or from an
    /// OBSERVED `event=UserPromptSubmit` marker (otherwise it is only "when
    /// we first saw it" — minutes unknown).
    var exactStart: Bool
    /// The marker `ts` / `event` as last observed.
    var lastTs: Int
    var lastEvent: String
    /// Once-per-episode dedupe for the waiting buzz.
    var waitingBuzzed: Bool
}

/// An alert-worthy transition. Minutes only — never a session id.
enum FinishAlertEvent: Equatable, Sendable {
    /// A session's marker disappeared after a run of at least the floor.
    case finished(minutes: Int?)
    /// A session's marker transitioned to `event=waiting` at least the floor
    /// into its run.
    case waiting(minutes: Int?)
}

/// Why a transition produced no event (log-safe reason, never an id).
enum FinishAlertSuppression: String, Equatable, Sendable {
    /// Shorter than the run floor (`observe`'s `minimumRunSeconds`).
    case underMinimumRun
    /// Last-known marker ts older than the 12 h cap: the hook's sweep.
    case stale
    /// Negative duration: the wall clock went backwards.
    case clockJump
}

/// Result of one diff. `tracked` replaces the caller's previous map.
struct FinishAlertObservation: Equatable, Sendable {
    let tracked: [String: TrackedSession]
    /// Waiting events (present ids, sorted by id) first, then finished events
    /// (disappeared ids, sorted by id).
    let events: [FinishAlertEvent]
    let suppressed: [FinishAlertSuppression]
    /// Sessions in `tracked` whose last marker ts is FRESH
    /// (`ClaudeActivityPolicy.markerIsFresh` — the same rule as the B1/B2
    /// busy count). A session waiting on the user still has its marker and
    /// IS counted; `FinishAlertDigest.messages()` subtracts the waiting
    /// session itself for the `.needsAttention` "others" count.
    let stillWorking: Int
    /// Hook v7: ids seen for the FIRST time in this diff whose marker carried
    /// an `ep` the policy rejected (`EpisodeStartReading.invalid`) — they fell
    /// back to the pre-v7 anchor. A count for the controller's log line only.
    let invalidEpisodeStarts: Int
    /// F4: how many present ids WROTE a waiting marker (either waiting token)
    /// in this diff, one each at most — the first input of
    /// `FinishAlertPolicy.waitingBuzzYieldsToPromptPush`. Counted:
    /// - every transition into waiting (from a non-waiting token, or a new id
    ///   already waiting), whatever rule 4 of `observe` then makes of it: a
    ///   `.waiting` event, or a suppression under the run floor or for a
    ///   clock jump;
    /// - a waiting marker rewritten while waiting, never an event: its ts
    ///   differs from the one last observed, or its token changed between
    ///   the two waiting tokens.
    /// Not counted: a waiting marker read again with the same ts and token
    /// (a rewrite in the same second, as the diff sees it, is no write), any
    /// non-waiting marker, and a disappearance. The arm-time baseline counts
    /// nothing.
    let waitingWrites: Int
}

/// F4: what one read of the seam's recent prompts tells the alert lane
/// (`RemoteApprovalsController.waitingPrompts`): Int counts only, never a
/// prompt's ID, preview or session. `.none` while remote approvals are off
/// or not listening, and for a diff the lane does not read for.
struct WaitingPromptContext: Equatable, Sendable {
    /// Per kind, the prompts the gate would forward that opened in the last
    /// 30 s, from sessions still connected: what a waiting push counts.
    var counts = WaitingPromptCounts.none
    /// Of `counts`, per kind, the prompts with evidence that the phone's own
    /// prompt push covers them, over the same 30 s.
    var countsWithEvidence = WaitingPromptCounts.none
    /// The prompts relayed since the previous read and in the last 10 s,
    /// whatever the gate made of them.
    var newPrompts = 0
    /// Of `newPrompts`, the ones known to have that evidence.
    var newPromptsWithEvidence = 0

    static let none = WaitingPromptContext()
}

/// Hook v7: what one marker's RAW `ep` text says about its episode start.
/// Log-safe by construction: `.invalid` never carries the raw value.
enum EpisodeStartReading: Equatable, Sendable {
    /// No `ep` field — a hook v6 or earlier marker. The pre-v7 anchor applies,
    /// silently.
    case absent
    /// Present but unusable: not 1–10 ASCII digits, zero, in the future, or
    /// older than the 12 h horizon. The pre-v7 anchor applies, and it is
    /// counted for the log.
    case invalid
    /// A usable episode start (epoch seconds).
    case valid(Int)
}

/// Events folded inside one batch window, flushed as at most two messages.
struct FinishAlertDigest: Equatable, Sendable {
    var finishedCount = 0
    /// Minutes of the FIRST folded finish (used only when it is the only one).
    var firstFinishMinutes: Int? = nil
    var waitingCount = 0
    /// Minutes of the FIRST folded waiting buzz (used only when it is the
    /// only one).
    var firstWaitingMinutes: Int? = nil
    /// The LATEST observation's `stillWorking` (fresh tracked count).
    var stillWorking = 0
    /// F4 slice S2: the prompt counts of the LATEST folded waiting event (the
    /// seam's recent prompts, read once per diff, less those with evidence
    /// that the phone's own push covers them) — `.none` without one.
    var prompts = WaitingPromptCounts.none
    /// Epoch of the FIRST folded event — the retry age anchor. Meaningful
    /// only when `!isEmpty`.
    var originatedAt: Double = 0

    var isEmpty: Bool { finishedCount == 0 && waitingCount == 0 }

    /// How many alert events are folded in (finishes + waiting buzzes) — what
    /// alert healing counts as delivered late or dropped.
    var eventCount: Int { finishedCount + waitingCount }

    /// Fold one event observed at `now`. Keeps the FIRST minutes per kind and
    /// the first event's time; `stillWorking` is always the latest, and so
    /// are a waiting event's `prompts` (F4 slice S2).
    mutating func fold(_ event: FinishAlertEvent, stillWorking: Int, prompts: WaitingPromptCounts = .none,
                       at now: Double) {
        if isEmpty { originatedAt = now }
        switch event {
        case .finished(let minutes):
            if finishedCount == 0 { firstFinishMinutes = minutes }
            finishedCount += 1
        case .waiting(let minutes):
            if waitingCount == 0 { firstWaitingMinutes = minutes }
            waitingCount += 1
            self.prompts = prompts
        }
        self.stillWorking = stillWorking
    }

    /// S10 — re-enter an already-built session message that never went out
    /// (it was still QUEUED behind a send ntfy refused with 429): instead of
    /// being sent into the same rate limit, it folds back in and leaves with
    /// the next flush. `.sessionFinished(minutes, folded, stillWorking)`
    /// re-enters as `folded` finished events (at least one), its minutes kept
    /// only when it stood for exactly one finish; `.needsAttention(minutes,
    /// …)` as one waiting event with its minutes. Same first-minutes rule as
    /// `fold`; `stillWorking` is the caller's latest observation (as in
    /// `fold`); `originatedAt` keeps the EARLIEST event (the absorbed message
    /// may predate what the digest already holds). The lid kinds (`.lidAlert`,
    /// `.test`) never ride the session lane and are ignored — the digest is
    /// left exactly as it was. So is the healing restore push
    /// (`.connectionRestored`): it is recomposed from the outage's counts at
    /// the next flush, never folded.
    mutating func absorb(_ kind: LidGuardMessageKind, stillWorking: Int, at originated: Double) {
        let wasEmpty = isEmpty
        switch kind {
        case .sessionFinished(let minutes, let folded, _):
            let count = max(1, folded)
            if finishedCount == 0 { firstFinishMinutes = count == 1 ? minutes : nil }
            finishedCount += count
        case .needsAttention(let minutes, _, let prompts):
            // A newer fold's prompt counts win over the absorbed message's.
            if waitingCount == 0 {
                firstWaitingMinutes = minutes
                self.prompts = prompts
            }
            waitingCount += 1
        case .lidAlert, .test, .connectionRestored:
            return
        }
        originatedAt = wasEmpty ? originated : min(originatedAt, originated)
        self.stillWorking = stillWorking
    }

    /// `messages()`, each paired with how many folded events it stands for —
    /// what a healing flush counts as delivered late once ntfy accepts it.
    func messagesWithEventCounts() -> [(kind: LidGuardMessageKind, events: Int)] {
        messages().map { kind in
            switch kind {
            case .needsAttention: return (kind, waitingCount)
            case .sessionFinished: return (kind, finishedCount)
            case .lidAlert, .test, .connectionRestored: return (kind, 0)
            }
        }
    }

    /// The messages to publish, WAITING FIRST (the user can act on it), then
    /// the finish. Minutes ride only when exactly one event of that kind was
    /// folded (folded sessions' run lengths differ). `.needsAttention` counts
    /// OTHER sessions: the waiting session itself is subtracted (clamped at 0).
    func messages() -> [LidGuardMessageKind] {
        var out: [LidGuardMessageKind] = []
        if waitingCount > 0 {
            out.append(.needsAttention(minutes: waitingCount == 1 ? firstWaitingMinutes : nil,
                                       stillWorking: max(0, stillWorking - 1), prompts: prompts))
        }
        if finishedCount > 0 {
            out.append(.sessionFinished(minutes: finishedCount == 1 ? firstFinishMinutes : nil,
                                        folded: finishedCount,
                                        stillWorking: max(0, stillWorking)))
        }
        return out
    }
}

/// Whether a folded digest may be published now.
enum OutboxDecision: Equatable, Sendable {
    case sendNow
    case holdForWindow
    /// Alert healing: the session lane is OFFLINE — an open-ended hold.
    /// Nothing is scheduled; one of the flush triggers ends it.
    case holdOffline
}

/// Which publish attempt an outcome belongs to.
enum SendAttempt: Equatable, Sendable {
    case first
    case retry
}

enum RetryDecision: Equatable, Sendable {
    case done
    case retryAfter(TimeInterval)
}

/// What the menu caption says about the finish alert. `armed` is reachable
/// only with a watchable marker dir (contract F3).
enum FinishAlertDisplayState: Equatable, Sendable {
    case off
    case needsTopic
    case needsTestSend
    case paused
    case hookNotInstalled
    case armed
}

enum FinishAlertPolicy {
    // MARK: Wiring predicate (ADR §8 mirror)

    /// In debugBattery mode the finish alert is STRUCTURALLY absent (same
    /// shape as `LidGuardPolicy.lidGuardMayBeConstructed`).
    static func finishAlertMayBeConstructed(debugBattery: Bool) -> Bool {
        !debugBattery
    }

    // MARK: Run floor (issue #34)

    /// The run floor a STORED `finishAlertMinimumRunSeconds` value stands for
    /// — the one clamp rule, applied on every read. Missing (nil) or not an
    /// integer (a string, a fraction, an array — a hand-edited plist) ⇒ the
    /// 60 s default; an integer outside `minimumRunSecondsRange` ⇒ the nearer
    /// bound. Only the alert floor of `observe` follows it: the healing
    /// outage floor (`AlertHealingTuning.minimumOutageSeconds`) and the held
    /// digest's max age stay fixed constants.
    static func minimumRunSeconds(stored: Any?) -> Int {
        guard let value = stored as? Int else { return FinishAlertTuning.minimumRunSeconds }
        let range = FinishAlertTuning.minimumRunSecondsRange
        return min(range.upperBound, max(range.lowerBound, value))
    }

    // MARK: Marker-set diffing

    /// Arm-time baseline: every present marker becomes tracked and NOTHING is
    /// emitted — disappearances that happened while disarmed are never
    /// alerted. A session already waiting at arm time is never buzzed for
    /// that episode (no transition was observed). Each anchor follows rule 1
    /// of `observe`, so a hook v7 marker's valid `ep` survives a NapCat
    /// restart or a disarm/re-arm; `now` judges only that `ep` (a stale
    /// baseline marker stays tracked so its later sweep is classified
    /// `.stale`). Rejected `ep` values are counted by
    /// `invalidEpisodeStartCount`, for the controller's log line.
    static func baseline(current: [IdentifiedBusyMarker], now: Int) -> [String: TrackedSession] {
        uniqueMarkers(current).mapValues { newTrackedSession($0, now: now) }
    }

    /// Diff `current` against `previous` (PLAN.md Track C slice C3, rules 1–4
    /// and 6 of the C3a contract; table-tested row by row):
    /// 1. NEW id ⇒ the EPISODE anchor (`firstSeen` / `exactStart`), set here
    ///    once and kept until the id disappears. Hook v7: a valid `ep`
    ///    (`episodeStart`) is the episode start the hook recorded, so it
    ///    anchors EXACTLY whatever the marker's token; otherwise (no `ep`, or
    ///    one rejected — counted in `invalidEpisodeStarts`) the id is tracked
    ///    from its own ts, exact only if it is a UserPromptSubmit marker. A
    ///    new id already `waiting` is a transition.
    /// 2. EXISTING id ⇒ the anchor never moves (AMENDED 2026-10-27, user
    ///    ruling): any rewrite — a newer UserPromptSubmit included — updates
    ///    only lastTs/lastEvent; leaving waiting (either waiting token, B-2)
    ///    ends the waiting episode (dedupe cleared — this also covers a prompt
    ///    that answers a wait). Why: UserPromptSubmit fires not only for a
    ///    typed prompt but also when a scheduled task fires, a background
    ///    subagent reports back, or a cross-session message arrives, so
    ///    re-anchoring on it made a long busy episode report the minutes since
    ///    its last automated prompt. A later marker's `ep` is never consulted
    ///    for a tracked id either (a hook v6 → v7 swap mid-episode writes a
    ///    FRESH, later `ep`). The baseline (a NapCat restart, a disarm/re-arm)
    ///    applies rule 1, so with hook v7 it re-anchors at the recorded
    ///    episode start; a hook v6 marker still re-anchors at its CURRENT ts.
    /// 3. DISAPPEARED id ⇒ stale (last ts beyond the 12 h cap; exactly the cap
    ///    is NOT stale) / clockJump (negative run) / underMinimumRun, else
    ///    `.finished`.
    /// 4. WAITING transition (non-waiting or new → waiting, not yet buzzed) ⇒
    ///    clockJump / underMinimumRun, else `.waiting` and the dedupe flag is
    ///    set. A suppressed transition leaves the flag false; rewrites that
    ///    stay waiting — including `waiting` ⇄ `waiting-after-stop` — are
    ///    never a transition.
    ///
    /// `minimumRunSeconds` is the ONE floor of rules 3 and 4 — the finish and
    /// the waiting buzz share it (`runSuppression`). The controller passes the
    /// user's live setting (issue #34); it defaults to the 60 s constant.
    /// The diff's waiting writes are counted beside rule 4
    /// (`FinishAlertObservation.waitingWrites`); counting changes no event.
    static func observe(
        previous: [String: TrackedSession],
        current: [IdentifiedBusyMarker],
        now: Int,
        minimumRunSeconds: Int = FinishAlertTuning.minimumRunSeconds
    ) -> FinishAlertObservation {
        let present = uniqueMarkers(current)
        // Not named `tracked`: outside FinishAlertController no Sources file
        // may say `tracked[` (FinishAlertStructureTests.trackedReadFailures).
        var observed: [String: TrackedSession] = [:]
        var events: [FinishAlertEvent] = []
        var suppressed: [FinishAlertSuppression] = []
        var invalidEpisodeStarts = 0
        var waitingWrites = 0

        for id in present.keys.sorted() {
            guard let marker = present[id] else { continue }
            let isWaiting = isWaitingEvent(marker.event)
            var session: TrackedSession
            let isTransitionToWaiting: Bool
            var isWaitingRewrite = false
            if let prior = previous[id] {
                session = prior
                let wasWaiting = isWaitingEvent(prior.lastEvent)
                if wasWaiting && !isWaiting { session.waitingBuzzed = false }
                let markerChanged: Bool = marker.ts != prior.lastTs || marker.event != prior.lastEvent
                isWaitingRewrite = wasWaiting && isWaiting && markerChanged
                session.lastTs = marker.ts
                session.lastEvent = marker.event
                isTransitionToWaiting = isWaiting && !wasWaiting
            } else {
                session = newTrackedSession(marker, now: now)
                if episodeStart(marker.ep, now: now) == .invalid { invalidEpisodeStarts += 1 }
                isTransitionToWaiting = isWaiting
            }
            if isTransitionToWaiting || isWaitingRewrite { waitingWrites += 1 }

            if isTransitionToWaiting && !session.waitingBuzzed {
                let duration = now - session.firstSeen
                if let reason = runSuppression(duration: duration, minimumRunSeconds: minimumRunSeconds) {
                    suppressed.append(reason)
                } else {
                    events.append(.waiting(minutes: minutes(duration: duration, exact: session.exactStart)))
                    session.waitingBuzzed = true
                }
            }
            observed[id] = session
        }

        for id in previous.keys.sorted() where present[id] == nil {
            guard let gone = previous[id] else { continue }
            if now - gone.lastTs > FinishAlertTuning.staleCapSeconds {
                suppressed.append(.stale)
                continue
            }
            let duration = now - gone.firstSeen
            if let reason = runSuppression(duration: duration, minimumRunSeconds: minimumRunSeconds) {
                suppressed.append(reason)
            } else {
                events.append(.finished(minutes: minutes(duration: duration, exact: gone.exactStart)))
            }
        }

        let stillWorking = observed.values.filter {
            ClaudeActivityPolicy.markerIsFresh(ts: $0.lastTs, now: now)
        }.count
        return FinishAlertObservation(tracked: observed, events: events,
                                      suppressed: suppressed, stillWorking: stillWorking,
                                      invalidEpisodeStarts: invalidEpisodeStarts, waitingWrites: waitingWrites)
    }

    // MARK: Episode start (hook v7 `ep`)

    /// Validates a marker's RAW `ep` text (`BusyMarker.ep` is never trusted
    /// upstream). The LENGTH is checked first, so nothing longer than
    /// `ClaudeBusyConstants.episodeStartMaxDigits` ever reaches the integer
    /// conversion; then ASCII digits only; then a positive value inside the
    /// same `[now − 12 h, now]` window as marker freshness — a future start,
    /// or one past the 12 h horizon, is invalid (exactly 12 h still counts).
    /// nil ⇒ `.absent` (a hook v6 or earlier marker).
    static func episodeStart(_ raw: String?, now: Int) -> EpisodeStartReading {
        guard let raw else { return .absent }
        let bytes = raw.utf8
        guard (1...ClaudeBusyConstants.episodeStartMaxDigits).contains(bytes.count),
              bytes.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              let value = Int(raw), value > 0,
              ClaudeActivityPolicy.markerIsFresh(ts: value, now: now) else { return .invalid }
        return .valid(value)
    }

    /// How many of `current` — one marker per id, exactly as `baseline`
    /// reads them — carry an `ep` the policy rejects: they fell back to the
    /// pre-v7 anchor. The controller logs it as a count when it arms;
    /// `observe` reports the same for ids it sees for the first time.
    static func invalidEpisodeStartCount(in current: [IdentifiedBusyMarker], now: Int) -> Int {
        uniqueMarkers(current).values.filter { episodeStart($0.ep, now: now) == .invalid }.count
    }

    /// Rule 5: run minutes for a message. Known only when the anchor was
    /// exact (a valid hook v7 `ep`, or an observed UserPromptSubmit) AND the
    /// run lasted at least a minute.
    static func minutes(duration: Int, exact: Bool) -> Int? {
        guard exact, duration >= 60 else { return nil }
        return duration / 60
    }

    /// B-2: BOTH synthetic waiting tokens mean "blocked on the user" — the
    /// in-flight `waiting` and the post-Stop `waiting-after-stop`. A change
    /// between the two is NOT a new episode; any other token ends it.
    private static func isWaitingEvent(_ event: String) -> Bool {
        event == ClaudeBusyConstants.waitingEventToken || event == ClaudeBusyConstants.waitingAfterStopEventToken
    }

    /// Floor + clock checks shared by finishes and waiting buzzes; nil = the
    /// run qualifies (exactly the floor does).
    private static func runSuppression(duration: Int, minimumRunSeconds: Int) -> FinishAlertSuppression? {
        if duration < 0 { return .clockJump }
        if duration < minimumRunSeconds { return .underMinimumRun }
        return nil
    }

    /// Rule 1's anchor for an id seen for the first time: a valid hook v7
    /// `ep`, exact; else the marker's own ts, exact only for a
    /// UserPromptSubmit marker (the pre-v7 rule, unchanged).
    private static func newTrackedSession(_ marker: BusyMarker, now: Int) -> TrackedSession {
        var firstSeen = marker.ts
        var exactStart = marker.event == ClaudeBusyConstants.setEvent
        if case .valid(let start) = episodeStart(marker.ep, now: now) {
            firstSeen = start
            exactStart = true
        }
        return TrackedSession(firstSeen: firstSeen,
                              exactStart: exactStart,
                              lastTs: marker.ts,
                              lastEvent: marker.event,
                              waitingBuzzed: false)
    }

    /// A directory cannot hold two files of one name, but the API takes an
    /// array: a duplicated id keeps the NEWEST marker (deterministic).
    private static func uniqueMarkers(_ current: [IdentifiedBusyMarker]) -> [String: BusyMarker] {
        Dictionary(current.map { ($0.sessionID, $0.marker) },
                   uniquingKeysWith: { first, second in second.ts > first.ts ? second : first })
    }

    // MARK: One buzz for one permission wait (F4)

    /// The singleton rule. A diff's plain waiting buzz yields to the phone's
    /// own prompt push only when the diff holds exactly ONE waiting write
    /// (`FinishAlertObservation.waitingWrites`), exactly ONE prompt was
    /// relayed since the previous read (`newPrompts`), and that one prompt
    /// carries the caller's evidence that the phone's push covers it
    /// (`newPromptsWithEvidence`). Anything else keeps the buzz: two writes
    /// or none, two prompts or none, a prompt without evidence, and counts
    /// that cannot all hold at once (more evidence than prompts, a negative
    /// count). Exact equality is the whole rule; nothing is clamped first,
    /// so an inconsistent input never yields.
    static func waitingBuzzYieldsToPromptPush(waitingWrites: Int, newPrompts: Int,
                                              newPromptsWithEvidence: Int) -> Bool {
        waitingWrites == 1 && newPrompts == 1 && newPromptsWithEvidence == 1
    }

    /// The per-kind counts a waiting buzz's phrase is built from
    /// (`LidGuardPolicy.promptsPhrase`), less the prompts whose evidence says
    /// the phone's own push covers them: a buzz that still goes out names
    /// only the prompts the phone may not have shown. A kind loses at most
    /// what it holds, so every kind, and so the total, is clamped at zero;
    /// an evidence count below zero takes nothing. With no evidence the
    /// counts come back exactly as given, and the phrase built from them is
    /// today's, byte for byte.
    static func promptsWithoutEvidence(_ prompts: WaitingPromptCounts,
                                       withEvidence: WaitingPromptCounts) -> WaitingPromptCounts {
        guard withEvidence != .none else { return prompts }
        var left: WaitingPromptCounts = prompts
        left.bash = countLessEvidence(prompts.bash, withEvidence.bash)
        left.write = countLessEvidence(prompts.write, withEvidence.write)
        left.edit = countLessEvidence(prompts.edit, withEvidence.edit)
        left.notebookEdit = countLessEvidence(prompts.notebookEdit, withEvidence.notebookEdit)
        left.read = countLessEvidence(prompts.read, withEvidence.read)
        return left
    }

    /// One kind of `promptsWithoutEvidence`: what it holds (a count below
    /// zero holds nothing) less at most all of it. Never below zero, never
    /// added to, and it cannot overflow.
    private static func countLessEvidence(_ count: Int, _ withEvidence: Int) -> Int {
        let held: Int = max(0, count)
        let taken: Int = min(max(0, withEvidence), held)
        return held - taken
    }

    /// The singleton rule applied to one diff, read once for it (`context`):
    /// what the controller folds into the digest. When the rule yields
    /// (`waitingBuzzYieldsToPromptPush`), the diff's waiting events are
    /// dropped and every finish is kept, in order, and `folded` counts the
    /// waiting events dropped: none for a diff that has none (its waiting
    /// write was a rewrite or a suppressed transition, no event, so its one
    /// prompt is only used up). `prompts` is what a waiting event
    /// that still goes out counts: the counts less those with evidence
    /// (`promptsWithoutEvidence`). With no evidence nothing changes: every
    /// event is kept, and `prompts` is the counts as read.
    static func promptPushFold(events: [FinishAlertEvent], waitingWrites: Int, context: WaitingPromptContext)
        -> (events: [FinishAlertEvent], folded: Int, prompts: WaitingPromptCounts) {
        let prompts: WaitingPromptCounts = promptsWithoutEvidence(context.counts, withEvidence: context.countsWithEvidence)
        guard waitingBuzzYieldsToPromptPush(waitingWrites: waitingWrites, newPrompts: context.newPrompts,
                                            newPromptsWithEvidence: context.newPromptsWithEvidence) else {
            return (events, 0, prompts)
        }
        let kept: [FinishAlertEvent] = events.filter { if case .waiting = $0 { return false }; return true }
        return (kept, events.count - kept.count, prompts)
    }

    // MARK: Outbox + retry (normative tables)

    /// The FIRST event sends immediately and opens a batch window; later
    /// events fold into the digest and are flushed once the window has closed
    /// and nothing is in flight. Alert healing: while the lane is `offline`
    /// everything holds, open-ended. A healing flush goes through this same
    /// table once the lane is no longer offline, so an open 429 hold still
    /// wins over it.
    static func outboxDecision(windowOpenUntil: Double?, sendInFlight: Bool, offline: Bool = false,
                               now: Double) -> OutboxDecision {
        guard !offline else { return .holdOffline }
        guard !sendInFlight else { return .holdForWindow }
        if let windowOpenUntil, now < windowOpenUntil { return .holdForWindow }
        return .sendNow
    }

    /// FA-7: retry ONCE, iff `.sendFailed` — which is now an ALLOW-LIST of
    /// pre-connect failures (`LidGuardPolicy.preConnectTransportErrorCodes`:
    /// no network, DNS, TCP connect, TLS/certificate, unusable address) plus
    /// the sender's inline refusals (lane busy, unusable address), so nothing
    /// left the Mac. NEVER retry `.accepted`, `.rejected` (the server answered
    /// — e.g. a 429 quota) or `.timedOutUnconfirmed` (timed out, connection
    /// lost, unreadable response, or an unknown transport code: it may have
    /// been delivered — duplicate risk).
    static func retryDecision(outcome: MessageSendOutcome, attempt: SendAttempt) -> RetryDecision {
        switch (outcome, attempt) {
        case (.sendFailed, .first): return .retryAfter(FinishAlertTuning.retryDelaySeconds)
        case (.sendFailed, .retry): return .done
        case (.accepted, _), (.rejected, _), (.timedOutUnconfirmed, _): return .done
        }
    }

    /// B-1: how far a session-lane send outcome pushes the batch window out.
    /// Only a 429 (ntfy is rate-limiting this Mac) holds — for
    /// `rateLimitHoldSeconds`, during which events keep folding into the
    /// digest; every other outcome (accepted, unconfirmed, failed, any other
    /// refusal) leaves the window alone. No retry either way (`retryDecision`).
    static func windowExtension(after outcome: MessageSendOutcome) -> TimeInterval? {
        guard outcome == .rejected(429) else { return nil }
        return FinishAlertTuning.rateLimitHoldSeconds
    }

    /// A pending retry is re-gated at fire time: still armed, not paused, the
    /// marker dir still there, and the originating event at most
    /// `retryMaxAgeSeconds` old (exactly the max still fires).
    static func retryMayFire(armed: Bool, paused: Bool, markerDirExists: Bool,
                             originatedAt: Double, now: Double) -> Bool {
        armed && !paused && markerDirExists && now - originatedAt <= FinishAlertTuning.retryMaxAgeSeconds
    }

    // MARK: Arming + display

    /// `armingState` is `LidGuardPolicy.armingState` evaluated with the
    /// FINISH toggle (`claudeFinishAlertEnabled`) and the SHARED lid-guard
    /// destination + priming. Defined as `displayState == .armed`, so the
    /// watcher arms exactly when the caption may say "armed".
    static func finishAlertMayArm(armingState: LidGuardArmingState, detectionPaused: Bool,
                                  markerDirExists: Bool) -> Bool {
        displayState(armingState: armingState, detectionPaused: detectionPaused,
                     markerDirExists: markerDirExists) == .armed
    }

    /// Caption state. The not-armed lid states pass through unchanged; when
    /// armed, a pause wins over a missing hook dir, and "armed" requires a
    /// watchable dir (F3).
    static func displayState(armingState: LidGuardArmingState, detectionPaused: Bool,
                             markerDirExists: Bool) -> FinishAlertDisplayState {
        switch armingState {
        case .off: return .off
        case .needsTopic: return .needsTopic
        case .needsTestSend: return .needsTestSend
        case .armed:
            if detectionPaused { return .paused }
            if !markerDirExists { return .hookNotInstalled }
            return .armed
        }
    }

    // MARK: Alert-channel healing (issue #23)

    /// Healing arms iff there is a validated destination to heal toward, a
    /// feature that sends to it (session alerts armed, or the lid alert
    /// armed), and something in play: Stay Awake is ON, or the finish watcher
    /// is armed and tracking at least one session — or the session lane is
    /// still HOLDING something (an alert pending in it, or an open outage with
    /// alerts delivered late, dropped or lid misses to report), so the
    /// disarm that follows a last session finishing can never drop the very
    /// alert the feature exists to deliver.
    static func healingMayArm(destinationValid: Bool, sessionAlertsArmed: Bool, lidAlertArmed: Bool,
                              stayAwakeOn: Bool, trackedSessions: Int, sessionLaneHolding: Bool) -> Bool {
        guard destinationValid, sessionAlertsArmed || lidAlertArmed else { return false }
        return stayAwakeOn || (sessionAlertsArmed && trackedSessions >= 1) || sessionLaneHolding
    }

    /// The held digest has passed its max age: its OLDEST event is more than
    /// `AlertHealingTuning.heldDigestMaxAgeSeconds` old (exactly the max age
    /// is still delivered).
    static func heldDigestExpired(originatedAt: Double, now: Double) -> Bool {
        now - originatedAt > AlertHealingTuning.heldDigestMaxAgeSeconds
    }

    /// The restore push for a healing outage, or nil. Sent ONLY with content
    /// — session alerts delivered late or dropped, or lid alerts missed since
    /// the outage began — and only after an outage of at least
    /// `AlertHealingTuning.minimumOutageSeconds` (exactly the floor counts),
    /// measured from the ORIGINAL anchor to when the healing flush began.
    static func restoreMessage(for outage: AlertOutage, lidMisses: Int) -> LidGuardMessageKind? {
        guard let healedAt = outage.flushStartedAt else { return nil }
        let duration = healedAt - outage.startedAt
        guard duration >= AlertHealingTuning.minimumOutageSeconds else { return nil }
        let lidMissed = max(0, lidMisses - outage.lidMissBaseline)
        let deliveredLate = max(0, outage.deliveredLate)
        let dropped = max(0, outage.dropped)
        guard deliveredLate > 0 || dropped > 0 || lidMissed > 0 else { return nil }
        return .connectionRestored(minutes: outageMinutes(duration), deliveredLate: deliveredLate,
                                   dropped: dropped, lidMissed: lidMissed)
    }

    /// The restore push's minutes: rounded UP, at least 1 — never "0 min".
    static func outageMinutes(_ seconds: TimeInterval) -> Int {
        max(1, Int((max(0, seconds) / 60).rounded(.up)))
    }
}

// MARK: - Alert-channel healing (issue #23)

/// Alert-healing tunables. CODE CONSTANTS — no defaults key and no toggle:
/// the feature arms itself from the live state (`healingMayArm`).
enum AlertHealingTuning {
    /// A path must stay unsatisfied this long before the session lane holds:
    /// ONE one-shot debounce, armed by the path update itself — never
    /// periodic. A shorter flap is no outage.
    static let pathDebounceSeconds: TimeInterval = 2
    /// An outage shorter than this never earns the restore push.
    static let minimumOutageSeconds: TimeInterval = 60
    /// HELD-DIGEST MAX AGE (12 h). A held session alert whose oldest event is
    /// older than this is DROPPED — counted for the restore push, never
    /// delivered. Deliberately its own constant:
    /// `FinishAlertTuning.retryMaxAgeSeconds` bounds ONE retry and must never
    /// silently cap an outage hold.
    static let heldDigestMaxAgeSeconds: TimeInterval = 43_200
}

/// DISARMED → ONLINE → OFFLINE → FLUSHING → ONLINE. Session lane only: the
/// lid lane is never gated, queued or flushed by any of it.
enum AlertHealingPhase: String, Equatable, Sendable {
    /// Zero footprint: no path monitor, nothing scheduled, nothing held.
    case disarmed
    /// Watching the path; session alerts send as usual.
    case online
    /// The session lane holds everything (open-ended) until a flush trigger.
    case offline
    /// A flush attempt is under way (an open 429 hold may still defer it).
    case flushing
}

/// What may end an OFFLINE hold. Fixed log-safe words.
enum AlertHealingFlushTrigger: String, Equatable, Sendable {
    /// The path went from unsatisfied to satisfied.
    case pathRestored
    /// A new session alert event arrived while offline.
    case sessionEvent
    /// The menu opened (the menu-open reconcile).
    case menuOpen
}

/// One input to the healing state machine.
enum AlertHealingInput: Equatable, Sendable {
    case arm
    case disarm
    /// One path update — a repeat of the same status included.
    case path(ConnectivityPathStatus)
    /// The one-shot path debounce fired.
    case pathDebounceFired
    /// A session-lane send failed before leaving the Mac (`.sendFailed`).
    case sessionSendFailed
    /// A session event arrived or the menu opened (the path trigger is
    /// derived from `.path`). Coalesced: only an OFFLINE lane reacts.
    case flushTrigger(AlertHealingFlushTrigger)
    /// The flush — held digest and restore push alike — completed without a
    /// pre-connect failure.
    case flushCompleted
}

/// What the controller must do after a transition.
enum AlertHealingEffect: Equatable, Sendable {
    case startMonitor
    case stopMonitor
    /// Schedule the ONE one-shot path debounce.
    case scheduleDebounce
    case cancelDebounce
    /// OFFLINE was entered: cancel the pending session retries and fold them,
    /// and anything still queued, into the digest — then hold the lane.
    case holdSessionLane
    /// Flush through the outbox (an open 429 hold still wins).
    case flush
}

/// One connectivity outage, from the moment the connection was first seen
/// down until a flush succeeds. Counts only — never a session id.
struct AlertOutage: Equatable, Sendable {
    /// The ORIGINAL anchor (epoch seconds). A failed flush never moves it.
    let startedAt: Double
    /// The lid-alert miss counter when the outage began: misses are its delta.
    let lidMissBaseline: Int
    /// Session alert events a healing flush got accepted by ntfy.
    var deliveredLate = 0
    /// Session alert events dropped at the held digest's max age.
    var dropped = 0
    /// When the current flush attempt began — the outage's end for the
    /// restore push's minutes. nil while OFFLINE.
    var flushStartedAt: Double?
}

/// The healing state machine (pure, table-tested). The controller feeds it
/// inputs and performs the effects it returns.
struct AlertHealingState: Equatable, Sendable {
    private(set) var phase: AlertHealingPhase = .disarmed
    /// The last path status delivered (nil before the first one).
    private(set) var lastPath: ConnectivityPathStatus?
    /// When the path went unsatisfied while ONLINE — the debounce's anchor
    /// and, once sustained, the outage's.
    private(set) var unsatisfiedSince: Double?
    /// The open outage (OFFLINE / FLUSHING), else nil.
    private(set) var outage: AlertOutage?

    var isArmed: Bool { phase != .disarmed }

    /// Entry: a session-lane pre-connect `.sendFailed` (even on a path the
    /// monitor calls satisfied — a captive portal) or a path unsatisfied
    /// for the full debounce. Exit: a completed flush only; a pre-connect
    /// failure during the flush re-enters OFFLINE with the ORIGINAL anchor.
    /// Flush triggers (the path coming back, a session event, the menu
    /// opening) act only on an OFFLINE lane, so simultaneous triggers cause
    /// ONE attempt.
    mutating func apply(_ input: AlertHealingInput, now: Double, lidMisses: Int) -> [AlertHealingEffect] {
        switch (phase, input) {
        case (.disarmed, .arm):
            self = AlertHealingState()
            phase = .online
            return [.startMonitor]
        case (.disarmed, _), (_, .arm):
            return []
        case (_, .disarm):
            self = AlertHealingState()
            return [.cancelDebounce, .stopMonitor]
        case (_, .path(let status)):
            return path(status, now: now)
        case (.online, .pathDebounceFired):
            guard lastPath == .unsatisfied, let since = unsatisfiedSince else {
                unsatisfiedSince = nil
                return []
            }
            guard now - since >= AlertHealingTuning.pathDebounceSeconds else { return [.scheduleDebounce] }
            enterOffline(anchor: since, lidMisses: lidMisses)
            return [.holdSessionLane]
        case (_, .pathDebounceFired):
            return []
        case (.online, .sessionSendFailed):
            let effects: [AlertHealingEffect] = unsatisfiedSince == nil ? [] : [.cancelDebounce]
            enterOffline(anchor: unsatisfiedSince ?? now, lidMisses: lidMisses)
            return effects + [.holdSessionLane]
        case (.flushing, .sessionSendFailed):
            enterOffline(anchor: now, lidMisses: lidMisses)
            return [.holdSessionLane]
        case (.offline, .sessionSendFailed):
            return []
        case (.offline, .flushTrigger):
            beginFlush(at: now)
            return [.flush]
        case (_, .flushTrigger):
            return []
        case (.flushing, .flushCompleted):
            phase = .online
            outage = nil
            // Healed while the path reads down: start the debounce afresh.
            guard lastPath == .unsatisfied else { return [] }
            unsatisfiedSince = now
            return [.scheduleDebounce]
        case (_, .flushCompleted):
            return []
        }
    }

    /// A healing-flush message ntfy ACCEPTED: its events were delivered late.
    mutating func recordDeliveredLate(_ events: Int) {
        guard events > 0 else { return }
        outage?.deliveredLate += events
    }

    /// The held digest's max age, applied: once its OLDEST event is past it,
    /// the digest collapses to counts — every event in it is counted DROPPED
    /// and the digest is emptied, so none of them can also be delivered late
    /// (dropped wins). Only an open outage expires anything. Returns the
    /// events dropped (0 = nothing expired).
    mutating func expireHeldDigest(_ digest: inout FinishAlertDigest, now: Double) -> Int {
        guard outage != nil, !digest.isEmpty,
              FinishAlertPolicy.heldDigestExpired(originatedAt: digest.originatedAt, now: now) else { return 0 }
        let events = digest.eventCount
        outage?.dropped += events
        digest = FinishAlertDigest()
        return events
    }

    /// An open outage with something to report: session alerts delivered late
    /// or dropped, or lid alerts missed since it began.
    func outageHasContent(lidMisses: Int) -> Bool {
        guard let outage else { return false }
        return outage.deliveredLate > 0 || outage.dropped > 0 || lidMisses > outage.lidMissBaseline
    }

    private mutating func path(_ status: ConnectivityPathStatus, now: Double) -> [AlertHealingEffect] {
        let previous = lastPath
        lastPath = status
        switch status {
        case .unsatisfied:
            guard phase == .online, unsatisfiedSince == nil else { return [] }
            unsatisfiedSince = now
            return [.scheduleDebounce]
        case .satisfied:
            var effects: [AlertHealingEffect] = []
            if unsatisfiedSince != nil {
                unsatisfiedSince = nil
                effects.append(.cancelDebounce)
            }
            if phase == .offline && previous == .unsatisfied {
                beginFlush(at: now)
                effects.append(.flush)
            }
            return effects
        }
    }

    /// From ONLINE a new outage begins at `anchor`; from FLUSHING the open one
    /// continues — its ORIGINAL anchor and counts kept.
    private mutating func enterOffline(anchor: Double, lidMisses: Int) {
        phase = .offline
        unsatisfiedSince = nil
        if outage == nil {
            outage = AlertOutage(startedAt: anchor, lidMissBaseline: lidMisses)
        } else {
            outage?.flushStartedAt = nil
        }
    }

    private mutating func beginFlush(at now: Double) {
        phase = .flushing
        outage?.flushStartedAt = now
    }
}
