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

    /// A Bash request the Mac forwarded `age` seconds before `now`.
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
        let inbox = RequestInbox(clock: { clock.now })
        let request = F.request(1, createdAt: clock.now)
        inbox.receive([request])
        #expect(inbox.phase(of: request.id) == .pending(until: request.expiresAt))
        clock.advance(F.ttl - 1)
        #expect(inbox.phase(of: request.id)?.isPending == true)
        clock.advance(1)
        #expect(inbox.phase(of: request.id) == .expired, "the window is half-open: at expiry it is over")
    }

    /// A Mac clock running ahead cannot stretch the window: at most the TTL
    /// after this phone first saw the request.
    @Test func theWindowNeverOutlastsTheTTLFromFirstSight() {
        let clock = TestClock()
        let inbox = RequestInbox(clock: { clock.now })
        let ahead = F.request(1, createdAt: clock.now.addingTimeInterval(3_600))
        inbox.receive([ahead])
        #expect(inbox.phase(of: ahead.id) == .pending(until: clock.now.addingTimeInterval(F.ttl)))
        clock.advance(F.ttl)
        #expect(inbox.phase(of: ahead.id) == .expired)
    }

    /// A request first seen after its expiry was never answerable here.
    @Test func aRequestSeenLateIsAlreadyExpired() {
        let clock = TestClock()
        let inbox = RequestInbox(clock: { clock.now })
        let stale = F.request(1, createdAt: clock.now.addingTimeInterval(-F.ttl - 5))
        inbox.receive([stale])
        #expect(inbox.phase(of: stale.id) == .expired)
    }

    /// Expiry is terminal once seen: a clock moved back does not reopen it.
    @Test func expiryIsStickyWhenTheClockGoesBack() {
        let clock = TestClock()
        let inbox = RequestInbox(clock: { clock.now })
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
        let inbox = RequestInbox(clock: { clock.now })
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
        let inbox = RequestInbox(clock: { clock.now })
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
        let inbox = RequestInbox(clock: { clock.now })
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

    @Test func anUnknownRequestHasNoPhase() {
        let inbox = RequestInbox()
        inbox.withdraw(F.id(9))
        #expect(inbox.phase(of: F.id(9)) == nil)
        #expect(inbox.requests.isEmpty)
    }

    // MARK: The list

    /// Several requests are held separately, newest first.
    @Test func requestsAreListedNewestFirst() {
        let clock = TestClock()
        let inbox = RequestInbox(clock: { clock.now })
        let older = F.request(1, createdAt: clock.now.addingTimeInterval(-60))
        let newer = F.request(2, createdAt: clock.now)
        inbox.receive([older, newer])
        #expect(inbox.requests.map(\.id) == [newer.id, older.id])
    }

    /// Past the capacity, finished requests go first; pending ones stay.
    @Test func finishedRequestsMakeRoomFirst() {
        let clock = TestClock()
        let inbox = RequestInbox(clock: { clock.now })
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

    @Test(arguments: [(0.0, false), (-1, false), (1, true), (60, true), (PendingRequest.timeToLive, true),
                      (PendingRequest.timeToLive + 1, false)])
    func aWindowIsAPositiveSpanOfAtMostTheTTL(_ window: TimeInterval, _ fit: Bool) {
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
}
