// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

// MARK: - Test doubles

/// In-memory marker dir: the tests mutate the marker set by hand. Only the
/// DISABLED pause flag lives on disk (in a per-test TEMP dir), because the
/// controller reads it exactly like ClaudeActivityController does.
@MainActor
final class FakeMarkerStore: BusyMarkerStore {
    var current: [IdentifiedBusyMarker] = []
    var dirExists = true
    var hookLogPresent = true

    func markers() -> [BusyMarker] { current.map(\.marker) }
    func identifiedMarkers() -> [IdentifiedBusyMarker] { current }
    func markerDirExists() -> Bool { dirExists }
    func hookLogExists() -> Bool { hookLogPresent }
    func lastActivityEpoch() -> Int? { nil }

    /// Create or rewrite one marker (a rewrite is the hook's mktemp + mv).
    func put(_ id: String, ts: Int, event: String = ClaudeBusyConstants.setEvent) {
        remove(id)
        current.append(IdentifiedBusyMarker(sessionID: id, marker: BusyMarker(ts: ts, event: event, pid: 1, src: "unknown")))
    }

    func remove(_ id: String) {
        current.removeAll { $0.sessionID == id }
    }
}

/// Fake kqueue watcher: records start/stop and lets a test inject events.
/// Events go through the controller's REAL main-queue hop. Used from the
/// main actor only (the protocol itself is not actor-isolated).
final class RecordingWatcher: MarkerDirectoryWatching {
    let directory: URL
    let startResult: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var handler: (@Sendable (MarkerDirectoryEvent) -> Void)?
    /// Survives `stop()`, so a test can replay a STALE delivery.
    private(set) var lastHandler: (@Sendable (MarkerDirectoryEvent) -> Void)?

    init(directory: URL, startResult: Bool) {
        self.directory = directory
        self.startResult = startResult
    }

    var isRunning: Bool { handler != nil }

    func start(handler: @escaping @Sendable (MarkerDirectoryEvent) -> Void) -> Bool {
        startCount += 1
        guard startResult else { return false }
        self.handler = handler
        lastHandler = handler
        return true
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func deliver(_ event: MarkerDirectoryEvent) {
        handler?(event)
    }
}

@MainActor
final class WatcherFactory {
    var startResult = true
    private(set) var made: [RecordingWatcher] = []
    var latest: RecordingWatcher? { made.last }

    func make(_ directory: URL) -> MarkerDirectoryWatching {
        let watcher = RecordingWatcher(directory: directory, startResult: startResult)
        made.append(watcher)
        return watcher
    }
}

/// Records every one-shot callback; a test fires or inspects them by hand.
@MainActor
final class ManualScheduler: FinishAlertScheduling {
    @MainActor
    final class Work: FinishAlertScheduledWork {
        let delay: TimeInterval
        private let work: @MainActor () -> Void
        private(set) var cancelled = false
        private(set) var fired = false

        init(delay: TimeInterval, work: @escaping @MainActor () -> Void) {
            self.delay = delay
            self.work = work
        }

        var isPending: Bool { !cancelled && !fired }

        func cancel() { cancelled = true }

        /// Runs the work unless it was cancelled or already ran.
        func fire() {
            guard isPending else { return }
            fired = true
            work()
        }
    }

    private(set) var scheduled: [Work] = []

    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> FinishAlertScheduledWork {
        let item = Work(delay: delay, work: work)
        scheduled.append(item)
        return item
    }

    var pending: [Work] { scheduled.filter(\.isPending) }

    func pending(delay: TimeInterval) -> [Work] { pending.filter { $0.delay == delay } }
}

final class FakeFinishConfig: FinishAlertConfigSource {
    var finishAlertArmingState: LidGuardArmingState = .armed
    var storedDestination: NtfyDestination? = LidGuardPolicy.destination(server: "https://ntfy.sh",
                                                                         topic: "napcat-finish-4k7q2w")
}

@MainActor
final class NowBox {
    var value: Double
    init(_ value: Double) { self.value = value }
}

/// Lets every main-queue hop queued so far (and the hops THOSE queue, up to
/// `rounds` deep) run before the test continues.
@MainActor
func drainMain(rounds: Int = 6) async {
    for _ in 0..<rounds {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

/// One controller wired to fakes only: no kqueue, no network, no real
/// timer, and the only on-disk path is a per-test TEMP dir (never the real
/// marker dir).
@MainActor
final class FinishAlertHarness {
    static let t0 = 1_800_000_000
    static let ups = ClaudeBusyConstants.setEvent
    static let waiting = ClaudeBusyConstants.waitingEventToken
    static let s1 = "aaaa0001-0000-4abc-8def-000000000001"
    static let s2 = "bbbb0002-0000-4abc-8def-000000000002"
    static let s3 = "cccc0003-0000-4abc-8def-000000000003"
    static let s4 = "dddd0004-0000-4abc-8def-000000000004"

    let dir: URL
    let store = FakeMarkerStore()
    let config = FakeFinishConfig()
    let scheduler = ManualScheduler()
    let factory = WatcherFactory()
    let clock = NowBox(Double(t0))
    let sender: MessageSender
    let controller: FinishAlertController
    private(set) var changeCount = 0

    init(sender: MessageSender) throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("napcat-finishalert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.sender = sender
        let factory = self.factory
        let clock = self.clock
        controller = FinishAlertController(
            store: store,
            markerDirURL: dir,
            config: config,
            sender: sender,
            makeWatcher: { factory.make($0) },
            scheduler: scheduler,
            now: { clock.value }
        )
        controller.setChangeHandler { [weak self] in self?.changeCount += 1 }
    }

    var watcher: RecordingWatcher? { factory.latest }
    var now: Int { Int(clock.value) }
    var sends: [RecordedMessageSend] {
        (sender as? RecordingMessageSender)?.sends ?? (sender as? DeferredMessageSender)?.sends ?? []
    }

    func advance(_ seconds: Int) { clock.value += Double(seconds) }

    func pause() {
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent(ClaudeBusyConstants.disabledFlagName).path, contents: Data())
    }

    /// The watcher reports a change; the hop runs; the debounce is scheduled.
    func change() async {
        watcher?.deliver(.contentsChanged)
        await drainMain()
    }

    /// Fires the live debounce, then lets every send completion hop land.
    func fireDebounce() async {
        let debounces = scheduler.pending(delay: FinishAlertTuning.debounceSeconds)
        #expect(debounces.count == 1, "exactly one debounce may be pending, found \(debounces.count)")
        debounces.last?.fire()
        await drainMain()
    }

    /// change + debounce in one step.
    func settle() async {
        await change()
        await fireDebounce()
    }

    var pendingRetries: [ManualScheduler.Work] { scheduler.pending(delay: FinishAlertTuning.retryDelaySeconds) }

    func cleanup() {
        try? FileManager.default.removeItem(at: dir)
    }
}

@MainActor
func withFinishAlertHarness(
    sender: MessageSender = RecordingMessageSender(),
    _ body: (FinishAlertHarness) async throws -> Void
) async throws {
    let harness = try FinishAlertHarness(sender: sender)
    defer { harness.cleanup() }
    try await body(harness)
}

// MARK: - Tests

/// Track C slice C3 — the FinishAlertController shell around the pure policy
/// (PLAN.md Track C, verification rows FA-3, FA-5, FA-6, FA-7, the batch
/// window, the run floor, and the waiting buzz).
@MainActor
struct FinishAlertControllerTests {
    typealias H = FinishAlertHarness

    // MARK: Arm / disarm

    @Test func armingTakesABaselineAndSendsNothing() async throws {
        try await withFinishAlertHarness { h in
            h.store.put(H.s1, ts: H.t0 - 100)
            h.store.put(H.s2, ts: H.t0 - 50, event: H.waiting)
            h.controller.reconcile()

            #expect(h.factory.made.count == 1)
            #expect(h.watcher?.directory == h.dir)
            #expect(h.watcher?.startCount == 1)
            #expect(h.controller.isWatching)
            #expect(h.controller.displayState == .armed)
            #expect(Set(h.controller.tracked.keys) == [H.s1, H.s2])
            #expect(h.controller.tracked[H.s1]?.firstSeen == H.t0 - 100)
            #expect(h.controller.tracked[H.s1]?.exactStart == true)
            #expect(h.controller.tracked[H.s2]?.waitingBuzzed == false,
                    "a session already waiting at arm time is never buzzed for that episode")
            #expect(h.sends.isEmpty)
            #expect(h.scheduler.scheduled.isEmpty)
            #expect(h.changeCount == 1)

            // Idempotent: a second reconcile neither rebuilds nor restarts.
            h.controller.reconcile()
            #expect(h.factory.made.count == 1)
            #expect(h.watcher?.startCount == 1)
        }
    }

    @Test(arguments: [LidGuardArmingState.off, .needsTopic, .needsTestSend])
    func aNotArmedConfigNeverBuildsTheWatcher(_ state: LidGuardArmingState) async throws {
        try await withFinishAlertHarness { h in
            h.config.finishAlertArmingState = state
            h.controller.reconcile()
            #expect(h.factory.made.isEmpty, "zero footprint while not armed")
            #expect(!h.controller.isWatching)
            let expected: FinishAlertDisplayState = switch state {
            case .off: .off
            case .needsTopic: .needsTopic
            case .needsTestSend: .needsTestSend
            case .armed: .armed
            }
            #expect(h.controller.displayState == expected)
        }
    }

    @Test func thePauseFlagKeepsTheWatcherOff() async throws {
        try await withFinishAlertHarness { h in
            h.pause()
            h.controller.reconcile()
            #expect(h.factory.made.isEmpty)
            #expect(h.controller.displayState == .paused)
        }
    }

    @Test func aMissingMarkerDirKeepsTheWatcherOff() async throws {
        try await withFinishAlertHarness { h in
            h.store.dirExists = false
            h.controller.reconcile()
            #expect(h.factory.made.isEmpty)
            #expect(h.controller.displayState == .hookNotInstalled)
        }
    }

    /// F3 honesty: "armed" is shown only while the watcher really runs.
    @Test func anUnwatchableDirStaysDisarmedAndIsNeverShownArmed() async throws {
        try await withFinishAlertHarness { h in
            h.store.put(H.s1, ts: H.t0 - 100)
            h.factory.startResult = false
            h.controller.reconcile()
            #expect(h.factory.made.count == 1)
            #expect(!h.controller.isWatching)
            #expect(h.controller.tracked.isEmpty)
            #expect(h.controller.displayState == .hookNotInstalled)

            // The next reconcile retries with a fresh watcher.
            h.factory.startResult = true
            h.controller.reconcile()
            #expect(h.factory.made.count == 2)
            #expect(h.controller.isWatching)
            #expect(h.controller.displayState == .armed)
        }
    }

    @Test func turningTheConfigOffDisarmsAndClearsEverything() async throws {
        try await withFinishAlertHarness { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.controller.reconcile()
            h.store.remove(H.s1)
            await h.change()
            #expect(h.scheduler.pending.count == 1)

            h.config.finishAlertArmingState = .off
            h.controller.reconcile()
            #expect(!h.controller.isWatching)
            #expect(h.watcher?.stopCount == 1)
            #expect(h.controller.tracked.isEmpty)
            #expect(h.scheduler.pending.isEmpty, "teardown cancels the pending debounce")
            #expect(h.controller.displayState == .off)
            #expect(h.changeCount == 2, "armed + disarmed")
            for work in h.scheduler.scheduled { work.fire() }
            await drainMain()
            #expect(h.sends.isEmpty)
        }
    }

    @Test func shutdownDisarms() async throws {
        try await withFinishAlertHarness { h in
            h.controller.reconcile()
            h.controller.disarmForShutdown()
            #expect(!h.controller.isWatching)
            #expect(h.watcher?.stopCount == 1)
            h.controller.disarmForShutdown()
            #expect(h.watcher?.stopCount == 1, "idempotent")
        }
    }

    /// Construction gate (ADR §8 mirror). Only the nil-returning paths and a
    /// never-reconciled instance are exercised: nothing here may watch the
    /// REAL marker dir.
    @Test func constructionIsGatedAndDoesNoIO() {
        withLidGuardHarness { lid in
            #expect(FinishAlertController.makeIfEnabled(
                debugBattery: true, lidGuard: lid.controller, sender: RecordingMessageSender()) == nil,
                "debugBattery mode must not construct the finish alert")
            #expect(FinishAlertController.makeIfEnabled(
                debugBattery: false, lidGuard: nil, sender: RecordingMessageSender()) == nil)
            #expect(FinishAlertController.makeIfEnabled(
                debugBattery: false, lidGuard: lid.controller, sender: nil) == nil)
            let built = FinishAlertController.makeIfEnabled(
                debugBattery: false, lidGuard: lid.controller, sender: RecordingMessageSender())
            #expect(built != nil)
            #expect(built?.isWatching == false, "construction alone watches nothing")
        }
    }

    // MARK: FA-3 — a vanished directory is never a finish

    @Test func aVanishedDirectoryIsNeverAFinishAndReArmsWithAFreshBaseline() async throws {
        try await withFinishAlertHarness { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.controller.reconcile()
            let first = try #require(h.watcher)

            h.store.remove(H.s1)
            await h.change()
            let debounce = try #require(h.scheduler.pending.first)

            h.store.dirExists = false
            first.deliver(.directoryGone)
            await drainMain()
            #expect(!h.controller.isWatching)
            #expect(first.stopCount == 1)
            #expect(debounce.cancelled, "teardown cancels the pending debounce")
            debounce.fire()
            await drainMain()
            #expect(h.sends.isEmpty, "a vanished directory is never a finish")
            #expect(h.controller.tracked.isEmpty)
            #expect(h.controller.displayState == .hookNotInstalled)

            // Recreated + reconciled (menu open): watching again, new baseline.
            h.store.dirExists = true
            h.store.put(H.s2, ts: H.t0 + 10)
            h.controller.reconcile()
            #expect(h.factory.made.count == 2)
            #expect(h.controller.isWatching)
            #expect(Set(h.controller.tracked.keys) == [H.s2])
            #expect(h.sends.isEmpty)
        }
    }

    // MARK: FA-5 — recreated inside the debounce window

    @Test func aMarkerRecreatedInsideTheDebounceWindowIsNoFinish() async throws {
        try await withFinishAlertHarness { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.controller.reconcile()

            h.advance(5)
            h.store.remove(H.s1)
            await h.change()
            let first = try #require(h.scheduler.pending.first)
            h.store.put(H.s1, ts: h.now)
            await h.change()
            #expect(first.cancelled, "each event re-arms the ONE debounce")
            #expect(h.scheduler.pending.count == 1)

            await h.fireDebounce()
            #expect(h.sends.isEmpty)
            #expect(h.controller.tracked[H.s1]?.firstSeen == H.t0 + 5, "firstSeen re-anchored to the new turn")
            #expect(h.controller.tracked[H.s1]?.exactStart == true)
        }
    }

    // MARK: FA-6 — pause races

    @Test func pausingBeforeTheDebounceFiresSendsNothingAndDisarms() async throws {
        try await withFinishAlertHarness { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.controller.reconcile()
            h.store.remove(H.s1)
            await h.change()
            // Writing the DISABLED flag is itself a dir event.
            h.pause()
            await h.change()
            await h.fireDebounce()
            #expect(h.sends.isEmpty)
            #expect(!h.controller.isWatching)
            #expect(h.watcher?.stopCount == 1)
            #expect(h.controller.displayState == .paused)
        }
    }

    @Test func disarmCancelsAPendingRetryAndAPendingFlush() async throws {
        try await withFinishAlertHarness(sender: RecordingMessageSender(outcome: .sendFailed("offline"))) { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.store.put(H.s2, ts: H.t0 - 600)
            h.controller.reconcile()
            h.store.remove(H.s1)
            await h.settle()
            #expect(h.sends.count == 1)
            let retry = try #require(h.pendingRetries.first)

            h.advance(5)
            h.store.remove(H.s2)
            await h.settle()
            let flush = try #require(h.scheduler.pending(delay: 25).first, "held for the rest of the window")

            h.pause()
            h.controller.reconcile()
            #expect(!h.controller.isWatching)
            #expect(retry.cancelled)
            #expect(flush.cancelled)
            h.advance(60)
            for work in h.scheduler.scheduled { work.fire() }
            await drainMain()
            #expect(h.sends.count == 1, "nothing fires after a disarm")
        }
    }

    // MARK: FA-7 — retry table, controller half

    @Test func aSendFailedIsRetriedExactlyOnceWithTheSameKind() async throws {
        try await withFinishAlertHarness(sender: RecordingMessageSender(outcome: .sendFailed("offline"))) { h in
            h.store.put(H.s1, ts: H.t0 - 2520)
            h.controller.reconcile()
            h.store.remove(H.s1)
            await h.settle()
            #expect(h.sends.count == 1)
            #expect(h.pendingRetries.count == 1)
            #expect(h.scheduler.pending.count == 1, "only the retry is pending")

            h.advance(30)
            h.pendingRetries.first?.fire()
            await drainMain()
            #expect(h.sends.count == 2)
            #expect(h.sends.map(\.kind) == Array(repeating: .sessionFinished(minutes: 42, folded: 1, stillWorking: 0),
                                                 count: 2))
            #expect(h.scheduler.pending.isEmpty, "a failed RETRY is never retried again")
            #expect(h.controller.lastSendOutcome == .sendFailed("offline"))
            for work in h.scheduler.scheduled { work.fire() }
            await drainMain()
            #expect(h.sends.count == 2, "no third attempt")
        }
    }

    @Test(arguments: [MessageSendOutcome.rejected(429), .timedOutUnconfirmed, .accepted])
    func outcomesThatReachedTheServerAreNeverRetried(_ outcome: MessageSendOutcome) async throws {
        try await withFinishAlertHarness(sender: RecordingMessageSender(outcome: outcome)) { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.controller.reconcile()
            h.store.remove(H.s1)
            await h.settle()
            #expect(h.sends.count == 1)
            #expect(h.pendingRetries.isEmpty)
            #expect(h.controller.lastSendOutcome == outcome)
            #expect(h.controller.lastSendOutcomeAt == Double(H.t0))
            #expect(h.controller.lastSendKind == .sessionFinished(minutes: 10, folded: 1, stillWorking: 0))
        }
    }

    enum RetryGate: String, CaseIterable, Sendable { case paused, directoryGone, tooOld, disarmed }

    @Test(arguments: RetryGate.allCases)
    func aRetryIsDroppedWhenItsGateCloses(_ gate: RetryGate) async throws {
        try await withFinishAlertHarness(sender: RecordingMessageSender(outcome: .sendFailed("offline"))) { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.controller.reconcile()
            h.store.remove(H.s1)
            await h.settle()
            let retry = try #require(h.pendingRetries.first)

            h.advance(30)
            switch gate {
            case .paused: h.pause()
            case .directoryGone: h.store.dirExists = false
            case .tooOld: h.advance(FinishAlertTuning.retryMaxAgeSeconds.toInt - 30 + 1)
            case .disarmed:
                h.config.finishAlertArmingState = .off
                h.controller.reconcile()
                #expect(retry.cancelled)
            }
            retry.fire()
            await drainMain()
            #expect(h.sends.count == 1, "\(gate.rawValue): the retry must be dropped")
        }
    }

    // MARK: Batch window

    @Test func threeFinishesInOneDebounceFoldIntoOneMessage() async throws {
        try await withFinishAlertHarness { h in
            for id in [H.s1, H.s2, H.s3] { h.store.put(id, ts: H.t0 - 600) }
            h.store.put(H.s4, ts: H.t0 - 10)
            h.controller.reconcile()
            for id in [H.s1, H.s2, H.s3] { h.store.remove(id) }
            await h.settle()
            #expect(h.sends.map(\.kind) == [.sessionFinished(minutes: nil, folded: 3, stillWorking: 1)])
        }
    }

    @Test func aFinishInsideTheBatchWindowIsHeldThenFlushedAlone() async throws {
        try await withFinishAlertHarness { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.store.put(H.s2, ts: H.t0 - 600)
            h.controller.reconcile()
            h.store.remove(H.s1)
            await h.settle()
            #expect(h.sends.map(\.kind) == [.sessionFinished(minutes: 10, folded: 1, stillWorking: 1)])

            h.advance(10)
            h.store.remove(H.s2)
            await h.settle()
            #expect(h.sends.count == 1, "held while the window is open")
            let flush = try #require(h.scheduler.pending(delay: 20).first)

            h.advance(20)
            flush.fire()
            await drainMain()
            #expect(h.sends.count == 2)
            #expect(h.sends.last?.kind == .sessionFinished(minutes: 10, folded: 1, stillWorking: 0))
        }
    }

    @Test func aWindowCloseWithASendInFlightFlushesOnlyAfterTheCompletion() async throws {
        let sender = DeferredMessageSender()
        try await withFinishAlertHarness(sender: sender) { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.store.put(H.s2, ts: H.t0 - 600)
            h.controller.reconcile()
            h.store.remove(H.s1)
            await h.settle()
            #expect(h.sends.count == 1)

            h.advance(10)
            h.store.remove(H.s2)
            await h.settle()
            let flush = try #require(h.scheduler.pending(delay: 20).first)
            h.advance(20)
            flush.fire()
            await drainMain()
            #expect(h.sends.count == 1, "the first send is still in flight")
            #expect(h.scheduler.pending.isEmpty, "past the window the completion pumps — no flush busy-loop")

            sender.completeAll(.accepted)
            await drainMain()
            #expect(h.sends.count == 2)
            #expect(h.sends.last?.kind == .sessionFinished(minutes: 10, folded: 1, stillWorking: 0))
        }
    }

    // MARK: Floor + minutes, end to end

    @Test func aLongRunFinishCarriesItsMinutes() async throws {
        try await withFinishAlertHarness { h in
            h.store.put(H.s1, ts: H.t0 - 2520)
            h.controller.reconcile()
            h.store.remove(H.s1)
            await h.settle()
            #expect(h.sends.map(\.kind) == [.sessionFinished(minutes: 42, folded: 1, stillWorking: 0)])
            #expect(h.sends.first?.destination == h.config.storedDestination)
            #expect(h.sends.first?.firedAt == Date(timeIntervalSince1970: Double(H.t0)))
        }
    }

    @Test func aRunUnderTheFloorSendsNothing() async throws {
        try await withFinishAlertHarness { h in
            h.store.put(H.s1, ts: H.t0 - 20)
            h.controller.reconcile()
            h.store.remove(H.s1)
            await h.settle()
            #expect(h.sends.isEmpty)
            #expect(h.scheduler.pending.isEmpty)
            #expect(h.controller.tracked.isEmpty)
            #expect(h.controller.isWatching)
        }
    }

    // MARK: Waiting buzz

    @Test func aWaitingTransitionBuzzesOnceAndRewritesDoNot() async throws {
        try await withFinishAlertHarness { h in
            h.store.put(H.s1, ts: H.t0 - 720)
            h.store.put(H.s2, ts: H.t0 - 60)
            h.controller.reconcile()
            h.store.put(H.s1, ts: H.t0, event: H.waiting)
            await h.settle()
            #expect(h.sends.map(\.kind) == [.needsAttention(minutes: 12, stillWorking: 1)])

            h.advance(40)
            h.store.put(H.s1, ts: h.now, event: H.waiting)
            await h.settle()
            #expect(h.sends.count == 1, "a rewrite that stays waiting never re-buzzes")
            #expect(h.scheduler.pending.isEmpty)
        }
    }

    @Test func waitingAndAFinishInOneDigestSendWaitingFirstThenTheFinish() async throws {
        let sender = DeferredMessageSender()
        try await withFinishAlertHarness(sender: sender) { h in
            h.store.put(H.s1, ts: H.t0 - 720)
            h.store.put(H.s2, ts: H.t0 - 1200)
            h.controller.reconcile()
            h.store.put(H.s1, ts: H.t0, event: H.waiting)
            h.store.remove(H.s2)
            await h.settle()
            #expect(h.sends.map(\.kind) == [.needsAttention(minutes: 12, stillWorking: 0)],
                    "the second message waits for the first to complete")

            sender.completeAll(.accepted)
            await drainMain()
            #expect(h.sends.map(\.kind) == [.needsAttention(minutes: 12, stillWorking: 0),
                                            .sessionFinished(minutes: 20, folded: 1, stillWorking: 1)])
            #expect(h.controller.lastSendKind == .needsAttention(minutes: 12, stillWorking: 0))
        }
    }

    // MARK: Inline refusal / re-entrancy

    @Test func anInlineRefusalIsHandledOnlyAfterSendReturns() async throws {
        try await withFinishAlertHarness(sender: RecordingMessageSender(outcome: .sendFailed("lane busy"))) { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.controller.reconcile()
            h.store.remove(H.s1)
            await h.change()
            // Fire WITHOUT draining: the sender has already completed inline.
            h.scheduler.pending.first?.fire()
            #expect(h.sends.count == 1)
            #expect(h.controller.lastSendOutcome == nil, "the completion hops — never handled inside send")
            #expect(h.pendingRetries.isEmpty)

            await drainMain()
            #expect(h.controller.lastSendOutcome == .sendFailed("lane busy"))
            #expect(h.pendingRetries.count == 1)
            #expect(h.sends.count == 1)
        }
    }

    // MARK: Stale deliveries

    @Test func eventsFromAnEarlierArmOrWhileDisarmedAreIgnored() async throws {
        try await withFinishAlertHarness { h in
            h.controller.reconcile()
            let first = try #require(h.watcher)
            let staleHandler = try #require(first.lastHandler)

            h.config.finishAlertArmingState = .off
            h.controller.reconcile()
            staleHandler(.contentsChanged)
            await drainMain()
            #expect(h.scheduler.scheduled.isEmpty, "ignored while disarmed")

            h.config.finishAlertArmingState = .armed
            h.controller.reconcile()
            #expect(h.factory.made.count == 2)
            staleHandler(.contentsChanged)
            staleHandler(.directoryGone)
            await drainMain()
            #expect(h.scheduler.scheduled.isEmpty, "an earlier arm's event never schedules")
            #expect(h.controller.isWatching, "an earlier arm's directoryGone never disarms the new one")
        }
    }

    @Test func aCompletionAfterDisarmIsRecordedButSendsNoMore() async throws {
        let sender = DeferredMessageSender()
        try await withFinishAlertHarness(sender: sender) { h in
            h.store.put(H.s1, ts: H.t0 - 720)
            h.store.put(H.s2, ts: H.t0 - 1200)
            h.controller.reconcile()
            h.store.put(H.s1, ts: H.t0, event: H.waiting)
            h.store.remove(H.s2)
            await h.settle()
            #expect(h.sends.count == 1, "the finish is queued behind the in-flight waiting buzz")

            h.config.finishAlertArmingState = .off
            h.controller.reconcile()
            sender.completeAll(.sendFailed("offline"))
            await drainMain()
            #expect(h.controller.lastSendOutcome == .sendFailed("offline"))
            #expect(h.scheduler.pending.isEmpty, "no retry after a disarm")
            #expect(h.sends.count == 1, "the queued finish was dropped with the disarm")
        }
    }

    @Test func anUnusableDestinationDropsTheQueueWithoutSending() async throws {
        try await withFinishAlertHarness { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.controller.reconcile()
            h.config.storedDestination = nil
            h.store.remove(H.s1)
            await h.settle()
            #expect(h.sends.isEmpty)
            #expect(h.scheduler.pending.isEmpty)
        }
    }
}

private extension TimeInterval {
    var toInt: Int { Int(self) }
}

// MARK: - The real kqueue watcher (integration, TEMP dirs only)

/// Collects deliveries from the watcher's private queue.
final class WatcherEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MarkerDirectoryEvent] = []

    func record(_ event: MarkerDirectoryEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var all: [MarkerDirectoryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    /// Polls (no blocking) for up to `seconds`.
    func waitFor(_ event: MarkerDirectoryEvent, seconds: Double = 3) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if all.contains(event) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return all.contains(event)
    }
}

struct MarkerDirectoryWatcherTests {
    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("napcat-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func theEventMapPrefersTheDirectoryGoingAway() {
        typealias W = KqueueMarkerDirectoryWatcher
        #expect(W.event(for: .write) == .contentsChanged)
        #expect(W.event(for: .delete) == .directoryGone)
        #expect(W.event(for: .rename) == .directoryGone)
        #expect(W.event(for: .revoke) == .directoryGone)
        #expect(W.event(for: [.write, .delete]) == .directoryGone, "a vanished dir is never a finish")
        #expect(W.event(for: [.write, .rename]) == .directoryGone)
        #expect(W.event(for: .attrib) == nil)
        #expect(W.event(for: []) == nil)
        #expect(W.eventMask == [.write, .delete, .rename, .revoke])
    }

    @Test func reportsEntryChangesThenTheDirectoryGoingAway() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = KqueueMarkerDirectoryWatcher(directory: dir)
        let recorder = WatcherEventRecorder()
        #expect(!watcher.isRunning)
        #expect(watcher.start(handler: recorder.record))
        #expect(watcher.isRunning)

        let file = dir.appendingPathComponent("aaaa0001-0000-4abc-8def-000000000001")
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data("v1".utf8)))
        try FileManager.default.removeItem(at: file)
        #expect(await recorder.waitFor(.contentsChanged), "create+delete inside the dir is a dir write")

        try FileManager.default.removeItem(at: dir)
        #expect(await recorder.waitFor(.directoryGone))

        watcher.stop()
        #expect(!watcher.isRunning)
        watcher.stop()
        #expect(!watcher.isRunning, "stop is idempotent")
    }

    @Test func startOnAMissingDirectoryFailsAndStaysStopped() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("napcat-watch-missing-\(UUID().uuidString)")
        let watcher = KqueueMarkerDirectoryWatcher(directory: dir)
        #expect(!watcher.start { _ in })
        #expect(!watcher.isRunning)
    }

    @Test func startStopStartWorksAndAStoppedWatcherIsSilent() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = KqueueMarkerDirectoryWatcher(directory: dir)
        let silent = WatcherEventRecorder()
        #expect(watcher.start(handler: silent.record))
        watcher.stop()
        #expect(!watcher.isRunning)

        FileManager.default.createFile(atPath: dir.appendingPathComponent("one").path, contents: Data())
        try? await Task.sleep(for: .milliseconds(300))
        #expect(silent.all.isEmpty, "a stopped watcher delivers nothing")

        let recorder = WatcherEventRecorder()
        #expect(watcher.start(handler: recorder.record))
        #expect(watcher.isRunning)
        #expect(watcher.start { _ in }, "starting a running watcher is a no-op")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("two").path, contents: Data())
        #expect(await recorder.waitFor(.contentsChanged))
        watcher.stop()
        #expect(!watcher.isRunning)
    }
}
