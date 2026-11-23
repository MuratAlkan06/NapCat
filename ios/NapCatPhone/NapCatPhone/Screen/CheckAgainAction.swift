import SwiftUI

/// The pull's single-step twin (WCAG 2.5.1): where the screen says it
/// couldn't get alerts, VoiceOver and Switch Control offer a "Check again"
/// action that runs exactly what pulling the list down runs: the screen's
/// refresh action, which `ReceiverRoot` sets to `feed.pullToRefresh()`.
/// The screen reads that action itself and hands it here, because the
/// scroll view clears it for its own content (so no nested scroll view
/// refreshes too). With no refresh action (a preview) there is no action
/// to offer.
struct CheckAgainAction: ViewModifier {
    nonisolated static let name = "Check again"

    let offered: Bool
    let refresh: RefreshAction?

    func body(content: Content) -> some View {
        content.accessibilityActions {
            if offered, let refresh {
                Button(Self.name) { Task { await refresh() } }
            }
        }
    }
}

extension View {
    func checkAgainAction(offered: Bool, refresh: RefreshAction?) -> some View {
        modifier(CheckAgainAction(offered: offered, refresh: refresh))
    }
}
