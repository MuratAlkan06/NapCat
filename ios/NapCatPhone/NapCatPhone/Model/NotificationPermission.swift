/// Whether this iPhone may show and buzz for an alert, as the feed last read
/// it from the notification center (`NotificationGate.alertsAllowed`), and
/// the words the app uses for it. The main screen's permission row (shown
/// only while the pill reads "Notifications off") and Settings ›
/// Notifications both present it.
enum NotificationPermission: Equatable, Sendable {
    /// Not read yet: a live launch before its first refresh.
    case checking
    /// Alerts may show and buzz.
    case on
    /// Undecided, denied or quiet-only: alerts still land in the list, but
    /// the iPhone will not buzz.
    case off

    init(alertsAllowed: Bool) {
        self = alertsAllowed ? .on : .off
    }

    /// The off state, said in full (the main screen's permission row).
    static let offTitle = "Notifications are off"
    static let offDetail = "Alerts still show up here, but your iPhone won't buzz."
    /// The affordance while off, and otherwise.
    static let turnOnAction = "Turn On in Settings"
    static let openAction = "Open Notification Settings"

    /// The state as a line: the severity glyph and text, never color alone.
    var line: PhoneLine {
        switch self {
        case .checking: return PhoneLine(text: "Checking…", severity: .nominal)
        case .on: return PhoneLine(text: "On", severity: .nominal)
        case .off: return PhoneLine(text: "Off", severity: .warning)
        }
    }

    /// What the affordance to the system's notification settings says.
    var action: String {
        self == .off ? Self.turnOnAction : Self.openAction
    }

    /// What the state means for the owner, when it needs saying.
    var detail: String? {
        self == .off ? Self.offDetail : nil
    }
}
