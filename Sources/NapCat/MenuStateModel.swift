import ServiceManagement
import SwiftUI

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

    // Track B (READ-ONLY detection) mirrors — sampled on menu open only.
    @Published private(set) var claudeTaskInFlight = false
    @Published private(set) var claudeHoldingAwake = false
    @Published private(set) var claudeHookInstalled = false
    @Published private(set) var claudeHookEverSeen = false
    @Published private(set) var claudeHookLastSeenSeconds: Int?
    @Published private(set) var claudeDetectionPaused = false

    // Track B / B2 (lid-close alert) mirrors.
    @Published private(set) var lidGuardEnabled = false
    @Published private(set) var lidGuardRecipient = ""
    @Published private(set) var lidGuardArming: LidGuardArmingState = .off
    @Published private(set) var lidGuardAutomation: AutomationPermission?
    @Published private(set) var lidGuardLastOutcome: MessageSendOutcome?
    @Published private(set) var lidGuardLastOutcomeAt: Double?

    // MARK: Wiring

    private let power: PowerInterface
    private let sleep: SleepStateController
    private let limiter: ChargeLimiter
    private let loginItem: LoginItemController?
    /// Non-nil only in debugBattery mode — enables the hidden debug section.
    private let simulator: DebugPowerSimulator?
    /// Non-nil outside debugBattery mode — drives the Claude detection section.
    private let detection: ClaudeActivityController?
    /// Non-nil outside debugBattery mode — drives the lid-alert controls (B2).
    private let lidGuard: LidGuardController?

    /// Stay-awake needs NSAlert flows and menu dismissal — owned by
    /// MenuContentView, reached through this hook.
    var requestStayAwakeToggle: ((Bool) -> Void)?
    var requestQuit: (() -> Void)?
    /// B2 actions that need AppKit flows (the recipient modal) or a privileged-
    /// free but off-main command (the test send) — owned by MenuContentView.
    var requestLidGuardToggle: ((Bool) -> Void)?
    var requestLidGuardRecipientPrompt: (() -> Void)?
    var requestLidGuardTestSend: (() -> Void)?

    var debugControlsVisible: Bool { simulator != nil }
    var claudeDetectionVisible: Bool { detection != nil }
    var lidGuardVisible: Bool { lidGuard != nil }

    init(
        power: PowerInterface,
        sleep: SleepStateController,
        limiter: ChargeLimiter,
        loginItem: LoginItemController? = nil,
        simulator: DebugPowerSimulator? = nil,
        detection: ClaudeActivityController? = nil,
        lidGuard: LidGuardController? = nil
    ) {
        self.power = power
        self.sleep = sleep
        self.limiter = limiter
        self.loginItem = loginItem
        self.simulator = simulator
        self.detection = detection
        self.lidGuard = lidGuard
        refresh()
    }

    /// Re-reads every mirror from the controllers.
    func refresh() {
        batteryPercent = power.batteryPercent
        isCharging = power.isCharging
        adapterConnected = power.adapterConnected
        hasBattery = power.hasBattery
        stayAwakeObserved = sleep.observedSleepDisabled
        featureState = limiter.featureState
        limit = limiter.limit
        limitEnabled = limiter.enabled
        // Cached snapshot only — MenuContentView refreshes the live status
        // on menu open (constructing the model must not query the service).
        loginItemStatus = loginItem?.status ?? .notRegistered
        // Track B mirrors — the controller is re-sampled by MenuContentView
        // on menu open before this refresh runs.
        claudeTaskInFlight = detection?.taskInFlight ?? false
        claudeHoldingAwake = detection?.claudeHoldingAwake ?? false
        claudeHookInstalled = detection?.hookInstalled ?? false
        claudeHookEverSeen = detection?.hookEverSeen ?? false
        claudeHookLastSeenSeconds = detection?.lastSeenSeconds
        claudeDetectionPaused = detection?.detectionPaused ?? false
        // B2 mirrors — read straight off the (thread-safe) controller.
        lidGuardEnabled = lidGuard?.isEnabled ?? false
        lidGuardRecipient = lidGuard?.storedRecipient ?? ""
        lidGuardArming = lidGuard?.armingState ?? .off
        lidGuardAutomation = lidGuard?.automationPermission
        lidGuardLastOutcome = lidGuard?.lastSendOutcome
        lidGuardLastOutcomeAt = lidGuard?.lastSendOutcomeAt
    }

    // MARK: Actions (forwarded)

    func setStayAwake(_ desired: Bool) { requestStayAwakeToggle?(desired) }
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
        refresh()
    }

    // MARK: B2 actions (forwarded — the model never sends anything itself)

    func setLidGuardEnabled(_ enabled: Bool) { requestLidGuardToggle?(enabled) }
    func editLidGuardRecipient() { requestLidGuardRecipientPrompt?() }
    func sendLidGuardTestMessage() { requestLidGuardTestSend?() }

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

    /// Feature-state messaging line under the charge-limit controls.
    nonisolated static func featureMessage(for state: ChargeLimitFeatureState) -> String? {
        switch state {
        case .hidden, .off:
            return nil
        case .notSupported:
            return "Charge limiting needs an Apple Silicon Mac. Stay Awake still works here."
        case .setupRequired:
            return "One-time setup needed: run “sudo ./scripts/setup.sh” in the NapCat folder, then reopen this menu."
        case .active:
            return "Charging normally — will pause at the limit."
        case .paused:
            return "Charging is paused at the limit."
        case .error(let message):
            return message
        }
    }

    // MARK: - Track B (Claude detection) presentation (READ-ONLY display)

    /// Primary line: whether a Claude turn is in flight. Paused (kill switch)
    /// takes precedence over running/idle.
    nonisolated static func claudeTaskLine(inFlight: Bool, paused: Bool) -> String {
        if paused { return "Claude task: detection paused" }
        return inFlight ? "Claude task: running" : "Claude task: idle"
    }

    /// Secondary line from the sleep-assertion reader (NOT the busy signal).
    nonisolated static func claudeAwakeLine(holding: Bool) -> String {
        "Keeping Mac awake: \(holding ? "yes" : "no")"
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
            return "Busy hook: not installed — run scripts/install-claude-busy-hook.sh"
        }
        guard everSeen, let seconds = lastSeenSeconds else {
            return "Busy hook: not seen yet — run scripts/install-claude-busy-hook.sh"
        }
        return "Busy hook: last seen \(ClaudeActivityPolicy.relativeTime(seconds: seconds))"
    }

    // MARK: - Track B / B2 (lid-close alert) presentation

    /// Primary line: what the feature will do right now, and if it is not
    /// armed, the NEXT step. Modeled on `featureMessage(for:)`.
    ///
    /// Honesty downgrade: NapCat is ad-hoc signed, so every rebuild re-signs the
    /// app and revokes the Messages Automation grant while `primedAt` (hence
    /// `.armed`) survives in UserDefaults. When the last Automation probe says a
    /// send would be refused (`.denied` / `.wouldRequireConsent`), the armed
    /// line must NOT claim "armed" — it names the fix instead. The arming logic
    /// itself is untouched; only the DISPLAYED wording changes.
    nonisolated static func lidAlertStatusLine(
        for state: LidGuardArmingState,
        automation: AutomationPermission?
    ) -> String {
        switch state {
        case .off:
            return "Lid alert: off"
        case .needsRecipient:
            return "Lid alert: add your own iMessage address to arm it"
        case .needsTestSend:
            return "Lid alert: send the test message to grant Messages access"
        case .armed:
            switch automation {
            case .denied?, .wouldRequireConsent?:
                return "Lid alert: needs Messages permission — re-run Send test message"
            default:
                return "Lid alert: armed — best-effort text if this Mac sleeps mid-task"
            }
        }
    }

    /// Recipient row. An invalid stored value says so instead of silently
    /// behaving as if nothing were set.
    nonisolated static func lidAlertRecipientLine(_ recipient: String) -> String {
        switch LidGuardPolicy.validateRecipient(recipient) {
        case .valid(let value):
            return "Sends to \(value)"
        case .empty:
            return "No recipient set"
        case .invalid:
            return "Recipient is not usable — no line breaks, max \(LidGuardTuning.maxRecipientLength) characters"
        }
    }

    /// Automation (TCC) grant caption from the SILENT probe. "Messages not
    /// running" is its own answer — never rendered as ready or denied.
    nonisolated static func lidAlertAutomationCaption(_ permission: AutomationPermission?) -> String {
        switch permission {
        case .none:
            return "Messages access: not checked yet"
        case .granted:
            return "Messages access: allowed"
        case .denied:
            return "Messages access: denied — see the README (tccutil), then send the test message again"
        case .wouldRequireConsent:
            return "Messages access: not granted yet — send the test message"
        case .targetNotRunning:
            return "Messages access: unknown (Messages is not running)"
        case .unknown(let status):
            return "Messages access: unknown (status \(status))"
        }
    }

    /// PERSISTENT last-send row: outcome + when. Note "handed to Messages" is
    /// the honest ceiling — iMessage transmission is asynchronous and may
    /// complete after the Mac wakes.
    nonisolated static func lidAlertLastSendCaption(
        outcome: MessageSendOutcome?,
        at: Double?,
        now: Double
    ) -> String {
        guard let outcome, let at else { return "Last message: none since NapCat started" }
        let when = ClaudeActivityPolicy.relativeTime(seconds: Int(max(0, now - at)))
        switch outcome {
        case .handedToMessages:
            return "Last message: handed to Messages \(when)"
        case .permissionDenied:
            return "Last message: refused by Messages permission \(when)"
        case .timedOutUnconfirmed:
            return "Last message: unconfirmed \(when) — it may still have gone out"
        case .sendFailed(let detail):
            return "Last message: failed \(when) — \(detail)"
        }
    }

    /// Ad-hoc signature churn: every `make` re-signs the app, which usually
    /// revokes the Automation grant. Always visible in the section.
    nonisolated static let lidAlertRebuildNote =
        "Updating NapCat re-signs the app and usually revokes Messages access — send the test message again after an update."

    /// The test send is offered only when there is something to send TO.
    nonisolated static func lidAlertTestSendAvailable(recipient: String) -> Bool {
        LidGuardPolicy.normalizedRecipient(recipient) != nil
    }
}
