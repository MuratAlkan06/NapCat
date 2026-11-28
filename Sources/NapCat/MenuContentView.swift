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
/// present).
///
/// Height (2026-10-18 redesign): the panel's height changes while the menu
/// is OPEN (a caption appearing after an async outcome). `MenuPanelHostingView` re-fits its own frame in the first
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
    /// F3 stage 1 composite sender (phone toggle + its last outcome); nil in
    /// debugBattery mode.
    private let phoneTransport: CompositeMessageSender?
    /// Issue #111 update check; nil in debugBattery mode. Checks only from a
    /// user action — see `menuWillOpen` / `settingsWindowBecameKey`.
    private let updateCheck: UpdateCheckController?
    /// F4 slice S2 remote approvals; nil in debugBattery mode. Refreshed on
    /// menu open and when Settings becomes key — never polled.
    private let remoteApprovals: RemoteApprovalsController?
    /// F4 slice S-PAIR-C1 pairing; nil wherever the toggle is. Its sheet
    /// hangs off the Settings window.
    private let pairing: PairingController?
    private let hostingView: MenuPanelHostingView<MenuPanelView>
    /// The Settings window (slice W, issue #78) — built on first use, opened
    /// by ⌘, (`showSettings(_:)`), refreshed every time it becomes key.
    private let settingsWindow: SettingsWindowController
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
        phoneTransport: CompositeMessageSender? = nil,
        updateCheck: UpdateCheckController? = nil,
        remoteApprovals: RemoteApprovalsController? = nil,
        pairing: PairingController? = nil,
        defaults: UserDefaults = .standard,
        settingsHooks: SettingsWindowHooks = .live
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
        self.phoneTransport = phoneTransport
        self.updateCheck = updateCheck
        self.remoteApprovals = remoteApprovals
        self.pairing = pairing
        self.model = MenuStateModel(
            power: power,
            sleep: sleep,
            limiter: limiter,
            loginItem: loginItem,
            screenLock: screenLock,
            simulator: simulator,
            detection: detection,
            lidGuard: lidGuard,
            finishAlert: finishAlert,
            phoneTransport: phoneTransport,
            updateCheck: updateCheck,
            remoteApprovals: remoteApprovals,
            pairing: pairing
        )
        self.menu = NSMenu()
        self.hostingView = MenuPanelHostingView(rootView: MenuPanelView(model: model))
        self.settingsWindow = SettingsWindowController(model: model, defaults: defaults, hooks: settingsHooks)
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

        // ⌘, while the menu is open (slice W): a menu item can hold one key
        // equivalent and the panel item holds ⌘Q, so ⌘, rides a HIDDEN item —
        // never drawn, its key equivalent kept live
        // (`allowsKeyEquivalentWhenHidden`; a plain hidden item takes no part
        // in key matching). Outside the menu, ⌘, comes from the main menu
        // (`AppMainMenu`); both reach `showSettings(_:)`.
        let settingsKeyItem = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsKeyItem.keyEquivalentModifierMask = .command
        settingsKeyItem.target = self
        settingsKeyItem.isHidden = true
        settingsKeyItem.allowsKeyEquivalentWhenHidden = true
        menu.addItem(settingsKeyItem)
        settingsWindow.onBecameKey = { [weak self] in self?.settingsWindowBecameKey() }

        // Observed-state pushes → published mirrors. A Stay Awake flip also
        // re-gates alert healing (Stay Awake ON is one of its arming inputs).
        sleep.onObservedStateChange = { [weak self] _ in
            self?.finishAlert?.reconcile()
            self?.model.refresh()
        }
        limiter.onChange = { [weak self] in self?.model.refresh() }

        // View actions that need AppKit flows.
        model.requestStayAwakeToggle = { [weak self] _ in self?.toggleStayAwake() }
        model.requestLockScreen = { [weak self] in self?.lockScreen() }
        model.requestQuit = { NSApp.terminate(nil) }
        model.requestLidGuardToggle = { [weak self] enabled in self?.toggleLidAlert(enabled) }
        model.requestLidGuardSettingsPrompt = { [weak self] in self?.promptForLidAlertSettings() }
        model.requestLidGuardTestSend = { [weak self] in self?.sendLidAlertTestMessage() }
        model.requestFinishAlertToggle = { [weak self] enabled in self?.toggleSessionAlerts(enabled) }
        model.requestOpenSettings = { [weak self] in self?.showSettings(nil) }
        model.requestSessionAlertsFloorChange = { [weak self] seconds in
            self?.saveSessionAlertsFloor(seconds)
            self?.model.refresh()
        }

        // The lid guard's own async events (send outcome, wake) republish
        // through the same refresh path as every other controller.
        lidGuard?.setChangeHandler { [weak self] in
            Task { @MainActor in self?.model.refresh() }
        }
        // Track C: arm/disarm and send outcomes republish the same way.
        finishAlert?.setChangeHandler { [weak self] in
            Task { @MainActor in self?.model.refresh() }
        }
        // F3 stage 1: a CloudKit attempt's outcome republishes the same way.
        phoneTransport?.setChangeHandler { [weak self] in
            Task { @MainActor in self?.model.refresh() }
        }
        // Issue #111: a check starting or finishing republishes the same way.
        updateCheck?.setChangeHandler { [weak self] in
            Task { @MainActor in self?.model.refresh() }
        }
        // F4 slice S2: a toggle transition (listening, the kill switch, a
        // new policy reading) republishes the same way.
        remoteApprovals?.setChangeHandler { [weak self] in
            Task { @MainActor in self?.model.refresh() }
        }
        // F4 slice S-PAIR-C1: the ceremony's sheet hangs off the Settings
        // window — shown as a ceremony begins, taken off as it closes; the
        // window's own close is the sheet's Cancel, and the sheet's key /
        // occlusion state hides the code (S1b). Unpair… asks first.
        if let pairing {
            pairing.onSheetChange = { [weak self] showing in
                guard let self else { return }
                if showing {
                    settingsWindow.presentSheet(PairingSheetView(pairing: pairing))
                } else {
                    settingsWindow.dismissSheet()
                }
            }
            pairing.onPaneChange = { [weak self] in self?.model.refresh() }
            pairing.announce = { PairingAnnouncer.post($0) }
            settingsWindow.onSheetVisible = { [weak pairing] in pairing?.setVisible($0) }
            settingsWindow.onWillClose = { [weak pairing] in pairing?.cancel() }
            model.requestUnpair = { [weak self] in self?.confirmUnpair() }
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
        // ntfy channel has no permission to check, and no alert is sent from
        // menu-open.
        lidGuard?.refreshArming()
        // Track C: arm or disarm the marker-dir watcher to match the config,
        // the pause flag and the dir (a re-arm takes a fresh baseline — never
        // a send).
        finishAlert?.reconcile()
        // F4: the stored toggle again, and while on a fresh policy reading
        // (and a retry of a socket that could not be opened).
        remoteApprovals?.refresh()
        // Alert healing: the menu-open reconcile is a flush trigger — an
        // OFFLINE session lane attempts its held alerts once (coalesced).
        finishAlert?.menuOpened()
        // Ruling (e): every panel session starts without a "Turning on…" —
        // a failed attempt was already reported by its own alert.
        model.stayAwakeTurnOn.panelOpened()
        // Issue #111: menu-open's ONE network exception — an opportunistic
        // update check, only while automatic checks are on and the last
        // attempt is 24 h old (UpdateCadence). It never blocks the menu: the
        // answer republishes through the change handler.
        updateCheck?.checkIfDue()
        // #205: the paired-key slot again (a keychain read, never
        // iCloud), so the Remote approvals row can say to pair first.
        pairing?.refreshPaired()
        model.refresh()
        // Section visibility (charge limit, debug) and the surfaced lines can
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

            Installed from the disk image? Clone github.com/MuratAlkan06/NapCat \
            first — the READ ME on the disk image has the exact commands.

            Then toggle Stay Awake again.
            """
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    /// Modal ntfy editor (accessory fields: masked topic + server). Saving a
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
    ///
    /// Issue #34: while session alerts exist, the editor also carries their
    /// run floor (prefilled from the model's mirror of the controller). It is
    /// saved on the same Save, after the same validation — never on Cancel,
    /// never while the editor is re-presented with an error.
    private func presentLidAlertSettingsPrompt() {
        guard let lidGuard else { return }
        var entry = LidAlertSettingsEntry(
            topic: lidGuard.storedTopic, server: lidGuard.storedServer,
            minimumRunSeconds: model.finishAlertVisible ? model.finishAlertMinimumRunSeconds : nil)
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
            // Issue #103: the topic saves to the keychain, which can refuse.
            // The controller then keeps the previous topic, so the editor
            // comes back with the reason rather than closing as if it saved.
            if lidGuard.topicSaveFailed {
                error = MenuStateModel.lidAlertTopicNotSavedError
                continue
            }
            if let seconds = entered.minimumRunSeconds {
                saveSessionAlertsFloor(seconds)
            }
            if lidGuard.armingState == .needsTestSend {
                lidGuard.sendTestMessage()
            }
            model.refresh()
            return
        }
    }

    /// Issue #34: persists the session alerts' run floor — through the
    /// policy's one clamp rule, and only when it changed, so an untouched
    /// default is never eagerly written. FinishAlertController reads the key
    /// at every marker diff: nothing to re-arm, no restart. Two callers: the
    /// editor's Save, and (slice W) Settings › Alerts' popup.
    private func saveSessionAlertsFloor(_ seconds: Int) {
        let floor = FinishAlertPolicy.minimumRunSeconds(stored: seconds)
        guard floor != model.finishAlertMinimumRunSeconds else { return }
        defaults.set(floor, forKey: DefaultsKey.finishAlertMinimumRunSeconds)
    }

    /// One pass of the two-field editor. Returns exactly what the user typed
    /// (unvalidated — the caller decides), or nil when they cancelled. `error`
    /// is rendered in the caption band above the topic field, so a rejected
    /// value comes back for correction instead of disappearing silently.
    ///
    /// Issue #42: every pass builds the SAME frame. The informative text is
    /// the explanation alone, and the band is reserved on every pass — as tall
    /// as the worst-case message wraps — so a failed Save never grows the
    /// dialog.
    private func runLidAlertSettingsEditor(
        entry: LidAlertSettingsEntry,
        error: String?
    ) -> LidAlertSettingsEntry? {
        let alert = NSAlert()
        alert.alertStyle = error == nil ? .informational : .warning
        alert.messageText = "Where should NapCat notify you?"
        alert.informativeText = Self.lidAlertSettingsExplanation
        // Issue #34: the "Session alerts" group sits UNDER the two fields
        // (bottom-up coordinates), so they move up by its height plus a gap.
        let floorGroup = entry.minimumRunSeconds.map { SessionAlertsFloorGroup(seconds: $0, width: 300) }
        let fieldsY = floorGroup.map { $0.view.frame.height + SessionAlertsFloorGroup.gapAbove } ?? 0
        // Masked by default (issue #10): the topic is the feed's password, and
        // this dialog opens wherever the screen happens to be visible.
        let topicRow = MaskedTopicRow(topic: entry.topic,
                                      fieldFrame: NSRect(x: 0, y: fieldsY + 30, width: 300, height: 24))
        let serverField = NSTextField(frame: NSRect(x: 0, y: fieldsY, width: 300, height: 24))
        serverField.stringValue = entry.server
        serverField.placeholderString = LidGuardTuning.defaultNtfyServer
        let stackWidth = max(300, topicRow.maxX, floorGroup?.view.frame.width ?? 0)
        // Issue #42: the error band, at the top of the stack. Its height is
        // MEASURED (as SessionAlertsFloorGroup measures its caption) for the
        // worst-case message — both fields invalid — at the stack width, then
        // the pass's own text goes in: empty on a nominal pass.
        let errorCaption = NSTextField(wrappingLabelWithString:
            MenuStateModel.lidAlertSettingsError(topic: .invalid, server: .invalid) ?? "")
        errorCaption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        // Contrast program (canon C11, issue #48): the error's words are in
        // the label color. systemRed text measured 3.57:1 on the light alert
        // (target 4.5:1); the meaning rides on the words ("Nothing was
        // saved. …"), never on color alone.
        errorCaption.textColor = .labelColor
        let worstCaseBounds = NSRect(x: 0, y: 0, width: stackWidth, height: .greatestFiniteMagnitude)
        let errorBandHeight = ceil(errorCaption.cell?.cellSize(forBounds: worstCaseBounds).height
                                   ?? errorCaption.fittingSize.height)
        let errorBandY = fieldsY + 54 + PanelMetrics.regular
        errorCaption.frame = NSRect(x: 0, y: errorBandY, width: stackWidth, height: errorBandHeight)
        errorCaption.stringValue = error ?? ""
        // A blank band is no element: VoiceOver must never land on an empty row.
        errorCaption.setAccessibilityElement(!errorCaption.stringValue.isEmpty)
        // Issue #103 (F-3): a pass with no error lends the band to the topic
        // row's soft hints (short topic / just generated), live as the topic
        // changes. Same reserved band, so the frame still never changes.
        if error == nil { topicRow.showsHints(in: errorCaption) }
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: stackWidth, height: errorBandY + errorBandHeight))
        stack.addSubview(errorCaption)
        topicRow.addSubviews(to: stack)
        stack.addSubview(serverField)
        if let floorGroup { stack.addSubview(floorGroup.view) }
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        // Focus: the topic (masked, as every pass opens) — unless an error
        // pass rejected only the server, which then gets it.
        let serverOnlyRejected = error != nil && LidGuardPolicy.validateTopic(entry.topic) != .invalid
        alert.window.initialFirstResponder = serverOnlyRejected ? serverField : topicRow.secureField
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        // `topicRow` stays alive through the modal run (it is read here), which
        // the checkbox needs: NSButton holds its target weakly. So does
        // `floorGroup`, its popup's target.
        return LidAlertSettingsEntry(topic: topicRow.topic, server: serverField.stringValue,
                                     minimumRunSeconds: floorGroup?.seconds)
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
    /// anything being committed first. `minimumRunSeconds` is the session
    /// alerts' run floor (issue #34) — nil while session alerts do not exist,
    /// and then the editor shows no group for it.
    private struct LidAlertSettingsEntry {
        let topic: String
        let server: String
        let minimumRunSeconds: Int?
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

    // MARK: - Settings window (slice W, issue #78)

    /// ⌘, — from the open menu's hidden item or from the main menu. A window
    /// is not a menu flow, so it goes through the one dismissal gateway like
    /// the modal flows: the menu closes first (a no-op when it is not open),
    /// then the window shows on the next runloop turn.
    @objc func showSettings(_ sender: Any?) {
        closeMenuThenPresent { [weak self] in self?.settingsWindow.show() }
    }

    /// The Settings window became key: the READ half of the menu-open
    /// reconciliation (`menuWillOpen`), so every pane renders freshly
    /// observed state — pmset, the smc helper, the limiter, the login item,
    /// Claude detection, both alerts' arming. Panel-only steps stay with the
    /// menu: the alert-healing flush trigger (a send attempt — focusing a
    /// window never sends an alert), the Stay Awake turn-on reset and the
    /// panel re-fit. The opportunistic update check (issue #111) runs here
    /// too, under the same 24 h cadence as on menu open.
    private func settingsWindowBecameKey() {
        sleep.refreshObservedState()
        power.reprobeChargeControlIfNeeded()
        limiter.evaluate(reason: "settings window")
        loginItem.refresh()
        detection?.sample()
        lidGuard?.refreshArming()
        finishAlert?.reconcile()
        remoteApprovals?.refresh()
        updateCheck?.checkIfDue()
        pairing?.refreshPaired()
        model.refresh()
    }

    /// S-PAIR-C1: Unpair always asks first. Confirmed, the slot is deleted
    /// and the remote-approvals toggle goes off through its kill switch.
    private func confirmUnpair() {
        let alert = Self.unpairAlert()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        pairing?.unpair()
        model.refresh()
    }

    /// The Unpair question. Unpair is marked destructive and answers no
    /// key, so it takes a deliberate click; Cancel keeps Esc (AppKit's rule
    /// for a button titled Cancel). Nothing is the default: a button holds
    /// one key, and making Cancel answer Return would cost it Esc.
    static func unpairAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = MenuStateModel.unpairAlertTitle
        alert.informativeText = MenuStateModel.unpairAlertText
        let unpair = alert.addButton(withTitle: MenuStateModel.unpairAlertConfirm)
        unpair.hasDestructiveAction = true
        unpair.keyEquivalent = ""
        alert.addButton(withTitle: MenuStateModel.unpairAlertCancel)
        return alert
    }
}

/// The topic row of the ntfy settings editor — the AppKit half of
/// `TopicFieldVisibility` (see there for why it is two overlaid fields). Owns
/// the masked field, its plain twin, the "Show" checkbox and (issue #103,
/// F-3) the "Generate" button, and only maps the pure state onto them.
///
/// The fields keep the editor's full 300 pt width; the checkbox and then the
/// button sit to their right. The placeholder's budget is its fitting width
/// at the system font: at most 270 pt (the 300 pt frame minus the bezel's
/// text insets and a margin), checked in TopicFieldVisibilityTests — so
/// neither a longer placeholder nor a field narrowed to make room may clip it.
@MainActor
private final class MaskedTopicRow: NSObject, NSTextFieldDelegate {
    let secureField: NSSecureTextField
    let plainField: NSTextField
    let showCheckbox: NSButton
    let generateButton: NSButton
    private var visibility = TopicFieldVisibility.initial
    /// What Generate last produced, so the hint can tell it from typed text.
    private var generatedTopic: String?
    /// The editor's caption band, lent to this row on a pass with no error.
    private weak var hintBand: NSTextField?

    private static let checkboxGap: CGFloat = 8

    init(topic: String, fieldFrame: NSRect) {
        secureField = NSSecureTextField(frame: fieldFrame)
        plainField = NSTextField(frame: fieldFrame)
        showCheckbox = NSButton(checkboxWithTitle: TopicFieldVisibility.checkboxTitle, target: nil, action: nil)
        generateButton = NSButton(title: TopicFieldVisibility.generateButtonTitle, target: nil, action: nil)
        super.init()
        // Only the masked field is prefilled: the plain twin holds the topic only
        // while it is the visible field (each toggle blanks the one it hides).
        secureField.stringValue = topic
        // A secure field with no content type is inferred as a password field,
        // and the system offers saved logins when it gains focus — it does, on
        // open. The topic is not an account password: a picked login would hide
        // behind the mask, pass the topic grammar, and be saved and sent.
        // `.newPassword` stops saved-credential offers but on its own may add
        // "Suggest Strong Password"; completion off is what suppresses that (DTS
        // says it "should" — not verified live). Source: Apple DTS, developer
        // forums thread 821395 (macOS 26.3), not the AppKit reference — re-verify
        // on new OS releases.
        secureField.contentType = .newPassword
        secureField.isAutomaticTextCompletionEnabled = false
        plainField.isAutomaticTextCompletionEnabled = false
        for field in [secureField, plainField] {
            // Deliberately NOT a paste-ready value (see the constant).
            field.placeholderString = TopicFieldVisibility.fieldPlaceholder
            field.setAccessibilityLabel(TopicFieldVisibility.fieldAccessibilityLabel)
            field.delegate = self   // live hints (controlTextDidChange)
        }
        showCheckbox.target = self
        showCheckbox.action = #selector(toggleVisibility(_:))
        showCheckbox.setAccessibilityLabel(TopicFieldVisibility.checkboxAccessibilityLabel)
        showCheckbox.sizeToFit()
        // Right of the field, its title on the same baseline as the field's text.
        let baseline = fieldFrame.maxY - secureField.firstBaselineOffsetFromTop
        showCheckbox.setFrameOrigin(NSPoint(
            x: fieldFrame.maxX + Self.checkboxGap,
            y: baseline + showCheckbox.firstBaselineOffsetFromTop - showCheckbox.frame.height
        ))
        generateButton.target = self
        generateButton.action = #selector(generateTopic(_:))
        generateButton.setAccessibilityLabel(TopicFieldVisibility.generateAccessibilityLabel)
        generateButton.sizeToFit()
        // Right of the checkbox, its title on the same baseline again.
        generateButton.setFrameOrigin(NSPoint(
            x: showCheckbox.frame.maxX + Self.checkboxGap,
            y: baseline + generateButton.firstBaselineOffsetFromTop - generateButton.frame.height
        ))
        apply()
    }

    /// Right edge of the row, so the accessory view grows only as far as needed.
    var maxX: CGFloat { generateButton.frame.maxX }

    /// The topic as Save returns it: the visible field's text, untouched.
    var topic: String {
        visibility.visibleText(secure: secureField.stringValue, plain: plainField.stringValue)
    }

    func addSubviews(to container: NSView) {
        container.addSubview(secureField)
        container.addSubview(plainField)
        container.addSubview(showCheckbox)
        container.addSubview(generateButton)
    }

    /// Lends this row the editor's caption band for its soft hints, and shows
    /// the hint for what the field holds right now (a short stored topic is
    /// flagged as soon as the editor opens).
    func showsHints(in band: NSTextField) {
        hintBand = band
        updateHint()
    }

    func controlTextDidChange(_ notification: Notification) {
        updateHint()
    }

    /// Fills the VISIBLE field with a fresh random topic (the hidden twin
    /// stays blank) and leaves the mask as the user set it: ticking Show is
    /// how they read it out to their phone.
    @objc private func generateTopic(_ sender: NSButton) {
        guard let generated = NtfyTopicGenerator.generate() else {
            NSSound.beep()
            return
        }
        generatedTopic = generated
        let shown: NSTextField = visibility.isRevealed ? plainField : secureField
        shown.stringValue = generated
        if shown.window?.makeFirstResponder(shown) == true, let editor = shown.currentEditor() {
            editor.selectedRange = NSRange(location: generated.utf16.count, length: 0)
        }
        updateHint()
    }

    private func updateHint() {
        guard let hintBand else { return }
        hintBand.stringValue = MenuStateModel.lidAlertTopicHint(topic, generated: generatedTopic) ?? ""
        hintBand.setAccessibilityElement(!hintBand.stringValue.isEmpty)
    }

    @objc private func toggleVisibility(_ sender: NSButton) {
        let text = topic   // read BEFORE the flip; includes an edit still in progress
        visibility = visibility.toggled()
        let shown: NSTextField = visibility.isRevealed ? plainField : secureField
        let hidden: NSTextField = visibility.isRevealed ? secureField : plainField
        shown.stringValue = text
        shown.isHidden = false
        // Focus moves BEFORE the old field hides (hiding the first responder
        // would first hop focus to its next key view) and lands with the caret
        // at the END — makeFirstResponder selects all, and one stray keystroke
        // would then replace the whole topic.
        if shown.window?.makeFirstResponder(shown) == true, let editor = shown.currentEditor() {
            editor.selectedRange = NSRange(location: text.utf16.count, length: 0)
        }
        apply()
        // Blanked LAST — after it lost focus and was hidden, so no end-of-editing
        // commit can refill it: a hidden field never keeps a copy of the topic.
        hidden.stringValue = ""
    }

    private func apply() {
        secureField.isHidden = visibility.secureFieldHidden
        plainField.isHidden = visibility.plainFieldHidden
        showCheckbox.state = visibility.checkboxState
    }
}

/// Issue #34: the "Session alerts" group of the ntfy settings editor — ONE
/// popup of preset floors for the session alerts' run floor
/// (`finishAlertMinimumRunSeconds`), every row "Immediately" (issue #242) or
/// a formatted duration (`MenuStateModel.sessionAlertsFloorText`). A stored
/// floor that is not a preset gets one extra row of its own, selected, so
/// merely opening the editor never changes it. It never sees the topic.
///
/// Its own view, laid out bottom-up (AppKit's default coordinates) and at
/// least the editor's field width: the caption, then the control row (the
/// label, then the popup, on one baseline), then the group title — small,
/// semibold, secondary, like the panel's group headers. The row
/// widens the group rather than truncate either half. The caption follows
/// the chosen row (issue #242), in a band as tall as the tallest caption a
/// row can show, so a choice never resizes the editor (the issue #42 rule).
/// System fonts, semantic colors and the panel's `PanelMetrics` spacing only.
@MainActor
final class SessionAlertsFloorGroup: NSObject {
    let view = NSView()
    let titleLabel = NSTextField(labelWithString: MenuStateModel.sessionAlertsFloorGroupTitle)
    let rowLabel = NSTextField(labelWithString: MenuStateModel.sessionAlertsFloorLabel)
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Its text is the chosen row's (`show()`).
    let caption = NSTextField(wrappingLabelWithString: "")

    /// The gap between the editor's server field and this group's title —
    /// the panel's spacing between feature blocks.
    static let gapAbove = PanelMetrics.loose

    /// `seconds` is clamped by the policy's one rule, like every read; each
    /// row's tag is its floor in seconds.
    init(seconds: Int, width: CGFloat) {
        super.init()
        let floor = FinishAlertPolicy.minimumRunSeconds(stored: seconds)
        for choice in MenuStateModel.sessionAlertsFloorChoices(seconds: floor) {
            popup.addItem(withTitle: MenuStateModel.sessionAlertsFloorText(seconds: choice))
            popup.lastItem?.tag = choice
        }
        popup.selectItem(withTag: floor)
        popup.target = self
        popup.action = #selector(chose(_:))
        popup.setAccessibilityLabel(MenuStateModel.sessionAlertsFloorAccessibilityLabel)

        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        layOut(width: width)
        show()
    }

    /// The floor as Save returns it: the selected row's seconds.
    var seconds: Int { popup.selectedTag() }

    /// The popup's action: keep its spoken value and the caption on the new
    /// choice.
    @objc func chose(_ sender: NSPopUpButton) {
        show()
    }

    private func show() {
        popup.setAccessibilityValue(MenuStateModel.sessionAlertsFloorText(seconds: seconds))
        caption.stringValue = MenuStateModel.sessionAlertsFloorCaption(seconds: seconds)
    }

    private func layOut(width: CGFloat) {
        // Fitting sizes (whole points): the popup's covers its widest row.
        let labelSize = rowLabel.fittingSize
        let popupSize = popup.fittingSize
        let groupWidth = max(width, labelSize.width + PanelMetrics.regular + popupSize.width)

        // The caption band: MEASURED for every row's caption at the group's
        // width, the tallest kept (`show()` then puts the chosen one in).
        let unbounded = NSRect(x: 0, y: 0, width: groupWidth, height: .greatestFiniteMagnitude)
        var captionHeight: CGFloat = 0
        for item in popup.itemArray {
            caption.stringValue = MenuStateModel.sessionAlertsFloorCaption(seconds: item.tag)
            let height = ceil(caption.cell?.cellSize(forBounds: unbounded).height ?? caption.fittingSize.height)
            captionHeight = max(captionHeight, height)
        }
        caption.frame = NSRect(x: 0, y: 0, width: groupWidth, height: captionHeight)

        let rowY = captionHeight + PanelMetrics.tight
        popup.frame = NSRect(origin: NSPoint(x: labelSize.width + PanelMetrics.regular, y: rowY), size: popupSize)
        // The label's text on the popup title's baseline.
        let baseline = popup.frame.maxY - popup.firstBaselineOffsetFromTop
        rowLabel.frame = NSRect(
            origin: NSPoint(x: 0, y: baseline + rowLabel.firstBaselineOffsetFromTop - labelSize.height),
            size: labelSize
        )

        let titleHeight = titleLabel.fittingSize.height
        titleLabel.frame = NSRect(x: 0, y: popup.frame.maxY + PanelMetrics.tight, width: groupWidth, height: titleHeight)
        view.frame = NSRect(x: 0, y: 0, width: groupWidth, height: titleLabel.frame.maxY)
        for subview in [caption, rowLabel, popup, titleLabel] {
            view.addSubview(subview)
        }
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
