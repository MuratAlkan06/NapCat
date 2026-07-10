import AppKit
import SwiftUI

/// Owns the status-item NSMenu. Since P3b the content is a rich SwiftUI
/// panel (MenuPanelView) hosted in an NSHostingView inside a single
/// view-based NSMenuItem — the menu still opens/closes as a plain NSMenu.
///
/// ⌘Q: the hosting item carries keyEquivalent "q" + the terminate action;
/// AppKit's command-key matching runs for view-based items, and the SwiftUI
/// Quit button is the visible control. (Live ⌘Q check happens at the
/// coordinated restart; fallback would be a native Quit item.)
///
/// The stay-awake toggle reflects the OBSERVED `pmset -g` state only,
/// re-read on every menu open (ADR §6) — never cached intent. The alert
/// flows (heat warning, setup required, failure) are unchanged from P2.
@MainActor
final class MenuContentView: NSObject, NSMenuDelegate {
    let menu: NSMenu
    let model: MenuStateModel

    private let sleep: SleepStateController
    private let watchdog: WatchdogController
    private let power: PowerInterface
    private let limiter: ChargeLimiter
    private let defaults: UserDefaults
    private let hostingView: NSHostingView<MenuPanelView>

    init(
        sleep: SleepStateController,
        watchdog: WatchdogController,
        power: PowerInterface,
        limiter: ChargeLimiter,
        simulator: DebugPowerSimulator? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.sleep = sleep
        self.watchdog = watchdog
        self.power = power
        self.limiter = limiter
        self.defaults = defaults
        self.model = MenuStateModel(power: power, sleep: sleep, limiter: limiter, simulator: simulator)
        self.menu = NSMenu()
        self.hostingView = NSHostingView(rootView: MenuPanelView(model: model))
        super.init()

        menu.autoenablesItems = false
        menu.delegate = self

        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        let panelItem = NSMenuItem()
        panelItem.view = hostingView
        panelItem.isEnabled = true
        // ⌘Q while the menu is open (see class comment).
        panelItem.keyEquivalent = "q"
        panelItem.keyEquivalentModifierMask = .command
        panelItem.target = nil // responder chain → NSApplication
        panelItem.action = #selector(NSApplication.terminate(_:))
        menu.addItem(panelItem)

        // Observed-state pushes → published mirrors.
        sleep.onObservedStateChange = { [weak self] _ in self?.model.refresh() }
        limiter.onChange = { [weak self] in self?.model.refresh() }

        // View actions that need AppKit flows.
        model.requestStayAwakeToggle = { [weak self] _ in self?.toggleStayAwake() }
        model.requestQuit = { NSApp.terminate(nil) }

        model.refresh()
    }

    /// Menu-open reconciliation (ADR §6): re-read the real pmset state and
    /// re-evaluate the charge limiter every time the menu opens, so external
    /// changes are reflected immediately. Also re-probes the smc helper so
    /// running setup.sh takes effect without an app restart.
    func menuWillOpen(_ menu: NSMenu) {
        sleep.refreshObservedState()
        power.reprobeChargeControlIfNeeded()
        limiter.evaluate(reason: "menu open")
        model.refresh()
        // Section visibility (charge limit, debug) can change the intrinsic
        // height — resize the hosted view before the menu lays out.
        hostingView.frame.size = hostingView.fittingSize
    }

    // MARK: - Stay-awake toggle (P2 flow, unchanged semantics)

    private func toggleStayAwake() {
        // Alerts may follow — close the menu before running modal flows.
        menu.cancelTracking()
        // Decide from fresh observed state, not the toggle position.
        if sleep.refreshObservedState() == true {
            disableStayAwake()
        } else {
            enableStayAwake()
        }
        model.refresh()
    }

    private func enableStayAwake() {
        guard confirmHeatRiskIfNeeded() else { return }
        switch sleep.setStayAwake(true) {
        case .success:
            defaults.set(true, forKey: DefaultsKey.stayAwakeIntent)
            watchdog.start(appPID: pid_t(ProcessInfo.processInfo.processIdentifier))
        case .sudoDenied:
            presentSetupRequiredAlert()
        case .commandFailed(let detail), .verificationFailed(let detail):
            presentFailureAlert(detail)
        }
    }

    private func disableStayAwake() {
        switch sleep.setStayAwake(false) {
        case .success:
            defaults.set(false, forKey: DefaultsKey.stayAwakeIntent)
            watchdog.stop()
        case .sudoDenied:
            presentSetupRequiredAlert()
        case .commandFailed(let detail), .verificationFailed(let detail):
            presentFailureAlert(detail)
        }
    }

    /// One-time heat-risk warning; acknowledgment persisted. Returns true
    /// when the user may proceed.
    private func confirmHeatRiskIfNeeded() -> Bool {
        if defaults.bool(forKey: DefaultsKey.heatWarningAcknowledged) { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Keep your Mac awake with the lid closed?"
        alert.informativeText = """
            A closed MacBook in a bag can overheat. While Stay Awake is on, \
            your Mac will not sleep when the lid is closed — make sure it has \
            ventilation, and turn this off before packing it away. NapCat \
            re-enables normal sleep automatically when it quits or crashes.
            """
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        defaults.set(true, forKey: DefaultsKey.heatWarningAcknowledged)
        return true
    }

    private func presentSetupRequiredAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Setup Required"
        alert.informativeText = """
            NapCat needs a one-time privileged setup before it can control \
            sleep. In Terminal, run this from the NapCat repository:

            sudo ./scripts/setup.sh

            Then toggle Stay Awake again.
            """
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    private func presentFailureAlert(_ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Stay Awake Failed"
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}
