import AppKit
import Testing
@testable import NapCat

/// Phase 1 scaffold tests (Swift Testing — XCTest is unavailable with
/// Command Line Tools only; see PLAN.md decision log 2026-07-09).
/// Real behavior tests (HysteresisEngine, animation mapping) arrive with
/// Phases 3 and 4.
@MainActor
struct ScaffoldTests {
    @Test func placeholderIconIsTemplateAt18Points() {
        let icon = StatusItemController.placeholderIcon()
        #expect(icon.isTemplate, "menu bar icon must be a template image")
        #expect(icon.size == NSSize(width: 18, height: 18))
    }

    @Test func menuLayoutAndEnabledStates() {
        let menu = MenuContentView().menu
        #expect(menu.items.count == 7)

        #expect(menu.items[0].title == "Battery: —%")
        #expect(!menu.items[0].isEnabled)

        #expect(menu.items[1].isSeparatorItem)

        #expect(menu.items[2].title == "Stay Awake (Lid Closed)")
        #expect(!menu.items[2].isEnabled)

        #expect(menu.items[3].title == "Charge Limit: 90%")
        #expect(!menu.items[3].isEnabled)

        #expect(menu.items[4].isSeparatorItem)

        #expect(menu.items[5].title == "Launch at Login")
        #expect(!menu.items[5].isEnabled)

        #expect(menu.items[6].title == "Quit NapCat")
        #expect(menu.items[6].isEnabled)
        #expect(menu.items[6].action == #selector(NSApplication.terminate(_:)))
    }
}
