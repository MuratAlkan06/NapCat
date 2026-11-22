import SwiftUI

/// NapCat Phone — the iOS receiver for the Mac's alerts (F3). A device build
/// shows the alerts the Mac writes to the owner's iCloud; simulator builds,
/// previews and tests show fixtures (`AlertSourceKind`, `LiveCapability`).
@main
struct NapCatPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    private let opensSettings = LaunchOptions.fromLaunchArguments().screen == .settings

    var body: some Scene {
        WindowGroup {
            ReceiverRoot(feed: appDelegate.feed, opensSettings: opensSettings)
        }
    }
}

/// The screen over the live feed: the first refresh at launch, another on
/// every return to the foreground (the missed-alert reconciliation: whatever
/// arrived while the app was away is fetched on open), and one whenever the
/// owner pulls the list down. Everything below it, Settings included, is
/// drawn in the owner's palette.
///
/// Settings opens from the gear in the main screen's toolbar as a sheet: a
/// self-contained task beside the alert list (which has no hierarchy for a
/// push to extend), closed with Done or a swipe, the list kept as it was
/// underneath.
struct ReceiverRoot: View {
    let feed: AlertFeed

    /// The chosen palette, kept in the app's own defaults across launches.
    /// A missing or unknown stored value reads as the default.
    @AppStorage(PaletteID.storageKey) private var palette = PaletteID.fallback
    @State private var showsSettings: Bool
    @Environment(\.scenePhase) private var scenePhase

    init(feed: AlertFeed, opensSettings: Bool = false) {
        self.feed = feed
        _showsSettings = State(initialValue: opensSettings)
    }

    var body: some View {
        NavigationStack {
            ReceiverScreen(alerts: feed.alerts, connection: feed.connection, fetch: feed.fetch)
                .refreshable { await feed.pullToRefresh() }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        SettingsGearButton { showsSettings = true }
                    }
                }
        }
        .sheet(isPresented: $showsSettings) {
            SettingsScreen(palette: $palette, notifications: feed.notificationPermission)
        }
        .environment(\.theme, ThemeID.fallback.theme(palette: palette))
        .task { await feed.start() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await feed.refresh() }
        }
    }
}

#Preview("Main screen") {
    ReceiverRoot(feed: AlertFeed.make(options: LaunchOptions(), now: .now, liveCapable: false))
}
