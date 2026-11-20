/// How loud a line is — the Mac panel's severity vocabulary (`PanelSeverity`
/// in Sources/NapCat/MenuStateModel.swift), mirrored value for value: the same
/// four levels, the same SF Symbols, the same VoiceOver prefixes. Anything
/// above `.nominal` renders with an icon AND text, never color alone; nominal
/// is plain text.
///
/// Mirrored rather than imported because the Mac's copy lives in the app
/// target, not in `NapCatWire` (which carries the wire contract only);
/// `PhoneSeverityTests` pins every value to the Mac's strings.
enum PhoneSeverity: Int, Comparable, CaseIterable, Sendable {
    case nominal, info, warning, error

    static func < (lhs: PhoneSeverity, rhs: PhoneSeverity) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The severity glyph; nil for nominal (plain text, no icon).
    var symbol: String? {
        switch self {
        case .nominal: return nil
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    /// Spoken before the text — the glyph is decorative, so the meaning is said.
    var accessibilityPrefix: String? {
        switch self {
        case .nominal: return nil
        case .info: return "Note"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }
}

/// One rendered line plus its severity (the Mac's `PanelLine`).
struct PhoneLine: Equatable, Sendable {
    let text: String
    let severity: PhoneSeverity

    /// What VoiceOver reads: "Warning: Notifications off".
    var spoken: String {
        severity.accessibilityPrefix.map { "\($0): \(text)" } ?? text
    }
}
