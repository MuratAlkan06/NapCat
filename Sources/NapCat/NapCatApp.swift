import AppKit

/// App delegate. Owns the status item controller for the lifetime of the app.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-braces alongside LSUIElement=true in Info.plist:
        // never show a Dock icon or app menu.
        NSApp.setActivationPolicy(.accessory)
        statusItemController = StatusItemController()
    }
}

/// Entry point. Plain NSApplication + AppDelegate (no SwiftUI App lifecycle)
/// so we keep full control of the NSStatusItem.
@main
@MainActor
enum NapCatApp {
    // Strong reference; NSApplication.delegate is weak.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}
