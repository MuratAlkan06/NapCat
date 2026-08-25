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
/// Claude turn is in flight and Stay Awake is off, hand one iMessage to
/// Messages. NOTIFY-ONLY: it never controls Claude, never arms itself, and
/// never touches sleep or charging state.
///
/// Zero privileged surface: `osascript`, IOKit power notifications, and the
/// AppleEvent permission probe are all unprivileged. No sudo, no PLAN §4
/// command, no smc.
///
/// Thread model: the config/menu surface is used from the main actor, while
/// `handle(_:ack:)` runs on the sleep source's private queue. Every piece of
/// mutable state lives behind `lock`, hence `@unchecked Sendable`.
final class LidGuardController: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "lidguard")

    private let defaults: UserDefaults
    private let sleepSource: SystemSleepSource
    private let sender: MessageSender
    private let probe: AutomationPermissionProbing
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
    /// In-memory ONLY. Persisting it would cache intent across relaunches.
    private var lastFiredAt: Double?
    private var sendInFlight = false
    private var lastOutcome: MessageSendOutcome?
    private var lastOutcomeAt: Double?
    private var automation: AutomationPermission?
    private var changeHandler: (@Sendable () -> Void)?

    init(
        defaults: UserDefaults,
        sleepSource: SystemSleepSource,
        sender: MessageSender,
        probe: AutomationPermissionProbing,
        stayAwakeMirror: ObservedStayAwakeMirror,
        busyProvider: @escaping ClaudeBusyProvider,
        now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.defaults = defaults
        self.sleepSource = sleepSource
        self.sender = sender
        self.probe = probe
        self.stayAwakeMirror = stayAwakeMirror
        self.busyProvider = busyProvider
        self.now = now
    }

    /// The single construction site, gated by the debug-sim wiring predicate
    /// (ADR §8 mirror, same shape as B1's `makeIfEnabled`). Returns nil in
    /// debugBattery mode — nothing in this subsystem is built there, so no
    /// IOKit registration and no osascript spawn can exist. Also nil without
    /// the B1 detection stack (there would be nothing to notify about) or
    /// without the bundled AppleScript.
    static func makeIfEnabled(
        debugBattery: Bool,
        defaults: UserDefaults = .standard,
        stayAwakeMirror: ObservedStayAwakeMirror,
        detection: ClaudeActivityController?
    ) -> LidGuardController? {
        guard LidGuardPolicy.lidGuardMayBeConstructed(debugBattery: debugBattery) else { return nil }
        guard let detection else { return nil }
        guard let sender = OSAScriptMessageSender() else { return nil }
        return LidGuardController(
            defaults: defaults,
            sleepSource: IOKitSystemSleepSource(),
            sender: sender,
            probe: AppleEventAutomationProbe(),
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
    /// that the panel renders (send outcome, permission probe).
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

    // MARK: - Persistence (PLAN.md §11 — three keys, nothing else)

    var isEnabled: Bool { defaults.bool(forKey: DefaultsKey.lidGuardEnabled) }
    var storedRecipient: String { defaults.string(forKey: DefaultsKey.lidGuardRecipient) ?? "" }
    /// Unix epoch seconds of the last SUCCESSFUL config-time test send; 0 =
    /// never primed. Arming requires it (see `armingState`).
    var primedAt: Double { defaults.double(forKey: DefaultsKey.lidGuardPrimedAt) }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: DefaultsKey.lidGuardEnabled)
        refreshArming()
    }

    /// Stores a validated recipient. A CHANGED recipient always clears the
    /// primed flag: the test send must be repeated against the new address, so
    /// the first message to it is never the lid-close one.
    @discardableResult
    func setRecipient(_ raw: String) -> RecipientValidation {
        let validation = LidGuardPolicy.validateRecipient(raw)
        switch validation {
        case .valid(let recipient):
            if recipient != storedRecipient {
                defaults.set(recipient, forKey: DefaultsKey.lidGuardRecipient)
                defaults.set(0.0, forKey: DefaultsKey.lidGuardPrimedAt)
            }
        case .empty:
            defaults.set("", forKey: DefaultsKey.lidGuardRecipient)
            defaults.set(0.0, forKey: DefaultsKey.lidGuardPrimedAt)
        case .invalid:
            // Keep the previous value; the caller renders the inline caption.
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
        LidGuardPolicy.armingState(enabled: isEnabled, recipient: storedRecipient, primedAt: primedAt)
    }

    var isArmed: Bool { armingState == .armed }

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
        let inputs = LidGuardGateInputs(
            snapshot: snapshot,
            sendInFlight: sendInFlight,
            lastFiredAt: lastFiredAt,
            now: sampledAt
        )
        let decision = LidGuardPolicy.decide(inputs)
        if decision == .fire {
            // Claimed BEFORE the spawn so a second notification cannot race in.
            sendInFlight = true
            lastFiredAt = sampledAt
        }
        lock.unlock()

        guard decision == .fire else {
            if case .skip(let reason) = decision {
                Self.logger.debug("lid guard: sleeping, no alert (\(reason.rawValue, privacy: .public))")
            }
            return
        }

        Self.logger.notice("lid guard: sleeping with a Claude task in flight — handing an alert to Messages")
        let done = DispatchSemaphore(value: 0)
        sender.send(
            .lidAlert(busySessionCount: busy.sessionCount),
            to: snapshot.recipient,
            at: Date(timeIntervalSince1970: sampledAt)
        ) { [weak self] outcome in
            self?.recordOutcome(outcome, clearingSendInFlight: true)
            done.signal()
        }
        // Hold the acknowledgment only long enough for the handoff. Even the
        // full budget guarantees ONLY that Messages accepted the AppleEvent —
        // the actual iMessage transmission is asynchronous and may complete
        // after the Mac is asleep (i.e. on wake). Deliberately best-effort.
        _ = done.wait(timeout: .now() + LidGuardTuning.ackHoldBudget)
        // The child is NOT killed here: it freezes with the system and
        // finishes on wake.
    }

    private func handleWake(_ event: SystemSleepEvent) {
        guard event == .systemHasPoweredOn else { return }
        lock.lock()
        let wasSending = sendInFlight
        sendInFlight = false
        lock.unlock()
        if wasSending {
            // NO retry-on-wake: the user is present now. The orphaned child's
            // exit is still collected by the sender and logged below.
            Self.logger.notice("lid guard: woke with a send still in flight — clearing state; its outcome is logged when the child exits")
        }
        notifyChanged()
    }

    private func snapshot(busy: LidGuardBusySample) -> LidGuardSnapshot {
        let validation = LidGuardPolicy.validateRecipient(storedRecipient)
        let recipient: String
        let recipientValid: Bool
        if case .valid(let value) = validation {
            recipient = value
            recipientValid = true
        } else {
            recipient = ""
            recipientValid = false
        }
        return LidGuardSnapshot(
            enabled: isEnabled,
            recipient: recipient,
            recipientValid: recipientValid,
            primed: primedAt > 0,
            // nil (pmset unreadable) satisfies "≠ true" and therefore fires:
            // a deliberate fail-toward-notify.
            stayAwakeObserved: stayAwakeMirror.value,
            taskInFlight: busy.taskInFlight,
            busySessionCount: busy.sessionCount
        )
    }

    // MARK: - Test send (the TCC gate)

    /// The config-time send. It exists so the "NapCat wants to control
    /// Messages" prompt is answered while the user is watching, and so the
    /// self-conversation exists — the FIRST send must never be the lid-close
    /// one, which would block osascript on an unanswered prompt as the machine
    /// goes down. A success is what primes (arms) the feature.
    func sendTestMessage() {
        guard let recipient = LidGuardPolicy.normalizedRecipient(storedRecipient) else {
            Self.logger.notice("lid guard: test send skipped — no valid recipient")
            return
        }
        let firedAt = now()
        sender.send(.test, to: recipient, at: Date(timeIntervalSince1970: firedAt)) { [weak self] outcome in
            guard let self else { return }
            self.recordOutcome(outcome, clearingSendInFlight: false)
            guard outcome == .handedToMessages else { return }
            // Prime ONLY the address that was actually tested. The user can
            // change the recipient while this send is in flight (and the
            // follow-up test for the new address can be refused by the
            // sender's single-flight guard) — priming the current config here
            // would arm an untested, possibly mistyped address.
            guard LidGuardPolicy.normalizedRecipient(self.storedRecipient) == recipient else {
                Self.logger.notice("lid guard: test send succeeded for a recipient that has since changed — not priming")
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
        // The CATEGORY is public, but the free-form `sendFailed` detail is raw
        // osascript stderr and can echo the recipient — it stays `.private` so
        // the recipient never reaches a `.public` (sysdiagnose-captured) line.
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

    var automationPermission: AutomationPermission? {
        lock.lock()
        defer { lock.unlock() }
        return automation
    }

    /// SYNCHRONOUS probe — call it off the main actor (MenuContentView runs it
    /// in a detached task so `menuWillOpen` stays on its critical path).
    func refreshAutomationPermission() {
        guard isArmed else { return }
        let permission = probe.probeMessages()
        lock.lock()
        automation = permission
        lock.unlock()
        notifyChanged()
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
