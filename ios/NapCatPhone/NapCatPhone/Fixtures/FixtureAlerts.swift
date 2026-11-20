import Foundation
import NapCatWire

/// Which fixture list the screen shows (part 1 has no live data).
enum FixtureSet: String, CaseIterable, Sendable {
    case populated
    case empty

    func alerts(now: Date, calendar: Calendar = .current) -> [PhoneAlert] {
        switch self {
        case .populated: return FixtureAlerts.recent(now: now, calendar: calendar)
        case .empty: return []
        }
    }
}

/// Synthetic alerts, newest first. Every body is written exactly as the Mac
/// generates it (`LidGuardPolicy.messageBody`: counts, minutes and a clock
/// time only). No topic, server, host or user name appears anywhere. There
/// are more than eight rows, so the stagger's eight-row cap is visible.
enum FixtureAlerts {
    static func recent(now: Date, calendar: Calendar = .current) -> [PhoneAlert] {
        func minutesAgo(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func session(_ body: String, _ firedAt: Date) -> PhoneAlert {
            PhoneAlert(body: body, lane: .session, firedAt: firedAt)
        }
        func lid(tasks: Int, _ firedAt: Date) -> PhoneAlert {
            let tasksPhrase = tasks == 1 ? "1 Claude Code task was" : "\(tasks) Claude Code tasks were"
            return PhoneAlert(
                body: "This Mac started going to sleep at \(clockTime(firedAt, calendar: calendar)) while "
                    + tasksPhrase + " still running, and Stay Awake is off.",
                lane: .lid,
                firedAt: firedAt
            )
        }
        return [
            session("A Claude session finished after 23 min — none still working", minutesAgo(2)),
            session("Claude is waiting for you — 12 min in — 1 other still working", minutesAgo(14)),
            lid(tasks: 1, minutesAgo(41)),
            session("3 Claude sessions finished — 1 still working", minutesAgo(83)),
            session("Connection was down 14 min. 2 session alerts delivered late. 1 lid alert missed.",
                    minutesAgo(190)),
            session("A Claude session finished after 61 min — 2 still working", minutesAgo(300)),
            lid(tasks: 2, minutesAgo(1_210)),
            session("Claude is waiting for you — 4 min in", minutesAgo(1_330)),
            session("A Claude session finished after 8 min — none still working", minutesAgo(1_560)),
            session("A Claude session finished after 117 min — none still working", minutesAgo(1_800)),
        ]
    }

    /// `HH:mm`, as the Mac's `LidGuardPolicy.clockTime` writes it.
    static func clockTime(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
