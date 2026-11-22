/// Whether alerts can reach this iPhone: the connection pill's states. A
/// live source probes them (`init(account:alertsAllowed:)`); fixtures pick
/// one of the `probed` states from the launch arguments.
enum ConnectionState: String, CaseIterable, Sendable {
    /// A live launch before its first account check has finished: nothing
    /// is known yet, so the pill claims nothing. Never a probe's answer, so
    /// never a fixture's either.
    case checking
    /// The account works, the iPhone may buzz, and the push subscription
    /// exists.
    case connected
    /// No usable iCloud account on this iPhone: no alert can arrive at all.
    case iCloudUnavailable
    /// Alerts still land in the list, but the iPhone will not buzz.
    case notificationsOff
    /// The account works, but the push subscription is not confirmed on the
    /// server (not created yet, refused, or unreachable): alerts still load
    /// whenever the app opens, but none is pushed, so the iPhone will not
    /// buzz. Retried on every refresh.
    case pushNotSetUp

    /// The probed state. No account beats everything (nothing can arrive);
    /// then whether the iPhone may show and buzz for an alert (the one the
    /// owner can fix, in Settings); then whether alerts are pushed at all.
    init(account: AccountAvailability, alertsAllowed: Bool) {
        switch (account, alertsAllowed) {
        case (.unavailable, _): self = .iCloudUnavailable
        case (_, false): self = .notificationsOff
        case (.availableWithoutPush, true): self = .pushNotSetUp
        case (.available, true): self = .connected
        }
    }

    /// The states a probe can answer: every state but `.checking`. Only
    /// these can be asked for with `-NapCatConnection`.
    static let probed: [ConnectionState] = allCases.filter { $0 != .checking }

    /// The pill's text and severity (icon + text, never color alone).
    var line: PhoneLine {
        switch self {
        case .checking: return PhoneLine(text: "Checking…", severity: .nominal)
        case .connected: return PhoneLine(text: "Connected", severity: .nominal)
        case .iCloudUnavailable: return PhoneLine(text: "iCloud unavailable", severity: .error)
        case .notificationsOff: return PhoneLine(text: "Notifications off", severity: .warning)
        case .pushNotSetUp: return PhoneLine(text: "Connected — no push", severity: .warning)
        }
    }

    /// The pill's glyph: the severity glyph, or an iCloud check when nominal
    /// (a plain cloud while checking: nothing is confirmed yet).
    var symbol: String {
        line.severity.symbol ?? (self == .checking ? "icloud" : "checkmark.icloud")
    }

    /// The notification-permission row (with its Settings affordance) shows
    /// only while notifications are off.
    var showsPermissionRow: Bool { self == .notificationsOff }
}
