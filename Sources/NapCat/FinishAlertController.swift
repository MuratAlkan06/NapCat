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

/// The slice of the lid-guard configuration the finish alert reads: its OWN
/// toggle folded into the shared arming grammar, plus the SHARED validated
/// destination. Adopted by `LidGuardController`; never exposes the raw topic.
protocol FinishAlertConfigSource: AnyObject {
    var finishAlertArmingState: LidGuardArmingState { get }
    var storedDestination: NtfyDestination? { get }
}

extension LidGuardController: FinishAlertConfigSource {}

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
    /// Pending single retries, keyed by a local token so a fired retry can
    /// remove itself. All cancelled on disarm.
    private var retries: [Int: FinishAlertScheduledWork] = [:]
    private var nextRetryToken = 0
    private var changeHandler: (@MainActor () -> Void)?

    // MARK: Menu-facing snapshot

    private(set) var lastSendOutcome: MessageSendOutcome?
    private(set) var lastSendOutcomeAt: Double?
    private(set) var lastSendKind: LidGuardMessageKind?

    /// True while the kqueue watcher is running — the ONLY meaning of "armed".
    var isWatching: Bool { watcher?.isRunning == true }

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
        now: @escaping () -> Double
    ) {
        self.store = store
        self.markerDirURL = markerDirURL
        self.disabledFlagURL = markerDirURL.appendingPathComponent(ClaudeBusyConstants.disabledFlagName)
        self.config = config
        self.sender = sender
        self.makeWatcher = makeWatcher
        self.scheduler = scheduler
        self.now = now
    }

    /// The single construction site, gated by the debug-sim wiring predicate
    /// (checked FIRST): nil in debugBattery mode, so no watcher, no marker
    /// read and no send path can exist there. Also nil without the lid guard
    /// (it owns the shared destination + priming) or without the shared
    /// sender. Construction does no I/O; nothing is watched until
    /// `reconcile()` finds the feature armable.
    static func makeIfEnabled(
        debugBattery: Bool,
        lidGuard: LidGuardController?,
        sender: MessageSender?
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
            now: { Date().timeIntervalSince1970 }
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
    }

    /// Clean-quit path: drop the watcher and everything pending.
    func disarmForShutdown() {
        disarm(.quit)
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
        // now are tracked from their own ts; disappearances that happened
        // while disarmed are unknown and never alerted.
        tracked = FinishAlertPolicy.baseline(current: store.identifiedMarkers(), now: Int(now()))
        Self.logger.notice("finish alert: armed, tracking \(self.tracked.count, privacy: .public) session(s)")
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
        for work in retries.values { work.cancel() }
        retries = [:]
        tracked = [:]
        digest = FinishAlertDigest()
        queue = []
        windowOpenUntil = nil
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
            return
        }
        let observedAt = now()
        let observation = FinishAlertPolicy.observe(
            previous: tracked,
            current: store.identifiedMarkers(),
            now: Int(observedAt)
        )
        tracked = observation.tracked
        logSuppressed(observation.suppressed)
        guard !observation.events.isEmpty else { return }
        Self.logger.notice("finish alert: \(observation.events.count, privacy: .public) alert event(s) observed")
        for event in observation.events {
            digest.fold(event, stillWorking: observation.stillWorking, at: observedAt)
        }
        pump()
    }

    private func logSuppressed(_ suppressed: [FinishAlertSuppression]) {
        for reason in [FinishAlertSuppression.underMinimumRun, .stale, .clockJump] {
            let count = suppressed.filter { $0 == reason }.count
            guard count > 0 else { continue }
            Self.logger.notice("finish alert: \(count, privacy: .public) transition(s) suppressed (\(reason.rawValue, privacy: .public))")
        }
    }

    // MARK: - Outbox

    /// Moves the digest to the send queue when the outbox allows, otherwise
    /// makes sure something will call back here: the window-close flush, or
    /// (with a send in flight past the window) that send's completion.
    private func pump() {
        guard !digest.isEmpty else { return }
        let at = now()
        switch FinishAlertPolicy.outboxDecision(windowOpenUntil: windowOpenUntil, sendInFlight: sendInFlight, now: at) {
        case .sendNow:
            flush?.cancel()
            flush = nil
            let originatedAt = digest.originatedAt
            for kind in digest.messages() {
                queue.append(Outgoing(kind: kind, attempt: .first, originatedAt: originatedAt))
            }
            digest = FinishAlertDigest()
            windowOpenUntil = at + FinishAlertTuning.batchWindowSeconds
            sendNext()
        case .holdForWindow:
            // A flush only while the window is still open; past it, the hold
            // is the in-flight send, whose completion pumps again.
            guard flush == nil, let until = windowOpenUntil, until > at else { return }
            scheduleFlush(after: until - at)
        }
    }

    /// The window-close flush: one one-shot callback that pumps the digest.
    private func scheduleFlush(after delay: TimeInterval) {
        flush = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.flush = nil
            guard self.isWatching else { return }
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
                    self?.sendCompleted(item.kind, attempt: item.attempt, originatedAt: item.originatedAt,
                                        generation: generation, outcome: outcome)
                }
            }
        }
    }

    private func sendCompleted(_ kind: LidGuardMessageKind, attempt: SendAttempt, originatedAt: Double,
                               generation: Int, outcome: MessageSendOutcome) {
        sendInFlight = false
        lastSendOutcome = outcome
        lastSendOutcomeAt = now()
        lastSendKind = kind
        let fields = LidGuardPolicy.outcomeLogFields(outcome)
        if let detail = fields.privateDetail {
            Self.logger.notice("finish alert: send outcome \(fields.publicCategory, privacy: .public) — \(detail, privacy: .private)")
        } else {
            Self.logger.notice("finish alert: send outcome \(fields.publicCategory, privacy: .public)")
        }
        if generation == armGeneration && isWatching {
            if case .retryAfter(let delay) = FinishAlertPolicy.retryDecision(outcome: outcome, attempt: attempt) {
                scheduleRetry(kind, originatedAt: originatedAt, after: delay)
            }
            if let hold = FinishAlertPolicy.windowExtension(after: outcome) {
                holdForRateLimit(hold)
            }
        } else {
            Self.logger.notice("finish alert: a send completed after disarm — outcome recorded, nothing more sent")
        }
        if isWatching {
            if queue.isEmpty { pump() } else { sendNext() }
        }
        notifyChanged()
    }

    // MARK: - Retry (FA-7)

    private func scheduleRetry(_ kind: LidGuardMessageKind, originatedAt: Double, after delay: TimeInterval) {
        nextRetryToken += 1
        let token = nextRetryToken
        retries[token] = scheduler.schedule(after: delay) { [weak self] in
            self?.retryFired(token: token, kind: kind, originatedAt: originatedAt)
        }
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
        case .lidAlert, .test: return "other"
        }
    }
}
