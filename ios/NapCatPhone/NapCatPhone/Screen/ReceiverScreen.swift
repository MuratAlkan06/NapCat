import NapCatWire
import SwiftUI

/// The receiver's one screen: the connection pill, the notification-
/// permission row (only while notifications are off), the permission prompts
/// waiting here (F4, #194: only while one is pending; each row, its whole
/// card, opens its prompt), and the recent alerts.
/// When there are no alerts, the empty state is the hero, with the sentence
/// the list state allows; where it says it couldn't get alerts, VoiceOver
/// can "Check again" (`CheckAgainAction`). A full list ends on its cap,
/// said. A row that arrives while the list is on screen comes in on the
/// theme's entrance curve, and nothing else moves with it (`ListMotion`;
/// nothing moves at all under Reduce Motion). Everything visual comes from
/// the environment's `Theme`.
struct ReceiverScreen: View {
    nonisolated static let title = "NapCat"
    nonisolated static let recentHeader = "Recent"
    /// Over the prompts waiting here (#194).
    nonisolated static let waitingHeader = "Waiting"
    /// What a waiting row's button does, for VoiceOver.
    nonisolated static let openHint = "Opens the prompt."
    /// The waiting row's chevron: the card opens something.
    nonisolated static let openSymbol = "chevron.right"

    /// What VoiceOver reads for a waiting row: the tool and the project (when
    /// there is one), as the prompt's own card begins
    /// (`PendingRequestScreen.spoken`), then how long ago it came, without
    /// the input, which the prompt shows in full.
    nonisolated static func spoken(_ request: PendingRequest, at now: Date) -> String {
        let age: String = Self.age(of: request, at: now, style: .full)
        guard !request.projectLabel.isEmpty else { return "\(request.toolName) permission prompt, \(age)" }
        return "\(request.toolName) permission prompt, project \(request.projectLabel), \(age)"
    }

    /// How long ago the Mac raised the prompt, in the alert rows' words
    /// (`AlertRow.relative`): never in the future, so a Mac clock running
    /// ahead reads as now.
    nonisolated static func age(of request: PendingRequest, at now: Date, style: RelativeDateTimeFormatter.UnitsStyle) -> String {
        AlertRow.relative(min(request.createdAt, now), to: now, style: style)
    }

    let alerts: [PhoneAlert]
    let connection: ConnectionState
    let fetch: FetchStatus
    /// The prompts pending here, newest first (#194).
    var requests: [PendingRequest] = []
    /// Opens one of them.
    var open: (PendingRequest) -> Void = { _ in }

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The pull's action, read here: the scroll view clears it for its own
    /// content, so the hero and the note get it from the screen.
    @Environment(\.refresh) private var refresh
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
                if !requests.isEmpty {
                    Text(Self.waitingHeader)
                        .font(theme.sectionFont)
                        .textCase(.uppercase)
                        .foregroundStyle(theme.inkSecondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(requests) { request in
                        // Periodic from now, as the alert rows' (their ages
                        // read the same).
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Button { open(request) } label: { WaitingCard(request: request, now: context.date) }
                                .buttonStyle(.plain)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Self.spoken(request, at: context.date))
                                .accessibilityHint(Self.openHint)
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                }
                switch list {
                case .empty(let hero):
                    EmptyStateView(hero: hero)
                        .checkAgainAction(offered: list.offersCheckAgain, refresh: refresh)
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
                            .checkAgainAction(offered: list.offersCheckAgain, refresh: refresh)
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

/// One prompt waiting here (#194), as a whole card: the tool's glyph and
/// name, with how long ago it came on the name's line (as an alert row's
/// time), the project label, and a chevron, centred on the card, since the
/// card opens the prompt. It is its button's whole label, so all of it is
/// the tap target (at least the theme's touch target tall) and all of it
/// dims as it is pressed. Nothing of the input: the prompt shows it in
/// full, never cut short.
struct WaitingCard: View {
    let request: PendingRequest
    let now: Date

    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .subheadline) private var glyphColumn: CGFloat = 24

    var body: some View {
        HStack(alignment: .center, spacing: theme.innerGap * 2) {
            HStack(alignment: .firstTextBaseline, spacing: theme.innerGap * 2) {
                Image(systemName: PendingRequestScreen.toolSymbol(request.toolName))
                    .symbolVariant(theme.symbolVariant)
                    .fontWeight(theme.symbolWeight)
                    .font(theme.metaFont)
                    .foregroundStyle(theme.accent)
                    .frame(width: glyphColumn)
                VStack(alignment: .leading, spacing: theme.innerGap) {
                    HStack(alignment: .firstTextBaseline, spacing: theme.innerGap) {
                        Text(verbatim: request.toolName)
                            .font(theme.metaFont)
                            .foregroundStyle(theme.ink)
                        Spacer(minLength: theme.innerGap)
                        Text(ReceiverScreen.age(of: request, at: now, style: .short))
                            .font(theme.timestampFont)
                            .foregroundStyle(theme.inkSecondary)
                    }
                    if !request.projectLabel.isEmpty {
                        Text(verbatim: request.projectLabel)
                            .font(theme.detailFont)
                            .foregroundStyle(theme.inkSecondary)
                    }
                }
            }
            Image(systemName: ReceiverScreen.openSymbol)
                .font(theme.detailFont)
                .foregroundStyle(theme.inkSecondary)
        }
        .themedCard()
        .frame(minHeight: theme.minTouchTarget)
        .contentShape(Rectangle())
    }
}

#Preview("Populated, notifications off") {
    ReceiverScreen(alerts: FixtureSet.populated.alerts(now: .now), connection: .notificationsOff, fetch: .fetched)
}

#Preview("Empty") {
    ReceiverScreen(alerts: [], connection: .connected, fetch: .fetched)
}

/// A prompt waiting over the alerts (#194).
#Preview("A prompt waiting") {
    ReceiverScreen(alerts: FixtureSet.populated.alerts(now: .now), connection: .connected, fetch: .fetched,
                   requests: [FixtureRequests.request(createdAt: .now.addingTimeInterval(-120))])
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
