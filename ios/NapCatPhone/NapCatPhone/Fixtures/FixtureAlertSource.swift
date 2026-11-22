import Foundation

/// The fixture conformance of `AlertSource`: a fixed list and a fixed
/// connection state, so previews, tests, simulator builds and screenshots
/// look exactly as the launch arguments ask. Touches neither iCloud nor the
/// notification center.
struct FixtureAlertSource: AlertSource {
    /// Computed once, so every fetch returns the same records (same names,
    /// so a refresh never duplicates a row).
    let alerts: [PhoneAlert]
    let connection: ConnectionState

    init(set: FixtureSet, connection: ConnectionState, now: Date) {
        self.alerts = set.alerts(now: now)
        self.connection = connection
    }

    func connect() async -> AccountAvailability {
        connection == .iCloudUnavailable ? .unavailable : .available
    }

    func fetchRecent() async throws -> [PhoneAlert] {
        alerts
    }
}

/// The fixture `NotificationGate`: no prompt, no registration, and a fixed
/// answer that reproduces the fixture's connection state.
struct FixedNotificationGate: NotificationGate {
    let allowed: Bool

    init(connection: ConnectionState) {
        self.allowed = connection != .notificationsOff
    }

    func prepare() async {}

    func alertsAllowed() async -> Bool { allowed }
}
