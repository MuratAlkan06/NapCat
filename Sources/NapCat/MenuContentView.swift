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
/// heat warning, setup required, failure, the "ntfy settings…" editor —
/// plus Lock Screen (the user is deliberately leaving the machine), and they
/// all go through `closeMenuThenPresent` (dismiss cleanly first, then
/// present). The Details disclosure is pure model state and never reaches
/// this class at all.
///
/// Height (2026-10-18 redesign): the panel's height changes while the menu
/// is OPEN (Details disclosure, a caption appearing after an async outcome). `MenuPanelHostingView` re-fits its own frame in the first
/// layout pass that sees new content, and NSMenu follows a view-based item's
/// frame live — see that class.
@MainActor
final class MenuContentView: NSObject, NSMenuDelegate {
    let menu: NSMenu
    let model: MenuStateModel

    private let sleep: SleepStateController
    private let watchdog: WatchdogController
    private let power: PowerInterface
    private let limiter: ChargeLimiter
    private let loginItem: LoginItemController
    private let screenLock: ScreenLockController
    private let defaults: UserDefaults
    /// Track B read-only detection; nil in debugBattery mode (structurally
    /// absent). Sampled on menu open only — no background timer.
    private let detection: ClaudeActivityController?
    /// Track B / B2 lid-close alert; nil in debugBattery mode (structurally
    /// absent). Registers for IOKit power notifications only while armed.
    private let lidGuard: LidGuardController?
    /// Track C finish alert + waiting buzz; nil in debugBattery mode
    /// (structurally absent). Watches the marker dir only while armed.
    private let finishAlert: FinishAlertController?
    private let hostingView: MenuPanelHostingView<MenuPanelView>
    /// Re-toggles are ignored while a privileged command is in flight; the
    /// completion refresh re-publishes the observed state either way.
    private var stayAwakeCommandInFlight = false
    /// Same guard for the lock sequence — a double click must not fire two
    /// lock/verify/darken runs.
    private var lockCommandInFlight = false

    init(
        sleep: SleepStateController,
        watchdog: WatchdogController,
        power: PowerInterface,
        limiter: ChargeLimiter,
        loginItem: LoginItemController = LoginItemController(),
        screenLock: ScreenLockController = ScreenLockController(),
        simulator: DebugPowerSimulator? = nil,
        detection: ClaudeActivityController? = nil,
        lidGuard: LidGuardController? = nil,
        finishAlert: FinishAlertController? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.sleep = sleep
        self.watchdog = watchdog
        self.power = power
        self.limiter = limiter
        self.loginItem = loginItem
        self.screenLock = screenLock
        self.defaults = defaults
        self.detection = detection
        self.lidGuard = lidGuard
        self.finishAlert = finishAlert
        self.model = MenuStateModel(
            power: power,
            sleep: sleep,
            limiter: limiter,
            loginItem: loginItem,
            screenLock: screenLock,
            simulator: simulator,
            detection: detection,
            lidGuard: lidGuard,
            finishAlert: finishAlert
        )
        self.menu = NSMenu()
        self.hostingView = MenuPanelHostingView(rootView: MenuPanelView(model: model))
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
        model.requestLockScreen = { [weak self] in self?.lockScreen() }
        model.requestQuit = { NSApp.terminate(nil) }
        model.requestLidGuardToggle = { [weak self] enabled in self?.toggleLidAlert(enabled) }
        model.requestLidGuardSettingsPrompt = { [weak self] in self?.promptForLidAlertSettings() }
        model.requestLidGuardTestSend = { [weak self] in self?.sendLidAlertTestMessage() }
        model.requestFinishAlertToggle = { [weak self] enabled in self?.toggleSessionAlerts(enabled) }

        // The lid guard's own async events (send outcome, wake) republish
        // through the same refresh path as every other controller.
        lidGuard?.setChangeHandler { [weak self] in
            Task { @MainActor in self?.model.refresh() }
        }
        // Track C: arm/disarm and send outcomes republish the same way.
        finishAlert?.setChangeHandler { [weak self] in
            Task { @MainActor in self?.model.refresh() }
        }
        // A pause toggle (the DISABLED flag) re-gates the finish alert at
        // once: pausing disarms it, resuming re-arms it with a fresh baseline.
        model.onDetectionPausedChange = { [weak self] in self?.finishAlert?.reconcile() }

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
        // stay-awake mirror the fire gate reads). Nothing is probed here — the
        // ntfy channel has no permission to check, and menu-open must never
        // touch the network.
        lidGuard?.refreshArming()
        // Track C: arm or disarm the marker-dir watcher to match the config,
        // the pause flag and the dir (a re-arm takes a fresh baseline — never
        // a send).
        finishAlert?.reconcile()
        model.refresh()
        // Section visibility (charge limit, debug) and the Details state can
        // change the height — pre-size before the menu lays out. If SwiftUI has not applied this refresh yet, the hosting view's
        // own first layout pass corrects it before anything is displayed.
        hostingView.refitToContent()
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

    // MARK: - Lock screen (2026-08-13)

    /// One click: lock the session, verify it, then turn the display off —
    /// the Mac keeps running (pairs with Stay Awake). Unlike the toggles this
    /// flow DOES dismiss the menu first, through the single gateway: the user
    /// is walking away, and an open menu would be left floating over a screen
    /// that is about to go dark. The sequence itself then runs async so the
    /// dismissal never waits on it.
    private func lockScreen() {
        guard !lockCommandInFlight else { return }
        lockCommandInFlight = true
        closeMenuThenPresent { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                let outcome = await self.screenLock.lockScreen()
                self.lockCommandInFlight = false
                self.handleLockOutcome(outcome)
            }
        }
    }

    /// Failure surfacing is asymmetric by design: a screen that failed to
    /// lock is still LIT, so the user can (and must) be told; a screen that
    /// locked but stayed lit is already safe, so it is logged only — a modal
    /// nobody can see would be pointless.
    private func handleLockOutcome(_ outcome: ScreenLockController.Outcome) {
        switch outcome {
        case .success, .lockedButDisplaySleepFailed:
            break // logged by ScreenLockController; the Mac is locked
        case .unavailable:
            break // the row is disabled in this state — nothing to report
        case .lockNotVerified(let detail):
            presentLockFailureAlert(detail)
        }
    }

    /// The menu is already dismissed by the time this runs (the lock flow
    /// closes it up front), so it presents directly.
    private func presentLockFailureAlert(_ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Could Not Lock the Screen"
        alert.informativeText = """
            \(detail)

            Your Mac is still unlocked. Try again, or use Apple menu › \
            Lock Screen (⌃⌘Q).
            """
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    // MARK: - Lid-close alert (Track B / B2)

    /// Happy path — the menu STAYS OPEN. Enabling with a topic that has never
    /// been primed also kicks off the config-time test send, which is what
    /// proves the phone really receives the feed while the user is present
    /// (never at lid-close). URLSession returns immediately, so nothing blocks
    /// here.
    private func toggleLidAlert(_ enabled: Bool) {
        guard let lidGuard else { return }
        lidGuard.setEnabled(enabled)
        if enabled, lidGuard.armingState == .needsTestSend {
            lidGuard.sendTestMessage()
        }
        model.refresh()
    }

    /// Track C — the "Session alerts" toggle. Happy path: the menu STAYS OPEN.
    /// The finish alert shares the lid guard's destination AND priming, so
    /// switching it on against a never-tested topic kicks off the SAME
    /// config-time test send — the first message on a topic is never a
    /// session alert. The reconcile is the arming-refresh hook's, run here
    /// synchronously too (idempotent) so the panel never flashes the
    /// not-watching caption for a turn before the hook lands.
    private func toggleSessionAlerts(_ enabled: Bool) {
        guard let lidGuard else { return }
        lidGuard.setFinishAlertEnabled(enabled)
        if enabled, lidGuard.finishAlertArmingState == .needsTestSend {
            lidGuard.sendTestMessage()
        }
        finishAlert?.reconcile()
        model.refresh()
    }

    /// Happy path — the menu STAYS OPEN; the publish is handed to URLSession
    /// and its outcome republishes through setChangeHandler.
    private func sendLidAlertTestMessage() {
        lidGuard?.sendTestMessage()
        model.refresh()
    }

    /// The ONE B2 flow that is genuinely modal (text fields), so it dismisses
    /// first through the single gateway.
    private func promptForLidAlertSettings() {
        closeMenuThenPresent { [weak self] in self?.presentLidAlertSettingsPrompt() }
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

    /// Modal ntfy editor (two accessory NSTextFields: topic + server). Saving a
    /// CHANGED topic or server clears the primed flag, so — while the feature
    /// is switched on — the test send re-runs against the new feed and the user
    /// sees here and now whether their phone gets it.
    ///
    /// VALIDATE BEFORE COMMITTING (security review 2026-09-09): the controller
    /// keeps the previous value for an `.invalid` field, so simply calling
    /// `setTopic`/`setServer` and dropping their results left a typo looking
    /// saved while the panel still claimed the feature was armed against the
    /// OLD configuration. The editor is therefore re-presented — with the text
    /// the user typed and an inline error naming the offending field — until
    /// both halves are usable or the user cancels. The keep-the-old-value
    /// behaviour in the controller is unchanged; only the honesty of the UI is.
    private func presentLidAlertSettingsPrompt() {
        guard let lidGuard else { return }
        var entry = LidAlertSettingsEntry(topic: lidGuard.storedTopic, server: lidGuard.storedServer)
        var error: String?
        while let entered = runLidAlertSettingsEditor(entry: entry, error: error) {
            entry = entered
            if let problem = MenuStateModel.lidAlertSettingsError(
                topic: LidGuardPolicy.validateTopic(entered.topic),
                server: LidGuardPolicy.validateServer(entered.server)
            ) {
                error = problem
                continue
            }
            // Server first: a changed server also clears priming, so the topic's
            // own arming check below sees the final configuration.
            lidGuard.setServer(entered.server)
            lidGuard.setTopic(entered.topic)
            if lidGuard.armingState == .needsTestSend {
                lidGuard.sendTestMessage()
            }
            model.refresh()
            return
        }
    }

    /// One pass of the two-field editor. Returns exactly what the user typed
    /// (unvalidated — the caller decides), or nil when they cancelled. `error`
    /// is rendered above the explanation, so a rejected value comes back for
    /// correction instead of disappearing silently.
    private func runLidAlertSettingsEditor(
        entry: LidAlertSettingsEntry,
        error: String?
    ) -> LidAlertSettingsEntry? {
        let alert = NSAlert()
        alert.alertStyle = error == nil ? .informational : .warning
        alert.messageText = "Where should NapCat notify you?"
        alert.informativeText = [error, Self.lidAlertSettingsExplanation]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        let topicField = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 24))
        topicField.stringValue = entry.topic
        // Deliberately NOT a paste-ready value: a placeholder someone could copy
        // verbatim would become a shared, publicly-known feed.
        topicField.placeholderString = "Topic — e.g. napcat-<your-own-random-suffix>"
        let serverField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        serverField.stringValue = entry.server
        serverField.placeholderString = LidGuardTuning.defaultNtfyServer
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 54))
        stack.addSubview(topicField)
        stack.addSubview(serverField)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        alert.window.initialFirstResponder = topicField
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return LidAlertSettingsEntry(topic: topicField.stringValue, server: serverField.stringValue)
    }

    private static let lidAlertSettingsExplanation = """
        NapCat publishes to ntfy — install the ntfy app on your iPhone and subscribe it to \
        a topic you invent. There is no account: THE TOPIC NAME IS THE PASSWORD, so choose \
        something long and unguessable and keep it private. Letters, digits, “_” and “-”, \
        up to 64 characters.

        NapCat posts to that topic only when this Mac starts sleeping while a Claude Code \
        task is still running (Lid alert) and, if Session alerts is on, when a Claude Code \
        session finishes or stops to wait for you. It never sends anything else, and never \
        any of your Claude conversation.
        """

    /// Raw, UNVALIDATED text from one pass of the ntfy settings editor. It
    /// exists so the editor can hand its two fields back for validation without
    /// anything being committed first.
    private struct LidAlertSettingsEntry {
        let topic: String
        let server: String
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

/// The panel's hosting view: keeps its frame equal to the SwiftUI content's
/// fitting size, so the OPEN menu grows and shrinks with the content
/// (2026-10-18 redesign — PLAN.md "UI Redesign — Menu Panel").
///
/// Why this works: NSMenu follows a view-based item's frame live — "A menu
/// will resize itself as its containing views change frame size. Changes to
/// the view's frame during tracking are reflected immediately in the menu."
/// (NSMenuItem.h). The menu stays anchored at the status item and grows
/// downward.
///
/// Why HERE, in `layout()`: prototyped in a real popped-up NSMenu, re-fitting
/// right after the state change — synchronously, one runloop turn later, or in
/// SwiftUI's `onChange` — read a STALE `fittingSize` (SwiftUI applies the change
/// in a later pass), clipping on expand and leaving dead space on collapse, or
/// left one pass with the content taller than the menu. Re-fitting in the first
/// layout pass that sees the new content matched content, frame and menu window
/// in that same pass, before display. This also covers captions that appear
/// while the menu is open (async outcomes), which a measure-once frame clipped.
///
/// No animation: height changes snap. Animating content inside a menu window
/// that resizes in one step either flashes dead space (expand) or clips the
/// fade (collapse).
final class MenuPanelHostingView<Content: View>: NSHostingView<Content> {
    private var isRefitting = false

    override func layout() {
        super.layout()
        refitToContent()
    }

    /// Sets the frame to `fittingSize` when it differs by more than half a
    /// point. Re-entrancy guarded: the frame change itself triggers layout.
    func refitToContent() {
        guard !isRefitting else { return }
        let fitting = fittingSize
        guard abs(fitting.height - frame.height) > 0.5 || abs(fitting.width - frame.width) > 0.5 else { return }
        isRefitting = true
        setFrameSize(fitting)
        isRefitting = false
    }
}
