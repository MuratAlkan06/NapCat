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

    @Test func placeholderIconIsTemplateAtIconPointHeight() {
        let icon = StatusItemController.placeholderIcon()
        #expect(icon.isTemplate, "menu bar icon must be a template image")
        #expect(StatusItemController.iconPointHeight == 21, "locked render size (user decision 2026-07-10)")
        #expect(icon.size == NSSize(
            width: StatusItemController.iconPointHeight,
            height: StatusItemController.iconPointHeight
        ))
    }

    /// P3b: the menu is a single view-based item hosting the SwiftUI panel.
    @Test func menuHostsExactlyOneSwiftUIPanelItem() throws {
        let menuContent = makeMenuContent()
        let menu = menuContent.menu
        #expect(menu.items.count == 1)

        let panelItem = menu.items[0]
        // Types spelled as strings: `import SwiftUI` next to `import Testing`
        // would pull in another CLT-missing cross-import overlay. Since the
        // 2026-10-18 redesign the item view is MenuPanelHostingView (an
        // NSHostingView subclass that re-fits the open menu), so the chain of
        // superclasses must still contain NSHostingView<MenuPanelView>.
        let view = try #require(panelItem.view)
        var chain: [String] = []
        var cls: AnyClass? = type(of: view)
        while let current = cls {
            chain.append(String(describing: current))
            cls = class_getSuperclass(current)
        }
        #expect(chain.first?.contains("MenuPanelHostingView") == true, "got \(chain)")
        #expect(chain.contains { $0.contains("NSHostingView") && $0.contains("MenuPanelView") }, "got \(chain)")
        #expect(panelItem.isEnabled)
        // The hosted panel must have laid out to a real size.
        #expect((panelItem.view?.frame.width ?? 0) > 0)
        #expect((panelItem.view?.frame.height ?? 0) > 0)
    }

    /// 2026-10-18 redesign — the NSMenu height problem. The panel's height
    /// changes while the menu is OPEN (Details disclosure, style switch); a
    /// frame measured once at menuWillOpen used to clip. MenuPanelHostingView
    /// re-fits itself in the first layout pass that sees new content (NSMenu
    /// follows an item view's frame live — NSMenuItem.h). Driven headlessly in
    /// an offscreen window: no menu is shown, nothing is clicked.
    @Test func panelRefitsItsHeightWhenDetailsToggleWhileOpen() throws {
        let menuContent = makeMenuContent()
        let view = try #require(menuContent.menu.items[0].view)
        let window = Self.offscreenHost(view)
        defer { window.contentView = nil }

        Self.settle(view)
        let collapsed = view.frame.height
        #expect(abs(collapsed - view.fittingSize.height) < 1)

        menuContent.model.setDetailsExpanded(true)
        Self.settle(view)
        #expect(view.frame.height > collapsed + 20, "Details content must grow the panel")
        #expect(abs(view.frame.height - view.fittingSize.height) < 1, "frame must match content — no clipping")

        menuContent.model.setDetailsExpanded(false)
        Self.settle(view)
        #expect(abs(view.frame.height - collapsed) < 1, "collapsing must not leave dead space")
    }

    /// Same mechanism for the curation-only style switch: every variant ends
    /// up exactly content-sized, without reopening the menu.
    @Test func panelRefitsForEveryStyleWithoutReopening() throws {
        let menuContent = makeMenuContent()
        let view = try #require(menuContent.menu.items[0].view)
        let window = Self.offscreenHost(view)
        defer { window.contentView = nil }
        var heights: Set<Int> = []
        for _ in MenuPanelStyle.allCases {
            menuContent.model.cyclePanelStyle()
            Self.settle(view)
            #expect(abs(view.frame.height - view.fittingSize.height) < 1,
                    "\(menuContent.model.panelStyle) is not content-sized")
            heights.insert(Int(view.frame.height.rounded()))
        }
        #expect(heights.count > 1, "the variants differ in height — the re-fit was really exercised")
    }

    private static func offscreenHost(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 1200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 1200))
        window.contentView = container
        container.addSubview(view)
        view.setFrameOrigin(.zero)
        return window
    }

    /// A few layout passes + runloop turns so SwiftUI applies pending state.
    private static func settle(_ view: NSView) {
        for _ in 0..<4 {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
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

    /// Same lock extended to the Track B / B2 controls (2026-08-24, updated for
    /// the B4 ntfy swap): the lid-alert toggle and the test-send button must
    /// keep the menu OPEN, and the ntfy settings editor — the one genuinely
    /// modal B2 flow — must go through `closeMenuThenPresent` rather than
    /// dismissing on its own. The "exactly one cancelTracking" assertion above
    /// still holds because the settings prompt reuses that single gateway.
    @Test func lidAlertHappyPathsNeverCloseTheMenu() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/NapCat/MenuContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        try #require(source.contains("final class MenuContentView"))

        let happyPathFunctions = ["toggleLidAlert", "sendLidAlertTestMessage"]
        let forbidden = ["cancelTracking", "NSAlert", "runModal", "NSApp.activate", "activate("]
        for function in happyPathFunctions {
            let body = try #require(Self.functionChunk(named: function, in: source),
                                    "function \(function) not found — rewiring must keep this lock updated")
            for token in forbidden {
                #expect(!body.contains(token),
                        "'\(token)' in \(function) — the happy path must keep the menu open")
            }
        }

        // The modal ntfy editor dismisses ONLY via the shared gateway.
        let prompt = try #require(Self.functionChunk(named: "promptForLidAlertSettings", in: source))
        #expect(prompt.contains("closeMenuThenPresent"))
        #expect(!prompt.contains("cancelTracking"))
        #expect(!prompt.contains("runModal"), "the modal itself lives in presentLidAlertSettingsPrompt")
    }

    /// M1 regression lock (security review 2026-09-09): the ntfy editor used to
    /// call `setServer`/`setTopic` and DISCARD their validation results, so an
    /// unusable value silently kept the old configuration while the panel went
    /// on claiming the feature was armed. The modal must now consult the
    /// validation before it commits anything. Lint-style: an AppKit modal
    /// session cannot be driven headlessly, so the pure mapping is unit-tested
    /// in MenuStateModelTests and its USE is locked here.
    @Test func theNtfySettingsModalValidatesBeforeItCommits() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/NapCat/MenuContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let body = try #require(Self.functionChunk(named: "presentLidAlertSettingsPrompt", in: source))

        #expect(body.contains("MenuStateModel.lidAlertSettingsError("),
                "the modal must surface an invalid field instead of dropping it")
        // Order matters: the validation must be consulted BEFORE either setter.
        let checkedAt = try #require(body.range(of: "lidAlertSettingsError("))
        for setter in ["lidGuard.setServer(", "lidGuard.setTopic("] {
            let setAt = try #require(body.range(of: setter), "\(setter) not found — keep this lock updated")
            #expect(checkedAt.lowerBound < setAt.lowerBound,
                    "\(setter) runs before the validation check — an invalid value would commit silently")
        }
    }

    /// Menu-open must stay off the network: the panel renders stored config and
    /// the last recorded outcome, never a live probe. (Before B4 this slot held
    /// the silent Automation-permission probe; the ntfy channel has nothing to
    /// probe, and a menu-open request would be a per-open network call.)
    @Test func menuOpenPerformsNoNetworkIO() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/NapCat/MenuContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let body = try #require(Self.functionChunk(named: "menuWillOpen", in: source))
        for token in ["sendTestMessage", "URLSession", "dataTask",
                      "probeAutomationPermission", "refreshAutomationPermission"] {
            #expect(!body.contains(token), "'\(token)' in menuWillOpen — opening the menu must not send anything")
        }
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
