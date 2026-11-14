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
    /// The finish alert never reads the installed hook's version.
    func installedHookVersion() -> Int? { nil }

    /// Create or rewrite one marker (a rewrite is the hook's mktemp + mv).
    /// `ep` is the hook v7 episode-start text (nil = a hook v6 marker).
    func put(_ id: String, ts: Int, event: String = ClaudeBusyConstants.setEvent, ep: String? = nil) {
        remove(id)
        current.append(IdentifiedBusyMarker(sessionID: id,
                                            marker: BusyMarker(ts: ts, event: event, pid: 1, src: "unknown", ep: ep)))
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
    /// Alert healing: the LID alert's own arming, and its pre-connect misses.
    var lidAlertArmingState: LidGuardArmingState = .off
    var lidAlertMissCount = 0
}

@MainActor
final class NowBox {
    var value: Double
    init(_ value: Double) { self.value = value }
}

@MainActor
final class FlagBox {
    var value: Bool
    init(_ value: Bool) { self.value = value }
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
    /// Alert healing: the observed Stay Awake state the controller reads.
    let stayAwake = FlagBox(false)
    let sender: MessageSender
    /// nil ⇒ alert healing is ABSENT: the rows written before it lock the
    /// pre-healing behaviour (which also applies whenever healing is
    /// disarmed). The healing rows pass a simulator.
    let connectivity: ConnectivitySimulator?
    let controller: FinishAlertController
    private(set) var changeCount = 0

    init(sender: MessageSender, connectivity: ConnectivitySimulator? = nil) throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("napcat-finishalert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.sender = sender
        self.connectivity = connectivity
        let factory = self.factory
        let clock = self.clock
        let stayAwake = self.stayAwake
        controller = FinishAlertController(
            store: store,
            markerDirURL: dir,
            config: config,
            sender: sender,
            makeWatcher: { factory.make($0) },
            scheduler: scheduler,
            now: { clock.value },
            connectivity: connectivity,
            stayAwakeOn: { stayAwake.value }
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
    connectivity: ConnectivitySimulator? = nil,
    _ body: (FinishAlertHarness) async throws -> Void
) async throws {
    let harness = try FinishAlertHarness(sender: sender, connectivity: connectivity)
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
            let path = ConnectivitySimulator()
            let mirror = ObservedStayAwakeMirror()
            #expect(FinishAlertController.makeIfEnabled(
                debugBattery: true, lidGuard: lid.controller, sender: RecordingMessageSender(),
                connectivity: path, stayAwakeMirror: mirror) == nil,
                "debugBattery mode must not construct the finish alert")
            #expect(FinishAlertController.makeIfEnabled(
                debugBattery: false, lidGuard: nil, sender: RecordingMessageSender(),
                connectivity: path, stayAwakeMirror: mirror) == nil)
            #expect(FinishAlertController.makeIfEnabled(
                debugBattery: false, lidGuard: lid.controller, sender: nil,
                connectivity: path, stayAwakeMirror: mirror) == nil)
            let built = FinishAlertController.makeIfEnabled(
                debugBattery: false, lidGuard: lid.controller, sender: RecordingMessageSender(),
                connectivity: path, stayAwakeMirror: mirror)
            #expect(built != nil)
            #expect(built?.isWatching == false, "construction alone watches nothing")
            #expect(!path.isRunning && path.startCount == 0, "construction alone observes no path")
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
            // C3 rule 2 AMENDED (2026-10-27): the watcher never saw the id
            // disappear, so it is still one busy episode — the anchor holds.
            #expect(h.controller.tracked[H.s1]?.firstSeen == H.t0 - 600, "the episode anchor is never moved")
            #expect(h.controller.tracked[H.s1]?.lastTs == H.t0 + 5)
            #expect(h.controller.tracked[H.s1]?.exactStart == true)
        }
    }

    // MARK: Issue #24 — the run clock survives a NapCat restart (hook v7 `ep`)

    /// The SAME 30-minute episode watched by two app processes: one armed
    /// before it began, and one RELAUNCHED mid-episode — a fresh controller
    /// whose baseline of the marker on disk is all it knows. With hook v7
    /// markers both report 30 min; with hook v6 markers the relaunched app
    /// re-anchors at the marker's own ts (the unchanged fallback).
    @Test(arguments: [true, false])
    func aRelaunchMidEpisodeKeepsTheRunMinutes(_ hookV7: Bool) async throws {
        let start = H.t0
        let ep: String? = hookV7 ? String(start) : nil
        var uninterrupted: [LidGuardMessageKind] = []
        try await withFinishAlertHarness { h in
            h.controller.reconcile()
            h.store.put(H.s1, ts: h.now, ep: ep)                       // the prompt: the episode begins
            await h.settle()
            h.advance(600)
            h.store.put(H.s1, ts: h.now, event: "Stop", ep: ep)        // background work keeps it
            await h.settle()
            h.advance(1_200)
            h.store.remove(H.s1)
            await h.settle()
            uninterrupted = h.sends.map(\.kind)
        }
        var relaunched: [LidGuardMessageKind] = []
        try await withFinishAlertHarness { h in
            h.advance(600)
            h.store.put(H.s1, ts: h.now, event: "Stop", ep: ep)        // on disk when NapCat relaunches
            h.controller.reconcile()                                   // the new process: a baseline only
            #expect(h.controller.tracked[H.s1]?.firstSeen == (hookV7 ? start : start + 600))
            #expect(h.controller.tracked[H.s1]?.exactStart == hookV7)
            h.advance(1_200)
            h.store.remove(H.s1)
            await h.settle()
            relaunched = h.sends.map(\.kind)
        }
        #expect(uninterrupted == [.sessionFinished(minutes: 30, folded: 1, stillWorking: 0)])
        if hookV7 {
            #expect(relaunched == uninterrupted, "a relaunch must not change the reported minutes")
        } else {
            #expect(relaunched == [.sessionFinished(minutes: nil, folded: 1, stillWorking: 0)],
                    "hook v6: re-anchored at a keep, so the minutes are left out (as before)")
        }
    }

    /// A rejected `ep` (malformed, future, past the 12 h horizon) never
    /// breaks the alert: the session falls back to the pre-v7 anchor — at
    /// arm time and when first seen in a diff alike.
    @Test func anUnusableEpisodeStartFallsBackToTheAppsOwnAnchor() async throws {
        try await withFinishAlertHarness { h in
            h.store.put(H.s1, ts: H.t0 - 600, ep: "not-a-number")
            h.store.put(H.s2, ts: H.t0 - 600, ep: String(H.t0 + 3_600))
            h.controller.reconcile()
            #expect(h.controller.tracked[H.s1]?.firstSeen == H.t0 - 600, "baseline: malformed ⇒ the marker's ts")
            #expect(h.controller.tracked[H.s2]?.firstSeen == H.t0 - 600, "baseline: future ⇒ the marker's ts")
            h.store.put(H.s3, ts: h.now, event: "Stop",
                        ep: String(H.t0 - ClaudeBusyConstants.freshnessCapSeconds - 1))
            await h.settle()
            #expect(h.controller.tracked[H.s3]?.firstSeen == H.t0, "first seen in a diff: too old ⇒ the marker's ts")
            #expect(h.controller.tracked[H.s3]?.exactStart == false)
            h.store.remove(H.s1)
            await h.settle()
            #expect(h.sends.map(\.kind) == [.sessionFinished(minutes: 10, folded: 1, stillWorking: 2)])
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

    // MARK: B-1 — session-lane hold after HTTP 429

    static let hold = FinishAlertTuning.rateLimitHoldSeconds

    /// A 429 opens the hold: the window now closes `rateLimitHoldSeconds`
    /// after the refusal and the ONE flush is scheduled for that instant — no
    /// retry, nothing else pending.
    @Test func a429HoldsTheWindowAndSchedulesTheFlushAtTheHoldEnd() async throws {
        try await withFinishAlertHarness(sender: RecordingMessageSender(outcome: .rejected(429))) { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.controller.reconcile()
            h.store.remove(H.s1)
            await h.settle()
            #expect(h.sends.count == 1)
            #expect(h.controller.lastSendOutcome == .rejected(429))
            #expect(h.pendingRetries.isEmpty, "a 429 is still never retried")
            #expect(h.scheduler.pending.map(\.delay) == [Self.hold],
                    "exactly one pending callback: the flush at the hold end, got \(h.scheduler.pending.map(\.delay))")
        }
    }

    /// Every finish observed during the hold FOLDS into the digest; nothing
    /// is sent until the hold ends, then ONE folded message goes out.
    @Test func finishesDuringTheHoldFoldIntoOneMessageAtTheHoldEnd() async throws {
        let sender = RecordingMessageSender(outcome: .rejected(429))
        try await withFinishAlertHarness(sender: sender) { h in
            for id in [H.s1, H.s2, H.s3] { h.store.put(id, ts: H.t0 - 600) }
            h.controller.reconcile()
            h.store.remove(H.s1)
            await h.settle()
            let flush = try #require(h.scheduler.pending(delay: Self.hold).first)
            sender.setOutcome(.accepted)

            h.advance(100)
            h.store.remove(H.s2)
            await h.settle()
            h.advance(200)
            h.store.remove(H.s3)
            await h.settle()
            #expect(h.sends.count == 1, "held: nothing goes out during the hold")
            #expect(h.scheduler.pending.count == 1 && flush.isPending, "still the one flush at the hold end")

            h.advance(300)   // t0 + 600: the hold ends
            flush.fire()
            await drainMain()
            #expect(h.sends.map(\.kind) == [.sessionFinished(minutes: 10, folded: 1, stillWorking: 2),
                                            .sessionFinished(minutes: nil, folded: 2, stillWorking: 0)])
            #expect(h.controller.lastSendOutcome == .accepted)
            #expect(h.scheduler.pending.isEmpty, "an accepted flush leaves no hold behind")
        }
    }

    /// A second 429 at the flush extends the hold again: a new flush one
    /// hold later, and what folds meanwhile goes out then.
    @Test func a429AtTheHoldEndExtendsTheHoldAgain() async throws {
        let sender = RecordingMessageSender(outcome: .rejected(429))
        try await withFinishAlertHarness(sender: sender) { h in
            for id in [H.s1, H.s2, H.s3] { h.store.put(id, ts: H.t0 - 600) }
            h.controller.reconcile()
            h.store.remove(H.s1)
            await h.settle()
            let first = try #require(h.scheduler.pending(delay: Self.hold).first)

            h.advance(100)
            h.store.remove(H.s2)
            await h.settle()
            h.advance(500)
            first.fire()
            await drainMain()
            #expect(h.sends.count == 2, "the held digest went out at the hold end")
            let second = try #require(h.scheduler.pending(delay: Self.hold).first, "the second 429 re-held the lane")
            #expect(second !== first)
            #expect(h.scheduler.pending.count == 1)

            sender.setOutcome(.accepted)
            h.advance(60)
            h.store.remove(H.s3)
            await h.settle()
            #expect(h.sends.count == 2, "still held after the second 429")
            h.advance(540)
            second.fire()
            await drainMain()
            #expect(h.sends.count == 3)
            #expect(h.sends.last?.kind == .sessionFinished(minutes: 21, folded: 1, stillWorking: 0))
        }
    }

    /// S10: a flush of TWO messages (waiting + finish) whose FIRST send gets
    /// 429 — the second is NOT sent into the same rate limit; it folds back
    /// into the digest, a finish observed during the hold joins it, and ONE
    /// combined flush goes out when the hold ends.
    @Test func a429FoldsTheRestOfItsFlushBackIntoTheDigest() async throws {
        let sender = RecordingMessageSender(outcome: .rejected(429))
        try await withFinishAlertHarness(sender: sender) { h in
            h.store.put(H.s1, ts: H.t0 - 720)
            h.store.put(H.s2, ts: H.t0 - 1200)
            h.store.put(H.s3, ts: H.t0 - 600)
            h.controller.reconcile()
            h.store.put(H.s1, ts: H.t0, event: H.waiting)
            h.store.remove(H.s2)
            await h.settle()
            #expect(h.sends.map(\.kind) == [.needsAttention(minutes: 12, stillWorking: 1)],
                    "the finish queued behind the 429 must NOT be sent into the same limit")
            #expect(h.controller.lastSendOutcome == .rejected(429))
            let flush = try #require(h.scheduler.pending(delay: Self.hold).first)
            #expect(h.scheduler.pending.count == 1, "only the hold's flush is pending (no retry)")

            sender.setOutcome(.accepted)
            h.advance(100)
            h.store.remove(H.s3)
            await h.settle()
            #expect(h.sends.count == 1, "held: nothing goes out during the hold")
            #expect(flush.isPending && h.scheduler.pending.count == 1, "still the one flush at the hold end")

            h.advance(500)   // t0 + 600: the hold ends
            flush.fire()
            await drainMain()
            #expect(h.sends.map(\.kind) == [.needsAttention(minutes: 12, stillWorking: 1),
                                            .sessionFinished(minutes: nil, folded: 2, stillWorking: 1)],
                    "the absorbed finish and the one observed during the hold leave as ONE message")
            #expect(h.scheduler.pending.isEmpty)
        }
    }

    /// S10, nothing else happening: the absorbed message goes out unchanged at
    /// the hold end — folding back in neither loses nor alters it.
    @Test func anAbsorbedMessageLeavesUnchangedAtTheHoldEnd() async throws {
        let sender = RecordingMessageSender(outcome: .rejected(429))
        try await withFinishAlertHarness(sender: sender) { h in
            h.store.put(H.s1, ts: H.t0 - 720)
            h.store.put(H.s2, ts: H.t0 - 1200)
            h.store.put(H.s3, ts: H.t0 - 600)
            h.controller.reconcile()
            h.store.put(H.s1, ts: H.t0, event: H.waiting)
            h.store.remove(H.s2)
            await h.settle()
            #expect(h.sends.count == 1)
            let flush = try #require(h.scheduler.pending(delay: Self.hold).first)
            sender.setOutcome(.accepted)
            h.advance(600)
            flush.fire()
            await drainMain()
            #expect(h.sends.map(\.kind) == [.needsAttention(minutes: 12, stillWorking: 1),
                                            .sessionFinished(minutes: 20, folded: 1, stillWorking: 2)])
        }
    }

    /// S10 is 429-only: after any other refusal the queued second message is
    /// still sent right away (no hold, nothing folded back).
    @Test func otherRefusalsStillSendTheRestOfTheFlush() async throws {
        let sender = RecordingMessageSender(outcome: .rejected(403))
        try await withFinishAlertHarness(sender: sender) { h in
            h.store.put(H.s1, ts: H.t0 - 720)
            h.store.put(H.s2, ts: H.t0 - 1200)
            h.controller.reconcile()
            h.store.put(H.s1, ts: H.t0, event: H.waiting)
            h.store.remove(H.s2)
            await h.settle()
            #expect(h.sends.map(\.kind) == [.needsAttention(minutes: 12, stillWorking: 0),
                                            .sessionFinished(minutes: 20, folded: 1, stillWorking: 1)])
            #expect(h.scheduler.pending(delay: Self.hold).isEmpty)
        }
    }

    enum HoldTeardown: String, CaseIterable, Sendable { case off, paused, quit }

    /// Disarm, pause and quit during the hold cancel the flush and drop the
    /// folded digest; after re-arming, the hold is gone (the next finish
    /// sends at once, unfolded).
    @Test(arguments: HoldTeardown.allCases)
    func aTeardownDuringTheHoldCancelsTheFlushAndDropsTheDigest(_ teardown: HoldTeardown) async throws {
        let sender = RecordingMessageSender(outcome: .rejected(429))
        try await withFinishAlertHarness(sender: sender) { h in
            for id in [H.s1, H.s2, H.s3] { h.store.put(id, ts: H.t0 - 600) }
            h.controller.reconcile()
            h.store.remove(H.s1)
            await h.settle()
            let flush = try #require(h.scheduler.pending(delay: Self.hold).first)
            h.advance(100)
            h.store.remove(H.s2)
            await h.settle()

            switch teardown {
            case .off:
                h.config.finishAlertArmingState = .off
                h.controller.reconcile()
            case .paused:
                h.pause()
                h.controller.reconcile()
            case .quit:
                h.controller.disarmForShutdown()
            }
            #expect(!h.controller.isWatching, "\(teardown.rawValue)")
            #expect(flush.cancelled, "\(teardown.rawValue): the hold's flush is cancelled")
            for work in h.scheduler.scheduled { work.fire() }
            await drainMain()
            #expect(h.sends.count == 1, "\(teardown.rawValue): nothing goes out after the teardown")

            // Re-arm: a fresh baseline, no window, no digest left over.
            h.config.finishAlertArmingState = .armed
            try? FileManager.default.removeItem(at: h.dir.appendingPathComponent(ClaudeBusyConstants.disabledFlagName))
            h.controller.reconcile()
            #expect(h.controller.isWatching, "\(teardown.rawValue): re-armed")
            sender.setOutcome(.accepted)
            h.store.remove(H.s3)
            await h.settle()
            #expect(h.sends.count == 2, "\(teardown.rawValue): the hold did not survive the teardown")
            #expect(h.sends.last?.kind == .sessionFinished(minutes: 11, folded: 1, stillWorking: 0),
                    "\(teardown.rawValue): the dropped digest's finish is not folded in")
        }
    }

    /// Any other refusal leaves the plain batch window: a finish after it
    /// goes out as soon as the 30 s window closes, not after a hold.
    @Test func otherRefusalsDoNotHold() async throws {
        let sender = RecordingMessageSender(outcome: .rejected(403))
        try await withFinishAlertHarness(sender: sender) { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.store.put(H.s2, ts: H.t0 - 600)
            h.controller.reconcile()
            h.store.remove(H.s1)
            await h.settle()
            #expect(h.scheduler.pending.isEmpty, "no hold after a 403")
            h.advance(10)
            h.store.remove(H.s2)
            await h.settle()
            #expect(h.scheduler.pending.map(\.delay) == [FinishAlertTuning.batchWindowSeconds - 10])
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

    /// The floor boundary end to end: a run of exactly 60 s (the floor) with
    /// an exact anchor is sent, and its body reads "after 1 min".
    @Test func aRunOfExactlyTheFloorFinishesAfterOneMinute() async throws {
        try await withFinishAlertHarness { h in
            h.store.put(H.s1, ts: H.t0 - 60)
            h.controller.reconcile()
            h.store.remove(H.s1)
            await h.settle()
            #expect(h.sends.map(\.kind) == [.sessionFinished(minutes: 1, folded: 1, stillWorking: 0)])
            let kind = try #require(h.sends.first?.kind)
            #expect(LidGuardPolicy.messageBody(kind: kind, clockTime: "22:49")
                    == "A Claude session finished after 1 min — none still working")
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

// MARK: - Alert-channel healing (issue #23), controller half

extension FinishAlertHarness {
    /// The simulated path (healing rows only).
    var path: ConnectivitySimulator {
        guard let connectivity else { preconditionFailure("a healing row must pass a ConnectivitySimulator") }
        return connectivity
    }

    var pathDebounces: [ManualScheduler.Work] { scheduler.pending(delay: AlertHealingTuning.pathDebounceSeconds) }

    /// The path drops and the hop lands; returns the path debounce it armed
    /// (nil when it armed none).
    func pathDown() async -> ManualScheduler.Work? {
        let before = scheduler.scheduled.count
        path.status = .unsatisfied
        await drainMain()
        return scheduler.scheduled.count > before ? scheduler.scheduled.last : nil
    }

    func pathUp() async {
        path.status = .satisfied
        await drainMain()
    }

    /// A path loss sustained for the full debounce: OFFLINE, anchored at the
    /// moment the path dropped.
    func goOfflineByPath() async {
        let debounce = await pathDown()
        advance(Int(AlertHealingTuning.pathDebounceSeconds))
        debounce?.fire()
        await drainMain()
    }
}

/// Alert-channel healing (issue #23) through the REAL controller: the
/// arming predicate and its zero footprint, the offline hold replacing the
/// FA-7 retry (each alert sent exactly once more, by the flush), the 429
/// hold winning over a flush and its restore push, coalesced triggers, the
/// 12 h held-digest max age, and the lid-lane exemption. Fakes only: the
/// path is a `ConnectivitySimulator`, the sender a recorder.
@MainActor
struct FinishAlertHealingTests {
    typealias H = FinishAlertHarness
    static let offline = MessageSendOutcome.sendFailed("this Mac had no internet connection")

    // MARK: Arming + zero footprint

    /// Disarmed: no monitor, nothing scheduled. Stay Awake ON arms ONE fresh
    /// observation cycle; OFF disarms it again (stop, nothing pending).
    @Test func healingHasZeroFootprintUntilSomethingIsInPlay() async throws {
        let path = ConnectivitySimulator()
        try await withFinishAlertHarness(connectivity: path) { h in
            h.controller.reconcile()
            #expect(h.controller.isWatching, "session alerts are armed")
            #expect(h.controller.healing.phase == .disarmed, "…but nothing is in play")
            #expect(!path.isRunning && path.startCount == 0)
            #expect(h.scheduler.scheduled.isEmpty)

            h.stayAwake.value = true
            h.controller.reconcile()
            #expect(h.controller.healing.phase == .online)
            #expect(path.isRunning && path.startCount == 1)
            await drainMain()
            #expect(h.scheduler.scheduled.isEmpty, "a satisfied path schedules nothing")
            h.controller.reconcile()
            #expect(path.startCount == 1, "idempotent")

            h.stayAwake.value = false
            h.controller.reconcile()
            #expect(h.controller.healing.phase == .disarmed)
            #expect(!path.isRunning && path.stopCount == 1)
            #expect(h.scheduler.pending.isEmpty, "zero footprint: nothing pending")

            h.stayAwake.value = true
            h.controller.reconcile()
            #expect(path.startCount == 2, "every arm cycle starts a fresh observation")
            h.controller.disarmForShutdown()
            #expect(!path.isRunning && path.stopCount == 2, "quit stops the monitor")
            #expect(h.controller.healing.phase == .disarmed)
        }
    }

    /// Tracking a session arms healing; the LAST session's finish keeps it
    /// armed while that alert is still in the lane, and only its completion
    /// lets it disarm — so the last alert is never sent unprotected.
    @Test func theLastSessionsFinishIsSentWithHealingStillArmed() async throws {
        let path = ConnectivitySimulator()
        let sender = DeferredMessageSender()
        try await withFinishAlertHarness(sender: sender, connectivity: path) { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.controller.reconcile()
            #expect(h.controller.healing.phase == .online)
            await drainMain()
            h.store.remove(H.s1)
            await h.settle()
            #expect(h.sends.count == 1)
            #expect(h.controller.tracked.isEmpty)
            #expect(h.controller.healing.phase == .online, "the finish is in flight — the lane still holds it")
            sender.completeAll(.accepted)
            await drainMain()
            #expect(h.controller.healing.phase == .disarmed, "nothing in play any more")
            #expect(!path.isRunning && path.stopCount == 1)
            #expect(h.scheduler.pending.isEmpty)
        }
    }

    /// The lid alert alone arms healing too (Stay Awake ON), with no watcher.
    @Test func aLidOnlyConfigurationArmsWithoutTheWatcher() async throws {
        let path = ConnectivitySimulator()
        try await withFinishAlertHarness(connectivity: path) { h in
            h.config.finishAlertArmingState = .off
            h.config.lidAlertArmingState = .armed
            h.stayAwake.value = true
            h.controller.reconcile()
            #expect(!h.controller.isWatching)
            #expect(h.controller.healing.phase == .online)
            #expect(path.isRunning)
            h.config.storedDestination = nil
            h.controller.reconcile()
            #expect(h.controller.healing.phase == .disarmed, "nothing to heal toward")
        }
    }

    // MARK: Entry, the single send, the flush

    /// Captive portal + FA-7 superseded: the path reads SATISFIED but the
    /// send fails pre-connect ⇒ OFFLINE, and NO retry is scheduled. However
    /// long it waits (past the 5 min retry max age too) nothing is re-sent
    /// into the outage; the menu-open flush sends the alert exactly ONCE
    /// more, then the restore push.
    @Test func aPreConnectFailureHoldsInsteadOfRetryingAndTheAlertIsSentExactlyOnceMore() async throws {
        let path = ConnectivitySimulator()
        let sender = RecordingMessageSender(outcome: Self.offline)
        let finished = LidGuardMessageKind.sessionFinished(minutes: 42, folded: 1, stillWorking: 0)
        try await withFinishAlertHarness(sender: sender, connectivity: path) { h in
            h.store.put(H.s1, ts: H.t0 - 2520)
            h.controller.reconcile()
            await drainMain()
            h.store.remove(H.s1)
            await h.settle()
            #expect(h.sends.map(\.kind) == [finished])
            #expect(h.controller.connectivityOffline, "satisfied path + pre-connect failure ⇒ OFFLINE")
            #expect(h.pendingRetries.isEmpty, "the offline hold replaces the FA-7 retry")
            #expect(h.controller.healing.outage?.startedAt == Double(H.t0))

            h.advance(600)
            for work in h.scheduler.pending { work.fire() }
            await drainMain()
            #expect(h.sends.count == 1, "nothing is sent into the outage")

            sender.setOutcome(.accepted)
            h.controller.menuOpened()
            await drainMain()
            #expect(h.sends.map(\.kind) == [finished, finished,
                                            .connectionRestored(minutes: 10, deliveredLate: 1, dropped: 0, lidMissed: 0)])
            #expect(!h.controller.connectivityOffline)
            #expect(h.controller.healing.phase == .disarmed, "healed, and nothing in play any more")
            for work in h.scheduler.pending { work.fire() }
            await drainMain()
            #expect(h.sends.count == 3, "exactly once — no straggler retry")
        }
    }

    /// A flap shorter than the debounce does nothing; a sustained loss holds.
    /// A session event while offline is a flush trigger — it fails pre-connect
    /// and the lane is OFFLINE again with the ORIGINAL anchor; the path coming
    /// back flushes ONCE and the restore push measures the whole outage.
    @Test func aSustainedPathLossHoldsAndThePathComingBackFlushesOnce() async throws {
        let path = ConnectivitySimulator()
        let sender = RecordingMessageSender()
        let finished = LidGuardMessageKind.sessionFinished(minutes: 11, folded: 1, stillWorking: 1)
        try await withFinishAlertHarness(sender: sender, connectivity: path) { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.store.put(H.s2, ts: H.t0 - 600)
            h.controller.reconcile()
            await drainMain()

            let armed = await h.pathDown()
            let flap = try #require(armed)
            #expect(flap.delay == AlertHealingTuning.pathDebounceSeconds)
            await h.pathUp()
            #expect(flap.cancelled, "a flap shorter than the debounce cancels it")
            #expect(!h.controller.connectivityOffline)

            await h.goOfflineByPath()
            #expect(h.controller.connectivityOffline)
            #expect(h.controller.healing.outage?.startedAt == Double(H.t0), "anchored when the path dropped")
            #expect(h.sends.isEmpty)

            sender.setOutcome(Self.offline)
            h.advance(100)
            h.store.remove(H.s1)
            await h.settle()
            #expect(h.sends.map(\.kind) == [finished], "the event triggered ONE attempt")
            #expect(h.controller.connectivityOffline, "it failed pre-connect: OFFLINE again")
            #expect(h.controller.healing.outage?.startedAt == Double(H.t0), "the ORIGINAL anchor is kept")
            #expect(h.pendingRetries.isEmpty)

            sender.setOutcome(.accepted)
            h.advance(400)
            await h.pathUp()
            #expect(h.sends.map(\.kind) == [finished, finished,
                                            .connectionRestored(minutes: 9, deliveredLate: 1, dropped: 0, lidMissed: 0)],
                    "502 s from the original anchor ⇒ 9 min")
            #expect(!h.controller.connectivityOffline)
            #expect(h.controller.healing.phase == .online, "s2 is still tracked")
        }
    }

    /// An outage shorter than the 60 s floor heals silently: the held alert
    /// is delivered, the restore push is suppressed.
    @Test func anOutageUnderTheFloorDeliversButSendsNoRestorePush() async throws {
        let path = ConnectivitySimulator()
        let sender = RecordingMessageSender(outcome: Self.offline)
        try await withFinishAlertHarness(sender: sender, connectivity: path) { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.store.put(H.s2, ts: H.t0 - 600)
            h.controller.reconcile()
            await drainMain()
            h.store.remove(H.s1)
            await h.settle()
            #expect(h.controller.connectivityOffline)
            sender.setOutcome(.accepted)
            h.advance(59)
            h.controller.menuOpened()
            await drainMain()
            #expect(h.sends.map(\.kind) == Array(repeating: .sessionFinished(minutes: 10, folded: 1, stillWorking: 1),
                                                 count: 2), "delivered, and no restore push under 60 s")
            #expect(h.controller.healing.phase == .online)
        }
    }

    // MARK: The 429 hold wins

    /// A 429 DURING the flush: the queued rest of the flush folds back, the
    /// restore push is NOT sent into the rate limit — it waits for the hold
    /// end, where ONE flush carries the refolded alert and then the push.
    @Test func a429DuringTheFlushRefoldsAndTheRestorePushWaitsForTheHoldEnd() async throws {
        let path = ConnectivitySimulator()
        let sender = RecordingMessageSender()
        let waiting = LidGuardMessageKind.needsAttention(minutes: 12, stillWorking: 1)
        let finished = LidGuardMessageKind.sessionFinished(minutes: 20, folded: 1, stillWorking: 2)
        try await withFinishAlertHarness(sender: sender, connectivity: path) { h in
            h.store.put(H.s1, ts: H.t0 - 720)
            h.store.put(H.s2, ts: H.t0 - 1200)
            h.store.put(H.s3, ts: H.t0 - 600)
            h.controller.reconcile()
            await drainMain()
            await h.goOfflineByPath()                                   // anchor t0, now t0 + 2

            sender.setOutcome(Self.offline)
            h.store.put(H.s1, ts: h.now, event: H.waiting)
            h.store.remove(H.s2)
            await h.settle()
            #expect(h.sends.map(\.kind) == [waiting], "the event's attempt failed at its first message")
            #expect(h.controller.connectivityOffline)

            sender.setOutcome(.rejected(429))
            h.advance(300)
            await h.pathUp()
            #expect(h.sends.map(\.kind) == [waiting, waiting], "the flush's first message hit the rate limit")
            #expect(h.controller.healing.phase == .flushing, "not healed: the flush has not succeeded")
            #expect(!h.controller.connectivityOffline)
            let holdEnd = try #require(h.scheduler.pending(delay: FinishAlertTuning.rateLimitHoldSeconds).first)
            #expect(h.scheduler.pending.count == 1, "only the hold's flush is pending")

            sender.setOutcome(.accepted)
            h.controller.menuOpened()                                   // not OFFLINE: no bypass
            await drainMain()
            #expect(h.sends.count == 2, "nothing — not the refolded alert, not the restore push — bypasses the hold")

            h.advance(600)
            holdEnd.fire()
            await drainMain()
            #expect(h.sends.map(\.kind) == [waiting, waiting, finished,
                                            .connectionRestored(minutes: 6, deliveredLate: 1, dropped: 0, lidMissed: 0)],
                    "the refolded finish, then the push (302 s ⇒ 6 min; the refused buzz is not counted late)")
            #expect(h.controller.healing.phase == .online)
        }
    }

    /// Lid-only: the restore push itself hits a 429 — it is recomposed and
    /// sent once, at the hold end, never into the rate limit.
    @Test func aLidOnlyRestorePushRefusedWith429WaitsForTheHoldEnd() async throws {
        let path = ConnectivitySimulator()
        let sender = RecordingMessageSender(outcome: .rejected(429))
        let push = LidGuardMessageKind.connectionRestored(minutes: 5, deliveredLate: 0, dropped: 0, lidMissed: 1)
        try await withFinishAlertHarness(sender: sender, connectivity: path) { h in
            h.config.finishAlertArmingState = .off
            h.config.lidAlertArmingState = .armed
            h.stayAwake.value = true
            h.controller.reconcile()
            await drainMain()
            await h.goOfflineByPath()
            h.config.lidAlertMissCount = 1
            h.advance(298)
            await h.pathUp()
            #expect(h.sends.map(\.kind) == [push], "lid-only: the push goes immediately")
            let holdEnd = try #require(h.scheduler.pending(delay: FinishAlertTuning.rateLimitHoldSeconds).first)
            #expect(h.controller.healing.phase == .flushing)

            sender.setOutcome(.accepted)
            h.advance(600)
            holdEnd.fire()
            await drainMain()
            #expect(h.sends.map(\.kind) == [push, push], "recomposed once at the hold end")
            #expect(h.controller.healing.phase == .online)
        }
    }

    // MARK: Coalescing

    /// The path coming back, the menu opening (twice) and a repeated path
    /// update in the same turn cause ONE flush attempt.
    @Test func simultaneousFlushTriggersCauseOneAttempt() async throws {
        let path = ConnectivitySimulator()
        let sender = DeferredMessageSender()
        let finished = LidGuardMessageKind.sessionFinished(minutes: 10, folded: 1, stillWorking: 1)
        try await withFinishAlertHarness(sender: sender, connectivity: path) { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.store.put(H.s2, ts: H.t0 - 600)
            h.controller.reconcile()
            await drainMain()
            h.store.remove(H.s1)
            await h.settle()
            sender.completeAll(Self.offline)
            await drainMain()
            #expect(h.controller.connectivityOffline)
            h.advance(120)
            let none = await h.pathDown()
            #expect(none == nil, "OFFLINE: a path loss arms no debounce")

            path.status = .satisfied                // its hop is still queued…
            h.controller.menuOpened()               // …when the menu opens
            h.controller.menuOpened()
            await drainMain()
            path.redeliver()
            await drainMain()
            #expect(h.sends.map(\.kind) == [finished, finished], "ONE attempt for every trigger")
            #expect(h.controller.healing.phase == .flushing)

            sender.completeAll(.accepted)
            await drainMain()
            sender.completeAll(.accepted)
            await drainMain()
            #expect(h.sends.map(\.kind) == [finished, finished,
                                            .connectionRestored(minutes: 2, deliveredLate: 1, dropped: 0, lidMissed: 0)])
            #expect(h.controller.healing.phase == .online)
        }
    }

    /// A path delivery queued before a disarm / re-arm is ignored: only the
    /// live arm's update arms a debounce.
    @Test func aPathDeliveryFromAnEarlierArmIsIgnored() async throws {
        let path = ConnectivitySimulator()
        try await withFinishAlertHarness(connectivity: path) { h in
            h.stayAwake.value = true
            h.controller.reconcile()
            await drainMain()
            path.status = .unsatisfied              // hop queued for arm 1
            h.stayAwake.value = false
            h.controller.reconcile()                // disarm
            h.stayAwake.value = true
            h.controller.reconcile()                // arm 2: delivers .unsatisfied again
            await drainMain()
            #expect(path.startCount == 2)
            #expect(h.pathDebounces.count == 1, "exactly one debounce — arm 1's delivery was dropped")
        }
    }

    // MARK: The 12 h held-digest max age

    /// Exactly 12 h: the held alert is delivered late. One second more: it is
    /// DROPPED (counted), never delivered, and the push says so — dropped
    /// wins. (The single retry's 5 min max age never applies to the hold.)
    @Test(arguments: [(43_200, false), (43_201, true)])
    func theHeldDigestMaxAgeDecidesDeliveredLateOrDropped(_ age: Int, _ dropped: Bool) async throws {
        let path = ConnectivitySimulator()
        let sender = RecordingMessageSender(outcome: Self.offline)
        let finished = LidGuardMessageKind.sessionFinished(minutes: 10, folded: 1, stillWorking: 1)
        try await withFinishAlertHarness(sender: sender, connectivity: path) { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.store.put(H.s2, ts: H.t0 - 600)
            h.controller.reconcile()
            await drainMain()
            h.store.remove(H.s1)
            await h.settle()
            #expect(h.controller.connectivityOffline)

            sender.setOutcome(.accepted)
            h.advance(age)
            h.controller.menuOpened()
            await drainMain()
            let minutes = (age + 59) / 60
            if dropped {
                #expect(h.sends.map(\.kind) == [finished,
                                                .connectionRestored(minutes: minutes, deliveredLate: 0, dropped: 1,
                                                                    lidMissed: 0)])
            } else {
                #expect(h.sends.map(\.kind) == [finished, finished,
                                                .connectionRestored(minutes: minutes, deliveredLate: 1, dropped: 0,
                                                                    lidMissed: 0)])
            }
        }
    }

    // MARK: The lid lane is exempt

    /// The REAL lid guard on the shared sender, the finish alert OFFLINE: the
    /// WillSleep lid alert is attempted AT ONCE (never gated, queued or
    /// held), its pre-connect failure is only COUNTED, it is never re-sent at
    /// the flush, and the restore push reports the miss.
    @Test func theLidLaneAttemptsAtOnceWhileOfflineAndItsMissIsOnlyCounted() async throws {
        let suite = "com.muratalkan.napcat.tests.healing.lid.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("napcat-healing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sender = RecordingMessageSender()
        let lid = LidGuardHarness(defaults: defaults, sender: sender)
        lid.arm()
        defaults.set(true, forKey: DefaultsKey.claudeFinishAlertEnabled)
        let store = FakeMarkerStore()
        store.put(H.s1, ts: H.t0 - 600)
        let path = ConnectivitySimulator()
        let scheduler = ManualScheduler()
        let factory = WatcherFactory()
        let clock = NowBox(Double(H.t0))
        let finish = FinishAlertController(
            store: store, markerDirURL: dir, config: lid.controller, sender: sender,
            makeWatcher: { factory.make($0) }, scheduler: scheduler, now: { clock.value },
            connectivity: path, stayAwakeOn: { false })
        finish.reconcile()
        await drainMain()
        #expect(finish.isWatching && finish.healing.phase == .online)

        path.status = .unsatisfied
        await drainMain()
        clock.value += AlertHealingTuning.pathDebounceSeconds
        scheduler.pending(delay: AlertHealingTuning.pathDebounceSeconds).first?.fire()
        await drainMain()
        #expect(finish.connectivityOffline)

        sender.setOutcome(Self.offline)
        let ack = lid.source.deliver(.systemWillSleep)
        #expect(ack.performedCount == 1)
        #expect(sender.sends.map(\.kind) == [.lidAlert(busySessionCount: 1)], "attempted AT ONCE while offline")
        #expect(lid.controller.lidAlertMissCount == 1, "its pre-connect failure is counted")
        #expect(finish.connectivityOffline, "the lid lane neither reads nor moves the healing state")
        #expect(finish.healing.phase == .offline)

        lid.source.deliver(.systemHasPoweredOn)
        sender.setOutcome(.accepted)
        clock.value += 298
        path.status = .satisfied
        await drainMain()
        #expect(sender.sends.map(\.kind) == [.lidAlert(busySessionCount: 1),
                                             .connectionRestored(minutes: 5, deliveredLate: 0, dropped: 0, lidMissed: 1)])
        #expect(sender.sends.filter { LidGuardPolicy.lane(for: $0.kind) == .lid }.count == 1,
                "the missed lid alert is never retried or re-sent")
        #expect(!finish.connectivityOffline)
        finish.disarmForShutdown()
    }

    /// Lid-only and nothing to report: the outage heals with NO push, and
    /// switching Stay Awake off mid-outage disarms with nothing pending.
    @Test func aLidOnlyOutageWithoutMissesHealsSilentlyAndDisarmsCleanly() async throws {
        let path = ConnectivitySimulator()
        let sender = RecordingMessageSender()
        try await withFinishAlertHarness(sender: sender, connectivity: path) { h in
            h.config.finishAlertArmingState = .off
            h.config.lidAlertArmingState = .armed
            h.stayAwake.value = true
            h.controller.reconcile()
            await drainMain()
            await h.goOfflineByPath()
            #expect(h.controller.connectivityOffline)
            h.advance(600)
            await h.pathUp()
            #expect(h.sends.isEmpty, "no content ⇒ no restore push")
            #expect(h.controller.healing.phase == .online)

            await h.goOfflineByPath()
            #expect(h.controller.connectivityOffline)
            h.stayAwake.value = false
            h.controller.reconcile()
            #expect(h.controller.healing.phase == .disarmed, "an outage with nothing held does not pin the monitor")
            #expect(!h.controller.connectivityOffline, "disarmed ⇒ no offline line")
            #expect(!path.isRunning)
            #expect(h.scheduler.pending.isEmpty)
        }
    }
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

    /// S8 (`O_DIRECTORY`): a REGULAR FILE at the watched path is refused by
    /// the open itself — start fails and nothing is watched.
    @Test func startOnARegularFileFailsAndStaysStopped() throws {
        let parent = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("claude-busy")
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data("not a dir".utf8)))
        let watcher = KqueueMarkerDirectoryWatcher(directory: file)
        #expect(!watcher.start { _ in }, "a regular file is not a marker directory")
        #expect(!watcher.isRunning)
    }

    /// S8 (`O_NONBLOCK` + `O_DIRECTORY`): a FIFO planted at the watched path
    /// is refused at once — the open never waits for a writer.
    @Test(.timeLimit(.minutes(1)))
    func startOnAFifoFailsWithoutBlocking() throws {
        let parent = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let fifo = parent.appendingPathComponent("claude-busy")
        try #require(mkfifo(fifo.path, 0o600) == 0, "setup: mkfifo failed (errno \(errno))")
        let watcher = KqueueMarkerDirectoryWatcher(directory: fifo)
        let started = Date()
        #expect(!watcher.start { _ in })
        #expect(Date().timeIntervalSince(started) < 3, "the open must not block on a FIFO")
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
