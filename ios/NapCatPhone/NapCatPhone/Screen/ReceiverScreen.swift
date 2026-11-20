import NapCatWire
import SwiftUI

/// The receiver's one screen: the connection pill, the notification-
/// permission row (only while notifications are off), and the recent alerts.
/// When there are no alerts, the empty state is the hero. Everything visual
/// comes from the environment's `Theme`.
struct ReceiverScreen: View {
    nonisolated static let title = "NapCat"
    nonisolated static let recentHeader = "Recent"

    let alerts: [PhoneAlert]
    let connection: ConnectionState

    @Environment(\.theme) private var theme
    @State private var revealed = false

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
                if alerts.isEmpty {
                    EmptyStateView()
                        .frame(maxWidth: .infinity)
                        .containerRelativeFrame(.vertical) { length, _ in length * 0.7 }
                } else {
                    Text(Self.recentHeader)
                        .font(theme.sectionFont)
                        .textCase(.uppercase)
                        .foregroundStyle(theme.inkSecondary)
                        .accessibilityAddTraits(.isHeader)
                    LazyVStack(spacing: theme.rowGap) {
                        ForEach(Array(alerts.enumerated()), id: \.element.id) { index, alert in
                            AlertRow(alert: alert)
                                .themedCard()
                                .staggeredEntrance(index: index, revealed: revealed)
                        }
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
    ReceiverScreen(alerts: FixtureSet.populated.alerts(now: .now), connection: .notificationsOff)
}

#Preview("Empty") {
    ReceiverScreen(alerts: [], connection: .connected)
}
