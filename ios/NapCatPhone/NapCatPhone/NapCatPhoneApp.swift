import SwiftUI

/// NapCat Phone — the iOS receiver for the Mac's alerts (F3). A device build
/// shows the alerts the Mac writes to the owner's iCloud; simulator builds,
/// previews and tests show fixtures (`AlertSourceKind`, `LiveCapability`).
@main
struct NapCatPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ReceiverRoot(feed: appDelegate.feed)
        }
    }
}

/// The screen over the live feed: the first refresh at launch, another on
/// every return to the foreground (the missed-alert reconciliation: whatever
/// arrived while the app was away is fetched on open). Everything below it
/// is drawn in the owner's palette.
struct ReceiverRoot: View {
    let feed: AlertFeed

    /// The chosen palette, kept in the app's own defaults across launches.
    /// A missing or unknown stored value reads as the default.
    @AppStorage(PaletteID.storageKey) private var palette = PaletteID.fallback
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ReceiverScreen(alerts: feed.alerts, connection: feed.connection)
            .environment(\.theme, ThemeID.fallback.theme(palette: palette))
            .task { await feed.start() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await feed.refresh() }
            }
    }
}
