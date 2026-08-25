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
        to recipient: String,
        at firedAt: Date,
        completion: @escaping @Sendable (MessageSendOutcome) -> Void
    ) {
        lock.lock()
        recorded.append(RecordedMessageSend(kind: kind, recipient: recipient, firedAt: firedAt))
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

final class StubAutomationProbe: AutomationPermissionProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var result: AutomationPermission
    private var calls = 0

    init(result: AutomationPermission = .granted) {
        self.result = result
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func setResult(_ permission: AutomationPermission) {
        lock.lock()
        result = permission
        lock.unlock()
    }

    func probeMessages() -> AutomationPermission {
        lock.lock()
        calls += 1
        let value = result
        lock.unlock()
        return value
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
/// registration, no process spawn, no real message — `make test` can never
/// send an iMessage or raise a TCC prompt.
final class LidGuardHarness {
    let defaults: UserDefaults
    let source = RecordingSystemSleepSource()
    let probe = StubAutomationProbe()
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
            probe: probe,
            stayAwakeMirror: mirror,
            busyProvider: busy.provider(),
            now: { [clock] in clock.now }
        )
    }

    /// enabled ∧ valid recipient ∧ primed, then register.
    func arm(recipient: String = "+15551234567") {
        defaults.set(true, forKey: DefaultsKey.lidGuardEnabled)
        defaults.set(recipient, forKey: DefaultsKey.lidGuardRecipient)
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
            #expect(sender.sends[0].recipient == "+15551234567")
            #expect(sender.sends[0].kind == .lidAlert(busySessionCount: 1))
            #expect(ack.performedCount == 1)
            #expect(harness.controller.lastSendOutcome == .handedToMessages)
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

            // A dark wake a minute later must NOT double-text.
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

    @Test func aSecondAlertIsNeverSpawnedWhileOneIsStillInFlight() {
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
            // child's outcome is still collected by the sender).
            harness.source.deliver(.systemHasPoweredOn)
            harness.clock.advance(LidGuardTuning.cooldownSeconds + 1)
            harness.source.deliver(.systemWillSleep)
            #expect(deferredSender.sends.count == 2)
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
            #expect(controller.armingState == .needsRecipient)
            #expect(!harness.source.isRunning)

            controller.setRecipient("+15551234567")
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
        let sender = RecordingMessageSender(outcome: .permissionDenied)
        withLidGuardHarness(sender: sender) { harness in
            let controller = harness.controller
            controller.setEnabled(true)
            controller.setRecipient("+15551234567")

            controller.sendTestMessage()
            #expect(sender.sends.count == 1)
            #expect(sender.sends[0].kind == .test)
            #expect(controller.primedAt == 0, "a refused send must not arm anything")
            #expect(controller.armingState == .needsTestSend)
            #expect(controller.lastSendOutcome == .permissionDenied)

            sender.setOutcome(.handedToMessages)
            controller.sendTestMessage()
            #expect(controller.primedAt == harness.clock.now)
            #expect(controller.armingState == .armed)
        }
    }

    /// A test send that lands AFTER the user changed the address must never
    /// arm the new (untested) one — otherwise a mistyped address could receive
    /// the lid-close message as its very first contact.
    @Test func aLateTestSendNeverPrimesADifferentRecipient() {
        let sender = DeferredMessageSender()
        withLidGuardHarness(sender: sender) { harness in
            let controller = harness.controller
            controller.setEnabled(true)
            controller.setRecipient("+15551110000")
            controller.sendTestMessage()
            #expect(sender.sends.count == 1)
            #expect(sender.sends[0].recipient == "+15551110000")

            // The user re-opens the editor and switches address while the
            // first test is still in flight.
            controller.setRecipient("+15552220000")
            #expect(controller.primedAt == 0)

            // Now the FIRST test's success arrives.
            sender.completeAll(.handedToMessages)
            #expect(controller.primedAt == 0, "the tested address is no longer the stored one")
            #expect(controller.armingState == .needsTestSend)
            #expect(!harness.source.isRunning)
        }
    }

    /// …and the ordinary case still primes.
    @Test func aTestSendForTheStoredRecipientPrimesOnCompletion() {
        let sender = DeferredMessageSender()
        withLidGuardHarness(sender: sender) { harness in
            harness.controller.setEnabled(true)
            harness.controller.setRecipient("+15551110000")
            harness.controller.sendTestMessage()
            sender.completeAll(.handedToMessages)
            #expect(harness.controller.primedAt == harness.clock.now)
            #expect(harness.controller.armingState == .armed)
        }
    }

    @Test func changingTheRecipientRequiresANewTestSend() {
        withLidGuardHarness { harness in
            harness.arm()
            #expect(harness.controller.armingState == .armed)

            harness.controller.setRecipient("you@example.com")
            #expect(harness.controller.storedRecipient == "you@example.com")
            #expect(harness.controller.primedAt == 0)
            #expect(harness.controller.armingState == .needsTestSend)
            #expect(!harness.source.isRunning, "changing the address disarms until re-primed")
        }
    }

    @Test func anUnusableRecipientIsNotStoredAndSendsNothing() {
        withLidGuardHarness { harness in
            let sender = harness.sender as! RecordingMessageSender
            harness.arm()
            let validation = harness.controller.setRecipient("bad\nvalue")
            #expect(validation == .invalid)
            #expect(harness.controller.storedRecipient == "+15551234567", "the previous value is kept")

            // And an unusable STORED value keeps the feature inert.
            harness.defaults.set("bad\nvalue", forKey: DefaultsKey.lidGuardRecipient)
            #expect(harness.controller.armingState == .needsRecipient)
            harness.controller.sendTestMessage()
            #expect(sender.sends.isEmpty)
        }
    }

    // MARK: Automation probe

    @Test func theAutomationProbeRunsOnlyWhileArmed() {
        withLidGuardHarness { harness in
            harness.controller.refreshAutomationPermission()
            #expect(harness.probe.callCount == 0)
            #expect(harness.controller.automationPermission == nil)

            harness.arm()
            harness.probe.setResult(.denied)
            harness.controller.refreshAutomationPermission()
            #expect(harness.probe.callCount == 1)
            #expect(harness.controller.automationPermission == .denied)
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
