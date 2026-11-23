import NapCatWire
import SwiftUI

/// The receiver's one screen: the connection pill, the notification-
/// permission row (only while notifications are off), and the recent alerts.
/// When there are no alerts, the empty state is the hero, with the sentence
/// the list state allows. A full list ends on its cap, said. A row that
/// arrives while the list is on screen comes in on the theme's entrance
/// curve, and nothing else moves with it (`ListMotion`; nothing moves at
/// all under Reduce Motion). Everything visual comes from the
/// environment's `Theme`.
struct ReceiverScreen: View {
    nonisolated static let title = "NapCat"
    nonisolated static let recentHeader = "Recent"

    let alerts: [PhoneAlert]
    let connection: ConnectionState
    let fetch: FetchStatus

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    /// What the screen says about its list (`ListState`).
    var list: ListState {
        ListState(connection: connection, fetch: fetch, hasAlerts: !alerts.isEmpty)
    }

    /// The full list's last line: the cap, said in the caption register.
    /// Only once the list holds `AlertFeed.listLimit` rows, the most it
    /// keeps. It states the rule, not that older alerts exist: the query
    /// asks for at most that many, so a list of exactly that many may have
    /// none older. VoiceOver reads it like any other line.
    nonisolated static func capLine(rowCount: Int) -> PhoneLine? {
        guard rowCount >= AlertFeed.listLimit else { return nil }
        return PhoneLine(text: "Capped — the list keeps the latest \(AlertFeed.listLimit) alerts", severity: .nominal)
    }

    /// Themed cards on the theme's own ground, in a plain vertical scroll
    /// (system scroll physics), with an in-content title.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.rowGap) {
                HStack(alignment: .center, spacing: theme.innerGap) {
                    Text(Self.title)
                        .font(theme.titleFont)
                        .foregroundStyle(theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: theme.innerGap)
                    ConnectionPill(state: connection)
                }
                if connection.showsPermissionRow {
                    PermissionRow().themedCard()
                }
                switch list {
                case .empty(let hero):
                    EmptyStateView(hero: hero)
                        .frame(maxWidth: .infinity)
                        .containerRelativeFrame(.vertical) { length, _ in length * 0.7 }
                case .rows, .staleRows:
                    Text(Self.recentHeader)
                        .font(theme.sectionFont)
                        .textCase(.uppercase)
                        .foregroundStyle(theme.inkSecondary)
                        .accessibilityAddTraits(.isHeader)
                    if let note = list.note {
                        CaptionLine(line: note)
                    }
                    LazyVStack(spacing: theme.rowGap) {
                        ForEach(Array(alerts.enumerated()), id: \.element.id) { index, alert in
                            // One flattened card, so a fade never shows the
                            // shadow through the fill.
                            AlertRow(alert: alert)
                                .themedCard()
                                .compositingGroup()
                                .staggeredEntrance(index: index, revealed: revealed)
                                .zIndex(ListMotion.stacking(index: index))
                                .transition(ListMotion.transition(theme, reduceMotion: reduceMotion))
                        }
                    }
                    if let cap = Self.capLine(rowCount: alerts.count) {
                        CaptionLine(line: cap)
                    }
                }
            }
            .padding(.horizontal, theme.margin)
            .padding(.bottom, theme.rowGap * 2)
        }
        .background(theme.ground.ignoresSafeArea())
        .tint(theme.accent)
        .onAppear { revealed = true }
        .onDisappear { revealed = false }
    }
}

#Preview("Populated, notifications off") {
    ReceiverScreen(alerts: FixtureSet.populated.alerts(now: .now), connection: .notificationsOff, fetch: .fetched)
}

#Preview("Empty") {
    ReceiverScreen(alerts: [], connection: .connected, fetch: .fetched)
}

/// A live launch's first frame (no fixture launch can show it).
#Preview("Checking") {
    ReceiverScreen(alerts: [], connection: .checking, fetch: .pending)
}

/// The query failed with earlier rows on screen: the list stays, and says why.
#Preview("Couldn't check, earlier alerts") {
    ReceiverScreen(alerts: FixtureSet.populated.alerts(now: .now), connection: .pushNotSetUp, fetch: .failed)
}

/// No iCloud with earlier rows on screen: the note gives that cause.
#Preview("No iCloud, earlier alerts") {
    ReceiverScreen(alerts: FixtureSet.populated.alerts(now: .now), connection: .iCloudUnavailable, fetch: .failed)
}

/// The query failed before anything was listed (no launch value shows it).
#Preview("Couldn't check, nothing listed") {
    ReceiverScreen(alerts: [], connection: .pushNotSetUp, fetch: .failed)
}

/// A full list: it ends on the cap line (scroll to the bottom).
#Preview("Full list") {
    let alerts = (0..<AlertFeed.listLimit).map { step in
        PhoneAlert(body: "A Claude session finished after 8 min — none still working", lane: .session,
                   firedAt: Date.now.addingTimeInterval(Double(-step) * 600))
    }
    ReceiverScreen(alerts: alerts, connection: .connected, fetch: .fetched)
}
