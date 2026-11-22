import Foundation
import Observation

/// What the screen shows: the alert list, how its last fetch went, the
/// connection pill and the notification permission, kept current from one
/// `AlertSource` and one `NotificationGate`. It refreshes on
/// launch, on every foreground and on every push; overlapping requests fold
/// into one follow-up pass, so a burst of pushes never queues a burst of
/// fetches. A push that names its record also has that record fetched
/// directly, so the newest alert never waits on the query's index.
@MainActor
@Observable
final class AlertFeed {
    /// The most rows the list keeps, and the most a fetch asks for.
    nonisolated static let listLimit = 50

    private(set) var alerts: [PhoneAlert]
    private(set) var connection: ConnectionState
    /// How the last pass's query went. With `connection`, it decides what
    /// the screen may say about the list (`ListState`): never "no alerts"
    /// before a query has answered.
    private(set) var fetch: FetchStatus
    /// Whether the iPhone may buzz, as last read. Unlike `connection`, it is
    /// read even without an account (the pill then says iCloud first).
    private(set) var notificationPermission: NotificationPermission
    /// Whether this feed reads iCloud (and so wants pushes).
    let isLive: Bool

    nonisolated private let source: any AlertSource
    private let notifications: any NotificationGate
    @ObservationIgnored private var started = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    /// Record names pushes have named since the last fetch, fetched directly
    /// on the next pass.
    @ObservationIgnored private var pushedNames: Set<String> = []

    /// A live feed starts `.checking` and `.pending`: the pill, the list and
    /// the permission claim nothing until the first probe is done.
    init(
        source: any AlertSource,
        notifications: any NotificationGate,
        isLive: Bool,
        alerts: [PhoneAlert] = [],
        connection: ConnectionState = .checking,
        fetch: FetchStatus = .pending,
        notificationPermission: NotificationPermission = .checking
    ) {
        self.source = source
        self.notifications = notifications
        self.isLive = isLive
        self.alerts = alerts
        self.connection = connection
        self.fetch = fetch
        self.notificationPermission = notificationPermission
    }

    /// The launch's feed. Fixtures are shown from the first frame (exactly
    /// as before there was a live source), with the fetch status a refresh
    /// of them reads; a live feed starts empty and fills on its first
    /// refresh. `liveCapable` is a parameter so tests can
    /// ask, but going live needs `CloudKitAlertSource.makeLive()` as well,
    /// which refuses in any build without `LiveCapability`.
    static func make(options: LaunchOptions, now: Date, liveCapable: Bool = LiveCapability.isAvailable) -> AlertFeed {
        if AlertSourceKind.select(options: options, liveCapable: liveCapable) == .cloudKit,
           let live = CloudKitAlertSource.makeLive() {
            return AlertFeed(source: live, notifications: SystemNotificationGate(), isLive: true)
        }
        let fixtures = FixtureAlertSource(set: options.fixture, connection: options.connection, now: now)
        let gate = FixedNotificationGate(connection: options.connection)
        return AlertFeed(
            source: fixtures,
            notifications: gate,
            isLive: false,
            alerts: fixtures.alerts,
            connection: options.connection,
            fetch: fixtures.availability.canFetch ? .fetched : .failed,
            notificationPermission: NotificationPermission(alertsAllowed: gate.allowed)
        )
    }

    /// Once per launch: the permission prompt and push registration, then
    /// the first refresh.
    func start() async {
        guard !started else { return }
        started = true
        await notifications.prepare()
        await refresh()
    }

    /// Re-probes and re-fetches. A call made while one is running returns
    /// at once (false) and makes the running one go round once more.
    /// Returns whether the list changed.
    @discardableResult
    func refresh() async -> Bool {
        if refreshing {
            refreshAgain = true
            return false
        }
        refreshing = true
        defer { refreshing = false }
        var changed = false
        repeat {
            refreshAgain = false
            if await refreshOnce() { changed = true }
        } while refreshAgain
        return changed
    }

    /// The record name a push carries, read by the source (only it knows
    /// its payload). Nonisolated so a notification delegate can read it
    /// where the payload is, then hand over just the name.
    nonisolated func pushedRecordName(in userInfo: [AnyHashable: Any]) -> String? {
        source.pushedRecordName(in: userInfo)
    }

    /// A push: the record it names, if any, is fetched directly on top of
    /// the usual refresh (in the same pass, or the follow-up one when a
    /// refresh is already running). Without a name the query alone catches
    /// up. Returns whether the list changed.
    @discardableResult
    func receivePush(recordName: String?) async -> Bool {
        if let recordName { pushedNames.insert(recordName) }
        return await refresh()
    }

    private func refreshOnce() async -> Bool {
        let account = await source.connect()
        let allowed = await notifications.alertsAllowed()
        let permission = NotificationPermission(alertsAllowed: allowed)
        if permission != notificationPermission { notificationPermission = permission }
        let state = ConnectionState(account: account, alertsAllowed: allowed)
        if state != connection { connection = state }
        // Without an account nothing can be fetched; the list stays (and
        // reads as not checked), and pushed names wait for a pass that can
        // fetch.
        guard account.canFetch else {
            if fetch != .failed { fetch = .failed }
            return false
        }
        var fresh: [PhoneAlert] = []
        // A record once listed never changes, so only new names are fetched.
        // A failed direct fetch is dropped: the query below is the fallback.
        let pushed = pushedNames.subtracting(alerts.map(\.id)).sorted()
        pushedNames.removeAll()
        for name in pushed {
            if let alert = try? await source.fetchAlert(named: name) { fresh.append(alert) }
        }
        // A failed query keeps the list but is not silent: the status says
        // so until the next pass whose query answers.
        let recent = try? await source.fetchRecent()
        if let recent { fresh += recent }
        let status: FetchStatus = recent == nil ? .failed : .fetched
        if status != fetch { fetch = status }
        let merged = Self.merge(alerts, with: fresh, limit: Self.listLimit)
        guard merged != alerts else { return false }
        alerts = merged
        return true
    }

    /// The list after a fetch: one row per record name (a record never
    /// changes once written, so a repeat is the same alert; the fetched copy
    /// wins), newest first, at most `limit` rows.
    static func merge(_ current: [PhoneAlert], with incoming: [PhoneAlert], limit: Int) -> [PhoneAlert] {
        var byName: [String: PhoneAlert] = [:]
        for alert in current { byName[alert.id] = alert }
        for alert in incoming { byName[alert.id] = alert }
        let ordered = byName.values.sorted { ($0.firedAt, $0.id) > ($1.firedAt, $1.id) }
        return Array(ordered.prefix(max(limit, 0)))
    }
}
