import Foundation
import os

// Track C slice C3 — the Claude finish alert and the waiting buzz. A THIN
// SHELL around the pure `FinishAlertPolicy`: it owns the kqueue watcher while
// armed, one ONE-SHOT debounce per event burst (never periodic — B1
// amendment), the batch-window flush, the single `.sendFailed` retry, and the
// hand-off to the SHARED ntfy sender. Every decision — arming, diffing, the
// floor, the stale cap, folding, the outbox and retry tables — is the policy's.
//
// What this file never does (lint-locked, FinishAlertStructureTests): probe a
// process, take a B1 sample, read the ntfy topic, touch the network directly,
// or run anything periodically. Session ids are in-memory dictionary keys
// only; log lines carry counts and fixed reason words.
//
// Alert-channel healing (issue #23) lives here too, as the SESSION lane's
// offline hold: the pure `AlertHealingState` decides, this shell observes the
// injected `ConnectivityInterface` only while healing is armed, holds the
// digest while OFFLINE (reusing the 429-hold machinery), flushes through the
// same outbox, and appends the restore push. The lid lane is never touched:
// lid alerts are only COUNTED here, through `lidAlertMissCount`.

/// The slice of the lid-guard configuration the finish alert reads: its OWN
/// toggle folded into the shared arming grammar, plus the SHARED validated
/// destination — and, for alert healing, the LID alert's own arming and its
/// pre-connect miss counter. Adopted by `LidGuardController`; never exposes
/// the raw topic.
protocol FinishAlertConfigSource: AnyObject {
    var finishAlertArmingState: LidGuardArmingState { get }
    var storedDestination: NtfyDestination? { get }
    var lidAlertArmingState: LidGuardArmingState { get }
    var lidAlertMissCount: Int { get }
}

extension LidGuardController: FinishAlertConfigSource {
    var lidAlertArmingState: LidGuardArmingState { armingState }
}

/// A cancellable delayed callback.
@MainActor
protocol FinishAlertScheduledWork: AnyObject {
    func cancel()
}

/// The ONLY way the finish alert defers work: one-shot callbacks on the main
/// actor (debounce, batch-window flush, retry). Injected so the tests fire
/// and cancel them by hand.
@MainActor
protocol FinishAlertScheduling: AnyObject {
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> FinishAlertScheduledWork
}

/// Production scheduler: `DispatchQueue.main.asyncAfter` with a cancellable
/// `DispatchWorkItem`. Strictly one-shot — the work runs at most once and
/// nothing re-arms it.
@MainActor
final class MainQueueFinishAlertScheduler: FinishAlertScheduling {
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> FinishAlertScheduledWork {
        let item = DispatchWorkItem {
            MainActor.assumeIsolated { work() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: item)
        return MainQueueScheduledWork(item)
    }
}

@MainActor
private final class MainQueueScheduledWork: FinishAlertScheduledWork {
    private let item: DispatchWorkItem

    init(_ item: DispatchWorkItem) {
        self.item = item
    }

    func cancel() { item.cancel() }
}

@MainActor
final class FinishAlertController {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "finishalert")

    /// Fixed, log-safe disarm reasons (the only words a disarm line carries).
    private enum DisarmReason: String {
        case off, needsTopic, needsTestSend, paused, directoryMissing, directoryVanished, quit
    }

    /// One message waiting for the sender.
    private struct Outgoing {
        let kind: LidGuardMessageKind
        let attempt: SendAttempt
        let originatedAt: Double
        /// Alert healing: how many alert events it stands for, and whether it
        /// belongs to a healing flush (its acceptance counts as delivered late).
        var events = 0
        var inFlush = false

        var isRestore: Bool {
            if case .connectionRestored = kind { return true }
            return false
        }
    }

    /// One pending FA-7 retry. The kind rides along so entering OFFLINE can
    /// fold it into the held digest instead of sending it into the outage.
    private struct PendingRetry {
        let work: FinishAlertScheduledWork
        let kind: LidGuardMessageKind
        let originatedAt: Double
    }

    private let store: BusyMarkerStore
    private let markerDirURL: URL
    private let disabledFlagURL: URL
    private let config: FinishAlertConfigSource
    private let sender: MessageSender
    private let makeWatcher: (URL) -> MarkerDirectoryWatching
    private let scheduler: FinishAlertScheduling
    /// WALL CLOCK, unix epoch seconds (injected for tests).
    private let now: () -> Double
    /// Alert healing: the network-path observer, started ONLY while healing
    /// is armed. nil ⇒ healing is absent altogether (a test seam: those
    /// tests lock the pre-healing behaviour, which also applies whenever
    /// healing is disarmed).
    private let connectivity: ConnectivityInterface?
    /// Alert healing: the OBSERVED Stay Awake state (true only when known on).
    private let stayAwakeOn: () -> Bool
    /// Issue #34: the user's run floor (finish AND waiting), already clamped.
    /// Read at EVERY marker diff — never cached — so a change in the ntfy
    /// settings applies to the next diff, with no restart and no re-arm.
    private let readMinimumRunSeconds: () -> Int
    /// F4: what one read of the seam says about the permission prompts wired
    /// sessions just relayed (`RemoteApprovalsController.waitingPrompts`;
    /// `.none` while remote approvals are off or not listening): counts per
    /// kind, and how many of them have evidence that the phone's own prompt
    /// push covers them. Read once for each diff with a waiting write, and
    /// once as the lane arms.
    private let waitingPrompts: () -> WaitingPromptContext

    // MARK: State (main actor only)

    /// Present sessions as of the last observation. Ids are diff keys only.
    private(set) var tracked: [String: TrackedSession] = [:]
    private var watcher: MarkerDirectoryWatching?
    /// Bumped on every arm, so an event or completion from an earlier armed
    /// period can be told apart from the current one.
    private var armGeneration = 0
    private var debounce: FinishAlertScheduledWork?
    private var digest = FinishAlertDigest()
    private var windowOpenUntil: Double?
    private var flush: FinishAlertScheduledWork?
    private var sendInFlight = false
    private var queue: [Outgoing] = []
    /// The latest observation's fresh-session count — what a message folded
    /// back into the digest after a 429 reports as still working (S10).
    private var latestStillWorking = 0
    /// Pending single retries, keyed by a local token so a fired retry can
    /// remove itself. All cancelled on disarm.
    private var retries: [Int: PendingRetry] = [:]
    private var nextRetryToken = 0
    private var changeHandler: (@MainActor () -> Void)?

    // MARK: Alert-healing state (main actor only)

    /// The pure state machine (DISARMED → ONLINE → OFFLINE → FLUSHING).
    private(set) var healing = AlertHealingState()
    /// Bumped on every healing arm, so a path delivery from an earlier armed
    /// period is ignored.
    private var healingGeneration = 0
    /// The ONE one-shot path debounce.
    private var pathDebounce: FinishAlertScheduledWork?
    /// Healing-flush messages still queued or in flight.
    private var flushOutstanding = 0
    /// The restore push of the current flush is queued or in flight.
    private var restoreQueued = false

    // MARK: Menu-facing snapshot

    private(set) var lastSendOutcome: MessageSendOutcome?
    private(set) var lastSendOutcomeAt: Double?
    private(set) var lastSendKind: LidGuardMessageKind?

    /// True while the kqueue watcher is running — the ONLY meaning of "armed".
    var isWatching: Bool { watcher?.isRunning == true }

    /// The run floor the next marker diff will apply (issue #34), read live.
    var minimumRunSeconds: Int { readMinimumRunSeconds() }

    /// Alert healing: armed and OFFLINE — session alerts are being held. The
    /// panel's one offline warning shows exactly while this is true.
    var connectivityOffline: Bool { healing.phase == .offline }

    /// The session lane has live work: the watcher runs, or healing is armed
    /// (a lid-only restore push needs no watcher).
    private var sessionLaneLive: Bool { isWatching || healing.isArmed }

    /// Caption state, computed live. The policy's `.armed` is reported only
    /// while the watcher really runs (F3: never "armed" without a watchable
    /// dir); armable-but-not-watching reads as `.hookNotInstalled`.
    var displayState: FinishAlertDisplayState {
        let state = FinishAlertPolicy.displayState(
            armingState: config.finishAlertArmingState,
            detectionPaused: detectionPaused(),
            markerDirExists: store.markerDirExists()
        )
        if state == .armed && !isWatching { return .hookNotInstalled }
        return state
    }

    init(
        store: BusyMarkerStore,
        markerDirURL: URL,
        config: FinishAlertConfigSource,
        sender: MessageSender,
        makeWatcher: @escaping (URL) -> MarkerDirectoryWatching,
        scheduler: FinishAlertScheduling,
        now: @escaping () -> Double,
        connectivity: ConnectivityInterface? = nil,
        stayAwakeOn: @escaping () -> Bool = { false },
        minimumRunSeconds: @escaping () -> Int = { FinishAlertTuning.minimumRunSeconds },
        waitingPrompts: @escaping () -> WaitingPromptContext = { .none }
    ) {
        self.store = store
        self.markerDirURL = markerDirURL
        self.disabledFlagURL = markerDirURL.appendingPathComponent(ClaudeBusyConstants.disabledFlagName)
        self.config = config
        self.sender = sender
        self.makeWatcher = makeWatcher
        self.scheduler = scheduler
        self.now = now
        self.connectivity = connectivity
        self.stayAwakeOn = stayAwakeOn
        self.readMinimumRunSeconds = minimumRunSeconds
        self.waitingPrompts = waitingPrompts
    }

    /// The single construction site, gated by the debug-sim wiring predicate
    /// (checked FIRST): nil in debugBattery mode, so no watcher, no marker
    /// read and no send path can exist there. Also nil without the lid guard
    /// (it owns the shared destination + priming) or without the shared
    /// sender. Construction does no I/O; nothing is watched until
    /// `reconcile()` finds the feature armable. Alert healing: `connectivity`
    /// comes from the startup swap (`ConnectivityWiring.makeInterface`) and
    /// is observed only while healing is armed; Stay Awake is read from the
    /// OBSERVED mirror. Issue #34: the run floor is read from `defaults`
    /// (`finishAlertMinimumRunSeconds`, clamped by the policy) at every diff.
    static func makeIfEnabled(
        debugBattery: Bool,
        lidGuard: LidGuardController?,
        sender: MessageSender?,
        connectivity: ConnectivityInterface,
        stayAwakeMirror: ObservedStayAwakeMirror,
        defaults: UserDefaults = .standard,
        waitingPrompts: @escaping () -> WaitingPromptContext = { .none }
    ) -> FinishAlertController? {
        guard FinishAlertPolicy.finishAlertMayBeConstructed(debugBattery: debugBattery) else { return nil }
        guard let lidGuard, let sender else { return nil }
        let markerDirURL = ClaudeBusyConstants.markerDirURL
        return FinishAlertController(
            store: MarkerDirectoryStore(root: markerDirURL),
            markerDirURL: markerDirURL,
            config: lidGuard,
            sender: sender,
            makeWatcher: { KqueueMarkerDirectoryWatcher(directory: $0) },
            scheduler: MainQueueFinishAlertScheduler(),
            now: { Date().timeIntervalSince1970 },
            connectivity: connectivity,
            stayAwakeOn: { stayAwakeMirror.value == true },
            minimumRunSeconds: {
                FinishAlertPolicy.minimumRunSeconds(stored: defaults.object(forKey: DefaultsKey.finishAlertMinimumRunSeconds))
            },
            waitingPrompts: waitingPrompts
        )
    }

    /// Called (on the main actor) after every state change the menu renders.
    func setChangeHandler(_ handler: (@MainActor () -> Void)?) {
        changeHandler = handler
    }

    private func notifyChanged() {
        changeHandler?()
    }

    // MARK: - Arming

    /// Arms or disarms to match the current config, pause flag and marker
    /// dir. Called at launch, on every menu open, after every lid-guard
    /// arming refresh (toggle / topic / server / priming), and after a pause
    /// toggle. Idempotent.
    func reconcile() {
        let gate = armingGate()
        if gate.mayArm && !isWatching {
            arm()
        } else if !gate.mayArm && isWatching {
            disarm(gate.reason)
        }
        reconcileHealing()
    }

    /// Alert healing — the menu-open reconcile is one of the three flush
    /// triggers (with the path coming back and a new session event). Only an
    /// OFFLINE lane reacts, so it coalesces with the others. Called right
    /// after `reconcile()` on every menu open.
    func menuOpened() {
        guard healing.phase == .offline else { return }
        applyHealing(.flushTrigger(.menuOpen))
    }

    /// Clean-quit path: drop the watcher, everything pending, and the path
    /// monitor.
    func disarmForShutdown() {
        disarm(.quit)
        applyHealing(.disarm)
    }

    private func arm() {
        let candidate = makeWatcher(markerDirURL)
        armGeneration += 1
        let generation = armGeneration
        let started = candidate.start { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleWatcherEvent(event, generation: generation) }
            }
        }
        guard started else {
            Self.logger.notice("finish alert: marker dir not watchable — staying disarmed")
            return
        }
        watcher = candidate
        // Baseline AFTER the watcher runs: a change racing the arm lands in
        // the baseline or raises an event, never in neither. Markers present
        // now are tracked from their recorded episode start (a valid hook v7
        // `ep` — so a relaunch keeps the run minutes) or else their own ts;
        // disappearances that happened while disarmed are unknown and never
        // alerted.
        let markers = store.identifiedMarkers()
        let armedAt = Int(now())
        tracked = FinishAlertPolicy.baseline(current: markers, now: armedAt)
        // F4: no prompt relayed before this arm is new to a diff of it: one
        // read, after the baseline, moves the seam's mark past them all (it
        // reaches the seam only while remote approvals listen).
        _ = waitingPrompts()
        Self.logger.notice("finish alert: armed, tracking \(self.tracked.count, privacy: .public) session(s)")
        logUnusableEpisodeStarts(FinishAlertPolicy.invalidEpisodeStartCount(in: markers, now: armedAt))
        notifyChanged()
    }

    /// Tears everything down. A send already in flight is left to its
    /// completion, which records the outcome but never sends more.
    private func disarm(_ reason: DisarmReason) {
        let wasWatching = isWatching
        let dropped = queue.count + retries.count + digest.messages().count
        watcher?.stop()
        watcher = nil
        debounce?.cancel()
        debounce = nil
        flush?.cancel()
        flush = nil
        for retry in retries.values { retry.work.cancel() }
        retries = [:]
        tracked = [:]
        digest = FinishAlertDigest()
        queue = []
        latestStillWorking = 0
        flushOutstanding = 0
        restoreQueued = false
        // Alert healing outlives the watcher (a lid-only outage): an open 429
        // hold must keep deferring its restore push, so the window stays.
        // (A flush this cut short resumes in `reconcileHealing`.)
        if !healing.isArmed { windowOpenUntil = nil }
        guard wasWatching || dropped > 0 else { return }
        Self.logger.notice("finish alert: disarmed (\(reason.rawValue, privacy: .public)), dropped \(dropped, privacy: .public) pending item(s)")
        notifyChanged()
    }

    // MARK: - Watcher events (hopped to the main actor)

    private func handleWatcherEvent(_ event: MarkerDirectoryEvent, generation: Int) {
        // An event from an earlier armed period, or one that raced a disarm.
        guard generation == armGeneration, isWatching else { return }
        switch event {
        case .directoryGone:
            // Never a finish: pending diffs are dropped with the rest.
            disarm(.directoryVanished)
            reconcileHealing()
        case .contentsChanged:
            debounce?.cancel()
            debounce = scheduler.schedule(after: FinishAlertTuning.debounceSeconds) { [weak self] in
                self?.debounceFired()
            }
        }
    }

    private func debounceFired() {
        debounce = nil
        guard isWatching else { return }
        // Re-gate first: the DISABLED flag write itself fires the watcher, so
        // a pause mid-burst lands here and disarms with no alert.
        let gate = armingGate()
        guard gate.mayArm else {
            disarm(gate.reason)
            reconcileHealing()
            return
        }
        let observedAt = now()
        let observation = FinishAlertPolicy.observe(
            previous: tracked,
            current: store.identifiedMarkers(),
            now: Int(observedAt),
            minimumRunSeconds: readMinimumRunSeconds()
        )
        tracked = observation.tracked
        latestStillWorking = observation.stillWorking
        logSuppressed(observation.suppressed)
        logUnusableEpisodeStarts(observation.invalidEpisodeStarts)
        if !observation.events.isEmpty {
            Self.logger.notice("finish alert: \(observation.events.count, privacy: .public) alert event(s) observed")
        }
        // F4: the prompt context is read once, and only for a diff with a
        // waiting write (zero hops otherwise): a transition that alerts, one
        // under the floor, or a waiting rewrite. So each such read moves the
        // seam's mark past the prompts it saw, whether or not the rule
        // yields. The policy drops the diff's waiting events only when it
        // does, and never a finish.
        let context: WaitingPromptContext = observation.waitingWrites > 0 ? waitingPrompts() : .none
        let fold = FinishAlertPolicy.promptPushFold(events: observation.events, waitingWrites: observation.waitingWrites,
                                                    context: context)
        logFoldedWaitingAlerts(fold.folded)
        let events = fold.events
        if !events.isEmpty {
            // A held digest past its max age is dropped BEFORE the new events
            // join it, so they are never dropped with it.
            expireHeldIfNeeded()
            for event in events {
                digest.fold(event, stillWorking: observation.stillWorking, prompts: fold.prompts, at: observedAt)
            }
        }
        // Healing re-gates on the new tracked count AFTER the fold: an alert
        // just raised keeps the lane holding, so the last session's finish
        // is never sent with healing disarmed under it.
        reconcileHealing()
        guard !events.isEmpty else { return }
        if healing.phase == .offline {
            applyHealing(.flushTrigger(.sessionEvent))
        } else {
            pump()
        }
    }

    private func logSuppressed(_ suppressed: [FinishAlertSuppression]) {
        for reason in [FinishAlertSuppression.underMinimumRun, .stale, .clockJump] {
            let count = suppressed.filter { $0 == reason }.count
            guard count > 0 else { continue }
            Self.logger.notice("finish alert: \(count, privacy: .public) transition(s) suppressed (\(reason.rawValue, privacy: .public))")
        }
    }

    /// Hook v7: markers whose `ep` the policy rejected fell back to NapCat's
    /// own anchor. Logged as a COUNT only — never a session id, the raw value
    /// or anything about the destination.
    private func logUnusableEpisodeStarts(_ count: Int) {
        guard count > 0 else { return }
        Self.logger.notice("finish alert: \(count, privacy: .public) unusable episode start(s), run minutes use the app's own anchor")
    }

    /// F4: waiting alerts dropped because the phone's own prompt push covers
    /// their wait. Logged as a COUNT only — never a session id or anything
    /// about the prompt.
    private func logFoldedWaitingAlerts(_ count: Int) {
        guard count > 0 else { return }
        Self.logger.notice("finish alert: \(count, privacy: .public) waiting alert(s) folded into the phone's prompt push")
    }

    // MARK: - Outbox

    /// Moves the digest to the send queue when the outbox allows, otherwise
    /// makes sure something will call back here: the window-close flush, or
    /// (with a send in flight past the window) that send's completion.
    /// Alert healing: OFFLINE holds open-ended; while FLUSHING the batch is a
    /// healing flush (an empty one still owes the restore push), and the same
    /// table applies — so an open 429 hold defers the flush and its push.
    private func pump() {
        let flushPending = healing.phase == .flushing && flushOutstanding == 0 && !restoreQueued
        guard !digest.isEmpty || flushPending else { return }
        if healing.phase == .flushing { expireHeldIfNeeded() }
        let at = now()
        switch FinishAlertPolicy.outboxDecision(windowOpenUntil: windowOpenUntil, sendInFlight: sendInFlight,
                                                offline: healing.phase == .offline, now: at) {
        case .sendNow:
            flush?.cancel()
            flush = nil
            let inFlush = healing.phase == .flushing
            let originatedAt = digest.originatedAt
            let batch = digest.messagesWithEventCounts()
            for (kind, events) in batch {
                queue.append(Outgoing(kind: kind, attempt: .first, originatedAt: originatedAt,
                                      events: events, inFlush: inFlush))
            }
            digest = FinishAlertDigest()
            if inFlush {
                flushOutstanding += batch.count
                // An empty healing flush: the restore push (if any) or done.
                if batch.isEmpty { finishFlushBatch() }
            }
            if !queue.isEmpty { windowOpenUntil = at + FinishAlertTuning.batchWindowSeconds }
            sendNext()
        case .holdForWindow:
            // A flush only while the window is still open; past it, the hold
            // is the in-flight send, whose completion pumps again.
            guard flush == nil, let until = windowOpenUntil, until > at else { return }
            scheduleFlush(after: until - at)
        case .holdOffline:
            // Alert healing: held open-ended — a flush trigger pumps again.
            return
        }
    }

    /// The window-close flush: one one-shot callback that pumps the digest.
    private func scheduleFlush(after delay: TimeInterval) {
        flush = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.flush = nil
            guard self.sessionLaneLive else { return }
            self.pump()
        }
    }

    /// B-1: ntfy answered 429 — hold the batch window open for `delay` from
    /// now (never shortening it) and move the ONE flush to the new close.
    /// Everything observed meanwhile folds into the digest and goes out as
    /// one message when the hold ends; a later 429 extends it again. Disarm
    /// cancels the flush and drops the digest like any other window.
    private func holdForRateLimit(_ delay: TimeInterval) {
        let at = now()
        let until = max(windowOpenUntil ?? at, at + delay)
        windowOpenUntil = until
        flush?.cancel()
        scheduleFlush(after: until - at)
        Self.logger.notice("finish alert: ntfy is rate-limiting — session alerts held and folded for \(Int(delay), privacy: .public) s")
    }

    /// S10: whatever is still QUEUED when ntfy answers 429 came from the same
    /// flush; sending it now would only hit the same rate limit. It folds back
    /// into the digest (`FinishAlertDigest.absorb`) and leaves with the ONE
    /// flush at the hold's end, together with anything observed meanwhile. A
    /// retry still waiting on its own timer is not in the queue — untouched.
    private func foldQueueBackIntoDigest() {
        // A healing flush cut short re-forms from the digest at the next pump
        // (a queued restore push is recomposed then, never folded).
        flushOutstanding = 0
        restoreQueued = false
        guard !queue.isEmpty else { return }
        let absorbed = queue
        queue = []
        for item in absorbed {
            digest.absorb(item.kind, stillWorking: latestStillWorking, at: item.originatedAt)
        }
        Self.logger.notice("finish alert: \(absorbed.count, privacy: .public) queued message(s) folded back into the held digest")
    }

    private func sendNext() {
        guard !sendInFlight, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        guard let destination = config.storedDestination else {
            // Unreachable while armed (arming requires a usable destination).
            let dropped = queue.count + 1
            queue = []
            Self.logger.notice("finish alert: ntfy settings not usable — dropped \(dropped, privacy: .public) message(s)")
            return
        }
        sendInFlight = true
        Self.logger.notice("finish alert: publishing \(Self.kindWord(item.kind), privacy: .public)")
        let generation = armGeneration
        // The completion ALWAYS hops: the sender may refuse INLINE (a lane
        // already busy, an unusable address), and state must never be
        // mutated re-entrantly inside `send`.
        sender.send(item.kind, to: destination, at: Date(timeIntervalSince1970: now())) { [weak self] outcome in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.sendCompleted(item, generation: generation, outcome: outcome)
                }
            }
        }
    }

    private func sendCompleted(_ item: Outgoing, generation: Int, outcome: MessageSendOutcome) {
        sendInFlight = false
        lastSendOutcome = outcome
        lastSendOutcomeAt = now()
        lastSendKind = item.kind
        let fields = LidGuardPolicy.outcomeLogFields(outcome)
        if let detail = fields.privateDetail {
            Self.logger.notice("finish alert: send outcome \(fields.publicCategory, privacy: .public) — \(detail, privacy: .private)")
        } else {
            Self.logger.notice("finish alert: send outcome \(fields.publicCategory, privacy: .public)")
        }
        // A restore push belongs to the healing flush, not to a watcher arm.
        let current = item.isRestore
            ? healing.phase == .flushing && restoreQueued
            : generation == armGeneration && isWatching
        if current {
            if case .sendFailed = outcome, healing.isArmed {
                // Alert healing: a session-lane pre-connect failure (single
                // flight + a validated destination make an inline refusal
                // unreachable here) holds the lane — the alert folds back
                // into the digest and leaves with the flush. Never a retry.
                digest.absorb(item.kind, stillWorking: latestStillWorking, at: item.originatedAt)
                applyHealing(.sessionSendFailed)
            } else {
                if case .retryAfter(let delay) = FinishAlertPolicy.retryDecision(outcome: outcome,
                                                                                attempt: item.attempt) {
                    scheduleRetry(item.kind, originatedAt: item.originatedAt, after: delay)
                }
                if let hold = FinishAlertPolicy.windowExtension(after: outcome) {
                    holdForRateLimit(hold)
                    foldQueueBackIntoDigest()
                } else if item.inFlush {
                    if outcome == .accepted { healing.recordDeliveredLate(item.events) }
                    flushOutstanding = max(0, flushOutstanding - 1)
                    if flushOutstanding == 0 { finishFlushBatch() }
                }
            }
        } else {
            Self.logger.notice("finish alert: a send completed after disarm — outcome recorded, nothing more sent")
        }
        if sessionLaneLive {
            if queue.isEmpty { pump() } else { sendNext() }
        }
        reconcileHealing()
        notifyChanged()
    }

    // MARK: - Retry (FA-7)

    private func scheduleRetry(_ kind: LidGuardMessageKind, originatedAt: Double, after delay: TimeInterval) {
        nextRetryToken += 1
        let token = nextRetryToken
        let work = scheduler.schedule(after: delay) { [weak self] in
            self?.retryFired(token: token, kind: kind, originatedAt: originatedAt)
        }
        retries[token] = PendingRetry(work: work, kind: kind, originatedAt: originatedAt)
        Self.logger.notice("finish alert: send failed before leaving the Mac — one retry in \(Int(delay), privacy: .public) s")
    }

    private func retryFired(token: Int, kind: LidGuardMessageKind, originatedAt: Double) {
        retries[token] = nil
        // Re-gated at fire time against the live state.
        guard FinishAlertPolicy.retryMayFire(
            armed: isWatching,
            paused: detectionPaused(),
            markerDirExists: store.markerDirExists(),
            originatedAt: originatedAt,
            now: now()
        ) else {
            Self.logger.notice("finish alert: retry dropped")
            return
        }
        queue.insert(Outgoing(kind: kind, attempt: .retry, originatedAt: originatedAt), at: 0)
        sendNext()
    }

    // MARK: - Alert-channel healing (issue #23)

    /// Arms or disarms healing to match the live state (`healingMayArm`), and
    /// resumes a healing flush a disarm cut short. Called after every arm /
    /// disarm, observation and send completion, and on every reconcile (menu
    /// open, launch, config and pause changes, Stay Awake flips). Idempotent.
    private func reconcileHealing() {
        guard connectivity != nil else { return }
        let lidMisses = config.lidAlertMissCount
        let holding = !digest.isEmpty || !queue.isEmpty || sendInFlight || !retries.isEmpty
            || healing.outageHasContent(lidMisses: lidMisses)
        let mayArm = FinishAlertPolicy.healingMayArm(
            destinationValid: config.storedDestination != nil,
            sessionAlertsArmed: isWatching,
            lidAlertArmed: config.lidAlertArmingState == .armed,
            stayAwakeOn: stayAwakeOn(),
            trackedSessions: tracked.count,
            sessionLaneHolding: holding)
        if mayArm != healing.isArmed { applyHealing(mayArm ? .arm : .disarm) }
        if healing.phase == .flushing && flushOutstanding == 0 && !restoreQueued { pump() }
    }

    /// Feeds one input to the state machine and performs its effects.
    private func applyHealing(_ input: AlertHealingInput) {
        guard let connectivity else { return }
        let before = healing.phase
        let dropped = input == .disarm ? healingDisarmDropCount() : 0
        let effects = healing.apply(input, now: now(), lidMisses: config.lidAlertMissCount)
        let after = healing.phase
        // Logged before the effects run: a flush may complete inside them.
        if after != before { logHealingTransition(from: before, to: after, dropped: dropped) }
        for effect in effects {
            switch effect {
            case .startMonitor:
                healingGeneration += 1
                let generation = healingGeneration
                connectivity.start { [weak self] status in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.handlePath(status, generation: generation) }
                    }
                }
            case .stopMonitor:
                connectivity.stop()
                flushOutstanding = 0
                restoreQueued = false
            case .scheduleDebounce:
                pathDebounce?.cancel()
                pathDebounce = scheduler.schedule(after: AlertHealingTuning.pathDebounceSeconds) { [weak self] in
                    guard let self else { return }
                    self.pathDebounce = nil
                    self.applyHealing(.pathDebounceFired)
                }
            case .cancelDebounce:
                pathDebounce?.cancel()
                pathDebounce = nil
            case .holdSessionLane:
                holdSessionLaneForOutage()
            case .flush:
                pump()
            }
        }
        if after != before { notifyChanged() }
    }

    /// A path update, hopped to the main actor. One from an earlier armed
    /// period, or one that raced a disarm, is ignored.
    private func handlePath(_ status: ConnectivityPathStatus, generation: Int) {
        guard generation == healingGeneration, healing.isArmed else { return }
        applyHealing(.path(status))
    }

    /// OFFLINE was entered: pending single retries are cancelled and fold —
    /// with anything still queued — into the held digest, so each alert is
    /// sent exactly once, by the flush.
    private func holdSessionLaneForOutage() {
        let pending = retries.values.sorted { $0.originatedAt < $1.originatedAt }
        retries = [:]
        for retry in pending {
            retry.work.cancel()
            digest.absorb(retry.kind, stillWorking: latestStillWorking, at: retry.originatedAt)
        }
        let count = pending.count + queue.count
        foldQueueBackIntoDigest()
        Self.logger.notice("finish alert: connection lost — session alerts held until it returns, \(count, privacy: .public) pending item(s) folded in")
    }

    /// The held digest's 12 h max age (only inside an outage): its events
    /// collapse to a DROPPED count for the restore push.
    private func expireHeldIfNeeded() {
        let dropped = healing.expireHeldDigest(&digest, now: now())
        guard dropped > 0 else { return }
        Self.logger.notice("finish alert: \(dropped, privacy: .public) held alert(s) passed the 12 h max age — dropped, counted for the restore push")
    }

    /// Every session message of the healing flush is done: append the restore
    /// push when it has something to say (it rides the same flush, so it
    /// already deferred to any 429 hold), else the flush is complete.
    private func finishFlushBatch() {
        guard healing.phase == .flushing, flushOutstanding == 0 else { return }
        if !restoreQueued, let outage = healing.outage,
           let restore = FinishAlertPolicy.restoreMessage(for: outage, lidMisses: config.lidAlertMissCount) {
            restoreQueued = true
            flushOutstanding = 1
            queue.append(Outgoing(kind: restore, attempt: .first, originatedAt: now(), inFlush: true))
            return
        }
        restoreQueued = false
        applyHealing(.flushCompleted)
    }

    /// What a healing disarm forgets: the open outage's report (delivered
    /// late + dropped + lid misses). Held alerts themselves stay in the digest.
    private func healingDisarmDropCount() -> Int {
        guard let outage = healing.outage else { return 0 }
        return outage.deliveredLate + outage.dropped + max(0, config.lidAlertMissCount - outage.lidMissBaseline)
    }

    /// Fixed words + counts only — never a path detail, an address or a topic.
    private func logHealingTransition(from before: AlertHealingPhase, to after: AlertHealingPhase, dropped: Int) {
        switch after {
        case .disarmed:
            Self.logger.notice("finish alert: alert healing disarmed, dropped \(dropped, privacy: .public) outage report item(s)")
        case .online where before == .disarmed:
            Self.logger.notice("finish alert: alert healing armed")
        case .online:
            Self.logger.notice("finish alert: connection healed — held session alerts flushed")
        case .offline where before == .flushing:
            Self.logger.notice("finish alert: the flush failed before leaving the Mac — offline again, outage start kept")
        case .offline:
            break   // `holdSessionLaneForOutage` logs the entry with its count
        case .flushing:
            Self.logger.notice("finish alert: flushing the held session alerts")
        }
    }

    // MARK: - Helpers

    /// Same kill-switch rule as `ClaudeActivityController`: the DISABLED flag
    /// file exists in the marker dir.
    private func detectionPaused() -> Bool {
        FileManager.default.fileExists(atPath: disabledFlagURL.path)
    }

    /// The arming predicate for the live inputs, plus the fixed word naming
    /// why it is false (meaningless when `mayArm`).
    private func armingGate() -> (mayArm: Bool, reason: DisarmReason) {
        let armingState = config.finishAlertArmingState
        let paused = detectionPaused()
        let dirExists = store.markerDirExists()
        let mayArm = FinishAlertPolicy.finishAlertMayArm(
            armingState: armingState, detectionPaused: paused, markerDirExists: dirExists)
        let reason: DisarmReason
        switch FinishAlertPolicy.displayState(armingState: armingState, detectionPaused: paused,
                                              markerDirExists: dirExists) {
        case .off: reason = .off
        case .needsTopic: reason = .needsTopic
        case .needsTestSend: reason = .needsTestSend
        case .paused: reason = .paused
        case .hookNotInstalled, .armed: reason = .directoryMissing
        }
        return (mayArm, reason)
    }

    /// The log word for a message kind — a fixed literal, never a payload.
    private static func kindWord(_ kind: LidGuardMessageKind) -> String {
        switch kind {
        case .sessionFinished: return "finish"
        case .needsAttention: return "waiting"
        case .connectionRestored: return "restored"
        case .lidAlert, .test: return "other"
        }
    }
}
