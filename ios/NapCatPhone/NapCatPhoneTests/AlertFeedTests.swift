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
        #expect(feed.fetch == .failed)
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

    // MARK: The pill is honest

    /// A live feed claims nothing until its first account check answers.
    @Test func aLiveFeedReadsCheckingUntilTheFirstProbeAnswers() async {
        let source = ScriptedSource(account: .available, alerts: [], holdFirstConnect: true)
        let feed = AlertFeed(source: source, notifications: FixedNotificationGate(connection: .connected), isLive: true)
        #expect(feed.connection == .checking)
        let first = Task { await feed.refresh() }
        while await !source.isHolding { await Task.yield() }
        #expect(feed.connection == .checking)
        await source.release()
        _ = await first.value
        #expect(feed.connection == .connected)
    }

    /// No subscription: never "Connected", but alerts still load.
    @Test func withoutThePushSubscriptionThePillSaysSoAndAlertsStillLoad() async {
        let fresh = [Self.alert("session-1", minutesAgo: 1)]
        let source = ScriptedSource(account: .availableWithoutPush, alerts: fresh)
        let feed = AlertFeed(source: source, notifications: FixedNotificationGate(connection: .connected), isLive: true)
        #expect(await feed.refresh())
        #expect(feed.connection == .pushNotSetUp)
        #expect(feed.alerts == fresh)
    }

    // MARK: The list is honest (#118)

    /// The list state the screen derives from the feed, as `ReceiverRoot`
    /// builds it.
    static func shown(_ feed: AlertFeed) -> ListState {
        ReceiverScreen(alerts: feed.alerts, connection: feed.connection, fetch: feed.fetch).list
    }

    /// Before the first probe, and while it runs, the hero says it is
    /// checking; only an answered, empty query earns the good outcome.
    @Test func aLiveFeedSaysCheckingUntilItsFirstQueryAnswers() async {
        let source = ScriptedSource(account: .available, alerts: [], holdFirstConnect: true)
        let feed = AlertFeed(source: source, notifications: FixedNotificationGate(connection: .connected), isLive: true)
        #expect(feed.fetch == .pending)
        #expect(Self.shown(feed) == .empty(.checking))
        let first = Task { await feed.refresh() }
        while await !source.isHolding { await Task.yield() }
        #expect(Self.shown(feed) == .empty(.checking))
        await source.release()
        _ = await first.value
        #expect(feed.fetch == .fetched)
        #expect(Self.shown(feed) == .empty(.noAlerts))
    }

    /// A long first query: the pill has answered, the list has not, so the
    /// hero still says it is checking (never the good outcome).
    @Test func aSlowFirstQueryStillSaysChecking() async {
        let source = ScriptedSource(account: .available, alerts: [], holdFirstFetch: true)
        let feed = AlertFeed(source: source, notifications: FixedNotificationGate(connection: .connected), isLive: true)
        let first = Task { await feed.refresh() }
        while await !source.isHolding { await Task.yield() }
        #expect(feed.connection == .connected)
        #expect(Self.shown(feed) == .empty(.checking))
        await source.release()
        _ = await first.value
        #expect(Self.shown(feed) == .empty(.noAlerts))
    }

    /// A failed query with nothing listed (airplane mode on a first launch)
    /// says it couldn't check; the next good pass clears it.
    @Test func aFailedQueryWithNothingListedSaysItCouldNotCheck() async {
        let source = ScriptedSource(account: .availableWithoutPush, alerts: [], fails: true)
        let feed = AlertFeed(source: source, notifications: FixedNotificationGate(connection: .connected), isLive: true)
        await feed.refresh()
        #expect(feed.connection == .pushNotSetUp)
        #expect(feed.fetch == .failed)
        #expect(Self.shown(feed) == .empty(.couldNotCheck))
        await source.setFails(false)
        await feed.refresh()
        #expect(Self.shown(feed) == .empty(.noAlerts))
    }

    /// A failed query keeps the rows and marks them stale; the next pass
    /// whose query answers clears the mark.
    @Test func aFailedQueryKeepsEarlierRowsAndSaysSoUntilAGoodPass() async {
        let shown = [Self.alert("session-1", minutesAgo: 10)]
        let source = ScriptedSource(account: .available, alerts: shown, fails: true)
        let feed = AlertFeed(source: source, notifications: FixedNotificationGate(connection: .connected),
                             isLive: true, alerts: shown, connection: .connected, fetch: .fetched)
        #expect(Self.shown(feed) == .rows)
        await feed.refresh()
        #expect(feed.alerts == shown)
        #expect(Self.shown(feed) == .staleRows)
        await source.setFails(false)
        #expect(await feed.refresh() == false)
        #expect(feed.fetch == .fetched)
        #expect(Self.shown(feed) == .rows)
    }

    /// No account: the hero says iCloud, and listed rows are marked stale.
    @Test func withoutAnAccountTheListSaysICloudOrStale() async {
        let empty = AlertFeed(source: ScriptedSource(account: .unavailable, alerts: []),
                              notifications: FixedNotificationGate(connection: .connected), isLive: true)
        await empty.refresh()
        #expect(empty.fetch == .failed)
        #expect(Self.shown(empty) == .empty(.iCloudUnavailable))
        let listed = AlertFeed(source: ScriptedSource(account: .unavailable, alerts: []),
                               notifications: FixedNotificationGate(connection: .connected), isLive: true,
                               alerts: [Self.alert("session-1", minutesAgo: 10)], connection: .connected, fetch: .fetched)
        await listed.refresh()
        #expect(Self.shown(listed) == .staleRows)
    }

    // MARK: Pull to refresh

    /// An idle pull runs one pass of its own: the probe and the query.
    @Test func aPullWhileIdleRunsOnePass() async {
        let fresh = [Self.alert("session-1", minutesAgo: 1)]
        let source = ScriptedSource(account: .available, alerts: fresh)
        let feed = AlertFeed(source: source, notifications: FixedNotificationGate(connection: .connected), isLive: true)
        await feed.pullToRefresh()
        #expect(await source.connects == 1)
        #expect(await source.fetches == 1)
        #expect(feed.alerts == fresh)
    }

    /// A pull during a running pass does not return at once (the spinner
    /// would end before anything was checked): it returns after the
    /// follow-up pass, which re-probes, and its answer is on screen.
    @Test func aPullDuringARunningPassWaitsForTheFollowUp() async {
        let source = ScriptedSource(account: .availableWithoutPush, alerts: [], holdFirstConnect: true)
        let feed = AlertFeed(source: source, notifications: FixedNotificationGate(connection: .connected), isLive: true)
        let first = Task { await feed.refresh() }
        while await !source.isHolding { await Task.yield() }
        let pull = Task {
            await feed.pullToRefresh()
            return (await source.connects, feed.connection)
        }
        for _ in 0..<10_000 {
            if feed.waitingPulls > 0 { break }
            await Task.yield()
        }
        #expect(feed.waitingPulls == 1)
        await source.setAccount(.available)
        await source.release()
        _ = await first.value
        let (connectsWhenDone, connectionWhenDone) = await pull.value
        #expect(connectsWhenDone == 2)
        #expect(connectionWhenDone == .connected)
        #expect(feed.waitingPulls == 0)
    }

    // MARK: Pushes

    /// The record a push names is fetched directly, so it is listed even
    /// while the query (its index lagging) does not return it yet.
    @Test func aPushedRecordIsListedEvenWhenTheQueryLags() async {
        let listed = Self.alert("session-1", minutesAgo: 10)
        let pushed = Self.alert("session-2", minutesAgo: 0)
        let source = ScriptedSource(account: .available, alerts: [listed], stored: [listed, pushed])
        let feed = AlertFeed(source: source, notifications: FixedNotificationGate(connection: .connected), isLive: true)
        let name = feed.pushedRecordName(in: ScriptedSource.push(naming: pushed.id))
        #expect(name == pushed.id)
        #expect(await feed.receivePush(recordName: name))
        #expect(feed.alerts == [pushed, listed])
        #expect(await source.directFetches == [pushed.id])
        // The query still runs: it catches anything a coalesced push missed.
        #expect(await source.fetches == 1)
    }

    /// A push without a usable record name falls back to the query alone.
    @Test func aPushWithoutARecordNameFallsBackToTheQuery() async {
        let fresh = [Self.alert("session-1", minutesAgo: 1)]
        let source = ScriptedSource(account: .available, alerts: fresh)
        let feed = AlertFeed(source: source, notifications: FixedNotificationGate(connection: .connected), isLive: true)
        let name = feed.pushedRecordName(in: ["aps": ["alert": "x"]])
        #expect(name == nil)
        #expect(await feed.receivePush(recordName: name))
        #expect(feed.alerts == fresh)
        #expect(await source.directFetches.isEmpty)
        #expect(await source.fetches == 1)
    }

    /// A record already listed never changes, so it is not fetched again.
    @Test func aPushedRecordAlreadyListedIsNotFetchedAgain() async {
        let listed = Self.alert("session-1", minutesAgo: 1)
        let source = ScriptedSource(account: .available, alerts: [listed], stored: [listed])
        let feed = AlertFeed(source: source, notifications: FixedNotificationGate(connection: .connected), isLive: true,
                             alerts: [listed])
        #expect(await feed.receivePush(recordName: listed.id) == false)
        #expect(await source.directFetches.isEmpty)
    }

    /// A failed direct fetch is not fatal: the query's answer still lands.
    @Test func aFailedDirectFetchStillLeavesTheQuery() async {
        let queried = [Self.alert("session-2", minutesAgo: 0)]
        let source = ScriptedSource(account: .available, alerts: queried, directFails: true)
        let feed = AlertFeed(source: source, notifications: FixedNotificationGate(connection: .connected), isLive: true)
        #expect(await feed.receivePush(recordName: "session-2"))
        #expect(await source.directFetches == ["session-2"])
        #expect(feed.alerts == queried)
    }

    /// A push that lands during a running refresh is fetched in the one
    /// follow-up pass, by name.
    @Test func aPushDuringARefreshIsFetchedInTheFollowUpPass() async {
        let pushed = Self.alert("session-2", minutesAgo: 0)
        let source = ScriptedSource(account: .available, alerts: [], stored: [pushed], holdFirstConnect: true)
        let feed = AlertFeed(source: source, notifications: FixedNotificationGate(connection: .connected), isLive: true)
        let first = Task { await feed.refresh() }
        while await !source.isHolding { await Task.yield() }
        #expect(await feed.receivePush(recordName: pushed.id) == false)
        await source.release()
        #expect(await first.value)
        #expect(feed.alerts == [pushed])
        #expect(await source.directFetches == [pushed.id])
        #expect(await source.connects == 2)
    }

    /// Without an account nothing is fetched, and the pushed name waits for
    /// the next pass that can fetch.
    @Test func aPushWithoutAnAccountWaitsForOneThatCanFetch() async {
        let pushed = Self.alert("session-2", minutesAgo: 0)
        let source = ScriptedSource(account: .unavailable, alerts: [], stored: [pushed])
        let feed = AlertFeed(source: source, notifications: FixedNotificationGate(connection: .connected), isLive: true)
        #expect(await feed.receivePush(recordName: pushed.id) == false)
        #expect(await source.directFetches.isEmpty)
        #expect(await source.fetches == 0)
        #expect(feed.alerts.isEmpty)
        await source.setAccount(.available)
        #expect(await feed.refresh())
        #expect(feed.alerts == [pushed])
        #expect(await source.directFetches == [pushed.id])
    }
}

/// A scripted `AlertSource`: a fixed account answer and list, call counts,
/// and optionally a first `connect()` (or a first query) that waits until
/// released. `stored` is what a direct fetch by name finds (the query's
/// `alerts` may lag it); a push payload names a record under `pushKey`.
actor ScriptedSource: AlertSource {
    struct Failure: Error {}
    static let pushKey = "scripted-record"

    private(set) var account: AccountAvailability
    let alerts: [PhoneAlert]
    let stored: [PhoneAlert]
    private(set) var fails: Bool
    let directFails: Bool
    private var holdFirstConnect: Bool
    private var holdFirstFetch: Bool
    private var held: CheckedContinuation<Void, Never>?
    private(set) var connects = 0
    private(set) var fetches = 0
    private(set) var directFetches: [String] = []

    init(
        account: AccountAvailability,
        alerts: [PhoneAlert],
        stored: [PhoneAlert] = [],
        fails: Bool = false,
        directFails: Bool = false,
        holdFirstConnect: Bool = false,
        holdFirstFetch: Bool = false
    ) {
        self.account = account
        self.alerts = alerts
        self.stored = stored
        self.fails = fails
        self.directFails = directFails
        self.holdFirstConnect = holdFirstConnect
        self.holdFirstFetch = holdFirstFetch
    }

    func setFails(_ fails: Bool) { self.fails = fails }

    static func push(naming recordName: String) -> [AnyHashable: Any] {
        [pushKey: recordName]
    }

    nonisolated func pushedRecordName(in userInfo: [AnyHashable: Any]) -> String? {
        userInfo[Self.pushKey] as? String
    }

    func fetchAlert(named recordName: String) async throws -> PhoneAlert? {
        directFetches.append(recordName)
        if directFails { throw Failure() }
        return stored.first { $0.id == recordName }
    }

    var isHolding: Bool { held != nil }

    func setAccount(_ account: AccountAvailability) { self.account = account }

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
        if holdFirstFetch {
            holdFirstFetch = false
            await withCheckedContinuation { held = $0 }
        }
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
