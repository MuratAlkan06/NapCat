import Foundation

// Pure Track C decision logic for the Claude finish alert and the waiting
// buzz: marker-set diffing, the 30 s run floor, the 12 h stale cap, the batch
// digest, the outbox and retry tables, and the arming/display predicates.
// I/O-free by construction — no filesystem, no timers, no network, no
// subprocess, no logging, no defaults reads. `FinishAlertStructureTests` locks
// that (canary-proven), and `FinishAlertPolicyTests` exercises every rule as a
// table row like `HysteresisEngine`. The only `import` is Foundation (for
// `TimeInterval`).
//
// Session ids are INTERNAL DIFF KEYS: they key the tracked map and nothing
// else. Every value that leaves this file toward a message is an Int count or
// minutes (`FinishAlertEvent`, `FinishAlertDigest`, `LidGuardMessageKind`).

/// Track C tunables. CODE CONSTANTS, not UserDefaults keys — the only new
/// persisted key of Track C is the `claudeFinishAlertEnabled` toggle.
enum FinishAlertTuning {
    /// Run-length floor (user ruling): a run shorter than this never alerts —
    /// neither a finish nor a waiting buzz (you are still looking).
    static let minimumRunSeconds = 30
    /// One-shot debounce armed ONLY by a filesystem event — never periodic
    /// (B1 amendment, PLAN.md Track C).
    static let debounceSeconds: TimeInterval = 2
    /// After a send, further events fold into one digest for this long.
    static let batchWindowSeconds: TimeInterval = 30
    /// The single retry of a `.sendFailed` publish waits this long.
    static let retryDelaySeconds: TimeInterval = 30
    /// A retry whose originating event is older than this is dropped.
    static let retryMaxAgeSeconds: TimeInterval = 300
    /// A disappearance whose last-known marker ts is older than this is the
    /// hook's sweep, not a finish (same 12 h cap as marker freshness).
    static let staleCapSeconds = ClaudeBusyConstants.freshnessCapSeconds
}

/// What the watcher remembers about one present session between two
/// observations. Keyed by session id in a `[String: TrackedSession]` map.
struct TrackedSession: Equatable, Sendable {
    /// Epoch seconds anchoring the current run's start.
    var firstSeen: Int
    /// True iff `firstSeen` came from an OBSERVED `event=UserPromptSubmit`
    /// marker (otherwise it is only "when we first saw it" — minutes unknown).
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
    /// Shorter than `FinishAlertTuning.minimumRunSeconds`.
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
    /// Epoch of the FIRST folded event — the retry age anchor. Meaningful
    /// only when `!isEmpty`.
    var originatedAt: Double = 0

    var isEmpty: Bool { finishedCount == 0 && waitingCount == 0 }

    /// Fold one event observed at `now`. Keeps the FIRST minutes per kind and
    /// the first event's time; `stillWorking` is always the latest.
    mutating func fold(_ event: FinishAlertEvent, stillWorking: Int, at now: Double) {
        if isEmpty { originatedAt = now }
        switch event {
        case .finished(let minutes):
            if finishedCount == 0 { firstFinishMinutes = minutes }
            finishedCount += 1
        case .waiting(let minutes):
            if waitingCount == 0 { firstWaitingMinutes = minutes }
            waitingCount += 1
        }
        self.stillWorking = stillWorking
    }

    /// The messages to publish, WAITING FIRST (the user can act on it), then
    /// the finish. Minutes ride only when exactly one event of that kind was
    /// folded (folded sessions' run lengths differ). `.needsAttention` counts
    /// OTHER sessions: the waiting session itself is subtracted (clamped at 0).
    func messages() -> [LidGuardMessageKind] {
        var out: [LidGuardMessageKind] = []
        if waitingCount > 0 {
            out.append(.needsAttention(minutes: waitingCount == 1 ? firstWaitingMinutes : nil,
                                       stillWorking: max(0, stillWorking - 1)))
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

    // MARK: Marker-set diffing

    /// Arm-time baseline: every present marker becomes tracked and NOTHING is
    /// emitted — disappearances that happened while disarmed are never
    /// alerted. A session already waiting at arm time is never buzzed for
    /// that episode (no transition was observed). `now` is deliberately
    /// unused: the baseline judges nothing time-based (a stale baseline
    /// marker stays tracked so its later sweep is classified `.stale`); it is
    /// kept for call-site symmetry with `observe`.
    static func baseline(current: [IdentifiedBusyMarker], now: Int) -> [String: TrackedSession] {
        uniqueMarkers(current).mapValues(newTrackedSession)
    }

    /// Diff `current` against `previous` (PLAN.md Track C slice C3, rules 1–4
    /// and 6 of the C3a contract; table-tested row by row):
    /// 1. NEW id ⇒ tracked from its own ts; exact only if it is a
    ///    UserPromptSubmit marker; a new id already `waiting` is a transition.
    /// 2. EXISTING id ⇒ a NEWER UserPromptSubmit ts starts a new turn (anchor
    ///    reset, exact, dedupe cleared — never a finish); leaving `waiting`
    ///    ends the episode (dedupe cleared); lastTs/lastEvent always updated.
    /// 3. DISAPPEARED id ⇒ stale (last ts beyond the 12 h cap; exactly the cap
    ///    is NOT stale) / clockJump (negative run) / underMinimumRun, else
    ///    `.finished`.
    /// 4. WAITING transition (non-waiting or new → waiting, not yet buzzed) ⇒
    ///    clockJump / underMinimumRun, else `.waiting` and the dedupe flag is
    ///    set. A suppressed transition leaves the flag false; rewrites that
    ///    stay `waiting` are never a transition.
    static func observe(
        previous: [String: TrackedSession],
        current: [IdentifiedBusyMarker],
        now: Int
    ) -> FinishAlertObservation {
        let present = uniqueMarkers(current)
        var tracked: [String: TrackedSession] = [:]
        var events: [FinishAlertEvent] = []
        var suppressed: [FinishAlertSuppression] = []
        let waiting = ClaudeBusyConstants.waitingEventToken

        for id in present.keys.sorted() {
            guard let marker = present[id] else { continue }
            let isWaiting = marker.event == waiting
            var session: TrackedSession
            let isTransitionToWaiting: Bool
            if let prior = previous[id] {
                session = prior
                if marker.event == ClaudeBusyConstants.setEvent && marker.ts > prior.lastTs {
                    session.firstSeen = marker.ts
                    session.exactStart = true
                    session.waitingBuzzed = false
                }
                let wasWaiting = prior.lastEvent == waiting
                if wasWaiting && !isWaiting { session.waitingBuzzed = false }
                session.lastTs = marker.ts
                session.lastEvent = marker.event
                isTransitionToWaiting = isWaiting && !wasWaiting
            } else {
                session = newTrackedSession(marker)
                isTransitionToWaiting = isWaiting
            }

            if isTransitionToWaiting && !session.waitingBuzzed {
                let duration = now - session.firstSeen
                if let reason = runSuppression(duration: duration) {
                    suppressed.append(reason)
                } else {
                    events.append(.waiting(minutes: minutes(duration: duration, exact: session.exactStart)))
                    session.waitingBuzzed = true
                }
            }
            tracked[id] = session
        }

        for id in previous.keys.sorted() where present[id] == nil {
            guard let gone = previous[id] else { continue }
            if now - gone.lastTs > FinishAlertTuning.staleCapSeconds {
                suppressed.append(.stale)
                continue
            }
            let duration = now - gone.firstSeen
            if let reason = runSuppression(duration: duration) {
                suppressed.append(reason)
            } else {
                events.append(.finished(minutes: minutes(duration: duration, exact: gone.exactStart)))
            }
        }

        let stillWorking = tracked.values.filter {
            ClaudeActivityPolicy.markerIsFresh(ts: $0.lastTs, now: now)
        }.count
        return FinishAlertObservation(tracked: tracked, events: events,
                                      suppressed: suppressed, stillWorking: stillWorking)
    }

    /// Rule 5: run minutes for a message. Known only when the anchor was an
    /// observed UserPromptSubmit AND the run lasted at least a minute.
    static func minutes(duration: Int, exact: Bool) -> Int? {
        guard exact, duration >= 60 else { return nil }
        return duration / 60
    }

    /// Floor + clock checks shared by finishes and waiting buzzes; nil = the
    /// run qualifies.
    private static func runSuppression(duration: Int) -> FinishAlertSuppression? {
        if duration < 0 { return .clockJump }
        if duration < FinishAlertTuning.minimumRunSeconds { return .underMinimumRun }
        return nil
    }

    private static func newTrackedSession(_ marker: BusyMarker) -> TrackedSession {
        TrackedSession(firstSeen: marker.ts,
                       exactStart: marker.event == ClaudeBusyConstants.setEvent,
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

    // MARK: Outbox + retry (normative tables)

    /// The FIRST event sends immediately and opens a batch window; later
    /// events fold into the digest and are flushed once the window has closed
    /// and nothing is in flight.
    static func outboxDecision(windowOpenUntil: Double?, sendInFlight: Bool, now: Double) -> OutboxDecision {
        guard !sendInFlight else { return .holdForWindow }
        if let windowOpenUntil, now < windowOpenUntil { return .holdForWindow }
        return .sendNow
    }

    /// FA-7: retry ONCE, and only when nothing left the Mac (`.sendFailed`,
    /// which includes an inline lane refusal). NEVER retry `.accepted`,
    /// `.rejected` (the server answered — e.g. a 429 quota) or
    /// `.timedOutUnconfirmed` (it may have been delivered: duplicate risk).
    static func retryDecision(outcome: MessageSendOutcome, attempt: SendAttempt) -> RetryDecision {
        switch (outcome, attempt) {
        case (.sendFailed, .first): return .retryAfter(FinishAlertTuning.retryDelaySeconds)
        case (.sendFailed, .retry): return .done
        case (.accepted, _), (.rejected, _), (.timedOutUnconfirmed, _): return .done
        }
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
}
