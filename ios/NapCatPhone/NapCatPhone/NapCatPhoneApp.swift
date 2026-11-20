import NapCatWire
import SwiftUI

/// NapCat Phone — the iOS receiver for the Mac's alerts (F3, part 1:
/// fixture data only; nothing here talks to iCloud or the network).
@main
struct NapCatPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            // Scaffold placeholder; the receiver screen replaces it.
            Text("NapCat — \(AlertWire.Lane.allCases.count) alert lanes")
        }
    }
}
