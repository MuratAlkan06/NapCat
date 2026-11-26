import Foundation
import NapCatWire
@testable import NapCatPhone
import Testing

/// A wall clock a test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }

    func set(_ date: Date) {
        lock.lock()
        current = date
        lock.unlock()
    }
}

enum RequestFixtures {
    static let ttl = PendingRequest.timeToLive

    static func id(_ low: UInt64) -> PromptID { PromptID(high: 0xabcd_ef01_2345_6789, low: low)! }

    /// An inbox on `clock` whose answers go nowhere: a recording writer, a
    /// biometric gate that confirms and a paired software key (answering
    /// has its own tests).
    @MainActor
    static func inbox(_ clock: TestClock) -> RequestInbox {
        RequestInbox(writer: RecordingDecisionWriter(), biometrics: ScriptedBiometricGate(), keyring: pairedKeyring(),
                     clock: { clock.now })
    }

    /// A keyring holding one committed software key (the fixtures' own).
    @MainActor
    static func pairedKeyring() -> PhoneKeyring {
        FixtureRequests.keyring(.pending)
    }

    /// A Bash request the Mac forwarded at `createdAt`.
    static func request(_ low: UInt64, createdAt: Date, window: TimeInterval = ttl,
                        preview: String = #"{"command":"git status --short"}"#) -> PendingRequest {
        PendingRequest(id: id(low), toolName: "Bash", inputPreview: preview, projectLabel: "napcat",
                       createdAt: createdAt, expiresAt: createdAt.addingTimeInterval(window))!
    }
}

/// The phone's request model: TTL expiry and withdrawal, both terminal.
@MainActor
@Suite struct RequestInboxTests {
    typealias F = RequestFixtures

    // MARK: The window

    @Test func aFreshRequestIsPendingUntilItsExpiry() {
        let clock = TestClock()
        let inbox = RequestFixtures.inbox(clock)
        let request = F.request(1, createdAt: clock.now)
        inbox.receive([request])
        #expect(inbox.phase(of: request.id) == .pending(until: request.expiresAt))
        clock.advance(F.ttl - 1)
        #expect(inbox.phase(of: request.id)?.isPending == true)
        clock.advance(1)
        #expect(inbox.phase(of: request.id) == .expired, "the window is half-open: at expiry it is over")
    }

    /// A Mac clock running ahead cannot stretch the window: at most the
    /// record's own window after this phone first saw the request.
    @Test func theWindowNeverOutlastsTheTTLFromFirstSight() {
        let clock = TestClock()
        let inbox = RequestFixtures.inbox(clock)
        let ahead = F.request(1, createdAt: clock.now.addingTimeInterval(3_600))
        inbox.receive([ahead])
        #expect(inbox.phase(of: ahead.id) == .pending(until: clock.now.addingTimeInterval(F.ttl)))
        clock.advance(F.ttl)
        #expect(inbox.phase(of: ahead.id) == .expired)
    }

    /// A request first seen after its expiry was never answerable here.
    @Test func aRequestSeenLateIsAlreadyExpired() {
        let clock = TestClock()
        let inbox = RequestFixtures.inbox(clock)
        let stale = F.request(1, createdAt: clock.now.addingTimeInterval(-F.ttl - 5))
        inbox.receive([stale])
        #expect(inbox.phase(of: stale.id) == .expired)
    }

    /// Expiry is terminal once seen: a clock moved back does not reopen it.
    @Test func expiryIsStickyWhenTheClockGoesBack() {
        let clock = TestClock()
        let inbox = RequestFixtures.inbox(clock)
        let request = F.request(1, createdAt: clock.now)
        inbox.receive([request])
        clock.advance(F.ttl + 1)
        inbox.tick()
        clock.set(request.createdAt)
        #expect(inbox.phase(of: request.id) == .expired)
        inbox.receive([request])
        #expect(inbox.phase(of: request.id) == .expired, "an offered record does not reopen it either")
    }

    // MARK: Withdrawal

    /// A request missing from a fetch of everything the Mac offers was taken
    /// back; the others are unchanged.
    @Test func aRequestMissingFromAFetchIsWithdrawn() {
        let clock = TestClock()
        let inbox = RequestFixtures.inbox(clock)
        let first = F.request(1, createdAt: clock.now)
        let second = F.request(2, createdAt: clock.now)
        inbox.receive([first, second])
        clock.advance(30)
        inbox.receive([second])
        #expect(inbox.phase(of: first.id) == .withdrawn)
        #expect(inbox.phase(of: second.id) == .pending(until: second.expiresAt))
    }

    @Test func aDirectWithdrawalIsTerminal() {
        let clock = TestClock()
        let inbox = RequestFixtures.inbox(clock)
        let request = F.request(1, createdAt: clock.now)
        inbox.receive([request])
        inbox.withdraw(request.id)
        #expect(inbox.phase(of: request.id) == .withdrawn)
        inbox.receive([request])
        #expect(inbox.phase(of: request.id) == .withdrawn, "a record that reappears never reopens it")
    }

    /// The first terminal state wins: an expired request a fetch no longer
    /// carries stays expired, and a withdrawn one never turns expired.
    @Test func theFirstTerminalStateWins() {
        let clock = TestClock()
        let inbox = RequestFixtures.inbox(clock)
        let expiring = F.request(1, createdAt: clock.now)
        let withdrawing = F.request(2, createdAt: clock.now)
        inbox.receive([expiring, withdrawing])
        inbox.withdraw(withdrawing.id)
        clock.advance(F.ttl + 1)
        inbox.receive([])
        inbox.withdraw(expiring.id)
        #expect(inbox.phase(of: expiring.id) == .expired)
        #expect(inbox.phase(of: withdrawing.id) == .withdrawn)
    }

    /// #194: the window is the record's own, from first sight, whatever its
    /// length up to the wire's maximum (the Mac's adjustable window).
    @Test(arguments: [300.0, 600, 1_800, 3_600])
    func theWindowIsTheRecordsOwnFromFirstSight(_ window: TimeInterval) {
        let clock = TestClock()
        let inbox = RequestFixtures.inbox(clock)
        let ahead = F.request(1, createdAt: clock.now.addingTimeInterval(7_200), window: window)
        let onTime = F.request(2, createdAt: clock.now, window: window)
        inbox.receive([ahead, onTime])
        #expect(inbox.phase(of: ahead.id) == .pending(until: clock.now.addingTimeInterval(window)))
        #expect(inbox.phase(of: onTime.id) == .pending(until: onTime.expiresAt))
        clock.advance(window - 1)
        #expect(inbox.phase(of: ahead.id)?.isPending == true && inbox.phase(of: onTime.id)?.isPending == true)
        clock.advance(1)
        #expect(inbox.phase(of: ahead.id) == .expired && inbox.phase(of: onTime.id) == .expired)
    }

    @Test func anUnknownRequestHasNoPhase() {
        let inbox = RequestFixtures.inbox(TestClock())
        inbox.withdraw(F.id(9))
        #expect(inbox.phase(of: F.id(9)) == nil)
        #expect(inbox.requests.isEmpty)
    }

    // MARK: The list

    /// Several requests are held separately, newest first.
    @Test func requestsAreListedNewestFirst() {
        let clock = TestClock()
        let inbox = RequestFixtures.inbox(clock)
        let older = F.request(1, createdAt: clock.now.addingTimeInterval(-60))
        let newer = F.request(2, createdAt: clock.now)
        inbox.receive([older, newer])
        #expect(inbox.requests.map(\.id) == [newer.id, older.id])
    }

    /// Past the capacity, finished requests go first; pending ones stay.
    @Test func finishedRequestsMakeRoomFirst() {
        let clock = TestClock()
        let inbox = RequestFixtures.inbox(clock)
        let finished = (0..<UInt64(RequestInbox.capacity)).map { F.request($0 + 1, createdAt: clock.now) }
        inbox.receive(finished)
        clock.advance(1)
        let fresh = (0..<UInt64(8)).map { F.request($0 + 1_000, createdAt: clock.now) }
        inbox.receive(fresh)
        #expect(inbox.entries.count == RequestInbox.capacity)
        for request in fresh {
            #expect(inbox.phase(of: request.id)?.isPending == true)
        }
    }
}

/// Which windows a request may claim.
@Suite struct PendingRequestTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// AMENDED (#194): the ceiling is the wire's maximum window, no longer its
    /// default.
    @Test(arguments: [(0.0, false), (-1, false), (1, true), (60, true), (PendingRequest.timeToLive, true),
                      (PendingRequest.timeToLive + 1, true), (PendingRequest.longestWindow, true),
                      (PendingRequest.longestWindow + 1, false)])
    func aWindowIsAPositiveSpanOfAtMostTheLongest(_ window: TimeInterval, _ fit: Bool) {
        let request = PendingRequest(id: RequestFixtures.id(1), toolName: "Bash", inputPreview: "{}", projectLabel: "p",
                                     createdAt: Self.start, expiresAt: Self.start.addingTimeInterval(window))
        #expect((request != nil) == fit, "window \(window)")
    }

    @Test func aRequestNeedsAToolName() {
        #expect(PendingRequest(id: RequestFixtures.id(1), toolName: "", inputPreview: "{}", projectLabel: "p",
                               createdAt: Self.start, expiresAt: Self.start.addingTimeInterval(60)) == nil)
    }

    @Test func theTTLIsTheWires() {
        #expect(PendingRequest.timeToLive == 600)
        #expect(PendingRequest.timeToLive == TimeInterval(ApprovalWire.promptTimeToLiveSeconds))
    }

    /// #194: the ceiling is the wire's maximum (1 hour), and a request knows
    /// its own window.
    @Test func theCeilingIsTheWiresMaximum() {
        #expect(PendingRequest.longestWindow == 3_600)
        #expect(PendingRequest.longestWindow == TimeInterval(ApprovalWire.maxPromptTimeToLiveSeconds))
        #expect(RequestFixtures.request(1, createdAt: PendingRequestTests.start, window: 1_800).window == 1_800)
    }
}

/// A prompt source a test scripts (#194): every call kept, in order, each
/// answered from its script (the last answer again once one runs out). A
/// call may be held open until the test lets it go (`holdSnapshots`,
/// `holdEnsures`).
final class ScriptedPromptSource: PromptSource, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var ensures: [Bool]
    private var removals: [Bool]
    private var snapshots: [[PendingRequest]?]
    private var held: [CheckedContinuation<Void, Never>] = []
    private var holding = false
    private var holdingEnsures = false

    init(ensures: [Bool] = [true], removals: [Bool] = [true], snapshots: [[PendingRequest]?] = [[]]) {
        self.ensures = ensures
        self.removals = removals
        self.snapshots = snapshots
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    /// From now on each snapshot waits for `release()`.
    func holdSnapshots() {
        lock.lock()
        holding = true
        lock.unlock()
    }

    /// From now on each ensure waits for `release()`.
    func holdEnsures() {
        lock.lock()
        holdingEnsures = true
        lock.unlock()
    }

    func release() {
        lock.lock()
        let waiting = held
        held.removeAll()
        holding = false
        holdingEnsures = false
        lock.unlock()
        for continuation in waiting { continuation.resume() }
    }

    var waiting: Int {
        lock.lock()
        defer { lock.unlock() }
        return held.count
    }

    func ensureSubscription() async -> Bool {
        if shouldHoldEnsure() {
            await withCheckedContinuation { continuation in park(continuation) }
        }
        return takeEnsure()
    }

    func removeSubscription() async -> Bool { takeRemoval() }

    func snapshot() async -> [PendingRequest]? {
        if shouldHold() {
            await withCheckedContinuation { continuation in park(continuation) }
        }
        return takeSnapshot()
    }

    private func takeEnsure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        log.append("ensure")
        return ensures.count > 1 ? ensures.removeFirst() : ensures[0]
    }

    private func takeRemoval() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        log.append("remove")
        return removals.count > 1 ? removals.removeFirst() : removals[0]
    }

    private func takeSnapshot() -> [PendingRequest]? {
        lock.lock()
        defer { lock.unlock() }
        log.append("snapshot")
        return snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0]
    }

    private func shouldHold() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return holding
    }

    private func shouldHoldEnsure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return holdingEnsures
    }

    private func park(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        held.append(continuation)
        lock.unlock()
    }
}

/// F4, #194: the inbox's live prompts, over a scripted source. The switch
/// gates every operation; a read feeds the inbox; switching off empties it
/// and removes the subscription; nothing reads on a timer (the callers are
/// pinned by `PushWiringTests`).
@MainActor
@Suite struct PromptSyncTests {
    typealias F = RequestFixtures

    static func inbox(_ clock: TestClock, _ source: ScriptedPromptSource, paired: Bool = true,
                      writer: any DecisionWriter = RecordingDecisionWriter()) -> RequestInbox {
        RequestInbox(writer: writer, biometrics: ScriptedBiometricGate(),
                     keyring: FixtureRequests.keyring(paired ? .pending : .unpaired), prompts: source, clock: { clock.now })
    }

    /// Off (the default) means zero approval operations, however often it
    /// is synced: no subscription, no read, an empty inbox.
    @Test func offMeansNoOperationAtAll() async {
        let source = ScriptedPromptSource(snapshots: [[F.request(1, createdAt: TestClock().now)]])
        let inbox = Self.inbox(TestClock(), source)
        for _ in 0..<3 { await inbox.syncPrompts(switchedOn: false) }
        await inbox.refreshPrompts()
        #expect(source.calls.isEmpty)
        #expect(inbox.requests.isEmpty)
    }

    /// On, but on a phone with no committed key: nothing either.
    @Test func onButUnpairedMeansNoOperationAtAll() async {
        let source = ScriptedPromptSource(snapshots: [[F.request(1, createdAt: TestClock().now)]])
        let inbox = Self.inbox(TestClock(), source, paired: false)
        await inbox.syncPrompts(switchedOn: true)
        #expect(source.calls.isEmpty)
        #expect(inbox.requests.isEmpty)
    }

    /// On: the subscription is made sure of once, then each sync is one read.
    @Test func onMakesSureOfTheSubscriptionOnceThenReads() async {
        let clock = TestClock()
        let request = F.request(1, createdAt: clock.now)
        let source = ScriptedPromptSource(snapshots: [[request]])
        let inbox = Self.inbox(clock, source)
        await inbox.syncPrompts(switchedOn: true)
        #expect(source.calls == ["ensure", "snapshot"])
        #expect(inbox.requests.map(\.id) == [request.id])
        await inbox.syncPrompts(switchedOn: true)
        await inbox.refreshPrompts()
        #expect(source.calls == ["ensure", "snapshot", "snapshot", "snapshot"], "a second ensure is never asked for")
    }

    /// A subscription not confirmed is tried again at the next sync; the
    /// read goes ahead regardless.
    @Test func anUnconfirmedSubscriptionIsTriedAgain() async {
        let source = ScriptedPromptSource(ensures: [false, true])
        let inbox = Self.inbox(TestClock(), source)
        await inbox.syncPrompts(switchedOn: true)
        await inbox.syncPrompts(switchedOn: true)
        await inbox.syncPrompts(switchedOn: true)
        #expect(source.calls == ["ensure", "snapshot", "ensure", "snapshot", "snapshot"])
    }

    /// A prompt missing from a successful read was taken back: Withdrawn.
    @Test func aPromptMissingFromASuccessfulReadIsWithdrawn() async {
        let clock = TestClock()
        let first = F.request(1, createdAt: clock.now)
        let second = F.request(2, createdAt: clock.now)
        let source = ScriptedPromptSource(snapshots: [[first, second], [second]])
        let inbox = Self.inbox(clock, source)
        await inbox.syncPrompts(switchedOn: true)
        await inbox.syncPrompts(switchedOn: true)
        #expect(inbox.phase(of: first.id) == .withdrawn)
        #expect(inbox.status(of: first.id) == .withdrawn)
        #expect(inbox.phase(of: second.id)?.isPending == true)
        #expect(inbox.pendingRequests.map(\.id) == [second.id])
    }

    /// A failed read withdraws nothing and adds nothing.
    @Test func aFailedReadChangesNothing() async {
        let clock = TestClock()
        let request = F.request(1, createdAt: clock.now)
        let source = ScriptedPromptSource(snapshots: [[request], nil])
        let inbox = Self.inbox(clock, source)
        await inbox.syncPrompts(switchedOn: true)
        let before: [PromptID: RequestInbox.Entry] = inbox.entries
        await inbox.syncPrompts(switchedOn: true)
        #expect(inbox.entries == before)
        #expect(inbox.phase(of: request.id)?.isPending == true)
    }

    /// Switching off empties the inbox and removes the subscription, once;
    /// off again does nothing more.
    @Test func switchingOffEmptiesTheInboxAndRemovesTheSubscription() async {
        let clock = TestClock()
        let source = ScriptedPromptSource(snapshots: [[F.request(1, createdAt: clock.now)]])
        let inbox = Self.inbox(clock, source)
        await inbox.syncPrompts(switchedOn: true)
        #expect(!inbox.requests.isEmpty)
        await inbox.syncPrompts(switchedOn: false)
        #expect(inbox.requests.isEmpty && inbox.pendingRequests.isEmpty)
        #expect(source.calls == ["ensure", "snapshot", "remove"])
        await inbox.syncPrompts(switchedOn: false)
        #expect(source.calls == ["ensure", "snapshot", "remove"], "nothing more once it is gone")
        await inbox.syncPrompts(switchedOn: true)
        #expect(source.calls == ["ensure", "snapshot", "remove", "ensure", "snapshot"], "on again makes sure of it again")
    }

    /// A removal that failed is tried again at each sync until it is done.
    @Test func aFailedRemovalIsTriedAgain() async {
        let source = ScriptedPromptSource(removals: [false, true])
        let inbox = Self.inbox(TestClock(), source)
        await inbox.syncPrompts(switchedOn: true)
        await inbox.syncPrompts(switchedOn: false)
        await inbox.syncPrompts(switchedOn: false)
        await inbox.syncPrompts(switchedOn: false)
        #expect(source.calls == ["ensure", "snapshot", "remove", "remove"])
    }

    /// A phone that stops being paired while on is off: emptied, and the
    /// subscription removed.
    @Test func aPhoneThatUnpairsGoesOff() async {
        let clock = TestClock()
        let store = MemorySigningKeyStore()
        let enclave = SoftwareEnclave()
        if let key = enclave.makeKey() {
            _ = store.write(StoredSigningKey(keyData: key.keyData, enrollment: FixtureRequests.enrolledAtPairing), to: .committed)
        }
        let keyring = PhoneKeyring(store: store, enclave: enclave, enrollment: FixedEnrollment(hash: FixtureRequests.enrolledAtPairing))
        let source = ScriptedPromptSource(snapshots: [[F.request(1, createdAt: clock.now)]])
        let inbox = RequestInbox(writer: RecordingDecisionWriter(), biometrics: ScriptedBiometricGate(), keyring: keyring,
                                 prompts: source, clock: { clock.now })
        await inbox.syncPrompts(switchedOn: true)
        #expect(inbox.requests.count == 1)
        _ = store.delete(.committed)
        await inbox.syncPrompts(switchedOn: true)
        #expect(inbox.requests.isEmpty)
        #expect(source.calls == ["ensure", "snapshot", "remove"])
    }

    /// A read that lands after the switch went off adds nothing: the sync
    /// begun meanwhile goes round once more, off, and empties the inbox.
    @Test func aReadLandingAfterSwitchingOffAddsNothing() async {
        let clock = TestClock()
        let source = ScriptedPromptSource(snapshots: [[F.request(1, createdAt: clock.now)]])
        let inbox = Self.inbox(clock, source)
        source.holdSnapshots()
        let running = Task { await inbox.syncPrompts(switchedOn: true) }
        while source.waiting == 0 { await Task.yield() }
        await inbox.syncPrompts(switchedOn: false)
        source.release()
        await running.value
        #expect(inbox.requests.isEmpty)
        #expect(source.calls == ["ensure", "snapshot", "remove"])
    }

    /// #194 security review: the switch turned off while the subscription is
    /// being made sure of stops the pass there: no read follows, and the
    /// sync begun meanwhile goes round once more, off, and removes the
    /// subscription.
    @Test func switchingOffWhileTheSubscriptionIsMadeSureOfReadsNothing() async {
        let clock = TestClock()
        let source = ScriptedPromptSource(snapshots: [[F.request(1, createdAt: clock.now)]])
        let inbox = Self.inbox(clock, source)
        source.holdEnsures()
        let running = Task { await inbox.syncPrompts(switchedOn: true) }
        while source.waiting == 0 { await Task.yield() }
        await inbox.syncPrompts(switchedOn: false)
        source.release()
        await running.value
        #expect(source.calls == ["ensure", "remove"], "no snapshot after the switch went off")
        #expect(inbox.requests.isEmpty)
    }

    /// With no live source (a fixture launch), a sync does nothing: the
    /// fixture's request stays, on or off.
    @Test func aFixtureInboxIsLeftAsItIs() async {
        let inbox = FixtureRequests.inbox(.pending, now: Date(), biometrics: ScriptedBiometricGate())
        await inbox.syncPrompts(switchedOn: false)
        await inbox.syncPrompts(switchedOn: true)
        #expect(inbox.requests.map(\.id) == [FixtureRequests.id])
    }

    /// Every answer to a live prompt still goes to the unsent writer, the
    /// live inbox's: it reads Unsent, and nothing is written anywhere.
    @Test func anAnswerToALivePromptStillReadsUnsent() async {
        let clock = TestClock()
        let request = F.request(1, createdAt: clock.now)
        let inbox = Self.inbox(clock, ScriptedPromptSource(snapshots: [[request]]), writer: UnsentDecisionWriter())
        await inbox.syncPrompts(switchedOn: true)
        await inbox.allow(request.id)
        #expect(inbox.entries[request.id]?.answer == .unsent(.allow))
        await inbox.deny(request.id)
        #expect(inbox.entries[request.id]?.answer == .unsent(.deny))
    }

    /// #194 design review: so the live inbox is read only, and its prompt
    /// screen offers no answer, only the line that says to answer on the
    /// Mac: no answer that ends unsent, and no "try again" after it.
    @Test func aLivePromptOffersNoAnswer() async throws {
        let clock = TestClock()
        let request = F.request(1, createdAt: clock.now)
        let inbox = Self.inbox(clock, ScriptedPromptSource(snapshots: [[request]]), writer: UnsentDecisionWriter())
        await inbox.syncPrompts(switchedOn: true)
        #expect(inbox.isReadOnly)
        let status: RequestStatus = try #require(inbox.status(of: request.id))
        #expect(status.isAnswerable)
        #expect(PendingRequestScreen.offer(for: status, biometry: inbox.biometry, key: inbox.keyHealth, readOnly: inbox.isReadOnly)
                == PendingRequestScreen.Offer(answers: nil, caption: PendingRequestScreen.readOnlyLine))
        #expect(!Self.inbox(clock, ScriptedPromptSource()).isReadOnly, "a writer that writes leaves the answers on offer")
    }

    /// A tapped push opens its prompt once the inbox holds it: at once when
    /// it does, otherwise after the read; once, then cleared.
    @Test func aTappedPromptOpensOnceHeld() async {
        let clock = TestClock()
        let request = F.request(1, createdAt: clock.now)
        let source = ScriptedPromptSource(snapshots: [[request]])
        let inbox = Self.inbox(clock, source)
        inbox.open(request.id)
        #expect(inbox.opening == nil, "not held yet")
        await inbox.syncPrompts(switchedOn: true)
        #expect(inbox.opening == request.id)
        inbox.opened()
        #expect(inbox.opening == nil)
        inbox.open(request.id)
        #expect(inbox.opening == request.id, "held already: at once")
        inbox.opened()
        await inbox.syncPrompts(switchedOn: true)
        #expect(inbox.opening == nil, "opened once")
    }

    /// #194 security review: a cold launch from a tapped prompt push. The
    /// delegate asks for the tapped prompt and a read before the root has
    /// handed in the owner's switch: that read does nothing and clears
    /// nothing (the switch is not known yet), and the root's first sync,
    /// switch on, reads the prompt and opens it.
    @Test func aTapBeforeTheSwitchIsKnownOpensAtTheFirstSync() async {
        let clock = TestClock()
        let request = F.request(1, createdAt: clock.now)
        let source = ScriptedPromptSource(snapshots: [[request]])
        let inbox = Self.inbox(clock, source)
        inbox.open(request.id)
        await inbox.refreshPrompts()
        #expect(source.calls.isEmpty, "the switch is not known yet: no operation")
        #expect(inbox.opening == nil)
        await inbox.syncPrompts(switchedOn: true)
        #expect(source.calls == ["ensure", "snapshot"])
        #expect(inbox.opening == request.id, "the tapped prompt opens once it is held")
    }

    /// A tap while the switch is off opens nothing, then or later.
    @Test func aTapWhileOffOpensNothing() async {
        let clock = TestClock()
        let request = F.request(1, createdAt: clock.now)
        let source = ScriptedPromptSource(snapshots: [[request]])
        let inbox = Self.inbox(clock, source)
        inbox.open(request.id)
        await inbox.syncPrompts(switchedOn: false)
        await inbox.syncPrompts(switchedOn: true)
        #expect(inbox.opening == nil)
    }

    /// The waiting list holds only what is still pending, newest first.
    @Test func theWaitingListHoldsOnlyPendingRequests() async {
        let clock = TestClock()
        let older = F.request(1, createdAt: clock.now.addingTimeInterval(-30))
        let newer = F.request(2, createdAt: clock.now)
        let short = F.request(3, createdAt: clock.now, window: 300)
        let source = ScriptedPromptSource(snapshots: [[older, newer, short], [newer, short]])
        let inbox = Self.inbox(clock, source)
        await inbox.syncPrompts(switchedOn: true)
        let all: [PromptID] = [short.id, newer.id, older.id]
        #expect(inbox.pendingRequests.map(\.id) == all, "newest first; a tie by ID")
        await inbox.syncPrompts(switchedOn: true)
        clock.advance(300)
        #expect(inbox.pendingRequests.map(\.id) == [newer.id], "withdrawn and expired ones leave the list")
    }
}
