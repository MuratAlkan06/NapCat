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

    // Track B / B2 (lid-close alert) mirrors. `lidGuardTopic` is a SECRET (the
    // ntfy topic is the feed's only password) — it exists so the editor can be
    // prefilled, and is deliberately never rendered into a panel caption.
    @Published private(set) var lidGuardEnabled = false
    @Published private(set) var lidGuardTopic = ""
    @Published private(set) var lidGuardServer = LidGuardTuning.defaultNtfyServer
    @Published private(set) var lidGuardArming: LidGuardArmingState = .off
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
    /// B2 actions that need AppKit flows (the topic/server modal) or an
    /// off-main command (the test send) — owned by MenuContentView.
    var requestLidGuardToggle: ((Bool) -> Void)?
    var requestLidGuardSettingsPrompt: (() -> Void)?
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
        lidGuardTopic = lidGuard?.storedTopic ?? ""
        lidGuardServer = lidGuard?.storedServer ?? LidGuardTuning.defaultNtfyServer
        lidGuardArming = lidGuard?.armingState ?? .off
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
    func editLidGuardSettings() { requestLidGuardSettingsPrompt?() }
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
    /// Honesty downgrade: `primedAt` (hence `.armed`) survives in UserDefaults
    /// even after the feed stops working — a deleted topic, a self-hosted
    /// instance that now needs auth, a typo'd server. When the LAST send was
    /// refused or failed outright, the armed line must NOT claim "armed"; it
    /// names the fix instead. The arming logic itself is untouched; only the
    /// DISPLAYED wording changes.
    nonisolated static func lidAlertStatusLine(
        for state: LidGuardArmingState,
        lastOutcome: MessageSendOutcome?
    ) -> String {
        switch state {
        case .off:
            return "Lid alert: off"
        case .needsTopic:
            return "Lid alert: set an ntfy topic to arm it"
        case .needsTestSend:
            return "Lid alert: send the test message to check your phone gets it"
        case .armed:
            switch lastOutcome {
            case .rejected?, .sendFailed?:
                return "Lid alert: the last message did not go out — re-run Send test message"
            default:
                return "Lid alert: armed — best-effort push if this Mac sleeps mid-task"
            }
        }
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
            problems.append("The topic can only contain letters, digits, “_” and “-”, "
                + "up to \(LidGuardTuning.maxTopicLength) characters.")
        }
        if server == .invalid {
            problems.append("The server must be an https address with no path, "
                + "like \(LidGuardTuning.defaultNtfyServer).")
        }
        guard !problems.isEmpty else { return nil }
        return (["Nothing was saved."] + problems).joined(separator: " ")
    }

    /// Standing security note: on ntfy there is no account, so the topic name
    /// is the whole access-control story. Always visible in the section.
    nonisolated static let lidAlertTopicSecrecyNote =
        "Anyone who knows your topic name can read — and post to — your alerts. "
        + "Pick a long, unguessable name and keep it private."

    /// The test send is offered only when there is something to publish TO.
    nonisolated static func lidAlertTestSendAvailable(server: String, topic: String) -> Bool {
        LidGuardPolicy.destination(server: server, topic: topic) != nil
    }
}
