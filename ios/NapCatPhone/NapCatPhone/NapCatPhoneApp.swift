import SwiftUI

/// NapCat Phone — the iOS receiver for the Mac's alerts (F3, part 1:
/// fixture data only; nothing here talks to iCloud or the network).
@main
struct NapCatPhoneApp: App {
    private let options = LaunchOptions.fromLaunchArguments()
    private let launchedAt = Date()

    var body: some Scene {
        WindowGroup {
            ReceiverScreen(alerts: options.fixture.alerts(now: launchedAt), connection: options.connection)
        }
    }
}
