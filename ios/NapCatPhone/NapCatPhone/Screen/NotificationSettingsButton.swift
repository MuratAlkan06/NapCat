import SwiftUI
import UIKit

/// The way to this app's page in Settings › Notifications, where the owner
/// turns alerts on (or changes them). The main screen's permission row and
/// Settings › Notifications both use it.
struct NotificationSettingsButton: View {
    /// The system's deep link to this app's page in Settings › Notifications.
    nonisolated static let settingsURL = URL(string: UIApplication.openNotificationSettingsURLString)

    let title: String

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = Self.settingsURL { openURL(url) }
        } label: {
            LinkOutLabel(title: title)
        }
    }
}

/// A text then a trailing link-out glyph: the label of every affordance
/// that leaves the app. Not a `Label`: inside a List row a Label's icon
/// takes the row's icon column.
struct LinkOutLabel: View {
    nonisolated static let symbol = "arrow.up.forward.app"

    let title: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.innerGap) {
            Text(title)
            Image(systemName: Self.symbol)
                .symbolVariant(theme.symbolVariant)
                .accessibilityHidden(true)
        }
    }
}
