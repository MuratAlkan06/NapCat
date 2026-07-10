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

    /// Regression lock for the 2026-07-10 UX fix: toggling Stay Awake used
    /// to close the menu because toggleStayAwake() called
    /// menu.cancelTracking() unconditionally before deciding anything.
    /// Lint-style (NSMenu tracking cannot be driven headlessly): the
    /// happy-path functions must contain no menu-dismissal, alert, or
    /// app-activation call, and the single cancelTracking call in the file
    /// must live inside closeMenuThenPresent — the one modal-flow gateway.
    @Test func stayAwakeToggleHappyPathNeverClosesTheMenu() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)  // Tests/NapCatTests/<this file>
            .deletingLastPathComponent()                 // Tests/NapCatTests
            .deletingLastPathComponent()                 // Tests
            .deletingLastPathComponent()                 // repo root
            .appendingPathComponent("Sources/NapCat/MenuContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        // Guard against path drift making the test vacuous.
        try #require(source.contains("final class MenuContentView"))

        let happyPathFunctions = ["toggleStayAwake", "applyStayAwake", "handleStayAwakeOutcome"]
        let forbidden = ["cancelTracking", "NSAlert", "runModal", "NSApp.activate", "activate("]
        for function in happyPathFunctions {
            let body = try #require(Self.functionChunk(named: function, in: source),
                                    "function \(function) not found — rewiring must keep this lock updated")
            for token in forbidden {
                #expect(!body.contains(token),
                        "'\(token)' in \(function) — the happy path must keep the menu open")
            }
        }

        // Exactly one dismissal call in the whole file, inside the gateway.
        let dismissals = source.components(separatedBy: "cancelTracking").count - 1
        #expect(dismissals == 1, "expected exactly one cancelTracking call, found \(dismissals)")
        let gateway = try #require(Self.functionChunk(named: "closeMenuThenPresent", in: source))
        #expect(gateway.contains("cancelTracking"),
                "the one dismissal must live in closeMenuThenPresent")
    }

    /// Source chunk from `func <name>(` to the next function declaration
    /// (or end of file) — coarse but stable for lint-style assertions.
    private static func functionChunk(named name: String, in source: String) -> String? {
        guard let start = source.range(of: "func \(name)(") else { return nil }
        let tail = source[start.upperBound...]
        let boundaries = ["\n    private func ", "\n    func ", "\n    static func ", "\n    nonisolated static func "]
        let end = boundaries
            .compactMap { tail.range(of: $0)?.lowerBound }
            .min() ?? tail.endIndex
        return String(tail[..<end])
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
