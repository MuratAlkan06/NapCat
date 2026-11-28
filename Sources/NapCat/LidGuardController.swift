import Foundation
import os

/// One fresh Claude-busy reading, taken at the moment the system announces
/// sleep. `sessionCount` is the number of FRESH busy markers — the only Claude
/// datum that reaches a message body (as a count, never as text).
struct LidGuardBusySample: Equatable, Sendable {
    let taskInFlight: Bool
    let sessionCount: Int
}

/// Supplies `LidGuardBusySample` on demand. Returns nil when the sample could
/// not be taken inside `LidGuardTuning.snapshotBudget` — the guard then SKIPS
/// (it never fires blind).
typealias ClaudeBusyProvider = @Sendable () -> LidGuardBusySample?

/// Track B slice B2 — the DELIVERY half. When the Mac starts sleeping while a
/// Claude turn is in flight and Stay Awake is off, publish one ntfy push.
/// NOTIFY-ONLY: it never controls Claude, never arms itself, and never touches
/// sleep or charging state.
///
/// Zero privileged surface: an https POST and IOKit power notifications are
/// both unprivileged. No sudo, no PLAN §4 command, no smc, no subprocess, no
/// TCC prompt.
///
/// Thread model: the config/menu surface is used from the main actor, while
/// `handle(_:ack:)` runs on the sleep source's private queue. Every piece of
/// mutable state lives behind `lock`, hence `@unchecked Sendable`.
final class LidGuardController: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "lidguard")

    private let defaults: UserDefaults
    /// Where the ntfy topic persists (the keychain, issue #103). Touched at
    /// construction — the ONE startup read — and when `setTopic` saves; the
    /// sleep path never reaches it (lint-locked in LidGuardStructureTests).
    private let topicStore: TopicStore
    private let sleepSource: SystemSleepSource
    private let sender: MessageSender
    /// Sendable atomic mirror of the OBSERVED stay-awake state, written
    /// synchronously at SleepStateController's single choke point — so a
    /// toggle-off made seconds before the lid closes is already visible here
    /// without a hop to the main actor.
    private let stayAwakeMirror: ObservedStayAwakeMirror
    private let busyProvider: ClaudeBusyProvider
    /// WALL CLOCK (unix epoch seconds). Injected for tests; it must advance
    /// across sleep — see `LidGuardPolicy.cooldownExpired`.
    private let now: @Sendable () -> Double
    /// Separate queue for the force-ack timer: the WillSleep handler may block
    /// its own queue for `ackHoldBudget`, so the backstop cannot live there.
    private let ackQueue = DispatchQueue(label: "com.muratalkan.napcat.lidguard.ack")

    private let lock = NSLock()
    /// The ntfy topic — A SECRET. The in-memory copy every reader uses: set
    /// once at construction from the store, then only by a successful save.
    private var topic: String
    /// Whether the last `setTopic` could not save to the store (it then kept
    /// the previous topic). In-memory; the editor reads it right after Save.
    private var lastTopicSaveFailed = false
    /// A topic item exists but this session holds no valid value from it:
    /// the startup read could not get it (a keychain error, a refused
    /// access, bytes that are not text), or it holds a value that is not
    /// valid exactly as stored (`LidGuardPolicy.isNormalizedTopic`; an empty
    /// one included). Cleared once a new topic is saved. Remote approvals
    /// then keep every prompt on the Mac.
    private var topicUnreadable = false
    /// In-memory ONLY. Persisting it would cache intent across relaunches.
    private var lastFiredAt: Double?
    private var sendInFlight = false
    private var lastOutcome: MessageSendOutcome?
    private var lastOutcomeAt: Double?
    /// Alert healing (issue #23): lid ALERTS that failed before leaving the
    /// Mac (`.sendFailed`) since launch. COUNTED ONLY — this file never reads
    /// the network path, and the lid send path is never gated, queued,
    /// retried or re-sent because of it. The finish alert reads the counter
    /// (its delta across an outage) for the restore push.
    private var lidAlertMisses = 0
    private var changeHandler: (@Sendable () -> Void)?
    private var armingRefreshHook: (@Sendable () -> Void)?

    init(
        defaults: UserDefaults,
        topicStore: TopicStore,
        sleepSource: SystemSleepSource,
        sender: MessageSender,
        stayAwakeMirror: ObservedStayAwakeMirror,
        busyProvider: @escaping ClaudeBusyProvider,
        now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.defaults = defaults
        self.topicStore = topicStore
        self.sleepSource = sleepSource
        self.sender = sender
        self.stayAwakeMirror = stayAwakeMirror
        self.busyProvider = busyProvider
        self.now = now
        let startup = Self.startupTopic(defaults: defaults, store: topicStore)
        topic = startup.topic
        topicUnreadable = startup.unreadable
    }

    /// The ONE startup read of the topic (issue #103). First the one-time
    /// move out of plaintext UserDefaults (`TopicKeychainMigration`: write,
    /// verify, then delete the old key); its verified read-back doubles as
    /// this read. Otherwise one keychain read — which, on the first launch
    /// of an ad-hoc rebuild, waits for the user's answer to the keychain's
    /// Allow dialog. An unreadable item starts the session with no topic —
    /// and says so (`unreadable`), so remote approvals can fail closed;
    /// nothing is deleted or rewritten because of it. An item that holds a
    /// value not valid exactly as stored (`LidGuardPolicy.isNormalizedTopic`,
    /// an empty one included) is `unreadable` too; that value is still this
    /// session's topic. Only no item at all reads as no topic to remote
    /// approvals.
    private static func startupTopic(defaults: UserDefaults, store: TopicStore) -> (topic: String, unreadable: Bool) {
        switch TopicKeychainMigration.run(defaults: defaults, store: store) {
        case .moved(let value):
            Self.logger.notice("startup: moved the ntfy setting into the keychain and deleted the plaintext copy")
            // An empty value was moved as a delete, verified gone: no item.
            return (value, !value.isEmpty && !LidGuardPolicy.isNormalizedTopic(value))
        case .kept(let value):
            Self.logger.error("startup: could not move the ntfy setting into the keychain — kept in place, retrying next launch")
            // The item may still be there (a refused delete, an unverified
            // write), so an empty value is not "no item".
            return (value, !LidGuardPolicy.isNormalizedTopic(value))
        case .discardedJunk:
            Self.logger.notice("startup: deleted an unusable legacy ntfy value (not a string)")
        case .nothingToMove:
            break
        }
        switch store.read() {
        case .found(let value):
            return (value, !LidGuardPolicy.isNormalizedTopic(value))
        case .notFound:
            return ("", false)
        case .failed(let status):
            Self.logger.error("startup: the keychain did not return the ntfy setting (OSStatus \(status, privacy: .public)) — starting without it")
            return ("", true)
        }
    }

    /// The ONE construction site of the real ntfy sender, gated by the same
    /// debug-sim wiring predicate: nil in debugBattery mode, so no URLSession
    /// and no network request can exist there. AppDelegate builds it ONCE and
    /// injects the same instance into the lid guard and (Track C) the finish
    /// alert, so both share one sender — and its per-kind lanes keep a session
    /// alert from ever starving the lid publish.
    static func makeSharedSender(debugBattery: Bool) -> NtfyMessageSender? {
        guard LidGuardPolicy.lidGuardMayBeConstructed(debugBattery: debugBattery) else { return nil }
        return NtfyMessageSender()
    }

    /// The single construction site, gated by the debug-sim wiring predicate
    /// (ADR §8 mirror, same shape as B1's `makeIfEnabled`). Returns nil in
    /// debugBattery mode — nothing in this subsystem is built there, so no
    /// IOKit registration and no network request can exist (the predicate is
    /// checked FIRST, so even a supplied sender cannot bypass it). Also nil
    /// without the B1 detection stack (there would be nothing to notify about)
    /// and without a sender (`makeSharedSender` returned nil).
    static func makeIfEnabled(
        debugBattery: Bool,
        defaults: UserDefaults = .standard,
        stayAwakeMirror: ObservedStayAwakeMirror,
        detection: ClaudeActivityController?,
        sender: MessageSender?,
        topicStore: TopicStore
    ) -> LidGuardController? {
        guard LidGuardPolicy.lidGuardMayBeConstructed(debugBattery: debugBattery) else { return nil }
        guard let detection, let sender else { return nil }
        return LidGuardController(
            defaults: defaults,
            topicStore: topicStore,
            sleepSource: IOKitSystemSleepSource(),
            sender: sender,
            stayAwakeMirror: stayAwakeMirror,
            busyProvider: busyProvider(detection: detection)
        )
    }

    /// Bridges the main-actor-isolated B1 readers to the sleep source's queue
    /// with a HARD budget, so a busy main thread can delay the power
    /// acknowledgment by at most `LidGuardTuning.snapshotBudget`.
    static func busyProvider(detection: ClaudeActivityController) -> ClaudeBusyProvider {
        {
            let box = BusySampleBox()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { box.set(detection.sampleBusyNow()) }
            }
            return box.wait(timeout: LidGuardTuning.snapshotBudget)
        }
    }

    /// Republished on the main actor by MenuContentView after any state change
    /// that the panel renders (send outcome, wake).
    func setChangeHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        changeHandler = handler
        lock.unlock()
    }

    private func notifyChanged() {
        lock.lock()
        let handler = changeHandler
        lock.unlock()
        handler?()
    }

    /// Track C: invoked at the END of every `refreshArming()` — so a toggle,
    /// topic, server or priming change also reconciles the finish alert. It
    /// may run OFF the main thread (priming completes on the sender's queue),
    /// so the installed hook must hop to the main actor itself.
    func setArmingRefreshHook(_ hook: (@Sendable () -> Void)?) {
        lock.lock()
        armingRefreshHook = hook
        lock.unlock()
    }

    // MARK: - Persistence (PLAN.md §11 — the lid-guard keys + the Track C
    // finish-alert toggle, nothing else; the topic itself is in the keychain)

    var isEnabled: Bool { defaults.bool(forKey: DefaultsKey.lidGuardEnabled) }
    /// The ntfy topic — A SECRET (it is the only password on the feed). The
    /// IN-MEMORY copy (read from the keychain once, at construction): the
    /// sleep path, the menu and the finish alert all read this, never the
    /// store. Kept raw so the menu can render an "unusable" caption for a
    /// hand-edited value; every consumer goes through
    /// `LidGuardPolicy.validateTopic`.
    var storedTopic: String {
        lock.lock()
        defer { lock.unlock() }
        return topic
    }

    /// F4: the strings the remote-approvals category gate must keep on the
    /// Mac — the topic, from memory (never the store), exactly the value the
    /// alerts are sent to — or nil while a topic item exists that holds no
    /// valid value this session could read (`topicUnreadable`): the gate
    /// cannot look for a secret it does not know, so every prompt then stays
    /// local (fail closed). No item at all is an empty list, not nil.
    var approvalSecrets: [String]? {
        lock.lock()
        defer { lock.unlock() }
        if topicUnreadable { return nil }
        return topic.isEmpty ? [] : [topic]
    }

    /// True when the last `setTopic` could not save the topic to the keychain
    /// and kept the previous one — the editor reports it instead of closing.
    var topicSaveFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastTopicSaveFailed
    }

    /// The ntfy server origin. Unset (or a junk non-string value) reads back as
    /// the public instance, so the feature has a working default.
    var storedServer: String {
        let raw = defaults.string(forKey: DefaultsKey.lidGuardNtfyServer) ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? LidGuardTuning.defaultNtfyServer
            : raw
    }
    /// Unix epoch seconds of the last SUCCESSFUL config-time test send; 0 =
    /// never primed. Arming requires it (see `armingState`).
    var primedAt: Double { defaults.double(forKey: DefaultsKey.lidGuardPrimedAt) }

    /// The validated pair the sender needs, or nil while the config is
    /// unusable.
    var storedDestination: NtfyDestination? {
        LidGuardPolicy.destination(server: storedServer, topic: storedTopic)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: DefaultsKey.lidGuardEnabled)
        refreshArming()
    }

    /// Stores a validated topic. A CHANGED topic always clears the primed flag:
    /// the test send must be repeated against the new topic, so the first
    /// message to it is never the lid-close one. An unchanged one (the
    /// editor saves both fields on every Save) touches nothing — not even the
    /// keychain. If the keychain refuses the save, the previous topic stays,
    /// still primed, and `topicSaveFailed` says so.
    @discardableResult
    func setTopic(_ raw: String) -> TopicValidation {
        let validation = LidGuardPolicy.validateTopic(raw)
        lock.lock()
        lastTopicSaveFailed = false
        lock.unlock()
        switch validation {
        case .valid(let newTopic):
            if newTopic != storedTopic { commitTopic(newTopic) }
        case .empty:
            if !storedTopic.isEmpty { commitTopic("") }
        case .invalid:
            // Keep the previous value; the caller renders the inline caption.
            break
        }
        refreshArming()
        return validation
    }

    /// Saves first, then adopts: the in-memory topic changes only once the
    /// keychain holds the new value (an empty topic deletes the item).
    private func commitTopic(_ newTopic: String) {
        let saved = newTopic.isEmpty ? topicStore.delete() : topicStore.write(newTopic)
        lock.lock()
        if saved {
            topic = newTopic
            topicUnreadable = false
        }
        lastTopicSaveFailed = !saved
        lock.unlock()
        guard saved else {
            Self.logger.error("lid guard: the keychain refused the new ntfy setting — keeping the previous one")
            return
        }
        defaults.set(0.0, forKey: DefaultsKey.lidGuardPrimedAt)
    }

    /// Stores a validated server. Like the topic, a CHANGED server clears the
    /// primed flag — a different instance is a different feed, and the test
    /// send has to prove it. Clearing the field reverts to the public default.
    @discardableResult
    func setServer(_ raw: String) -> ServerValidation {
        let validation = LidGuardPolicy.validateServer(raw)
        switch validation {
        case .valid(let server):
            if server != storedServer {
                defaults.set(server, forKey: DefaultsKey.lidGuardNtfyServer)
                defaults.set(0.0, forKey: DefaultsKey.lidGuardPrimedAt)
            }
        case .empty:
            if storedServer != LidGuardTuning.defaultNtfyServer {
                defaults.set(0.0, forKey: DefaultsKey.lidGuardPrimedAt)
            }
            defaults.removeObject(forKey: DefaultsKey.lidGuardNtfyServer)
        case .invalid:
            break
        }
        refreshArming()
        return validation
    }

    private func markPrimed() {
        defaults.set(now(), forKey: DefaultsKey.lidGuardPrimedAt)
        refreshArming()
    }

    // MARK: - Arming

    var armingState: LidGuardArmingState {
        LidGuardPolicy.armingState(
            enabled: isEnabled,
            server: storedServer,
            topic: storedTopic,
            primedAt: primedAt
        )
    }

    var isArmed: Bool { armingState == .armed }

    // MARK: - Track C finish alert (own toggle, SHARED destination + priming)

    /// The finish-alert toggle (`claudeFinishAlertEnabled`, default false).
    /// Independent of `isEnabled`: the lid guard may be off while the finish
    /// alert is on, and vice versa.
    var finishAlertEnabled: Bool { defaults.bool(forKey: DefaultsKey.claudeFinishAlertEnabled) }

    /// Persists the toggle, then re-runs the arming reconciliation (the hook
    /// the Track C watcher attaches to). It never registers the lid guard's
    /// sleep notification on its own — that still follows `armingState`.
    func setFinishAlertEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: DefaultsKey.claudeFinishAlertEnabled)
        refreshArming()
    }

    /// The finish alert reuses the lid-guard arming grammar with ITS OWN
    /// toggle and the SHARED topic / server / primed-at: one destination, one
    /// priming test send. Changing the topic or server clears `primedAt`, so
    /// both features disarm together until the next successful test send.
    var finishAlertArmingState: LidGuardArmingState {
        LidGuardPolicy.armingState(
            enabled: finishAlertEnabled,
            server: storedServer,
            topic: storedTopic,
            primedAt: primedAt
        )
    }

    /// True while the IOKit power notification is registered. The OFF /
    /// not-armed states must leave ZERO sleep-path footprint.
    var isObservingSleep: Bool { sleepSource.isRunning }

    /// Registers or deregisters the sleep hook to match the current config.
    /// Called at launch, on every menu open, and after every config change.
    ///
    /// The stay-awake mirror is expected to have been refreshed just before
    /// (menu-open reconciliation / launch reconciliation both call
    /// `SleepStateController.refreshObservedState()` first), so an arming
    /// controller starts from an observed value rather than a stale one.
    func refreshArming() {
        // Every exit path — including the "already registered" early
        // returns — ends with the finish-alert hook.
        defer {
            lock.lock()
            let hook = armingRefreshHook
            lock.unlock()
            hook?()
        }
        if isArmed {
            guard !sleepSource.isRunning else { return }
            sleepSource.start { [weak self] event, ack in
                guard let self else {
                    // Never leave a power change unacknowledged — an
                    // unanswered notification delays EVERY sleep for ~30 s.
                    ack.allow()
                    return
                }
                self.handle(event, ack: ack)
            }
        } else {
            guard sleepSource.isRunning else { return }
            sleepSource.stop()
        }
    }

    /// Clean-quit path: drop the registration (mirrors the stay-awake revert).
    func disarmForShutdown() {
        sleepSource.stop()
    }

    // MARK: - Power message table

    /// Every message the source delivers gets an answer here. Acknowledgment is
    /// EXACTLY ONCE per notification (`SystemSleepAck` is idempotent).
    func handle(_ event: SystemSleepEvent, ack: SystemSleepAck) {
        switch event {
        case .canSystemSleep:
            // IMMEDIATE ALLOW, no policy evaluation whatsoever. This message is
            // the idle-sleep poll: while it is unanswered the whole machine's
            // idle sleep is delayed, so the armed state must be invisible here.
            ack.allow()
        case .systemWillSleep:
            handleWillSleep(ack)
        case .systemWillPowerOn, .systemHasPoweredOn:
            handleWake(event)
        }
    }

    private func handleWillSleep(_ ack: SystemSleepAck) {
        // Unconditional backstop first: whatever happens below — a wedged main
        // thread, a slow spawn — the power change is acknowledged far inside
        // the OS ceiling.
        let forceAck = DispatchWorkItem { ack.allow() }
        ackQueue.asyncAfter(deadline: .now() + LidGuardTuning.forceAckCeiling, execute: forceAck)
        defer {
            ack.allow()
            forceAck.cancel()
        }

        guard let busy = busyProvider() else {
            Self.logger.notice("lid guard: sleeping, but the Claude sample timed out — not sending")
            return
        }
        let sampledAt = now()
        let snapshot = snapshot(busy: busy)
        lock.lock()
        let previousFiredAt = lastFiredAt
        let inputs = LidGuardGateInputs(
            snapshot: snapshot,
            sendInFlight: sendInFlight,
            lastFiredAt: lastFiredAt,
            now: sampledAt
        )
        let decision = LidGuardPolicy.decide(inputs)
        // `decide` returns `.fire` only for a snapshot that carries a validated
        // destination, so pairing the two here is redundant by construction —
        // but it guarantees the single-flight claim is NEVER taken without
        // something to publish, which would otherwise wedge the gate forever.
        let target = decision == .fire ? snapshot.destination : nil
        if target != nil {
            // Claimed BEFORE the request so a second notification cannot race in.
            sendInFlight = true
            lastFiredAt = sampledAt
        }
        lock.unlock()

        guard let destination = target else {
            if case .skip(let reason) = decision {
                // PERSISTED level on purpose (F1, 2026-10-18): this was `.debug`,
                // which macOS never writes to disk, so `log show` could not see
                // the skip reason and a one-click "Pause detection" hid for five
                // weeks. One line per real system sleep — low volume.
                Self.logger.notice("lid guard: sleeping, no alert (\(reason.rawValue, privacy: .public))")
            }
            return
        }

        Self.logger.notice("lid guard: sleeping with a Claude task in flight — publishing the alert")
        let done = DispatchSemaphore(value: 0)
        let inline = InlineOutcomeProbe()
        sender.send(
            .lidAlert(busySessionCount: busy.sessionCount),
            to: destination,
            at: Date(timeIntervalSince1970: sampledAt)
        ) { [weak self] outcome in
            inline.record(outcome)
            if case .sendFailed = outcome { self?.countLidAlertMiss() }
            self?.recordOutcome(outcome, clearingSendInFlight: true)
            done.signal()
        }
        // A refusal that lands INLINE — before `send` even returns — means
        // nothing was put on the wire: the sender's own single-flight held (its
        // previous request can outlive our `sendInFlight`, which a wake clears),
        // or the address was unusable. Spending the 15-minute cooldown on a
        // publish that never happened would silence the NEXT real one, so the
        // claim is rolled back. Only an inline `sendFailed` qualifies: a real
        // HTTP answer cannot arrive synchronously, and `accepted` /
        // `rejected` / `timedOutUnconfirmed` all mean the request DID leave.
        if case .sendFailed = inline.finish() {
            lock.lock()
            if lastFiredAt == sampledAt { lastFiredAt = previousFiredAt }
            lock.unlock()
            Self.logger.notice("lid guard: the publish was refused before it left the Mac — the cooldown is not spent")
        }
        // Hold the acknowledgment only long enough to give the POST a chance to
        // leave the Mac. Even the full budget guarantees nothing: if the server
        // has not answered by then the outcome is reported as
        // `timedOutUnconfirmed`. Deliberately best-effort.
        _ = done.wait(timeout: .now() + LidGuardTuning.ackHoldBudget)
        // The request is NOT cancelled here: it freezes with the system and
        // resolves on wake.
    }

    private func handleWake(_ event: SystemSleepEvent) {
        guard event == .systemHasPoweredOn else { return }
        lock.lock()
        let wasSending = sendInFlight
        sendInFlight = false
        lock.unlock()
        if wasSending {
            // NO retry-on-wake: the user is present now. The orphaned request
            // still resolves and its outcome is logged when it does.
            Self.logger.notice("lid guard: woke with a send still in flight — clearing state; its outcome is logged when the request resolves")
        }
        notifyChanged()
    }

    private func snapshot(busy: LidGuardBusySample) -> LidGuardSnapshot {
        let destination = storedDestination
        return LidGuardSnapshot(
            enabled: isEnabled,
            destination: destination,
            topicValid: destination != nil,
            primed: primedAt > 0,
            // nil (pmset unreadable) satisfies "≠ true" and therefore fires:
            // a deliberate fail-toward-notify.
            stayAwakeObserved: stayAwakeMirror.value,
            taskInFlight: busy.taskInFlight,
            busySessionCount: busy.sessionCount
        )
    }

    // MARK: - Test send (the priming gate)

    /// The config-time send. It exists so the user proves — while they are
    /// sitting there — that the topic is subscribed on their phone and the
    /// server accepts the publish. The FIRST message on a topic must never be
    /// the lid-close one, which nobody would be present to notice failing. A
    /// success is what primes (arms) the feature.
    func sendTestMessage() {
        guard let destination = storedDestination else {
            Self.logger.notice("lid guard: test send skipped — the ntfy settings are not usable")
            return
        }
        let firedAt = now()
        sender.send(.test, to: destination, at: Date(timeIntervalSince1970: firedAt)) { [weak self] outcome in
            guard let self else { return }
            self.recordOutcome(outcome, clearingSendInFlight: false)
            guard outcome == .accepted else { return }
            // Prime ONLY the destination that was actually tested. The user can
            // change the topic or server while this send is in flight (and the
            // follow-up test can be refused by the sender's single-flight
            // guard) — priming the current config here would arm an untested,
            // possibly mistyped feed.
            guard self.storedDestination == destination else {
                Self.logger.notice("lid guard: test send succeeded for settings that have since changed — not priming")
                return
            }
            self.markPrimed()
        }
    }

    private func recordOutcome(_ outcome: MessageSendOutcome, clearingSendInFlight: Bool) {
        let at = now()
        lock.lock()
        if clearingSendInFlight { sendInFlight = false }
        lastOutcome = outcome
        lastOutcomeAt = at
        lock.unlock()
        // The CATEGORY is public; the free-form `sendFailed` detail stays
        // `.private` so nothing derived from the request can ever reach a
        // `.public` (sysdiagnose-captured) line. The ntfy topic is a password
        // and is never logged at any level.
        let fields = LidGuardPolicy.outcomeLogFields(outcome)
        if let detail = fields.privateDetail {
            Self.logger.notice("lid guard: send outcome \(fields.publicCategory, privacy: .public) — \(detail, privacy: .private)")
        } else {
            Self.logger.notice("lid guard: send outcome \(fields.publicCategory, privacy: .public)")
        }
        notifyChanged()
    }

    // MARK: - Menu-facing snapshots

    var lastSendOutcome: MessageSendOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return lastOutcome
    }

    var lastSendOutcomeAt: Double? {
        lock.lock()
        defer { lock.unlock() }
        return lastOutcomeAt
    }

    /// Alert healing (issue #23): lid alerts that failed pre-connect since
    /// launch — a counter, nothing more.
    var lidAlertMissCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lidAlertMisses
    }

    private func countLidAlertMiss() {
        lock.lock()
        lidAlertMisses += 1
        lock.unlock()
    }
}

/// Records a send outcome only while it is still INLINE — i.e. delivered
/// before `MessageSender.send` returned. `finish()` closes the window and
/// hands back what (if anything) arrived inside it, so a completion racing in
/// from another thread a moment later cannot be mistaken for a synchronous
/// refusal.
private final class InlineOutcomeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var outcome: MessageSendOutcome?

    func record(_ newValue: MessageSendOutcome) {
        lock.lock()
        if !closed { outcome = newValue }
        lock.unlock()
    }

    func finish() -> MessageSendOutcome? {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        return outcome
    }
}

/// Bounded hand-off box for the main-actor busy sample.
private final class BusySampleBox: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: LidGuardBusySample?

    func set(_ sample: LidGuardBusySample) {
        lock.lock()
        value = sample
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> LidGuardBusySample? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
