/// Whether alerts can reach this iPhone: the connection pill's states. A
/// live source probes them (`init(account:alertsAllowed:)`); fixtures pick
/// one from the launch arguments.
enum ConnectionState: String, CaseIterable, Sendable {
    case connected
    /// No usable iCloud account on this iPhone: no alert can arrive at all.
    case iCloudUnavailable
    /// Alerts still land in the list, but the iPhone will not buzz.
    case notificationsOff

    /// The probed state. No account beats everything (nothing can arrive);
    /// otherwise it is whether the iPhone may show and buzz for an alert.
    init(account: AccountAvailability, alertsAllowed: Bool) {
        switch (account, alertsAllowed) {
        case (.unavailable, _): self = .iCloudUnavailable
        case (.available, false): self = .notificationsOff
        case (.available, true): self = .connected
        }
    }

    /// The pill's text and severity (icon + text, never color alone).
    var line: PhoneLine {
        switch self {
        case .connected: return PhoneLine(text: "Connected", severity: .nominal)
        case .iCloudUnavailable: return PhoneLine(text: "iCloud unavailable", severity: .error)
        case .notificationsOff: return PhoneLine(text: "Notifications off", severity: .warning)
        }
    }

    /// The pill's glyph: the severity glyph, or an iCloud check when nominal.
    var symbol: String {
        line.severity.symbol ?? "checkmark.icloud"
    }

    /// The notification-permission row (with its Settings affordance) shows
    /// only while notifications are off.
    var showsPermissionRow: Bool { self == .notificationsOff }
}
