import Foundation
import NapCatWire

/// One received alert: exactly the wire record's three fields
/// (`AlertWire.Field`: body, lane, firedAt) plus its record name, and nothing
/// else.
struct PhoneAlert: Identifiable, Hashable, Sendable {
    /// The record name. A received alert keeps EXACTLY the name the Mac wrote
    /// (`<lane>-<epoch milliseconds>`, deterministic), so two copies of one
    /// record are one row. A fixture derives a name of the same shape.
    let id: String
    /// The Mac's app-generated message (its closed vocabulary: counts and
    /// minutes only, never text from a Claude session).
    let body: String
    let lane: AlertWire.Lane
    /// When the event happened on the Mac.
    let firedAt: Date

    init(body: String, lane: AlertWire.Lane, firedAt: Date, recordName: String? = nil) {
        self.id = recordName ?? Self.recordName(lane: lane, firedAt: firedAt)
        self.body = body
        self.lane = lane
        self.firedAt = firedAt
    }

    /// The fixtures' record name, `<lane>-<epoch milliseconds>`. Received
    /// alerts never use it: they carry the record's own name.
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
