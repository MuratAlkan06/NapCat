import AppKit

/// Builds the status item menu.
/// Phase 1: plain NSMenuItem placeholders; only Quit is functional.
/// NSHostingView-backed SwiftUI items are introduced only when a phase
/// actually needs them (slider etc.) — see PLAN.md decision log 2026-07-09.
@MainActor
final class MenuContentView {
    let menu: NSMenu

    init() {
        let menu = NSMenu()
        // Explicit enable/disable control for placeholder items.
        menu.autoenablesItems = false

        let batteryItem = NSMenuItem(title: "Battery: —%", action: nil, keyEquivalent: "")
        batteryItem.isEnabled = false // Live IOKit data arrives in Phase 3.
        menu.addItem(batteryItem)

        menu.addItem(.separator())

        let stayAwakeItem = NSMenuItem(title: "Stay Awake (Lid Closed)", action: nil, keyEquivalent: "")
        stayAwakeItem.isEnabled = false // Wired up in Phase 2.
        menu.addItem(stayAwakeItem)

        let chargeLimitItem = NSMenuItem(title: "Charge Limit: 90%", action: nil, keyEquivalent: "")
        chargeLimitItem.isEnabled = false // Wired up in Phase 3.
        menu.addItem(chargeLimitItem)

        menu.addItem(.separator())

        let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
        launchAtLoginItem.isEnabled = false // Wired up in Phase 5 (SMAppService).
        menu.addItem(launchAtLoginItem)

        let quitItem = NSMenuItem(
            title: "Quit NapCat",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        // nil target: dispatch through the responder chain to NSApplication.
        quitItem.target = nil
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        self.menu = menu
    }
}
