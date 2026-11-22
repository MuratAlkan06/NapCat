import SwiftUI

/// Shown only while notifications are off: what that means, plus the
/// affordance to fix it, which opens this app's notification settings. The
/// words and the affordance are shared with Settings › Notifications
/// (`NotificationPermission`, `NotificationSettingsButton`).
struct PermissionRow: View {
    nonisolated static let title = NotificationPermission.offTitle
    nonisolated static let detail = NotificationPermission.offDetail
    nonisolated static let action = NotificationPermission.turnOnAction
    nonisolated static let actionSymbol = LinkOutLabel.symbol
    nonisolated static let settingsURL = NotificationSettingsButton.settingsURL

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

                NotificationSettingsButton(title: Self.action)
                    .font(theme.metaFont)
                    .buttonStyle(.borderless)
                    .tint(theme.accent)
            }
        }
    }
}
