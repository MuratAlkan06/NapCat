import ServiceManagement
import SwiftUI

// MARK: - Panel presentation types (UI redesign, 2026-10-18 — PLAN.md
// "UI Redesign — Menu Panel"; design frozen the same day on one layout)

/// How loud a panel line is. Decided ONLY by the pure mappings below — the
/// view never classifies a string as a warning. Anything above `.nominal`
/// renders with an icon AND text (never color alone).
enum PanelSeverity: Int, Comparable, CaseIterable, Sendable {
    case nominal, info, warning, error

    static func < (lhs: PanelSeverity, rhs: PanelSeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One rendered status line plus its severity.
struct PanelLine: Equatable, Sendable {
    let text: String
    let severity: PanelSeverity
}

/// Where a line renders. See `MenuStateModel.placement(ofDetailsLine:)`.
enum PanelTier: Equatable, Sendable {
    case topLevel
    case details
}

/// Every SF Symbol name the panel uses, in one place so a unit test can prove
/// each resolves on this macOS (a missing symbol renders as nothing at all).
enum PanelSymbol {
    static let stayAwake = "cup.and.saucer"
    /// The icon-only Lock Screen button (2026-10-21 declutter), in the
    /// battery header's top-right corner since 2026-10-22 — no longer a
    /// leading-column row symbol.
    static let lockScreen = "lock.display"
    static let chargeLimit = "battery.75percent"
    static let lidAlert = "bell"
    /// Track C (finish + waiting pushes): a finish flag, distinct from the
    /// lid alert's bell.
    static let sessionAlerts = "flag.checkered"
    static let disclosure = "chevron.right"
    static let desktop = "desktopcomputer"
    static let charging = "bolt.fill"
    static let battery = "battery.100"
    static let info = "info.circle"
    static let warning = "exclamationmark.triangle.fill"
    static let error = "xmark.octagon.fill"
    /// After "Sent" on the test-send button once ntfy accepted it (#67).
    static let sent = "checkmark"
    /// The footer's Settings gear (slice W, issue #78).
    static let settings = "gearshape"

    static let all = [stayAwake, lockScreen, chargeLimit, lidAlert, sessionAlerts, disclosure,
                      desktop, charging, battery, info, warning, error, sent, settings]
}

/// The test-send button's phase (#67): transient view state owned by
/// `SendFeedbackButton` and moved ONLY by `MenuStateModel.testSendPhase(_:on:)`.
enum TestSendPhase: CaseIterable, Equatable, Sendable {
    case idle, sending, sent
}

/// What moves the test-send button.
enum TestSendEvent: Equatable, Sendable {
    case tapped
    /// The lid lane recorded a send outcome (`lidGuardLastOutcomeAt` moved).
    case outcome(MessageSendOutcome?)
    /// `PanelMotion.sentRevert` elapsed.
    case revertElapsed
}

/// What the test-send button renders in one phase.
struct TestSendButtonPresentation: Equatable, Sendable {
    let title: String
    /// Drawn after the title; nil except on success.
    let symbol: String?
    let enabled: Bool
}

/// Owner ruling (e), 2026-11-20: where a flipped-ON Stay Awake switch stands
/// while pmset has not confirmed it. Moved ONLY by
/// `MenuStateModel.stayAwakeTurnOnPhase(_:on:)`, held by
/// `StayAwakeTurnOnFeedback`.
enum StayAwakeTurnOnPhase: Equatable, Sendable {
    /// Nothing pending.
    case idle
    /// Flipped ON, inside `PanelMotion.turnOnCaptionDelay`: no caption yet,
    /// so a fast confirm never flashes one.
    case waiting
    /// The hold ran out unconfirmed: the row says "Turning on…".
    case showing
}

/// What moves the Stay Awake turn-on phase.
enum StayAwakeTurnOnEvent: Equatable, Sendable {
    /// The user flipped the switch ON. Flipping it OFF is not an event: the
    /// disable path is unchanged.
    case flippedOn
    /// `PanelMotion.turnOnCaptionDelay` elapsed since the flip.
    case holdElapsed
    /// A published observed `pmset -g` state (nil = unreadable).
    case observed(Bool?)
    /// The menu is opening: every panel session starts clean, so a failed
    /// attempt (reported by its own alert) never leaves a stale caption.
    case panelOpened
}

/// The Stay Awake turn-on feedback (owner ruling e): the phase plus its one
/// timer, behind an injected clock (`after`).
///
/// It is its own ObservableObject, deliberately apart from the model. The
/// switch renders the OBSERVED state (ADR §6), and any model publish
/// re-renders it, so a flip published through the model would snap the
/// switch back off before pmset confirms. Only `StayAwakeCaptionSlot`
/// observes this object, so a flip re-renders the caption slot and never the
/// switch.
@MainActor
final class StayAwakeTurnOnFeedback: ObservableObject {
    /// Runs `fire` once, `delay` seconds from now.
    typealias Clock = @MainActor (_ delay: Double, _ fire: @escaping @MainActor @Sendable () -> Void) -> Void

    /// The production clock: a main-actor task sleep. Tests inject a manual
    /// clock instead, so no test ever sleeps.
    static let taskClock: Clock = { delay, fire in
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            fire()
        }
    }

    @Published private(set) var phase = StayAwakeTurnOnPhase.idle
    private let after: Clock
    /// Identifies the live hold, so a hold left over from an earlier flip
    /// can never promote a newer one.
    private var holdID = 0

    init(after: @escaping Clock = StayAwakeTurnOnFeedback.taskClock) {
        self.after = after
    }

    /// The switch flipped ON. Starts the hold from idle only; a repeat flip
    /// while one is pending changes nothing.
    func flippedOn() {
        guard phase == .idle else { return }
        apply(.flippedOn)
        holdID &+= 1
        let id = holdID
        after(PanelMotion.turnOnCaptionDelay) { [weak self] in
            guard let self, self.holdID == id else { return }
            self.apply(.holdElapsed)
        }
    }

    func observed(_ value: Bool?) { apply(.observed(value)) }

    func panelOpened() { apply(.panelOpened) }

    /// Publishes only a real change (the model refreshes often).
    private func apply(_ event: StayAwakeTurnOnEvent) {
        let next = MenuStateModel.stayAwakeTurnOnPhase(phase, on: event)
        if next != phase { phase = next }
    }
}

/// Observable bridge between the controllers and the SwiftUI menu panel
/// (P3b rich-menu decision). Views bind to the @Published mirrors, which are
/// re-read from the controllers on every change hook and menu open — the UI
/// renders OBSERVED state, never cached intent (ADR §6).
///
/// All display logic lives in the pure `nonisolated static` mappings below
/// (unit-tested); the class itself only mirrors values and forwards actions.
@MainActor
final class MenuStateModel: ObservableObject {
    // MARK: Published mirrors

    @Published private(set) var batteryPercent: Int?
    @Published private(set) var isCharging = false
    @Published private(set) var adapterConnected = false
    @Published private(set) var hasBattery = true
    /// Observed `pmset -g` SleepDisabled; nil = unreadable.
    @Published private(set) var stayAwakeObserved: Bool?
    @Published private(set) var featureState: ChargeLimitFeatureState = .off
    @Published private(set) var limit = ChargeLimiter.defaultLimit
    @Published private(set) var limitEnabled = false
    /// SMAppService status snapshot (source of truth — PLAN.md §11); the
    /// live service is queried on menu open, never persisted to defaults.
    @Published private(set) var loginItemStatus: SMAppService.Status = .notRegistered
    /// Whether the private lock entry point resolves on this OS. Fixed for
    /// the process lifetime (resolved once at launch).
    @Published private(set) var lockScreenAvailable = false

    // Track B (READ-ONLY detection) mirrors — sampled on menu open only.
    @Published private(set) var claudeTaskInFlight = false
    @Published private(set) var claudeHoldingAwake = false
    @Published private(set) var claudeHookInstalled = false
    @Published private(set) var claudeHookEverSeen = false
    @Published private(set) var claudeHookLastSeenSeconds: Int?
    @Published private(set) var claudeDetectionPaused = false
    /// S7: the installed hook copy's version stamp (nil = absent / no stamp).
    @Published private(set) var claudeInstalledHookVersion: Int?

    // Track B / B2 (lid-close alert) mirrors. `lidGuardTopic` is a SECRET (the
    // ntfy topic is the feed's only password). It is PRIVATE since the panel
    // redesign: the views cannot even read it — they get only the never-echo
    // derivations (`lidTopicStatus`, `lidAlertTestSendAvailable`). The editor
    // reads the controller directly.
    @Published private(set) var lidGuardEnabled = false
    @Published private var lidGuardTopic = ""
    @Published private(set) var lidGuardServer = LidGuardTuning.defaultNtfyServer
    @Published private(set) var lidGuardArming: LidGuardArmingState = .off
    @Published private(set) var lidGuardLastOutcome: MessageSendOutcome?
    @Published private(set) var lidGuardLastOutcomeAt: Double?

    // Track C (session alerts: finish + waiting buzz) mirrors. The toggle is
    // the lid guard's `claudeFinishAlertEnabled`; the rest comes off the
    // finish-alert controller, which exposes no topic at all.
    @Published private(set) var finishAlertEnabled = false
    @Published private(set) var finishAlertDisplayState: FinishAlertDisplayState = .off
    @Published private(set) var finishAlertLastOutcome: MessageSendOutcome?
    @Published private(set) var finishAlertLastOutcomeAt: Double?
    @Published private(set) var finishAlertLastKind: LidGuardMessageKind?
    /// Alert healing (issue #23): healing is armed AND the session lane is
    /// OFFLINE (holding). False whenever healing is disarmed — no line then.
    @Published private(set) var sessionAlertsOffline = false
    /// Issue #34: the run floor the controller applies (clamped, live). It
    /// feeds the "Session alerts" group of the ntfy settings editor only —
    /// the panel never renders it (nothing in the Details tier).
    @Published private(set) var finishAlertMinimumRunSeconds = FinishAlertTuning.minimumRunSeconds

    // F3 stage 1 (phone transport) mirrors — the composite sender's toggle,
    // whether this build can use iCloud (probed only while the toggle is on),
    // and the last CloudKit attempt. Outcome categories only, never content.
    @Published private(set) var phoneTransportEnabled = false
    @Published private(set) var phoneTransportAvailable = false
    @Published private(set) var phoneLastOutcome: MessageSendOutcome?
    @Published private(set) var phoneLastOutcomeAt: Double?

    // Panel redesign (2026-10-18).
    /// The ONE "Details" disclosure. In-memory UI state, deliberately NOT
    /// persisted to defaults: it survives menu close/reopen for the app's
    /// lifetime (so the height is measured with the right content before the
    /// menu opens) and starts collapsed at launch. Collapsing is always safe —
    /// problems never live only in Details (the iron rule).
    @Published private(set) var detailsExpanded = false
    /// Owner ruling (e): the Stay Awake turn-on feedback. In-memory UI state,
    /// held OUTSIDE the published mirrors on purpose (see
    /// `StayAwakeTurnOnFeedback`).
    let stayAwakeTurnOn: StayAwakeTurnOnFeedback

    // MARK: Wiring

    private let power: PowerInterface
    private let sleep: SleepStateController
    private let limiter: ChargeLimiter
    private let loginItem: LoginItemController?
    private let screenLock: ScreenLockController?
    /// Non-nil only in debugBattery mode — enables the hidden debug section.
    private let simulator: DebugPowerSimulator?
    /// Non-nil outside debugBattery mode — drives the Claude detection section.
    private let detection: ClaudeActivityController?
    /// Non-nil outside debugBattery mode — drives the lid-alert controls (B2).
    private let lidGuard: LidGuardController?
    /// Non-nil outside debugBattery mode — drives the session-alerts row
    /// (Track C). Read only; arming is MenuContentView's job.
    private let finishAlert: FinishAlertController?
    /// Non-nil outside debugBattery mode — the composite sender, for the
    /// phone transport toggle and its Details line (F3 stage 1).
    private let phoneTransport: CompositeMessageSender?

    /// Stay-awake needs NSAlert flows and menu dismissal — owned by
    /// MenuContentView, reached through this hook.
    var requestStayAwakeToggle: ((Bool) -> Void)?
    var requestQuit: (() -> Void)?
    /// Lock Screen dismisses the menu and may present a failure alert —
    /// owned by MenuContentView, reached through this hook.
    var requestLockScreen: (() -> Void)?
    /// B2 actions that need AppKit flows (the topic/server modal) or an
    /// off-main command (the test send) — owned by MenuContentView.
    var requestLidGuardToggle: ((Bool) -> Void)?
    var requestLidGuardSettingsPrompt: (() -> Void)?
    var requestLidGuardTestSend: (() -> Void)?
    /// Track C: the session-alerts toggle may kick off the shared priming test
    /// send — owned by MenuContentView, like the lid toggle.
    var requestFinishAlertToggle: ((Bool) -> Void)?
    /// Track C: told after the detection pause flag flips, so the owner can
    /// re-gate the finish alert (MenuContentView).
    var onDetectionPausedChange: (() -> Void)?
    /// Slice W: the footer gear opens the Settings window — a window, so it
    /// goes through MenuContentView's dismissal gateway like ⌘, does.
    var requestOpenSettings: (() -> Void)?
    /// Slice W: Settings › Alerts' run-floor popup. MenuContentView saves it
    /// through the ntfy editor's own save path (one clamp, only when changed).
    var requestSessionAlertsFloorChange: ((Int) -> Void)?

    var debugControlsVisible: Bool { simulator != nil }
    var claudeDetectionVisible: Bool { detection != nil }
    var lidGuardVisible: Bool { lidGuard != nil }
    /// The session-alerts row needs both halves: the lid guard owns the toggle
    /// key + the shared destination/priming, the controller owns the state.
    var finishAlertVisible: Bool { lidGuard != nil && finishAlert != nil }
    /// The phone toggle lives with the alerts' delivery settings, so it needs
    /// the lid guard's Details group as well as the composite.
    var phoneTransportVisible: Bool { lidGuard != nil && phoneTransport != nil }

    init(
        power: PowerInterface,
        sleep: SleepStateController,
        limiter: ChargeLimiter,
        loginItem: LoginItemController? = nil,
        screenLock: ScreenLockController? = nil,
        simulator: DebugPowerSimulator? = nil,
        detection: ClaudeActivityController? = nil,
        lidGuard: LidGuardController? = nil,
        finishAlert: FinishAlertController? = nil,
        phoneTransport: CompositeMessageSender? = nil,
        stayAwakeTurnOn: StayAwakeTurnOnFeedback = StayAwakeTurnOnFeedback()
    ) {
        self.power = power
        self.sleep = sleep
        self.limiter = limiter
        self.loginItem = loginItem
        self.screenLock = screenLock
        self.simulator = simulator
        self.detection = detection
        self.lidGuard = lidGuard
        self.finishAlert = finishAlert
        self.phoneTransport = phoneTransport
        self.stayAwakeTurnOn = stayAwakeTurnOn
        refresh()
    }

    /// Re-reads every mirror from the controllers.
    func refresh() {
        batteryPercent = power.batteryPercent
        isCharging = power.isCharging
        adapterConnected = power.adapterConnected
        hasBattery = power.hasBattery
        stayAwakeObserved = sleep.observedSleepDisabled
        // Ruling (e): an observed ON is the turn-on's confirm.
        stayAwakeTurnOn.observed(stayAwakeObserved)
        featureState = limiter.featureState
        limit = limiter.limit
        limitEnabled = limiter.enabled
        // Cached snapshot only — MenuContentView refreshes the live status
        // on menu open (constructing the model must not query the service).
        loginItemStatus = loginItem?.status ?? .notRegistered
        lockScreenAvailable = screenLock?.isAvailable ?? false
        // Track B mirrors — the controller is re-sampled by MenuContentView
        // on menu open before this refresh runs.
        claudeTaskInFlight = detection?.taskInFlight ?? false
        claudeHoldingAwake = detection?.claudeHoldingAwake ?? false
        claudeHookInstalled = detection?.hookInstalled ?? false
        claudeHookEverSeen = detection?.hookEverSeen ?? false
        claudeHookLastSeenSeconds = detection?.lastSeenSeconds
        claudeDetectionPaused = detection?.detectionPaused ?? false
        claudeInstalledHookVersion = detection?.installedHookVersion
        // B2 mirrors — read straight off the (thread-safe) controller.
        lidGuardEnabled = lidGuard?.isEnabled ?? false
        lidGuardTopic = lidGuard?.storedTopic ?? ""
        lidGuardServer = lidGuard?.storedServer ?? LidGuardTuning.defaultNtfyServer
        lidGuardArming = lidGuard?.armingState ?? .off
        lidGuardLastOutcome = lidGuard?.lastSendOutcome
        lidGuardLastOutcomeAt = lidGuard?.lastSendOutcomeAt
        // Track C mirrors. No controller (debugBattery mode) ⇒ off, nothing
        // sent — the stored toggle alone never makes the row claim "on".
        finishAlertEnabled = finishAlert != nil && (lidGuard?.finishAlertEnabled ?? false)
        finishAlertDisplayState = finishAlert?.displayState ?? .off
        finishAlertLastOutcome = finishAlert?.lastSendOutcome
        finishAlertLastOutcomeAt = finishAlert?.lastSendOutcomeAt
        finishAlertLastKind = finishAlert?.lastSendKind
        sessionAlertsOffline = finishAlert?.connectivityOffline ?? false
        finishAlertMinimumRunSeconds = finishAlert?.minimumRunSeconds ?? FinishAlertTuning.minimumRunSeconds
        // F3 stage 1 mirrors. Stored state only — reading the snapshot never
        // checks the iCloud account and never sends.
        let phone = phoneTransport?.phoneSnapshot
        phoneTransportEnabled = phone?.enabled ?? false
        phoneTransportAvailable = phone?.available ?? false
        phoneLastOutcome = phone?.lastOutcome
        phoneLastOutcomeAt = phone?.lastOutcomeAt
    }

    // MARK: Actions (forwarded)

    /// Flipping ON starts the turn-on feedback BEFORE forwarding, so a confirm
    /// published during the forward clears it. Flipping OFF only forwards, as
    /// it always has.
    func setStayAwake(_ desired: Bool) {
        if desired { stayAwakeTurnOn.flippedOn() }
        requestStayAwakeToggle?(desired)
    }
    func lockScreen() { requestLockScreen?() }
    func openSettings() { requestOpenSettings?() }
    func setLimitEnabled(_ enabled: Bool) { limiter.setEnabled(enabled) }
    func setLimit(_ newLimit: Int) { limiter.setLimit(newLimit) }
    func quit() { requestQuit?() }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItem?.setEnabled(enabled)
        refresh()
    }

    func openLoginItemsSettings() {
        loginItem?.openSystemSettingsLoginItems()
    }

    func setSimulatedPercent(_ percent: Int) {
        simulator?.batteryPercent = min(100, max(0, percent))
    }

    func setSimulatedAdapter(_ connected: Bool) {
        simulator?.adapterConnected = connected
    }

    /// Kill switch (create/remove the DISABLED flag). NapCat writing its OWN
    /// state dir is allowed — this NEVER touches ~/.claude/settings.json.
    func setDetectionPaused(_ paused: Bool) {
        detection?.setPaused(paused)
        onDetectionPausedChange?()
        refresh()
    }

    // MARK: B2 actions (forwarded — the model never sends anything itself)

    func setLidGuardEnabled(_ enabled: Bool) { requestLidGuardToggle?(enabled) }
    func editLidGuardSettings() { requestLidGuardSettingsPrompt?() }
    func sendLidGuardTestMessage() { requestLidGuardTestSend?() }

    // MARK: Track C action (forwarded — same rule as the lid toggle)

    func setFinishAlertEnabled(_ enabled: Bool) { requestFinishAlertToggle?(enabled) }

    /// Slice W: the run floor picked in Settings › Alerts (issue #34's key).
    func setFinishAlertMinimumRunSeconds(_ seconds: Int) { requestSessionAlertsFloorChange?(seconds) }

    // MARK: F3 stage 1 action — a stored toggle; no AppKit flow, no send

    func setPhoneTransportEnabled(_ enabled: Bool) {
        phoneTransport?.setPhoneTransportEnabled(enabled)
        refresh()
    }

    // MARK: Panel-only actions (pure UI state — never dismiss the menu)

    /// The Details chevron. Purely local state: no controller, no AppKit flow,
    /// so it can never dismiss the menu. The open menu follows the new height
    /// through `MenuPanelHostingView`.
    func setDetailsExpanded(_ expanded: Bool) { detailsExpanded = expanded }

    // MARK: Panel presentation — what the panel renders (thin wrappers over
    // the pure mappings; the views compose these and never classify).

    var lockScreenStatus: PanelLine { Self.lockScreenStatus(available: lockScreenAvailable) }
    var chargeLimitCaption: PanelLine? { Self.chargeLimitCaption(for: featureState) }
    var launchAtLoginCaption: PanelLine? { Self.launchAtLoginCaption(for: loginItemStatus) }

    /// The footer disclosure's text (2026-10-21 "status-as-disclosure"): the
    /// Claude status. Without the detection stack (debugBattery mode) there is
    /// no Claude state to report, so it keeps its plain "Details" name rather
    /// than claim an "idle" nobody observed.
    var detailsLabel: PanelLine {
        guard claudeDetectionVisible else { return Self.plainDetailsLabel }
        return Self.claudeFooterLabel(inFlight: claudeTaskInFlight, paused: claudeDetectionPaused)
    }

    /// Tucked under Details › Claude detection; present only while true.
    var claudeAwakeLine: PanelLine? { Self.claudeHoldingAwakeLine(holdingAwake: claudeHoldingAwake) }

    /// A warning only while the lid alert or session alerts are switched on
    /// (H1); otherwise it tucks into Details › Claude detection.
    var hookStatus: PanelLine {
        Self.claudeHookStatus(
            installed: claudeHookInstalled,
            everSeen: claudeHookEverSeen,
            lastSeenSeconds: claudeHookLastSeenSeconds,
            lidAlertEnabled: lidGuardEnabled,
            sessionAlertsEnabled: finishAlertEnabled
        )
    }

    /// Tucked under Details › Claude detection (S7); absent when there is
    /// nothing to add to `hookStatus`.
    var hookVersionStatus: PanelLine? {
        Self.claudeHookVersionStatus(installedVersion: claudeInstalledHookVersion,
                                     expectedVersion: ClaudeBusyConstants.hookVersion,
                                     markerDirExists: claudeHookInstalled)
    }

    var lidStatus: PanelLine {
        Self.lidAlertStatus(
            for: lidGuardArming,
            lastOutcome: lidGuardLastOutcome,
            detectionPaused: claudeDetectionPaused
        )
    }

    /// Never the topic itself — only whether one is set / usable.
    var lidTopicStatus: PanelLine { Self.lidAlertTopicStatus(lidGuardTopic) }
    var lidServerStatus: PanelLine { Self.lidAlertServerStatus(lidGuardServer) }

    func lidLastSend(now: Double) -> PanelLine {
        Self.lidAlertLastSend(outcome: lidGuardLastOutcome, at: lidGuardLastOutcomeAt, now: now)
    }

    var lidAlertTestSendAvailable: Bool {
        Self.lidAlertTestSendAvailable(server: lidGuardServer, topic: lidGuardTopic)
    }

    /// The session-alerts SLOT (the caption under the Session alerts row):
    /// the alert-healing offline warning while the lane is offline, else the
    /// session status line — so offline > 429 hold > nominal.
    var finishAlertStatus: PanelLine {
        Self.sessionAlertsSlot(offline: sessionAlertsOffline, status: finishAlertStatusWithoutOffline)
    }

    /// The session status line itself, before the offline precedence. The
    /// Details badge reads this one: the offline warning has no Details home.
    private var finishAlertStatusWithoutOffline: PanelLine {
        Self.finishAlertStatus(for: finishAlertDisplayState, lastOutcome: finishAlertLastOutcome,
                               lastOutcomeAt: finishAlertLastOutcomeAt,
                               lidLastOutcome: lidGuardLastOutcome, lidLastOutcomeAt: lidGuardLastOutcomeAt)
    }

    func finishAlertLastSend(now: Double) -> PanelLine {
        Self.finishAlertLastSend(outcome: finishAlertLastOutcome, kind: finishAlertLastKind,
                                 at: finishAlertLastOutcomeAt, now: now)
    }

    /// F3 stage 1: the phone transport's Details line (nil while the toggle
    /// is off — nothing to report — or without the composite).
    func phoneAlertStatus(now: Double) -> PanelLine? {
        guard phoneTransportVisible else { return nil }
        return Self.phoneAlertLine(enabled: phoneTransportEnabled, available: phoneTransportAvailable,
                                   outcome: phoneLastOutcome, at: phoneLastOutcomeAt, now: now)
    }

    /// Badge on the collapsed "Details" row: the worst severity among the
    /// items whose home or fix lives in Details (the problems themselves are
    /// already shown at top level — the badge says where the setting is).
    /// The Claude status is NOT aggregated (2026-10-21): it is the
    /// disclosure's own text and carries its own warning there, so the badge
    /// summarises only the OTHER items — and a paused Claude never raises it,
    /// not even through its echoes: the lid line counts with the severity it
    /// would have WITHOUT the pause, and the session line's `.paused` (only
    /// ever armed-but-paused) counts as nominal. Every non-pause problem still
    /// counts (a failed send, a missing topic, a missing hook an alert
    /// needs, …).
    var detailsBadge: PanelSeverity {
        var severities = [launchAtLoginCaption?.severity ?? .nominal, lockScreenStatus.severity]
        if claudeDetectionVisible {
            severities += [hookStatus.severity, claudeAwakeLine?.severity ?? .nominal,
                           hookVersionStatus?.severity ?? .nominal]
        }
        if lidGuardVisible {
            let lidWithoutThePause = Self.lidAlertStatus(
                for: lidGuardArming, lastOutcome: lidGuardLastOutcome, detectionPaused: false)
            severities += [lidWithoutThePause.severity, lidTopicStatus.severity, lidServerStatus.severity,
                           Self.lidAlertLastSendSeverity(lidGuardLastOutcome, at: lidGuardLastOutcomeAt)]
        }
        // Session alerts share the ntfy settings + test send in Details.
        if finishAlertVisible {
            let sessionWithoutThePause = finishAlertDisplayState == .paused
                ? .nominal : finishAlertStatusWithoutOffline.severity
            severities += [sessionWithoutThePause,
                           Self.finishAlertLastSendSeverity(finishAlertLastOutcome, at: finishAlertLastOutcomeAt)]
        }
        // F3 stage 1: the phone toggle and its line live in the same group.
        if phoneTransportVisible {
            severities.append(Self.phoneAlertSeverity(enabled: phoneTransportEnabled,
                                                      available: phoneTransportAvailable,
                                                      outcome: phoneLastOutcome, at: phoneLastOutcomeAt))
        }
        return Self.detailsBadge(severities)
    }

    /// Badge on the footer's Settings gear (slice W, issue #78): the worst
    /// severity among the SETTINGS-RESIDENT lines — those whose home or fix
    /// is a pane of the Settings window — over the panes this wiring shows.
    /// Same rule as the Details badge: the problems themselves are already
    /// surfaced at top level; the badge says where their setting lives. Lines
    /// whose home is a panel row (the charge-limit caption) are not counted:
    /// the panel row is where they surface and where they are acted on.
    var settingsBadge: PanelSeverity {
        Self.detailsBadge(settingsPanes.flatMap(settingsResidentSeverities))
    }

    /// One pane's Settings-resident severities.
    func settingsResidentSeverities(_ pane: SettingsPane) -> [PanelSeverity] {
        switch pane {
        case .general:
            return Self.generalResidentSeverities(loginStatus: loginItemStatus, lockAvailable: lockScreenAvailable)
        case .alerts:
            return alertsResidentSeverities
        }
    }

    /// Alerts: everything whose fix is the pane's Destination (the ntfy
    /// editor, the test send) — the lid and session status lines, counted
    /// WITHOUT the detection pause exactly as the Details badge counts them
    /// (the footer label carries the pause), the topic and server lines —
    /// plus the History lines and the phone transport line.
    private var alertsResidentSeverities: [PanelSeverity] {
        guard lidGuardVisible else { return [] }
        let lidWithoutThePause = Self.lidAlertStatus(
            for: lidGuardArming, lastOutcome: lidGuardLastOutcome, detectionPaused: false)
        var severities = [lidWithoutThePause.severity, lidTopicStatus.severity, lidServerStatus.severity,
                          Self.lidAlertLastSendSeverity(lidGuardLastOutcome, at: lidGuardLastOutcomeAt)]
        if finishAlertVisible {
            let sessionWithoutThePause = finishAlertDisplayState == .paused
                ? .nominal : finishAlertStatusWithoutOffline.severity
            severities += [sessionWithoutThePause,
                           Self.finishAlertLastSendSeverity(finishAlertLastOutcome, at: finishAlertLastOutcomeAt)]
        }
        if phoneTransportVisible {
            severities.append(Self.phoneAlertSeverity(enabled: phoneTransportEnabled, available: phoneTransportAvailable,
                                                      outcome: phoneLastOutcome, at: phoneLastOutcomeAt))
        }
        return severities
    }

    /// General: the Launch at Login caption (approval / not found) and the
    /// Lock Screen availability line.
    nonisolated static func generalResidentSeverities(loginStatus: SMAppService.Status,
                                                      lockAvailable: Bool) -> [PanelSeverity] {
        [launchAtLoginCaption(for: loginStatus)?.severity ?? .nominal, lockScreenStatus(available: lockAvailable).severity]
    }

    // MARK: - Pure display mappings (unit-tested)

    nonisolated static func percentText(_ percent: Int?) -> String {
        percent.map { "\($0)%" } ?? "—"
    }

    /// 0…1 for the battery gauge; unknown renders empty, never a guess.
    nonisolated static func gaugeFraction(_ percent: Int?) -> Double {
        Double(min(100, max(0, percent ?? 0))) / 100
    }

    nonisolated static func batteryHeadline(hasBattery: Bool, percent: Int?) -> String {
        hasBattery ? "Battery \(percentText(percent))" : "NapCat"
    }

    nonisolated static func chargingStatusLine(
        hasBattery: Bool,
        percent: Int?,
        isCharging: Bool,
        adapterConnected: Bool
    ) -> String {
        guard hasBattery else { return "Desktop Mac — no battery" }
        if isCharging { return "Charging" }
        if adapterConnected {
            return percent == 100 ? "Fully charged" : "On AC power — not charging"
        }
        return "On battery"
    }

    /// Toggle equivalent of the P2 checkmark semantics: definite observed
    /// states render on/off; unreadable renders off WITH a caption — never a
    /// silent false state.
    nonisolated static func stayAwakeToggle(forObserved observed: Bool?) -> (isOn: Bool, caption: String?) {
        switch observed {
        case .some(true): return (true, nil)
        case .some(false): return (false, nil)
        case .none: return (false, "Sleep state could not be read")
        }
    }

    /// Lock Screen button from the OBSERVED capability of this OS: the button
    /// is live only when the private lock entry point actually resolved. When
    /// it did not, the button is disabled and the panel says so instead of
    /// failing on click — there is no alternative mechanism to fall back to
    /// (PLAN.md decision log 2026-08-13).
    nonisolated static func lockScreenPresentation(
        available: Bool
    ) -> (enabled: Bool, caption: String?) {
        available
            ? (true, nil)
            : (false, "Locking is unavailable on this version of macOS — use Apple menu › Lock Screen (⌃⌘Q).")
    }

    nonisolated static func limitLabel(limit: Int) -> String {
        limit >= 100 ? "No limit — charge to 100%" : "Pause charging at \(limit)%"
    }

    /// Launch-at-login checkbox from the OBSERVED SMAppService status —
    /// same never-guess rule as the stay-awake toggle. `.requiresApproval`
    /// renders off with guidance plus a System Settings shortcut;
    /// `.notFound` explains itself instead of failing silently.
    nonisolated static func launchAtLoginPresentation(
        for status: SMAppService.Status
    ) -> (isOn: Bool, caption: String?, showSettingsShortcut: Bool) {
        switch status {
        case .enabled:
            return (true, nil, false)
        case .notRegistered:
            return (false, nil, false)
        case .requiresApproval:
            return (false, "Waiting for approval in System Settings › General › Login Items.", true)
        case .notFound:
            return (false, "Login item not found — toggle again to re-register this copy of NapCat.", false)
        @unknown default:
            return (false, nil, false)
        }
    }

    /// Issue #58: this macOS exposes no charge-control key. A plain statement
    /// of the limitation — no error wording, no instruction to act.
    nonisolated static let chargeControlUnavailableText =
        "Charge limiting isn't available on this version of macOS."

    /// Feature-state messaging line under the charge-limit controls.
    nonisolated static func featureMessage(for state: ChargeLimitFeatureState) -> String? {
        switch state {
        case .hidden, .off:
            return nil
        case .notSupported:
            return "Charge limiting needs an Apple Silicon Mac. Stay Awake still works here."
        case .setupRequired:
            return "One-time setup needed: run “sudo ./scripts/setup.sh” in the NapCat folder, then reopen this menu."
        case .controlUnavailable:
            return chargeControlUnavailableText
        case .active:
            return "Charging normally — will pause at the limit."
        case .paused:
            return "Charging is paused at the limit."
        case .error(let message):
            return message
        }
    }

    // MARK: - Track B (Claude detection) presentation (READ-ONLY display)

    /// The Claude status as the TEXT of the footer's Details disclosure
    /// (2026-10-21 declutter, "status-as-disclosure" — it replaced the tier-1
    /// Claude row). A short FIXED vocabulary: these three strings are the only
    /// ones ever rendered there, so the footer can never be pushed out of
    /// shape by free-form text. Paused (the kill switch) wins over everything:
    /// it is a non-nominal state the user must see without opening Details,
    /// because while paused no busy marker exists and the lid alert can never
    /// fire (the 2026-10-18 root cause). Clicking the label opens Details,
    /// where the Pause toggle lives (F3).
    nonisolated static func claudeFooterLabel(inFlight: Bool, paused: Bool) -> PanelLine {
        if paused { return PanelLine(text: "Claude: paused", severity: .warning) }
        return PanelLine(text: inFlight ? "Claude: running" : "Claude: idle", severity: .nominal)
    }

    /// The disclosure's text when there is no Claude detection to report
    /// (debugBattery mode, where the detection stack is structurally absent).
    nonisolated static let plainDetailsLabel = PanelLine(text: "Details", severity: .nominal)

    /// "Claude is holding the Mac awake" left the glance tier on 2026-10-21:
    /// a nominal Details line, present ONLY while the sleep-assertion reader
    /// says so. That reader is NOT the busy signal, so this can be true while
    /// the task is idle — the line is independent of the footer label.
    nonisolated static func claudeHoldingAwakeLine(holdingAwake: Bool) -> PanelLine? {
        holdingAwake ? PanelLine(text: "Claude is holding the Mac awake", severity: .nominal) : nil
    }

    /// Explanation under the Pause toggle inside Details: pausing is legitimate
    /// but has a non-obvious consequence for the lid and session alerts.
    nonisolated static let pauseDetectionCaption =
        "Stops reading Claude busy markers. While paused the lid and session alerts cannot fire."

    /// Hook liveness with its severity: "last seen …" is nominal. A long gap
    /// is NOT flagged — it may simply mean Claude has not been used.
    ///
    /// Not installed / never seen are problems (they escape Details) ONLY
    /// while an alert that needs the hook is switched on — the lid alert or
    /// session alerts (UI audit H1, owner ruling 2026-11-19). With both off,
    /// nothing depends on the hook, so a fresh install that only wants Stay
    /// Awake must not open on a warning: the SAME text is nominal and tucks
    /// into Details › Claude detection. Neither toggle has a default, so a
    /// caller cannot silently get the quiet line.
    nonisolated static func claudeHookStatus(
        installed: Bool,
        everSeen: Bool,
        lastSeenSeconds: Int?,
        lidAlertEnabled: Bool,
        sessionAlertsEnabled: Bool
    ) -> PanelLine {
        let healthy = installed && everSeen && lastSeenSeconds != nil
        let anAlertNeedsTheHook = lidAlertEnabled || sessionAlertsEnabled
        return PanelLine(
            text: claudeHookLine(installed: installed, everSeen: everSeen, lastSeenSeconds: lastSeenSeconds),
            severity: healthy || !anAlertNeedsTheHook ? .nominal : .warning
        )
    }

    /// Hook-liveness line from the marker-dir state. Dir absent ⇒ not
    /// installed; present but the hook has never run ⇒ not seen yet; otherwise
    /// the relative time of the last marker activity.
    nonisolated static func claudeHookLine(
        installed: Bool,
        everSeen: Bool,
        lastSeenSeconds: Int?
    ) -> String {
        guard installed else {
            return "Busy hook: not installed — run install-claude-busy-hook.sh from the NapCat repository"
        }
        guard everSeen, let seconds = lastSeenSeconds else {
            return "Busy hook: not seen yet — run install-claude-busy-hook.sh from the NapCat repository"
        }
        return "Busy hook: last seen \(ClaudeActivityPolicy.relativeTime(seconds: seconds))"
    }

    /// S7 — is the INSTALLED hook copy the version this build expects? The
    /// installer copies the script once, so a checkout update leaves the old
    /// copy running until it is re-run. Equal ⇒ nominal; older ⇒ a warning
    /// naming the fix (a new Claude session is needed to load the new copy);
    /// no readable stamp while the marker dir exists ⇒ a warning (an install
    /// that predates the stamp). No stamp AND no marker dir ⇒ nil: the
    /// "not installed" hook line already says it. NEWER than this build (the
    /// checkout moved on but NapCat was not rebuilt) ⇒ info: nothing is
    /// broken, but the two halves no longer match.
    nonisolated static func claudeHookVersionStatus(
        installedVersion: Int?,
        expectedVersion: Int,
        markerDirExists: Bool
    ) -> PanelLine? {
        guard let installedVersion else {
            guard markerDirExists else { return nil }
            return PanelLine(text: "Busy hook: installed copy has no version stamp — re-run the installer",
                             severity: .warning)
        }
        if installedVersion < expectedVersion {
            return PanelLine(text: "Busy hook: installed copy is out of date — re-run "
                                + "scripts/install-claude-busy-hook.sh and open a new Claude session",
                             severity: .warning)
        }
        if installedVersion > expectedVersion {
            return PanelLine(text: "Busy hook: installed copy is newer than this NapCat — rebuild NapCat to match",
                             severity: .info)
        }
        return PanelLine(text: "Busy hook: installed copy is current", severity: .nominal)
    }

    // MARK: - Track B / B2 (lid-close alert) presentation

    /// Primary line: what the feature will do right now, and if it is not
    /// armed, the NEXT step. Modeled on `featureMessage(for:)`.
    ///
    /// Honesty downgrade: `primedAt` (hence `.armed`) survives in UserDefaults
    /// even after the feed stops working — a deleted topic, a self-hosted
    /// instance that now needs auth, a typo'd server. When the LAST send was
    /// refused or failed outright, the armed line must NOT claim "armed"; it
    /// names the fix instead. The arming logic itself is untouched; only the
    /// DISPLAYED wording changes.
    ///
    /// Second downgrade (F2, 2026-10-18): while Claude detection is PAUSED the
    /// guard is still registered and hears every sleep, but no busy marker can
    /// exist, so the gate always skips — armed+paused can NEVER fire. Plain
    /// "armed" there is what hid the five-week outage. Paused takes precedence
    /// over a failed last send because it is the stronger claim (cannot fire at
    /// all); the failed send still shows on its own line (`lidAlertLastSend`),
    /// which escapes Details as an error. `detectionPaused` has no default on
    /// purpose — a caller that forgets it must not get the dishonest line.
    nonisolated static func lidAlertStatusLine(
        for state: LidGuardArmingState,
        lastOutcome: MessageSendOutcome?,
        detectionPaused: Bool
    ) -> String {
        switch state {
        case .off:
            return "Lid alert: off"
        case .needsTopic:
            return "Lid alert: set an ntfy topic to arm it"
        case .needsTestSend:
            return "Lid alert: send the test message to check your phone gets it"
        case .armed:
            if detectionPaused {
                return "Lid alert: armed — but Claude detection is paused; alerts cannot fire"
            }
            switch lastOutcome {
            case .rejected?, .sendFailed?:
                return "Lid alert: the last message did not go out — re-run Send test message"
            default:
                return "Lid alert: armed — best-effort push if this Mac sleeps mid-task"
            }
        }
    }

    /// The status line with its severity. Off is a choice (nominal); a switched-
    /// on feature that is not armed yet, or armed but unable to fire, is a
    /// warning; armed with a failed last publish is an error.
    nonisolated static func lidAlertStatus(
        for state: LidGuardArmingState,
        lastOutcome: MessageSendOutcome?,
        detectionPaused: Bool
    ) -> PanelLine {
        let text = lidAlertStatusLine(for: state, lastOutcome: lastOutcome, detectionPaused: detectionPaused)
        let severity: PanelSeverity
        switch state {
        case .off:
            severity = .nominal
        case .needsTopic, .needsTestSend:
            severity = .warning
        case .armed:
            if detectionPaused {
                severity = .warning
            } else if case .rejected? = lastOutcome {
                severity = .error
            } else if case .sendFailed? = lastOutcome {
                severity = .error
            } else {
                severity = .nominal
            }
        }
        return PanelLine(text: text, severity: severity)
    }

    nonisolated static func lidAlertTopicStatus(_ topic: String) -> PanelLine {
        let invalid = LidGuardPolicy.validateTopic(topic) == .invalid
        return PanelLine(text: lidAlertTopicLine(topic), severity: invalid ? .warning : .nominal)
    }

    nonisolated static func lidAlertServerStatus(_ server: String) -> PanelLine {
        let invalid = LidGuardPolicy.validateServer(server) == .invalid
        return PanelLine(text: lidAlertServerLine(server), severity: invalid ? .warning : .nominal)
    }

    /// A refused or failed publish is an error; "unconfirmed" is a warning
    /// (we do not know, and it does not prime); accepted / none are nominal.
    /// Same guard as `lidAlertLastSendCaption`: no timestamp ⇒ the caption says
    /// "none", so the severity must not claim otherwise.
    nonisolated static func lidAlertLastSendSeverity(_ outcome: MessageSendOutcome?, at: Double?) -> PanelSeverity {
        guard at != nil else { return .nominal }
        switch outcome {
        case nil, .accepted?: return .nominal
        case .timedOutUnconfirmed?: return .warning
        case .rejected?, .sendFailed?: return .error
        }
    }

    nonisolated static func lidAlertLastSend(outcome: MessageSendOutcome?, at: Double?, now: Double) -> PanelLine {
        PanelLine(
            text: lidAlertLastSendCaption(outcome: outcome, at: at, now: now),
            severity: lidAlertLastSendSeverity(outcome, at: at)
        )
    }

    /// Topic row. THE TOPIC IS NEVER ECHOED: on ntfy the topic name is the only
    /// password on the feed, so a panel that anyone can screenshot must say
    /// whether one is set, not what it is. The editor is where it is visible.
    nonisolated static func lidAlertTopicLine(_ topic: String) -> String {
        switch LidGuardPolicy.validateTopic(topic) {
        case .valid:
            return "Topic: set (hidden — it is the password to your feed)"
        case .empty:
            return "Topic: none set"
        case .invalid:
            return "Topic is not usable — letters, digits, “_” and “-” only, "
                + "max \(LidGuardTuning.maxTopicLength) characters"
        }
    }

    /// Server row. The server is NOT a secret, so it is shown in full; an
    /// unusable stored value says so instead of silently falling back.
    nonisolated static func lidAlertServerLine(_ server: String) -> String {
        switch LidGuardPolicy.validateServer(server) {
        case .valid(let value):
            return "Server: \(value)"
        case .empty:
            return "Server: \(LidGuardTuning.defaultNtfyServer)"
        case .invalid:
            return "Server is not usable — it must be an https address like \(LidGuardTuning.defaultNtfyServer)"
        }
    }

    /// PERSISTENT last-send row: outcome + when. "Accepted by ntfy" is the
    /// honest ceiling — the server has the message (and holds it 12 h), but the
    /// push to the phone is asynchronous.
    nonisolated static func lidAlertLastSendCaption(
        outcome: MessageSendOutcome?,
        at: Double?,
        now: Double
    ) -> String {
        guard let outcome, let at else { return "Last message: none since NapCat started" }
        let when = ClaudeActivityPolicy.relativeTime(seconds: Int(max(0, now - at)))
        switch outcome {
        case .accepted:
            return "Last message: accepted by ntfy \(when)"
        case .rejected(let status):
            return "Last message: refused by the server \(when) (HTTP \(status)) — check the topic and server"
        case .timedOutUnconfirmed:
            return "Last message: unconfirmed \(when) — it may still have gone out"
        case .sendFailed(let detail):
            return "Last message: failed \(when) — \(detail)"
        }
    }

    /// Inline error for the ntfy settings editor, or nil when both fields can
    /// be saved as entered.
    ///
    /// HONESTY (security review 2026-09-09): the controller deliberately KEEPS
    /// the previous value when a field is `.invalid`. The modal used to discard
    /// that result, so a typo'd topic looked saved while the panel went on
    /// claiming the feature was armed against the OLD one. The editor now
    /// validates before committing and re-presents itself with this message.
    ///
    /// `.empty` is NOT an error: clearing the topic switches the feature off at
    /// the source, and clearing the server reverts to the public instance.
    nonisolated static func lidAlertSettingsError(
        topic: TopicValidation,
        server: ServerValidation
    ) -> String? {
        var problems: [String] = []
        if topic == .invalid {
            // The topic field opens masked (issue #10), so the user cannot see
            // the typo — point at the checkbox that reveals it (UI audit M3).
            problems.append("The topic can only contain letters, digits, “_” and “-”, "
                + "up to \(LidGuardTuning.maxTopicLength) characters. "
                + "Tick \(TopicFieldVisibility.checkboxTitle) to check what you typed.")
        }
        if server == .invalid {
            problems.append("The server must be an https address with no path, "
                + "like \(LidGuardTuning.defaultNtfyServer).")
        }
        guard !problems.isEmpty else { return nil }
        return (["Nothing was saved."] + problems).joined(separator: " ")
    }

    /// Standing security note: on ntfy there is no account, so the topic name
    /// is the whole access-control story. Lives in the Details tier next to
    /// "ntfy settings…" since the 2026-10-18 redesign (kept, not removed —
    /// the user has not signed off on dropping it).
    nonisolated static let lidAlertTopicSecrecyNote =
        "Anyone who knows your topic name can read — and post to — your alerts. "
        + "Pick a long, unguessable name and keep it private."

    /// The test send is offered only when there is something to publish TO.
    nonisolated static func lidAlertTestSendAvailable(server: String, topic: String) -> Bool {
        LidGuardPolicy.destination(server: server, topic: topic) != nil
    }

    /// #67: the test-send button acknowledges the tap at once. A tap moves it
    /// to `.sending`; the lid lane's NEXT recorded outcome ends that — only
    /// `.accepted` earns `.sent`, anything else goes straight back to `.idle`
    /// (the surfaced last-send line stays the one error signal); `.sent`
    /// reverts when its hold elapses. An outcome outside `.sending` (a
    /// priming send from a toggle, say) never moves the button.
    nonisolated static func testSendPhase(_ phase: TestSendPhase, on event: TestSendEvent) -> TestSendPhase {
        switch (phase, event) {
        case (_, .tapped):
            return .sending
        case (.sending, .outcome(let outcome)):
            return outcome == .accepted ? .sent : .idle
        case (.sent, .revertElapsed):
            return .idle
        default:
            return phase
        }
    }

    /// The button in each phase: "Sending…" is always disabled (no second
    /// send while one is out); idle and "Sent" follow the destination's
    /// availability.
    nonisolated static func testSendButton(phase: TestSendPhase, available: Bool) -> TestSendButtonPresentation {
        switch phase {
        case .idle:
            return TestSendButtonPresentation(title: "Send test message", symbol: nil, enabled: available)
        case .sending:
            return TestSendButtonPresentation(title: "Sending…", symbol: nil, enabled: false)
        case .sent:
            return TestSendButtonPresentation(title: "Sent", symbol: PanelSymbol.sent, enabled: available)
        }
    }

    // MARK: - Track C (session alerts: finish + waiting pushes) presentation

    /// Primary line under the "Session alerts" toggle — the lid grammar
    /// (off / set a topic / send the test message / armed / failed-send
    /// downgrade) plus the two states only the finish alert has. `.armed` here
    /// already means the marker-dir watcher is RUNNING (the controller reports
    /// `.hookNotInstalled` otherwise), and `.paused` is the F2 downgrade: on,
    /// but no busy marker can exist, so nothing can fire. A refused or failed
    /// LAST session send must not read "armed" either — it names the fix
    /// (re-run the test send; for a 429 it says alerts are being held, B-1),
    /// and a STRICTLY LATER accepted lid-lane send (that test send, or a lid
    /// alert) clears the downgrade: see
    /// `finishAlertSendDowngraded`. The Details "Last session alert" line is
    /// unaffected — it stays the truthful history.
    nonisolated static func finishAlertStatusLine(
        for state: FinishAlertDisplayState,
        lastOutcome: MessageSendOutcome?,
        lastOutcomeAt: Double?,
        lidLastOutcome: MessageSendOutcome?,
        lidLastOutcomeAt: Double?
    ) -> String {
        switch state {
        case .off:
            return "Session alerts: off"
        case .needsTopic:
            return "Session alerts: set an ntfy topic to arm them"
        case .needsTestSend:
            return "Session alerts: send the test message to check your phone gets it"
        case .paused:
            return "Session alerts: on — but Claude detection is paused; alerts cannot fire"
        case .hookNotInstalled:
            return "Session alerts: on — install the Claude busy hook first (see below)"
        case .armed:
            if finishAlertSendDowngraded(lastOutcome: lastOutcome, lastOutcomeAt: lastOutcomeAt,
                                         lidLastOutcome: lidLastOutcome, lidLastOutcomeAt: lidLastOutcomeAt) {
                if finishAlertRateLimited(lastOutcome) {
                    return "Session alerts: ntfy is rate-limiting this Mac — alerts are held and folded for a while"
                }
                return "Session alerts: the last message did not go out — re-run Send test message"
            }
            return "Session alerts: armed — a push when a Claude session finishes or waits for you"
        }
    }

    /// Alert healing (issue #23): the ONE fixed top-level warning while
    /// healing is armed and the session lane is OFFLINE. Neutral and true in
    /// both arming modes (session alerts held; lid alerts still attempted,
    /// so they may not get through).
    nonisolated static let sessionAlertsOfflineLine = PanelLine(
        text: "Offline — session alerts are held until the connection returns; lid alerts may be missed",
        severity: .warning)

    /// The session-alerts slot's precedence: offline > the status line (whose
    /// own armed branch puts the 429-hold caption above nominal).
    nonisolated static func sessionAlertsSlot(offline: Bool, status: PanelLine) -> PanelLine {
        offline ? sessionAlertsOfflineLine : status
    }

    /// B-1: the last session send was refused with HTTP 429. The controller
    /// then holds the session lane (events fold, one message when the hold
    /// ends), so the caption says so — a WARNING, not the generic error:
    /// "re-run Send test message" is the wrong advice for a rate limit (it
    /// would only burn more quota). Same recovery rule as the generic
    /// downgrade (`finishAlertSendDowngraded`).
    nonisolated static func finishAlertRateLimited(_ outcome: MessageSendOutcome?) -> Bool {
        outcome == .rejected(429)
    }

    /// The status line with its severity. Off is a choice (nominal); switched
    /// on but unable to fire (no topic, untested, paused, nothing to watch) is
    /// a warning; armed with a refused / failed last send (not yet recovered
    /// by a later accepted lid-lane send) is an error — except a 429, which is
    /// a warning: alerts are held and folded, not lost (B-1).
    nonisolated static func finishAlertStatus(
        for state: FinishAlertDisplayState,
        lastOutcome: MessageSendOutcome?,
        lastOutcomeAt: Double?,
        lidLastOutcome: MessageSendOutcome?,
        lidLastOutcomeAt: Double?
    ) -> PanelLine {
        let text = finishAlertStatusLine(for: state, lastOutcome: lastOutcome, lastOutcomeAt: lastOutcomeAt,
                                         lidLastOutcome: lidLastOutcome, lidLastOutcomeAt: lidLastOutcomeAt)
        let severity: PanelSeverity
        switch state {
        case .off:
            severity = .nominal
        case .needsTopic, .needsTestSend, .paused, .hookNotInstalled:
            severity = .warning
        case .armed:
            let downgraded = finishAlertSendDowngraded(
                lastOutcome: lastOutcome, lastOutcomeAt: lastOutcomeAt,
                lidLastOutcome: lidLastOutcome, lidLastOutcomeAt: lidLastOutcomeAt)
            if !downgraded {
                severity = .nominal
            } else {
                severity = finishAlertRateLimited(lastOutcome) ? .warning : .error
            }
        }
        return PanelLine(text: text, severity: severity)
    }

    /// The armed-line downgrade: the last SESSION send was refused or failed
    /// and has not been RECOVERED since. The caption tells the user to re-run
    /// the test send, so doing that — or any lid-lane send ntfy ACCEPTED (both
    /// lanes publish to the one shared destination) — STRICTLY LATER than the
    /// failed session send proves the path works again. Equal timestamps, an unconfirmed / refused / failed
    /// lid send, or a missing timestamp on either side never count.
    nonisolated static func finishAlertSendDowngraded(
        lastOutcome: MessageSendOutcome?,
        lastOutcomeAt: Double?,
        lidLastOutcome: MessageSendOutcome?,
        lidLastOutcomeAt: Double?
    ) -> Bool {
        switch lastOutcome {
        case .rejected?, .sendFailed?: break
        case nil, .accepted?, .timedOutUnconfirmed?: return false
        }
        guard lidLastOutcome == .accepted, let lidLastOutcomeAt, let lastOutcomeAt else { return true }
        return !(lidLastOutcomeAt > lastOutcomeAt)
    }

    /// Same mapping as `lidAlertLastSendSeverity`: refused / failed ⇒ error,
    /// unconfirmed ⇒ warning, accepted / none ⇒ nominal, and no timestamp ⇒
    /// nominal (the caption then says "none").
    nonisolated static func finishAlertLastSendSeverity(_ outcome: MessageSendOutcome?, at: Double?) -> PanelSeverity {
        guard at != nil else { return .nominal }
        switch outcome {
        case nil, .accepted?: return .nominal
        case .timedOutUnconfirmed?: return .warning
        case .rejected?, .sendFailed?: return .error
        }
    }

    nonisolated static func finishAlertLastSend(
        outcome: MessageSendOutcome?,
        kind: LidGuardMessageKind?,
        at: Double?,
        now: Double
    ) -> PanelLine {
        PanelLine(
            text: finishAlertLastSendCaption(outcome: outcome, kind: kind, at: at, now: now),
            severity: finishAlertLastSendSeverity(outcome, at: at)
        )
    }

    /// The last SESSION alert (finish or waiting buzz), in the shape of
    /// `lidAlertLastSendCaption`: outcome + when, plus which kind it was in a
    /// closed word. In-memory like the lid's — nothing until a send this run.
    nonisolated static func finishAlertLastSendCaption(
        outcome: MessageSendOutcome?,
        kind: LidGuardMessageKind?,
        at: Double?,
        now: Double
    ) -> String {
        guard let outcome, let at else { return "Last session alert: none since NapCat started" }
        let when = ClaudeActivityPolicy.relativeTime(seconds: Int(max(0, now - at))) + finishAlertKindLabel(kind)
        switch outcome {
        case .accepted:
            return "Last session alert: accepted by ntfy \(when)"
        case .rejected(let status):
            return "Last session alert: refused by the server \(when) (HTTP \(status)) — check the topic and server"
        case .timedOutUnconfirmed:
            return "Last session alert: unconfirmed \(when) — it may still have gone out"
        case .sendFailed(let detail):
            return "Last session alert: failed \(when) — \(detail)"
        }
    }

    /// Closed vocabulary: which session-alert kind went out. The lid kinds
    /// never reach this controller; they get no label.
    nonisolated static func finishAlertKindLabel(_ kind: LidGuardMessageKind?) -> String {
        switch kind {
        case .sessionFinished?: return " (finished)"
        case .needsAttention?: return " (waiting)"
        case .connectionRestored?: return " (connection restored)"
        case .lidAlert?, .test?, nil: return ""
        }
    }

    // MARK: - F3 stage 1 (phone transport) presentation

    /// The Details checkbox's title.
    nonisolated static let phoneTransportToggleTitle = "Phone alerts (beta)"

    /// Its tooltip / VoiceOver hint: what switching it on changes.
    nonisolated static let phoneTransportToggleHint =
        "Sends alerts to the NapCat iPhone app through your iCloud first; ntfy stays the fallback."

    /// The ONE phone-transport line, from a CLOSED vocabulary: the toggle,
    /// this build's entitlement, and the last CloudKit attempt's outcome
    /// category + age — never a record, a body or an address. The failure
    /// detail is one of `CloudKitMessageSender`'s fixed sentences.
    /// - off → nil (no line at all);
    /// - on in a build without the iCloud entitlement → info: it is on but
    ///   cannot work, so it escapes Details;
    /// - none yet / accepted → nominal ("accepted by iCloud" is the honest
    ///   ceiling, like "accepted by ntfy": the push to the phone is async);
    /// - unconfirmed → warning (it may have landed; ntfy was NOT used — the
    ///   double-buzz rule);
    /// - failed → warning (nothing was saved; ntfy carried the alert instead).
    nonisolated static func phoneAlertLine(
        enabled: Bool,
        available: Bool,
        outcome: MessageSendOutcome?,
        at: Double?,
        now: Double
    ) -> PanelLine? {
        guard enabled else { return nil }
        let severity = phoneAlertSeverity(enabled: enabled, available: available, outcome: outcome, at: at)
        guard available else {
            return PanelLine(text: "Phone alerts: unavailable in this build — it is not signed for iCloud, "
                                + "so alerts go to ntfy", severity: severity)
        }
        guard let outcome, let at else {
            return PanelLine(text: "Phone alert: none since NapCat started", severity: severity)
        }
        let when = ClaudeActivityPolicy.relativeTime(seconds: Int(max(0, now - at)))
        switch outcome {
        case .accepted:
            return PanelLine(text: "Phone alert: accepted by iCloud \(when)", severity: severity)
        case .timedOutUnconfirmed:
            return PanelLine(text: "Phone alert: unconfirmed \(when) — it may still reach your phone",
                             severity: severity)
        case .sendFailed(let detail):
            return PanelLine(text: "Phone alert: failed \(when) — \(detail); ntfy was used instead",
                             severity: severity)
        case .rejected:
            return PanelLine(text: "Phone alert: refused by iCloud \(when)", severity: severity)
        }
    }

    /// The line's severity alone (it does not depend on the clock), for the
    /// Details badge.
    nonisolated static func phoneAlertSeverity(
        enabled: Bool,
        available: Bool,
        outcome: MessageSendOutcome?,
        at: Double?
    ) -> PanelSeverity {
        guard enabled else { return .nominal }
        guard available else { return .info }
        guard at != nil else { return .nominal }
        switch outcome {
        case nil, .accepted?: return .nominal
        case .timedOutUnconfirmed?, .sendFailed?, .rejected?: return .warning
        }
    }

    // MARK: - Issue #34: the run-floor group of the ntfy settings editor

    /// The "Session alerts" group's title in the "ntfy settings…" editor —
    /// the same name as the panel row it configures. The group holds ONE
    /// popup of preset floors for `finishAlertMinimumRunSeconds`; it never
    /// appears in the panel itself.
    nonisolated static let sessionAlertsFloorGroupTitle = "Session alerts"

    /// The popup's leading label.
    nonisolated static let sessionAlertsFloorLabel = "Only alert for runs longer than:"

    /// The popup's VoiceOver name; its value is the selected row's text.
    nonisolated static let sessionAlertsFloorAccessibilityLabel = "Minimum run before alerting"

    /// Under the popup, small and secondary.
    nonisolated static let sessionAlertsFloorCaption = "Shorter runs finish silently."

    /// The popup's preset floors in seconds, ascending: both clamp bounds and
    /// the 60 s default (pre-selected while nothing is stored). There is no
    /// reset row — "1 minute" is the default.
    nonisolated static let sessionAlertsFloorPresets = [30, 60, 120, 300, 600]

    /// The popup's rows for a (clamped) floor: the presets, plus — only when
    /// the floor is not one of them, e.g. 90 set with `defaults write` — ONE
    /// extra row for it, in order. Opening the editor shows a stored value as
    /// it is instead of snapping it to a preset; only a Save of a different
    /// choice writes the key.
    nonisolated static func sessionAlertsFloorChoices(seconds: Int) -> [Int] {
        guard !sessionAlertsFloorPresets.contains(seconds) else { return sessionAlertsFloorPresets }
        return (sessionAlertsFloorPresets + [seconds]).sorted()
    }

    /// A floor as the popup shows it: a formatted duration, never raw seconds
    /// above 59 — "30 seconds", "1 minute", "10 minutes", "1 min 30 s". Each
    /// floor gets its own text (a popup merges rows with the same title).
    nonisolated static func sessionAlertsFloorText(seconds: Int) -> String {
        let minutes = seconds / 60
        let rest = seconds % 60
        if minutes == 0 { return rest == 1 ? "1 second" : "\(rest) seconds" }
        if rest == 0 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        return "\(minutes) min \(rest) s"
    }

    // MARK: - Panel tiers + severity (UI redesign 2026-10-18)

    /// THE IRON RULE, in one place: a line whose home is the Details
    /// disclosure stays there ONLY while it is nominal. Anything else — error,
    /// setup required, send failed, hook missing, detection paused, an armed
    /// downgrade — renders at top level. Collapsed sections may hide settings,
    /// never problems.
    nonisolated static func placement(ofDetailsLine severity: PanelSeverity) -> PanelTier {
        severity == .nominal ? .details : .topLevel
    }

    /// The collapsed Details row's badge: the worst of the given severities.
    nonisolated static func detailsBadge(_ severities: [PanelSeverity]) -> PanelSeverity {
        severities.max() ?? .nominal
    }

    /// Leading icon for a non-nominal line (icon + text, never color alone);
    /// nil for nominal lines.
    nonisolated static func severitySymbol(_ severity: PanelSeverity) -> String? {
        switch severity {
        case .nominal: return nil
        case .info: return PanelSymbol.info
        case .warning: return PanelSymbol.warning
        case .error: return PanelSymbol.error
        }
    }

    /// VoiceOver prefix — the icon is decorative, so the meaning is spoken.
    nonisolated static func severityAccessibilityPrefix(_ severity: PanelSeverity) -> String? {
        switch severity {
        case .nominal: return nil
        case .info: return "Note"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }

    /// Unreadable sleep state is a warning (never a silent "off").
    nonisolated static func stayAwakeCaption(forObserved observed: Bool?) -> PanelLine? {
        stayAwakeToggle(forObserved: observed).caption.map { PanelLine(text: $0, severity: .warning) }
    }

    /// Owner ruling (e): the transient acknowledgment under a flipped-ON
    /// switch that pmset has not confirmed within the hold.
    nonisolated static let stayAwakeTurningOnText = "Turning on…"

    /// How the turn-on phase moves. A flip starts the hold from idle; the hold
    /// elapsing unconfirmed shows the caption; an observed ON (the confirm)
    /// clears it, as does the menu opening. An observed OFF or unreadable state
    /// changes nothing: the command may still be running.
    nonisolated static func stayAwakeTurnOnPhase(_ phase: StayAwakeTurnOnPhase,
                                                 on event: StayAwakeTurnOnEvent) -> StayAwakeTurnOnPhase {
        switch (phase, event) {
        case (.idle, .flippedOn):
            return .waiting
        case (.waiting, .holdElapsed):
            return .showing
        case (_, .observed(true)), (_, .panelOpened):
            return .idle
        default:
            return phase
        }
    }

    /// The Stay Awake row's caption slot. Precedence: the unreadable-state
    /// warning, then "Turning on…" (nominal: the panel's quiet caption style,
    /// shown while the hold has run out unconfirmed), then nothing.
    nonisolated static func stayAwakeSlot(observed: Bool?, turnOn: StayAwakeTurnOnPhase) -> PanelLine? {
        if let unreadable = stayAwakeCaption(forObserved: observed) { return unreadable }
        guard turnOn == .showing, observed != true else { return nil }
        return PanelLine(text: stayAwakeTurningOnText, severity: .nominal)
    }

    /// Lock Screen availability as a Details-home line (Details › General)
    /// since the 2026-10-21 declutter made the button an icon in the footer:
    /// nominal while the lock entry point resolved; the disabled-lock
    /// explanation is a warning (the button cannot work), so it escapes
    /// Details to top level.
    nonisolated static func lockScreenStatus(available: Bool) -> PanelLine {
        if let caption = lockScreenPresentation(available: available).caption {
            return PanelLine(text: caption, severity: .warning)
        }
        return PanelLine(text: "Lock Screen: available — locks and turns the display off; the Mac keeps running",
                         severity: .nominal)
    }

    /// Charge-limit message with severity: a write/verify error is an error,
    /// missing setup is a warning, Intel (permanently unsupported) and an OS
    /// without charge-control keys (#58) are info — calm, never the error
    /// treatment; "charging normally" / "paused at the limit" are nominal.
    nonisolated static func chargeLimitCaption(for state: ChargeLimitFeatureState) -> PanelLine? {
        guard let text = featureMessage(for: state) else { return nil }
        let severity: PanelSeverity
        switch state {
        case .error: severity = .error
        case .setupRequired: severity = .warning
        case .notSupported, .controlUnavailable: severity = .info
        case .hidden, .off, .active, .paused: severity = .nominal
        }
        return PanelLine(text: text, severity: severity)
    }

    /// Compact trailing value for rows that do not show `limitLabel`.
    nonisolated static func chargeLimitValueText(limit: Int) -> String {
        limit >= 100 ? "No limit" : "\(limit)%"
    }

    /// Waiting-for-approval and not-found both need the user — warnings, so
    /// the Launch at Login row escapes Details while either is showing.
    nonisolated static func launchAtLoginCaption(for status: SMAppService.Status) -> PanelLine? {
        launchAtLoginPresentation(for: status).caption.map { PanelLine(text: $0, severity: .warning) }
    }
}
