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

    var body: some View {
        Group {
            switch theme.chrome {
            case .insetGrouped: groupedList
            case .cards: cardScroll
            }
        }
        .tint(theme.accent)
        .onAppear { revealed = true }
        .onDisappear { revealed = false }
    }

    // MARK: Inset-grouped chrome

    private var groupedList: some View {
        NavigationStack {
            List {
                Section {
                    ConnectionPill(state: connection)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                if connection.showsPermissionRow {
                    Section { PermissionRow() }
                }
                if !alerts.isEmpty {
                    Section {
                        ForEach(Array(alerts.enumerated()), id: \.element.id) { index, alert in
                            AlertRow(alert: alert)
                                .staggeredEntrance(index: index, revealed: revealed)
                        }
                    } header: {
                        Text(Self.recentHeader)
                            .font(theme.sectionFont)
                    }
                }
            }
            .listStyle(.insetGrouped)
            // The HIG empty-list pattern (where ContentUnavailableView goes):
            // centered over the list rather than inside a row.
            .overlay {
                if alerts.isEmpty {
                    EmptyStateView()
                }
            }
            .navigationTitle(Self.title)
        }
    }

    // MARK: Cards chrome

    private var cardScroll: some View {
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
    }
}

#Preview("Night Groom") {
    ReceiverScreen(alerts: FixtureSet.populated.alerts(now: .now), connection: .connected)
        .environment(\.theme, .nightGroom)
}

#Preview("System Paper") {
    ReceiverScreen(alerts: FixtureSet.populated.alerts(now: .now), connection: .notificationsOff)
        .environment(\.theme, .systemPaper)
}

#Preview("Pixel Nap, empty") {
    ReceiverScreen(alerts: [], connection: .connected)
        .environment(\.theme, .pixelNap)
}
