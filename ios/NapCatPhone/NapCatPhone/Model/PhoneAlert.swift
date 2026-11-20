import Foundation
import NapCatWire

/// One received alert: exactly the wire record's three fields
/// (`AlertWire.Field`: body, lane, firedAt) and nothing else. `id` is the
/// record name the Mac writes, `<lane>-<epoch milliseconds>`.
struct PhoneAlert: Identifiable, Hashable, Sendable {
    /// The Mac's app-generated message (its closed vocabulary: counts and
    /// minutes only, never text from a Claude session).
    let body: String
    let lane: AlertWire.Lane
    /// When the event happened on the Mac.
    let firedAt: Date

    var id: String { Self.recordName(lane: lane, firedAt: firedAt) }

    static func recordName(lane: AlertWire.Lane, firedAt: Date) -> String {
        "\(lane.rawValue)-\(Int64((firedAt.timeIntervalSince1970 * 1000).rounded()))"
    }
}

/// How a lane presents on a row. The wire has no severity field, so the lane
/// decides: a lid alert means the Mac went to sleep with work in flight
/// (warning); session alerts are routine (nominal). The glyphs are the Mac
/// panel's own (`PanelSymbol.lidAlert`, `PanelSymbol.sessionAlerts`).
extension AlertWire.Lane {
    var title: String {
        switch self {
        case .lid: return "Lid alert"
        case .session: return "Session alert"
        }
    }

    var symbol: String {
        switch self {
        case .lid: return "bell"
        case .session: return "flag.checkered"
        }
    }

    var severity: PhoneSeverity {
        switch self {
        case .lid: return .warning
        case .session: return .nominal
        }
    }
}
