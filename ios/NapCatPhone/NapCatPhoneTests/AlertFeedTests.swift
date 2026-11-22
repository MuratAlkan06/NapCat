import Foundation
import NapCatWire
@testable import NapCatPhone
import Testing

/// The feed: one row per record name, newest first, capped; a refresh that
/// cannot reach iCloud keeps the list; overlapping refreshes fold into one
/// follow-up pass. Every source here is a fixture.
@Suite @MainActor struct AlertFeedTests {
    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    static func alert(_ name: String, minutesAgo: Double, lane: AlertWire.Lane = .session) -> PhoneAlert {
        PhoneAlert(body: "A Claude session finished after 8 min — none still working", lane: lane,
                   firedAt: base.addingTimeInterval(-minutesAgo * 60), recordName: name)
    }

    // MARK: Merge

    @Test func aRecordFetchedTwiceIsOneRow() {
        let one = Self.alert("session-1", minutesAgo: 5)
        let merged = AlertFeed.merge([one], with: [one, one], limit: 50)
        #expect(merged == [one])
    }

    @Test func theMergedListIsNewestFirst() {
        let old = Self.alert("session-1", minutesAgo: 90)
        let mid = Self.alert("lid-2", minutesAgo: 30, lane: .lid)
        let new = Self.alert("session-3", minutesAgo: 1)
        #expect(AlertFeed.merge([mid], with: [old, new], limit: 50) == [new, mid, old])
    }

    /// The record name is the identity: two records at the same instant on
    /// different lanes are two rows, in a stable order.
    @Test func sameInstantDifferentRecordsAreBothKept() {
        let a = Self.alert("lid-100", minutesAgo: 3, lane: .lid)
        let b = Self.alert("session-100", minutesAgo: 3)
        let merged = AlertFeed.merge([], with: [a, b], limit: 50)
        #expect(merged.count == 2)
        #expect(merged == AlertFeed.merge([], with: [b, a], limit: 50))
    }

    @Test func theListKeepsOnlyTheNewestUpToTheLimit() {
        let many = (0..<60).map { Self.alert("session-\($0)", minutesAgo: Double($0)) }
        let merged = AlertFeed.merge([], with: many, limit: AlertFeed.listLimit)
        #expect(merged.count == AlertFeed.listLimit)
        #expect(merged == Array(many.prefix(AlertFeed.listLimit)))
        #expect(AlertFeed.merge(many, with: [], limit: 0).isEmpty)
    }

    // MARK: Refresh

    @Test func aRefreshAddsWhatTheSourceHas() async {
        let fresh = [Self.alert("session-1", minutesAgo: 1)]
        let source = ScriptedSource(account: .available, alerts: fresh)
        let feed = AlertFeed(source: source, notifications: FixedNotificationGate(connection: .connected), isLive: true)
        #expect(await feed.refresh())
        #expect(feed.alerts == fresh)
        #expect(feed.connection == .connected)
        // Nothing new the second time.
        #expect(await feed.refresh() == false)
        #expect(feed.alerts == fresh)
    }

    /// No account: the pill says so, nothing is fetched, the list stays.
    @Test func withoutAnAccountTheListStaysAndNothingIsFetched() async {
        let shown = [Self.alert("session-1", minutesAgo: 10)]
        let source = ScriptedSource(account: .unavailable, alerts: [Self.alert("session-2", minutesAgo: 1)])
        let feed = AlertFeed(source: source, notifications: FixedNotificationGate(connection: .connected),
                             isLive: true, alerts: shown)
        #expect(await feed.refresh() == false)
        #expect(feed.alerts == shown)
        #expect(feed.connection == .iCloudUnavailable)
        #expect(await source.fetches == 0)
    }

    @Test func aFailedFetchKeepsTheList() async {
        let shown = [Self.alert("session-1", minutesAgo: 10)]
        let source = ScriptedSource(account: .available, alerts: [], fails: true)
        let feed = AlertFeed(source: source, notifications: FixedNotificationGate(connection: .connected),
                             isLive: true, alerts: shown)
        #expect(await feed.refresh() == false)
        #expect(feed.alerts == shown)
        #expect(feed.connection == .connected)
    }

    @Test func notificationsOffShowsInThePillButAlertsStillArrive() async {
        let fresh = [Self.alert("session-1", minutesAgo: 1)]
        let source = ScriptedSource(account: .available, alerts: fresh)
        let feed = AlertFeed(source: source, notifications: FixedNotificationGate(connection: .notificationsOff),
                             isLive: true)
        await feed.refresh()
        #expect(feed.connection == .notificationsOff)
        #expect(feed.alerts == fresh)
    }

    /// Refreshes asked for while one is running (a burst of pushes) fold
    /// into ONE follow-up pass, never one fetch each.
    @Test func overlappingRefreshesFoldIntoOneFollowUp() async {
        let source = ScriptedSource(account: .available, alerts: [Self.alert("session-1", minutesAgo: 1)],
                                    holdFirstConnect: true)
        let feed = AlertFeed(source: source, notifications: FixedNotificationGate(connection: .connected), isLive: true)
        let first = Task { await feed.refresh() }
        while await !source.isHolding { await Task.yield() }
        #expect(await feed.refresh() == false)
        #expect(await feed.refresh() == false)
        #expect(await feed.refresh() == false)
        await source.release()
        #expect(await first.value)
        #expect(await source.connects == 2)
        #expect(await source.fetches == 2)
        #expect(feed.alerts.count == 1)
    }

    /// `start()` prompts once, however often the scene asks.
    @Test func startRunsOnce() async {
        let source = ScriptedSource(account: .available, alerts: [])
        let gate = CountingGate()
        let feed = AlertFeed(source: source, notifications: gate, isLive: true)
        await feed.start()
        await feed.start()
        #expect(gate.prepares == 1)
        #expect(await source.connects == 1)
    }
}

/// A scripted `AlertSource`: a fixed account answer and list, call counts,
/// and optionally a first `connect()` that waits until released.
actor ScriptedSource: AlertSource {
    struct Failure: Error {}

    let account: AccountAvailability
    let alerts: [PhoneAlert]
    let fails: Bool
    private var holdFirstConnect: Bool
    private var held: CheckedContinuation<Void, Never>?
    private(set) var connects = 0
    private(set) var fetches = 0

    init(account: AccountAvailability, alerts: [PhoneAlert], fails: Bool = false, holdFirstConnect: Bool = false) {
        self.account = account
        self.alerts = alerts
        self.fails = fails
        self.holdFirstConnect = holdFirstConnect
    }

    var isHolding: Bool { held != nil }

    func release() {
        held?.resume()
        held = nil
    }

    func connect() async -> AccountAvailability {
        connects += 1
        if holdFirstConnect {
            holdFirstConnect = false
            await withCheckedContinuation { held = $0 }
        }
        return account
    }

    func fetchRecent() async throws -> [PhoneAlert] {
        fetches += 1
        if fails { throw Failure() }
        return alerts
    }
}

/// A `NotificationGate` that counts prompts and always allows.
@MainActor final class CountingGate: NotificationGate {
    private(set) var prepares = 0

    func prepare() async { prepares += 1 }

    func alertsAllowed() async -> Bool { true }
}
