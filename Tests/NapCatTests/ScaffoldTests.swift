import AppKit
import Testing
@testable import NapCat

/// Menu scaffold tests (Swift Testing — XCTest is unavailable with
/// Command Line Tools only; see PLAN.md decision log 2026-07-09).
/// Construction only — no test here (or anywhere) may invoke sudo or spawn
/// the real watchdog; building these objects runs no external process.
@MainActor
struct ScaffoldTests {
    /// Isolated defaults suite so tests never touch com.muratalkan.napcat.
    private static let testSuite = "com.muratalkan.napcat.tests"

    private func makeMenuContent() -> MenuContentView {
        let defaults = UserDefaults(suiteName: Self.testSuite)!
        defaults.removePersistentDomain(forName: Self.testSuite)
        return MenuContentView(
            sleep: SleepStateController(),
            watchdog: WatchdogController(),
            defaults: defaults
        )
    }

    @Test func placeholderIconIsTemplateAt18Points() {
        let icon = StatusItemController.placeholderIcon()
        #expect(icon.isTemplate, "menu bar icon must be a template image")
        #expect(icon.size == NSSize(width: 18, height: 18))
    }

    @Test func menuLayoutAndEnabledStates() {
        let menuContent = makeMenuContent()
        let menu = menuContent.menu
        #expect(menu.items.count == 7)

        #expect(menu.items[0].title == "Battery: —%")
        #expect(!menu.items[0].isEnabled)

        #expect(menu.items[1].isSeparatorItem)

        // Phase 2: stay-awake is live — enabled with a toggle action, and it
        // stays enabled even when setup is missing (alert must re-trigger).
        #expect(menu.items[2].title == "Stay Awake (Lid Closed)")
        #expect(menu.items[2].isEnabled)
        #expect(menu.items[2].action != nil)
        #expect(menu.items[2].target === menuContent)

        #expect(menu.items[3].title == "Charge Limit: 90%")
        #expect(!menu.items[3].isEnabled)

        #expect(menu.items[4].isSeparatorItem)

        #expect(menu.items[5].title == "Launch at Login")
        #expect(!menu.items[5].isEnabled)

        #expect(menu.items[6].title == "Quit NapCat")
        #expect(menu.items[6].isEnabled)
        #expect(menu.items[6].action == #selector(NSApplication.terminate(_:)))
    }

    @Test func menuIsItsOwnDelegateForOpenReconciliation() {
        let menuContent = makeMenuContent()
        // menuWillOpen re-reads pmset -g on every open (ADR §6).
        #expect(menuContent.menu.delegate === menuContent)
    }

    @Test func stayAwakeItemStartsFromObservedStateNotIntent() {
        let menuContent = makeMenuContent()
        // No pmset -g read has happened yet in this fresh controller, so the
        // observed state is unknown → mixed, never a cached-intent checkmark.
        #expect(menuContent.menu.items[2].state == .mixed)
    }
}
