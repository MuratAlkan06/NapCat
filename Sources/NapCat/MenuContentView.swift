import AppKit

/// Builds the status item menu and owns the stay-awake toggle flow.
/// Plain NSMenuItems; NSHostingView-backed SwiftUI items are introduced only
/// when a phase actually needs them (slider etc.) — see PLAN.md decision log.
///
/// The stay-awake checkmark reflects the OBSERVED `pmset -g` state only,
/// re-read on every menu open (ADR §6) — never cached intent.
@MainActor
final class MenuContentView: NSObject, NSMenuDelegate {
    let menu: NSMenu

    private let sleep: SleepStateController
    private let watchdog: WatchdogController
    private let defaults: UserDefaults
    private let stayAwakeItem: NSMenuItem

    init(
        sleep: SleepStateController,
        watchdog: WatchdogController,
        defaults: UserDefaults = .standard
    ) {
        self.sleep = sleep
        self.watchdog = watchdog
        self.defaults = defaults
        self.menu = NSMenu()
        self.stayAwakeItem = NSMenuItem(
            title: "Stay Awake (Lid Closed)",
            action: #selector(toggleStayAwake(_:)),
            keyEquivalent: ""
        )
        super.init()

        // Explicit enable/disable control for placeholder items.
        menu.autoenablesItems = false
        menu.delegate = self

        let batteryItem = NSMenuItem(title: "Battery: —%", action: nil, keyEquivalent: "")
        batteryItem.isEnabled = false // Live IOKit data arrives in Phase 3.
        menu.addItem(batteryItem)

        menu.addItem(.separator())

        stayAwakeItem.target = self
        // Stays enabled even when setup is missing, so the "Setup Required"
        // alert can re-trigger.
        stayAwakeItem.isEnabled = true
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

        sleep.onObservedStateChange = { [weak self] observed in
            self?.stayAwakeItem.state = Self.stayAwakeItemState(forObserved: observed)
        }
        stayAwakeItem.state = Self.stayAwakeItemState(forObserved: sleep.observedSleepDisabled)
    }

    /// Menu-open reconciliation (ADR §6): re-read the real pmset state every
    /// time the menu opens, so external changes are reflected immediately.
    func menuWillOpen(_ menu: NSMenu) {
        sleep.refreshObservedState()
    }

    /// Pure mapping from observed state to the menu item checkmark.
    /// nil (pmset -g unreadable) renders as mixed — never a false on/off.
    nonisolated static func stayAwakeItemState(forObserved observed: Bool?) -> NSControl.StateValue {
        switch observed {
        case .some(true): return .on
        case .some(false): return .off
        case .none: return .mixed
        }
    }

    // MARK: - Stay-awake toggle

    @objc private func toggleStayAwake(_ sender: NSMenuItem) {
        // Decide from fresh observed state, not the menu checkmark.
        if sleep.refreshObservedState() == true {
            disableStayAwake()
        } else {
            enableStayAwake()
        }
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
