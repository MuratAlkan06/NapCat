import Foundation
import Observation

/// What the screen shows: the alert list and the connection pill, kept
/// current from one `AlertSource` and one `NotificationGate`. It refreshes on
/// launch, on every foreground and on every push; overlapping requests fold
/// into one follow-up pass, so a burst of pushes never queues a burst of
/// fetches.
@MainActor
@Observable
final class AlertFeed {
    /// The most rows the list keeps, and the most a fetch asks for.
    nonisolated static let listLimit = 50

    private(set) var alerts: [PhoneAlert]
    private(set) var connection: ConnectionState
    /// Whether this feed reads iCloud (and so wants pushes).
    let isLive: Bool

    private let source: any AlertSource
    private let notifications: any NotificationGate
    @ObservationIgnored private var started = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false

    init(
        source: any AlertSource,
        notifications: any NotificationGate,
        isLive: Bool,
        alerts: [PhoneAlert] = [],
        connection: ConnectionState = .connected
    ) {
        self.source = source
        self.notifications = notifications
        self.isLive = isLive
        self.alerts = alerts
        self.connection = connection
    }

    /// The launch's feed. Fixtures are shown from the first frame (exactly
    /// as before there was a live source); a live feed starts empty and
    /// fills on its first refresh. `liveCapable` is a parameter so tests can
    /// ask, but going live needs `CloudKitAlertSource.makeLive()` as well,
    /// which refuses in any build without `LiveCapability`.
    static func make(options: LaunchOptions, now: Date, liveCapable: Bool = LiveCapability.isAvailable) -> AlertFeed {
        if AlertSourceKind.select(options: options, liveCapable: liveCapable) == .cloudKit,
           let live = CloudKitAlertSource.makeLive() {
            return AlertFeed(source: live, notifications: SystemNotificationGate(), isLive: true)
        }
        let fixtures = FixtureAlertSource(set: options.fixture, connection: options.connection, now: now)
        return AlertFeed(
            source: fixtures,
            notifications: FixedNotificationGate(connection: options.connection),
            isLive: false,
            alerts: fixtures.alerts,
            connection: options.connection
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

    private func refreshOnce() async -> Bool {
        let account = await source.connect()
        let allowed = await notifications.alertsAllowed()
        let state = ConnectionState(account: account, alertsAllowed: allowed)
        if state != connection { connection = state }
        // Without an account nothing can be fetched; the list stays.
        guard account == .available, let fresh = try? await source.fetchRecent() else { return false }
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
