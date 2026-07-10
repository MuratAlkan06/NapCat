import AppKit
import Testing
@testable import NapCat

/// Menu scaffold tests (Swift Testing — XCTest is unavailable with
/// Command Line Tools only; see PLAN.md decision log 2026-07-09).
/// Construction only — no test here (or anywhere) may invoke sudo or spawn
/// the real watchdog; the power interface is always the simulator, so
/// building these objects runs no external process.
@MainActor
struct ScaffoldTests {
    /// Isolated defaults suite so tests never touch com.muratalkan.napcat.
    private static let testSuite = "com.muratalkan.napcat.tests"

    private func makeMenuContent() -> MenuContentView {
        let defaults = UserDefaults(suiteName: Self.testSuite)!
        defaults.removePersistentDomain(forName: Self.testSuite)
        let simulator = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        let limiter = ChargeLimiter(power: simulator, isAppleSilicon: true, defaults: defaults)
        return MenuContentView(
            sleep: SleepStateController(),
            watchdog: WatchdogController(),
            power: simulator,
            limiter: limiter,
            simulator: simulator,
            defaults: defaults
        )
    }

    @Test func placeholderIconIsTemplateAt18Points() {
        let icon = StatusItemController.placeholderIcon()
        #expect(icon.isTemplate, "menu bar icon must be a template image")
        #expect(icon.size == NSSize(width: 18, height: 18))
    }

    /// P3b: the menu is a single view-based item hosting the SwiftUI panel.
    @Test func menuHostsExactlyOneSwiftUIPanelItem() {
        let menuContent = makeMenuContent()
        let menu = menuContent.menu
        #expect(menu.items.count == 1)

        let panelItem = menu.items[0]
        // Type spelled as a string: `import SwiftUI` next to `import Testing`
        // would pull in another CLT-missing cross-import overlay.
        let hostedViewType = String(describing: type(of: panelItem.view as AnyObject))
        #expect(hostedViewType.contains("NSHostingView"), "got \(hostedViewType)")
        #expect(hostedViewType.contains("MenuPanelView"), "got \(hostedViewType)")
        #expect(panelItem.isEnabled)
        // The hosted panel must have laid out to a real size.
        #expect((panelItem.view?.frame.width ?? 0) > 0)
        #expect((panelItem.view?.frame.height ?? 0) > 0)
    }

    /// ⌘Q stays wired even though Quit is a SwiftUI button: the hosting item
    /// carries the key equivalent and terminates via the responder chain.
    @Test func commandQTerminatesThroughTheHostingItem() {
        let menuContent = makeMenuContent()
        let panelItem = menuContent.menu.items[0]
        #expect(panelItem.keyEquivalent == "q")
        #expect(panelItem.keyEquivalentModifierMask == .command)
        #expect(panelItem.action == #selector(NSApplication.terminate(_:)))
        #expect(panelItem.target == nil, "nil target → responder chain → NSApplication")
    }

    @Test func menuIsItsOwnDelegateForOpenReconciliation() {
        let menuContent = makeMenuContent()
        // menuWillOpen re-reads pmset -g and re-evaluates the limiter on
        // every open (ADR §6).
        #expect(menuContent.menu.delegate === menuContent)
    }

    @Test func modelStartsFromObservedStateNotIntent() {
        let menuContent = makeMenuContent()
        // No pmset -g read has happened yet in this fresh controller, so the
        // observed state is unknown → toggle off WITH caption, never a
        // cached-intent checkmark.
        #expect(menuContent.model.stayAwakeObserved == nil)
        let mapped = MenuStateModel.stayAwakeToggle(forObserved: menuContent.model.stayAwakeObserved)
        #expect(!mapped.isOn)
        #expect(mapped.caption != nil)
    }

    @Test func debugSectionVisibleOnlyWithSimulator() {
        let menuContent = makeMenuContent()
        #expect(menuContent.model.debugControlsVisible, "built with a simulator here")

        // Real-interface wiring (simulator: nil) hides the debug section.
        let defaults = UserDefaults(suiteName: Self.testSuite)!
        let power = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        let limiter = ChargeLimiter(power: power, isAppleSilicon: true, defaults: defaults)
        let model = MenuStateModel(power: power, sleep: SleepStateController(), limiter: limiter, simulator: nil)
        #expect(!model.debugControlsVisible)
    }
}
