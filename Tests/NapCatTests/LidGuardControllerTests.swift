// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

// MARK: - Test doubles (shared with PersistenceTests)

/// Fake sleep feed: records start/stop and lets a test synthesize the full
/// IOKit message table without registering anything with the system.
final class RecordingSystemSleepSource: SystemSleepSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (SystemSleepEvent, SystemSleepAck) -> Void)?
    private var starts = 0
    private var stops = 0

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handler != nil
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    func start(handler: @escaping @Sendable (SystemSleepEvent, SystemSleepAck) -> Void) {
        lock.lock()
        self.handler = handler
        starts += 1
        lock.unlock()
    }

    func stop() {
        lock.lock()
        handler = nil
        stops += 1
        lock.unlock()
    }

    /// Synthesize one notification and return its ack recorder.
    @discardableResult
    func deliver(_ event: SystemSleepEvent) -> AckRecorder {
        let recorder = AckRecorder()
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(event, recorder.ack)
        return recorder
    }
}

/// Counts how many times the ack ACTION actually ran (must be exactly one per
/// notification, however many code paths call `allow()`).
final class AckRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var performed = 0
    private(set) lazy var ack = SystemSleepAck { [self] in
        lock.lock()
        performed += 1
        lock.unlock()
    }

    var performedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return performed
    }
}

/// Records sends and holds their completions until a test releases them —
/// so `sendInFlight` stays open and late completions can be replayed.
final class DeferredMessageSender: MessageSender, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RecordedMessageSend] = []
    private var pending: [@Sendable (MessageSendOutcome) -> Void] = []

    var sends: [RecordedMessageSend] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(
        _ kind: LidGuardMessageKind,
        to destination: NtfyDestination,
        at firedAt: Date,
        completion: @escaping @Sendable (MessageSendOutcome) -> Void
    ) {
        lock.lock()
        recorded.append(RecordedMessageSend(kind: kind, destination: destination, firedAt: firedAt))
        pending.append(completion)
        lock.unlock()
    }

    /// Deliver every held completion (oldest first).
    func completeAll(_ outcome: MessageSendOutcome) {
        lock.lock()
        let handlers = pending
        pending = []
        lock.unlock()
        for handler in handlers { handler(outcome) }
    }
}

/// Injected WALL clock. Tests advance it by hand, including by "a whole night"
/// to prove the cooldown survives a sleep.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double

    init(_ start: Double) { value = start }

    var now: Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: Double) {
        lock.lock()
        value += seconds
        lock.unlock()
    }
}

/// Stands in for the main-actor B1 detection sample.
final class BusySampleStub: @unchecked Sendable {
    private let lock = NSLock()
    private var sample: LidGuardBusySample?
    private var calls = 0

    init(_ sample: LidGuardBusySample? = LidGuardBusySample(taskInFlight: true, sessionCount: 1)) {
        self.sample = sample
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func set(_ newValue: LidGuardBusySample?) {
        lock.lock()
        sample = newValue
        lock.unlock()
    }

    func provider() -> ClaudeBusyProvider {
        { [self] in
            lock.lock()
            calls += 1
            let value = sample
            lock.unlock()
            return value
        }
    }
}

/// Everything one controller test needs, wired to fakes only. No IOKit
/// registration, no network, no real publish — `make test` can never reach
/// ntfy.sh or any other host.
final class LidGuardHarness {
    let defaults: UserDefaults
    let source = RecordingSystemSleepSource()
    let mirror = ObservedStayAwakeMirror()
    let busy = BusySampleStub()
    let clock = TestClock(1_000_000)
    let sender: MessageSender
    let controller: LidGuardController

    init(defaults: UserDefaults, sender: MessageSender) {
        self.defaults = defaults
        self.sender = sender
        mirror.set(false)
        controller = LidGuardController(
            defaults: defaults,
            sleepSource: source,
            sender: sender,
            stayAwakeMirror: mirror,
            busyProvider: busy.provider(),
            now: { [clock] in clock.now }
        )
    }

    /// enabled ∧ usable topic ∧ primed, then register.
    func arm(topic: String = "napcat-lid-8f3k2p") {
        defaults.set(true, forKey: DefaultsKey.lidGuardEnabled)
        defaults.set(topic, forKey: DefaultsKey.lidGuardNtfyTopic)
        defaults.set(clock.now, forKey: DefaultsKey.lidGuardPrimedAt)
        controller.refreshArming()
    }
}

func withLidGuardHarness(
    sender: MessageSender = RecordingMessageSender(),
    _ body: (LidGuardHarness) -> Void
) {
    let suite = "com.muratalkan.napcat.tests.lidguard.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    body(LidGuardHarness(defaults: defaults, sender: sender))
}

// MARK: - Tests

/// Track B / B2 delivery behaviour: the IOKit message table, the
/// acknowledgment discipline, single-flight, the wall-clock cooldown across a
/// sleep gap, arming/disarming, and the test-send priming rule.
struct LidGuardControllerTests {
    // MARK: Message table

    /// The idle-sleep poll must be answered IMMEDIATELY and without evaluating
    /// anything — an unanswered CanSystemSleep delays every sleep on the
    /// machine, so an armed NapCat must be invisible here.
    @Test func canSystemSleepIsAllowedImmediatelyWithNoPolicy() {
        withLidGuardHarness { harness in
            let sender = harness.sender as! RecordingMessageSender
            harness.arm()
            let ack = harness.source.deliver(.canSystemSleep)
            #expect(ack.performedCount == 1)
            #expect(sender.sends.isEmpty)
            #expect(harness.busy.callCount == 0, "no policy evaluation on CanSystemSleep")
        }
    }

    @Test func willSleepWithAClaudeTaskSendsOnceAndAcknowledgesOnce() {
        withLidGuardHarness { harness in
            let sender = harness.sender as! RecordingMessageSender
            harness.arm()
            let ack = harness.source.deliver(.systemWillSleep)

            #expect(sender.sends.count == 1)
            #expect(sender.sends[0].destination
                    == NtfyDestination(server: "https://ntfy.sh", topic: "napcat-lid-8f3k2p"))
            #expect(sender.sends[0].kind == .lidAlert(busySessionCount: 1))
            #expect(ack.performedCount == 1)
            #expect(harness.controller.lastSendOutcome == .accepted)
            #expect(harness.controller.lastSendOutcomeAt == harness.clock.now)
        }
    }

    /// Ack exactly once, whichever path gets there: the fast path, the hold
    /// path, and the force-ack timer all funnel through the same token.
    @Test func acknowledgmentIsPerformedExactlyOnce() {
        withLidGuardHarness { harness in
            harness.arm()
            let ack = harness.source.deliver(.systemWillSleep)
            #expect(ack.performedCount == 1)
            // Simulate the force-ack timer firing after the handler already
            // acknowledged.
            ack.ack.allow()
            ack.ack.allow()
            #expect(ack.performedCount == 1)
            #expect(ack.ack.allowCallCount == 3)
        }
    }

    @Test func willSleepWithoutAClaudeTaskAcknowledgesAndSendsNothing() {
        withLidGuardHarness { harness in
            let sender = harness.sender as! RecordingMessageSender
            harness.arm()
            harness.busy.set(LidGuardBusySample(taskInFlight: false, sessionCount: 0))
            let ack = harness.source.deliver(.systemWillSleep)
            #expect(sender.sends.isEmpty)
            #expect(ack.performedCount == 1)
        }
    }

    /// A busy sample that cannot be taken inside the budget must SKIP, never
    /// fire blind — and must still acknowledge.
    @Test func unavailableBusySampleSkipsButStillAcknowledges() {
        withLidGuardHarness { harness in
            let sender = harness.sender as! RecordingMessageSender
            harness.arm()
            harness.busy.set(nil)
            let ack = harness.source.deliver(.systemWillSleep)
            #expect(sender.sends.isEmpty)
            #expect(ack.performedCount == 1)
        }
    }

    @Test func wakeEventsNeedNoAcknowledgmentAndSendNothing() {
        withLidGuardHarness { harness in
            let sender = harness.sender as! RecordingMessageSender
            harness.arm()
            let willPowerOn = harness.source.deliver(.systemWillPowerOn)
            let hasPoweredOn = harness.source.deliver(.systemHasPoweredOn)
            #expect(willPowerOn.performedCount == 0)
            #expect(hasPoweredOn.performedCount == 0)
            #expect(sender.sends.isEmpty)
        }
    }

    // MARK: Stay-awake mirror

    @Test func stayAwakeObservedTrueSuppressesTheAlert() {
        withLidGuardHarness { harness in
            let sender = harness.sender as! RecordingMessageSender
            harness.arm()
            harness.mirror.set(true)
            harness.source.deliver(.systemWillSleep)
            #expect(sender.sends.isEmpty, "Stay Awake is on — the Mac is not sleeping on us")
        }
    }

    /// Unknown (pmset unreadable) fires: deliberate fail-toward-notify.
    @Test func unreadableStayAwakeStateStillFires() {
        withLidGuardHarness { harness in
            let sender = harness.sender as! RecordingMessageSender
            harness.arm()
            harness.mirror.set(nil)
            harness.source.deliver(.systemWillSleep)
            #expect(sender.sends.count == 1)
        }
    }

    /// The guarded human error: Stay Awake toggled OFF seconds before the lid
    /// closes. The mirror is written at SleepStateController's choke point, so
    /// the gate sees `false`, not the stale `true`.
    @Test func aJustToggledOffStayAwakeStateIsVisibleToTheGate() {
        withLidGuardHarness { harness in
            let sender = harness.sender as! RecordingMessageSender
            harness.mirror.set(true)
            harness.arm()
            harness.source.deliver(.systemWillSleep)
            #expect(sender.sends.isEmpty)

            // …user toggles Stay Awake off; the controller publishes it.
            let sleepController = SleepStateControllerMirrorProbe.publish(false, to: harness.mirror)
            #expect(sleepController == false)
            harness.source.deliver(.systemWillSleep)
            #expect(sender.sends.count == 1)
        }
    }

    // MARK: Cooldown (wall clock across a sleep gap)

    @Test func cooldownBlocksARepeatThenExpiresAcrossAnOvernightSleep() {
        withLidGuardHarness { harness in
            let sender = harness.sender as! RecordingMessageSender
            harness.arm()
            harness.source.deliver(.systemWillSleep)
            #expect(sender.sends.count == 1)

            // A dark wake a minute later must NOT double-notify.
            harness.clock.advance(60)
            harness.source.deliver(.systemWillSleep)
            #expect(sender.sends.count == 1)

            // Overnight: a WALL clock has advanced 8 h while the Mac slept, so
            // the cooldown is genuinely over. (An uptime clock would still read
            // ~60 s here and the guard would never fire again.)
            harness.clock.advance(8 * 3_600)
            harness.source.deliver(.systemWillSleep)
            #expect(sender.sends.count == 2)
        }
    }

    // MARK: Single flight

    @Test func aSecondAlertIsNeverSentWhileOneIsStillInFlight() {
        let deferredSender = DeferredMessageSender()
        withLidGuardHarness(sender: deferredSender) { harness in
            harness.arm()
            harness.source.deliver(.systemWillSleep)
            #expect(deferredSender.sends.count == 1)

            // Cooldown out of the way — the only remaining blocker is the send
            // that never completed.
            harness.clock.advance(LidGuardTuning.cooldownSeconds + 1)
            harness.source.deliver(.systemWillSleep)
            #expect(deferredSender.sends.count == 1, "single-flight must hold")

            // Waking clears the in-flight state (no retry-on-wake; the orphaned
            // request's outcome is still collected by the sender).
            harness.source.deliver(.systemHasPoweredOn)
            harness.clock.advance(LidGuardTuning.cooldownSeconds + 1)
            harness.source.deliver(.systemWillSleep)
            #expect(deferredSender.sends.count == 2)
        }
    }

    /// N1 (security review 2026-09-09): the cooldown is claimed BEFORE the
    /// publish, so a send the sender refuses SYNCHRONOUSLY — its own
    /// single-flight still holding an orphaned request, or an unusable address —
    /// used to spend the whole 15-minute window on a message that never left the
    /// Mac, silencing the next real sleep. An inline `sendFailed` now rolls the
    /// claim back.
    @Test func aSynchronouslyRefusedPublishDoesNotSpendTheCooldown() {
        let sender = RecordingMessageSender(outcome: .sendFailed("another message is still being sent"))
        withLidGuardHarness(sender: sender) { harness in
            harness.arm()
            harness.source.deliver(.systemWillSleep)
            #expect(sender.sends.count == 1)
            #expect(harness.controller.lastSendOutcome == .sendFailed("another message is still being sent"))

            // Immediately again — well inside the cooldown. Because nothing was
            // published, the guard must still be allowed to try.
            harness.clock.advance(1)
            harness.source.deliver(.systemWillSleep)
            #expect(sender.sends.count == 2, "a refused publish must not burn the cooldown")

            // …and once one is really accepted, the cooldown applies as usual.
            sender.setOutcome(.accepted)
            harness.clock.advance(1)
            harness.source.deliver(.systemWillSleep)
            #expect(sender.sends.count == 3)
            harness.clock.advance(60)
            harness.source.deliver(.systemWillSleep)
            #expect(sender.sends.count == 3, "an accepted publish spends the cooldown")
        }
    }

    /// The rollback is keyed on the OUTCOME, not on the timing: an outcome that
    /// means the request DID leave (unconfirmed) still spends the cooldown —
    /// "we do not know" must not become "send another one".
    @Test func anUnconfirmedPublishStillSpendsTheCooldown() {
        let sender = RecordingMessageSender(outcome: .timedOutUnconfirmed)
        withLidGuardHarness(sender: sender) { harness in
            harness.arm()
            harness.source.deliver(.systemWillSleep)
            #expect(sender.sends.count == 1)
            harness.clock.advance(60)
            harness.source.deliver(.systemWillSleep)
            #expect(sender.sends.count == 1)
        }
    }

    // MARK: Arming

    /// The OFF and half-configured states must leave ZERO sleep-path
    /// footprint: no registration at all.
    @Test func theSleepHookIsRegisteredOnlyWhenFullyArmed() {
        withLidGuardHarness { harness in
            let controller = harness.controller
            controller.refreshArming()
            #expect(!harness.source.isRunning, "off → nothing registered")

            controller.setEnabled(true)
            #expect(controller.armingState == .needsTopic)
            #expect(!harness.source.isRunning)

            controller.setTopic("napcat-lid-8f3k2p")
            #expect(controller.armingState == .needsTestSend)
            #expect(!harness.source.isRunning, "an unprimed feature must not register")

            // A successful test send primes it — and only then do we register.
            controller.sendTestMessage()
            #expect(controller.armingState == .armed)
            #expect(harness.source.isRunning)
            #expect(controller.isObservingSleep)

            controller.setEnabled(false)
            #expect(!harness.source.isRunning)
            #expect(harness.source.stopCount == 1)
        }
    }

    @Test func repeatedRefreshDoesNotReRegister() {
        withLidGuardHarness { harness in
            harness.arm()
            harness.controller.refreshArming()
            harness.controller.refreshArming()
            #expect(harness.source.startCount == 1)
        }
    }

    @Test func shutdownDropsTheRegistration() {
        withLidGuardHarness { harness in
            harness.arm()
            #expect(harness.source.isRunning)
            harness.controller.disarmForShutdown()
            #expect(!harness.source.isRunning)
        }
    }

    /// Defense in depth: even if a notification somehow reached a disarmed
    /// controller, the gate refuses and the power change is still acknowledged.
    @Test func aDisarmedControllerRefusesButStillAcknowledges() {
        withLidGuardHarness { harness in
            let sender = harness.sender as! RecordingMessageSender
            let recorder = AckRecorder()
            harness.controller.handle(.systemWillSleep, ack: recorder.ack)
            #expect(sender.sends.isEmpty)
            #expect(recorder.performedCount == 1)
        }
    }

    // MARK: Test send / priming

    @Test func onlyASuccessfulTestSendPrimesTheFeature() {
        let sender = RecordingMessageSender(outcome: .rejected(404))
        withLidGuardHarness(sender: sender) { harness in
            let controller = harness.controller
            controller.setEnabled(true)
            controller.setTopic("napcat-lid-8f3k2p")

            controller.sendTestMessage()
            #expect(sender.sends.count == 1)
            #expect(sender.sends[0].kind == .test)
            #expect(controller.primedAt == 0, "a refused publish must not arm anything")
            #expect(controller.armingState == .needsTestSend)
            #expect(controller.lastSendOutcome == .rejected(404))

            sender.setOutcome(.accepted)
            controller.sendTestMessage()
            #expect(controller.primedAt == harness.clock.now)
            #expect(controller.armingState == .armed)
        }
    }

    /// An UNCONFIRMED publish must not prime either: "we do not know" is not a
    /// proof that the phone got it.
    @Test func anUnconfirmedTestSendDoesNotPrime() {
        let sender = RecordingMessageSender(outcome: .timedOutUnconfirmed)
        withLidGuardHarness(sender: sender) { harness in
            harness.controller.setEnabled(true)
            harness.controller.setTopic("napcat-lid-8f3k2p")
            harness.controller.sendTestMessage()
            #expect(harness.controller.primedAt == 0)
            #expect(harness.controller.armingState == .needsTestSend)
        }
    }

    /// A test send that lands AFTER the user changed the topic must never arm
    /// the new (untested) one — otherwise a mistyped topic could be trusted
    /// with the lid-close message without anyone ever proving it works.
    @Test func aLateTestSendNeverPrimesADifferentTopic() {
        let sender = DeferredMessageSender()
        withLidGuardHarness(sender: sender) { harness in
            let controller = harness.controller
            controller.setEnabled(true)
            controller.setTopic("napcat-first-topic")
            controller.sendTestMessage()
            #expect(sender.sends.count == 1)
            #expect(sender.sends[0].destination.topic == "napcat-first-topic")

            // The user re-opens the editor and switches topic while the first
            // test is still in flight.
            controller.setTopic("napcat-second-topic")
            #expect(controller.primedAt == 0)

            // Now the FIRST test's success arrives.
            sender.completeAll(.accepted)
            #expect(controller.primedAt == 0, "the tested topic is no longer the stored one")
            #expect(controller.armingState == .needsTestSend)
            #expect(!harness.source.isRunning)
        }
    }

    /// The same rule for the SERVER half of the destination.
    @Test func aLateTestSendNeverPrimesADifferentServer() {
        let sender = DeferredMessageSender()
        withLidGuardHarness(sender: sender) { harness in
            let controller = harness.controller
            controller.setEnabled(true)
            controller.setTopic("napcat-lid-8f3k2p")
            controller.sendTestMessage()
            #expect(sender.sends[0].destination.server == "https://ntfy.sh")

            controller.setServer("https://ntfy.example.com")
            sender.completeAll(.accepted)
            #expect(controller.primedAt == 0, "the tested server is no longer the stored one")
            #expect(controller.armingState == .needsTestSend)
        }
    }

    /// …and the ordinary case still primes.
    @Test func aTestSendForTheStoredDestinationPrimesOnCompletion() {
        let sender = DeferredMessageSender()
        withLidGuardHarness(sender: sender) { harness in
            harness.controller.setEnabled(true)
            harness.controller.setTopic("napcat-lid-8f3k2p")
            harness.controller.sendTestMessage()
            sender.completeAll(.accepted)
            #expect(harness.controller.primedAt == harness.clock.now)
            #expect(harness.controller.armingState == .armed)
        }
    }

    @Test func changingTheTopicRequiresANewTestSend() {
        withLidGuardHarness { harness in
            harness.arm()
            #expect(harness.controller.armingState == .armed)

            harness.controller.setTopic("napcat-other-topic")
            #expect(harness.controller.storedTopic == "napcat-other-topic")
            #expect(harness.controller.primedAt == 0)
            #expect(harness.controller.armingState == .needsTestSend)
            #expect(!harness.source.isRunning, "changing the topic disarms until re-primed")
        }
    }

    @Test func changingTheServerRequiresANewTestSend() {
        withLidGuardHarness { harness in
            harness.arm()
            #expect(harness.controller.storedServer == LidGuardTuning.defaultNtfyServer)

            #expect(harness.controller.setServer("https://ntfy.example.com:8443/")
                    == .valid("https://ntfy.example.com:8443"))
            #expect(harness.controller.storedServer == "https://ntfy.example.com:8443")
            #expect(harness.controller.primedAt == 0)
            #expect(harness.controller.armingState == .needsTestSend)
            #expect(!harness.source.isRunning)
        }
    }

    /// Re-saving the SAME values must not disarm a working configuration.
    @Test func reSavingTheSameSettingsKeepsThePriming() {
        withLidGuardHarness { harness in
            harness.arm()
            let primed = harness.controller.primedAt
            harness.controller.setTopic("  napcat-lid-8f3k2p  ")
            harness.controller.setServer("https://ntfy.sh")
            #expect(harness.controller.primedAt == primed)
            #expect(harness.controller.armingState == .armed)
            #expect(harness.source.isRunning)
        }
    }

    /// Clearing the server field reverts to the public instance.
    @Test func clearingTheServerFallsBackToThePublicInstance() {
        withLidGuardHarness { harness in
            harness.controller.setServer("https://ntfy.example.com")
            #expect(harness.controller.storedServer == "https://ntfy.example.com")
            #expect(harness.controller.setServer("") == .empty)
            #expect(harness.controller.storedServer == LidGuardTuning.defaultNtfyServer)
        }
    }

    @Test func anUnusableTopicIsNotStoredAndSendsNothing() {
        withLidGuardHarness { harness in
            let sender = harness.sender as! RecordingMessageSender
            harness.arm()
            #expect(harness.controller.setTopic("bad/topic") == .invalid)
            #expect(harness.controller.storedTopic == "napcat-lid-8f3k2p", "the previous value is kept")

            // And an unusable STORED value keeps the feature inert.
            harness.defaults.set("bad/topic", forKey: DefaultsKey.lidGuardNtfyTopic)
            #expect(harness.controller.armingState == .needsTopic)
            harness.controller.sendTestMessage()
            #expect(sender.sends.isEmpty)
        }
    }

    @Test func anUnusableServerIsNotStoredAndSendsNothing() {
        withLidGuardHarness { harness in
            let sender = harness.sender as! RecordingMessageSender
            harness.arm()
            #expect(harness.controller.setServer("http://ntfy.sh") == .invalid)
            #expect(harness.controller.storedServer == LidGuardTuning.defaultNtfyServer,
                    "the previous value is kept")

            harness.defaults.set("http://ntfy.sh", forKey: DefaultsKey.lidGuardNtfyServer)
            #expect(harness.controller.armingState == .needsTopic)
            harness.controller.sendTestMessage()
            #expect(sender.sends.isEmpty)
        }
    }

    // MARK: Track C finish alert — own toggle, SHARED destination + priming

    /// The two toggles are independent: lid OFF + finish ON with a valid,
    /// primed destination arms the finish alert only — and the finish toggle
    /// never registers the lid guard's IOKit sleep hook.
    @Test func theFinishAlertArmsOnItsOwnToggleWithTheLidGuardOff() {
        withLidGuardHarness { harness in
            harness.defaults.set("napcat-lid-8f3k2p", forKey: DefaultsKey.lidGuardNtfyTopic)
            harness.defaults.set(harness.clock.now, forKey: DefaultsKey.lidGuardPrimedAt)
            harness.controller.setFinishAlertEnabled(true)

            #expect(harness.controller.finishAlertArmingState == .armed)
            #expect(harness.controller.armingState == .off, "the lid guard keeps its own toggle")
            #expect(!harness.source.isRunning, "the finish toggle must not register the sleep hook")
        }
    }

    @Test func theFinishAlertNeedsTheSharedTestSend() {
        withLidGuardHarness { harness in
            harness.controller.setFinishAlertEnabled(true)
            harness.controller.setTopic("napcat-lid-8f3k2p")
            #expect(harness.controller.primedAt == 0)
            #expect(harness.controller.finishAlertArmingState == .needsTestSend)

            // The ONE priming test send arms both features.
            harness.controller.setEnabled(true)
            harness.controller.sendTestMessage()
            #expect(harness.controller.finishAlertArmingState == .armed)
            #expect(harness.controller.armingState == .armed)
        }
    }

    @Test func theFinishAlertNeedsTheSharedTopic() {
        withLidGuardHarness { harness in
            harness.controller.setFinishAlertEnabled(true)
            #expect(harness.controller.finishAlertArmingState == .needsTopic)
            // An unusable stored server is "no destination" for both features.
            harness.defaults.set("napcat-lid-8f3k2p", forKey: DefaultsKey.lidGuardNtfyTopic)
            harness.defaults.set(harness.clock.now, forKey: DefaultsKey.lidGuardPrimedAt)
            harness.defaults.set("http://ntfy.sh", forKey: DefaultsKey.lidGuardNtfyServer)
            #expect(harness.controller.finishAlertArmingState == .needsTopic)
        }
    }

    /// Finish toggle off ⇒ `.off`, even with the lid guard fully armed.
    @Test func theFinishAlertIsOffWhenItsToggleIsOff() {
        withLidGuardHarness { harness in
            harness.arm()
            #expect(harness.controller.armingState == .armed)
            #expect(!harness.controller.finishAlertEnabled)
            #expect(harness.controller.finishAlertArmingState == .off)

            harness.controller.setFinishAlertEnabled(true)
            #expect(harness.controller.finishAlertArmingState == .armed)
            harness.controller.setFinishAlertEnabled(false)
            #expect(harness.controller.finishAlertArmingState == .off)
            #expect(harness.controller.armingState == .armed, "the lid guard is unaffected")
            #expect(harness.source.isRunning, "…and so is its sleep registration")
        }
    }

    /// The toggle persists under its own key and round-trips across a
    /// relaunch (a second controller on the same defaults).
    @Test func theFinishAlertTogglePersistsAndRoundTrips() {
        withLidGuardHarness { harness in
            harness.controller.setFinishAlertEnabled(true)
            #expect(harness.defaults.bool(forKey: DefaultsKey.claudeFinishAlertEnabled))
            #expect(harness.defaults.object(forKey: DefaultsKey.lidGuardEnabled) == nil)
            let relaunched = LidGuardHarness(defaults: harness.defaults, sender: RecordingMessageSender())
            #expect(relaunched.controller.finishAlertEnabled)

            harness.controller.setFinishAlertEnabled(false)
            #expect(harness.defaults.object(forKey: DefaultsKey.claudeFinishAlertEnabled) as? Bool == false)
            #expect(!relaunched.controller.finishAlertEnabled)
        }
    }

    /// SHARED priming: changing the topic or the server clears `primedAt`, so
    /// both features disarm together until the next successful test send.
    @Test func changingTheSharedDestinationDisarmsBothFeatures() {
        withLidGuardHarness { harness in
            harness.arm()
            harness.controller.setFinishAlertEnabled(true)
            #expect(harness.controller.finishAlertArmingState == .armed)

            harness.controller.setTopic("napcat-other-topic")
            #expect(harness.controller.armingState == .needsTestSend)
            #expect(harness.controller.finishAlertArmingState == .needsTestSend)

            harness.controller.sendTestMessage()
            #expect(harness.controller.finishAlertArmingState == .armed)

            harness.controller.setServer("https://ntfy.example.com")
            #expect(harness.controller.armingState == .needsTestSend)
            #expect(harness.controller.finishAlertArmingState == .needsTestSend)
        }
    }
}

/// Small shim so the mirror test reads like the real publish path.
enum SleepStateControllerMirrorProbe {
    static func publish(_ value: Bool?, to mirror: ObservedStayAwakeMirror) -> Bool? {
        mirror.set(value)
        return mirror.value
    }
}
