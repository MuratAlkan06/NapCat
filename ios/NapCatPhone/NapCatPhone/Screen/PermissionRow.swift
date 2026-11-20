import SwiftUI

/// Shown only while notifications are off: what that means, plus the
/// affordance to fix it. In part 1 the button is deliberately inert. Part 2
/// wires it to the app's notification settings.
struct PermissionRow: View {
    nonisolated static let title = "Notifications are off"
    nonisolated static let detail = "Alerts still show up here, but your iPhone won't buzz."
    nonisolated static let action = "Turn On in Settings"
    nonisolated static let actionSymbol = "arrow.up.forward.app"

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.innerGap * 2) {
            Image(systemName: PhoneSeverity.warning.symbol ?? "")
                .fontWeight(theme.symbolWeight)
                .foregroundStyle(theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: theme.innerGap * 2) {
                VStack(alignment: .leading, spacing: theme.innerGap) {
                    Text(Self.title)
                        .font(theme.metaFont)
                        .foregroundStyle(theme.ink)
                    Text(Self.detail)
                        .font(theme.detailFont)
                        .foregroundStyle(theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(PhoneLine(text: "\(Self.title). \(Self.detail)", severity: .warning).spoken)

                Button {
                    // Part 2: open the app's notification settings.
                } label: {
                    // Text then a trailing link-out glyph (not a `Label`: inside
                    // a List row a Label's icon takes the row's icon column).
                    HStack(spacing: theme.innerGap) {
                        Text(Self.action)
                        Image(systemName: Self.actionSymbol)
                            .symbolVariant(theme.symbolVariant)
                            .accessibilityHidden(true)
                    }
                    .font(theme.metaFont)
                }
                .buttonStyle(.borderless)
                .tint(theme.accent)
            }
        }
    }
}
