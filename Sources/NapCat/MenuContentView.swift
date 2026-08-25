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
/// re-read on every menu open (ADR §6) — never cached intent.
///
/// Menu-stays-open rule (2026-07-10 UX fix): panel controls never dismiss
/// the menu. The stay-awake flip runs off the main actor and the published
/// observed state re-renders the open panel when it completes. The only
/// flows allowed to close the menu are the genuinely modal ones — first-ever
/// heat warning, setup required, failure — and they go through
/// `closeMenuThenPresent` (dismiss cleanly first, then present).
@MainActor
final class MenuContentView: NSObject, NSMenuDelegate {
    let menu: NSMenu
    let model: MenuStateModel

    private let sleep: SleepStateController
    private let watchdog: WatchdogController
    private let power: PowerInterface
    private let limiter: ChargeLimiter
    private let loginItem: LoginItemController
    private let defaults: UserDefaults
    /// Track B read-only detection; nil in debugBattery mode (structurally
    /// absent). Sampled on menu open only — no background timer.
    private let detection: ClaudeActivityController?
    /// Track B / B2 lid-close alert; nil in debugBattery mode (structurally
    /// absent). Registers for IOKit power notifications only while armed.
    private let lidGuard: LidGuardController?
    private let hostingView: NSHostingView<MenuPanelView>
    /// Re-toggles are ignored while a privileged command is in flight; the
    /// completion refresh re-publishes the observed state either way.
    private var stayAwakeCommandInFlight = false

    init(
        sleep: SleepStateController,
        watchdog: WatchdogController,
        power: PowerInterface,
        limiter: ChargeLimiter,
        loginItem: LoginItemController = LoginItemController(),
        simulator: DebugPowerSimulator? = nil,
        detection: ClaudeActivityController? = nil,
        lidGuard: LidGuardController? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.sleep = sleep
        self.watchdog = watchdog
        self.power = power
        self.limiter = limiter
        self.loginItem = loginItem
        self.defaults = defaults
        self.detection = detection
        self.lidGuard = lidGuard
        self.model = MenuStateModel(power: power, sleep: sleep, limiter: limiter, loginItem: loginItem, simulator: simulator, detection: detection, lidGuard: lidGuard)
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
        model.requestLidGuardToggle = { [weak self] enabled in self?.toggleLidAlert(enabled) }
        model.requestLidGuardRecipientPrompt = { [weak self] in self?.promptForLidAlertRecipient() }
        model.requestLidGuardTestSend = { [weak self] in self?.sendLidAlertTestMessage() }

        // The lid guard's own async events (send outcome, permission probe)
        // republish through the same refresh path as every other controller.
        lidGuard?.setChangeHandler { [weak self] in
            Task { @MainActor in self?.model.refresh() }
        }

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
        // Launch-at-login reflects the live SMAppService status on every
        // open (approval may have been granted in System Settings meanwhile).
        loginItem.refresh()
        // Track B: sample the marker dir / processes / sleep assertions once,
        // here — the only place detection is read (no polling timer).
        detection?.sample()
        // Track B / B2: register or drop the IOKit sleep hook so it matches the
        // current config (the pmset refresh above has already primed the
        // stay-awake mirror the fire gate reads), then probe the Messages
        // permission OFF this critical path.
        lidGuard?.refreshArming()
        probeAutomationPermission()
        model.refresh()
        // Section visibility (charge limit, debug) can change the intrinsic
        // height — resize the hosted view before the menu lays out.
        hostingView.frame.size = hostingView.fittingSize
    }

    // MARK: - Stay-awake toggle (P2 semantics; menu-stays-open rework 2026-07-10)

    /// Happy path (warning acknowledged, setup done): the menu STAYS OPEN.
    /// Only the first-ever heat warning needs a modal answer before the
    /// command may run — that flow dismisses first via closeMenuThenPresent.
    private func toggleStayAwake() {
        guard !stayAwakeCommandInFlight else { return }
        // Decide from fresh observed state, not the toggle position.
        if sleep.refreshObservedState() == true {
            applyStayAwake(false)
        } else if defaults.bool(forKey: DefaultsKey.heatWarningAcknowledged) {
            applyStayAwake(true)
        } else {
            closeMenuThenPresent { [weak self] in
                guard let self else { return }
                if self.confirmHeatRiskIfNeeded() {
                    self.applyStayAwake(true)
                } else {
                    // Declined — snap the toggle back to the observed state.
                    self.model.refresh()
                }
            }
        }
    }

    /// Runs the privileged flip OFF the tracking runloop (async controller
    /// path); the open menu stays responsive and re-renders from the
    /// published observed state when the outcome lands.
    private func applyStayAwake(_ enable: Bool) {
        guard !stayAwakeCommandInFlight else { return }
        stayAwakeCommandInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.sleep.setStayAwakeAsync(enable)
            self.stayAwakeCommandInFlight = false
            self.handleStayAwakeOutcome(outcome, enable: enable)
            self.model.refresh()
        }
    }

    /// Success bookkeeping stays inline (menu open); the two failure flows
    /// are modal and therefore dismiss first via closeMenuThenPresent.
    private func handleStayAwakeOutcome(
        _ outcome: SleepStateController.SetStayAwakeOutcome,
        enable: Bool
    ) {
        switch outcome {
        case .success:
            defaults.set(enable, forKey: DefaultsKey.stayAwakeIntent)
            if enable {
                watchdog.start(appPID: pid_t(ProcessInfo.processInfo.processIdentifier))
            } else {
                watchdog.stop()
            }
        case .sudoDenied:
            closeMenuThenPresent { [weak self] in self?.presentSetupRequiredAlert() }
        case .commandFailed(let detail), .verificationFailed(let detail):
            closeMenuThenPresent { [weak self] in self?.presentFailureAlert(detail) }
        }
    }

    // MARK: - Lid-close alert (Track B / B2)

    /// Happy path — the menu STAYS OPEN. Enabling with a recipient that has
    /// never been primed also kicks off the config-time test send, which is
    /// what raises the "NapCat wants to control Messages" prompt while the
    /// user is present (never at lid-close). The send itself runs on the
    /// sender's private queue, so nothing blocks here.
    private func toggleLidAlert(_ enabled: Bool) {
        guard let lidGuard else { return }
        lidGuard.setEnabled(enabled)
        if enabled, lidGuard.armingState == .needsTestSend {
            lidGuard.sendTestMessage()
        }
        model.refresh()
    }

    /// Happy path — the menu STAYS OPEN; the send is handed to the sender's
    /// private queue and its outcome republishes through setChangeHandler.
    private func sendLidAlertTestMessage() {
        lidGuard?.sendTestMessage()
        model.refresh()
    }

    /// The ONE B2 flow that is genuinely modal (a text field), so it dismisses
    /// first through the single gateway.
    private func promptForLidAlertRecipient() {
        closeMenuThenPresent { [weak self] in self?.presentRecipientPrompt() }
    }

    /// Silent Automation-permission probe: armed only, and detached so it
    /// never sits on the menuWillOpen critical path. The probe passes
    /// `askUserIfNeeded: false`, so it can never raise a prompt.
    private func probeAutomationPermission() {
        guard let lidGuard, lidGuard.isArmed else { return }
        Task.detached(priority: .utility) {
            lidGuard.refreshAutomationPermission()
        }
    }

    /// The ONLY place that may dismiss the menu (locked by a lint-style
    /// regression test in ScaffoldTests). Presentation is deferred one
    /// runloop turn so the dismissal finishes before the modal session
    /// starts.
    private func closeMenuThenPresent(_ present: @escaping @MainActor () -> Void) {
        menu.cancelTracking()
        Task { @MainActor in present() }
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

    /// Modal recipient editor (accessory NSTextField). Saving a CHANGED
    /// recipient clears the primed flag, so — while the feature is switched on
    /// — the test send re-runs against the new address and its Automation
    /// prompt is answered here and now.
    private func presentRecipientPrompt() {
        guard let lidGuard else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Where should NapCat text you?"
        alert.informativeText = """
            Enter YOUR own iMessage address — the phone number or Apple ID you use on your \
            iPhone. NapCat messages that address (a note to yourself) when this Mac starts \
            sleeping while a Claude Code task is still running. It never sends anything else, \
            and never any of your Claude conversation.
            """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = lidGuard.storedRecipient
        field.placeholderString = "+15551234567 or you@example.com"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if case .valid = lidGuard.setRecipient(field.stringValue),
           lidGuard.armingState == .needsTestSend {
            lidGuard.sendTestMessage()
        }
        model.refresh()
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
