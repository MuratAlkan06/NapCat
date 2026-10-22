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
    /// The icon-only Lock Screen button in the footer row (2026-10-21
    /// declutter) — no longer a leading-column row symbol.
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

    static let all = [stayAwake, lockScreen, chargeLimit, lidAlert, sessionAlerts, disclosure,
                      desktop, charging, battery, info, warning, error]
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

    // Panel redesign (2026-10-18).
    /// The ONE "Details" disclosure. In-memory UI state, deliberately NOT
    /// persisted to defaults: it survives menu close/reopen for the app's
    /// lifetime (so the height is measured with the right content before the
    /// menu opens) and starts collapsed at launch. Collapsing is always safe —
    /// problems never live only in Details (the iron rule).
    @Published private(set) var detailsExpanded = false

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

    var debugControlsVisible: Bool { simulator != nil }
    var claudeDetectionVisible: Bool { detection != nil }
    var lidGuardVisible: Bool { lidGuard != nil }
    /// The session-alerts row needs both halves: the lid guard owns the toggle
    /// key + the shared destination/priming, the controller owns the state.
    var finishAlertVisible: Bool { lidGuard != nil && finishAlert != nil }

    init(
        power: PowerInterface,
        sleep: SleepStateController,
        limiter: ChargeLimiter,
        loginItem: LoginItemController? = nil,
        screenLock: ScreenLockController? = nil,
        simulator: DebugPowerSimulator? = nil,
        detection: ClaudeActivityController? = nil,
        lidGuard: LidGuardController? = nil,
        finishAlert: FinishAlertController? = nil
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
    }

    // MARK: Actions (forwarded)

    func setStayAwake(_ desired: Bool) { requestStayAwakeToggle?(desired) }
    func lockScreen() { requestLockScreen?() }
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

    // MARK: Panel-only actions (pure UI state — never dismiss the menu)

    /// The Details chevron. Purely local state: no controller, no AppKit flow,
    /// so it can never dismiss the menu. The open menu follows the new height
    /// through `MenuPanelHostingView`.
    func setDetailsExpanded(_ expanded: Bool) { detailsExpanded = expanded }

    // MARK: Panel presentation — what the panel renders (thin wrappers over
    // the pure mappings; the views compose these and never classify).

    var stayAwakeCaption: PanelLine? { Self.stayAwakeCaption(forObserved: stayAwakeObserved) }
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

    var hookStatus: PanelLine {
        Self.claudeHookStatus(
            installed: claudeHookInstalled,
            everSeen: claudeHookEverSeen,
            lastSeenSeconds: claudeHookLastSeenSeconds
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

    var finishAlertStatus: PanelLine {
        Self.finishAlertStatus(for: finishAlertDisplayState, lastOutcome: finishAlertLastOutcome,
                               lastOutcomeAt: finishAlertLastOutcomeAt,
                               lidLastOutcome: lidGuardLastOutcome, lidLastOutcomeAt: lidGuardLastOutcomeAt)
    }

    func finishAlertLastSend(now: Double) -> PanelLine {
        Self.finishAlertLastSend(outcome: finishAlertLastOutcome, kind: finishAlertLastKind,
                                 at: finishAlertLastOutcomeAt, now: now)
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
    /// counts (a failed send, a missing topic, a missing hook, …).
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
            let sessionWithoutThePause = finishAlertDisplayState == .paused ? .nominal : finishAlertStatus.severity
            severities += [sessionWithoutThePause,
                           Self.finishAlertLastSendSeverity(finishAlertLastOutcome, at: finishAlertLastOutcomeAt)]
        }
        return Self.detailsBadge(severities)
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

    /// Hook liveness with its severity: not installed / never seen are
    /// problems (they escape Details); "last seen …" is nominal. A long gap is
    /// NOT flagged — it may simply mean Claude has not been used.
    nonisolated static func claudeHookStatus(installed: Bool, everSeen: Bool, lastSeenSeconds: Int?) -> PanelLine {
        let healthy = installed && everSeen && lastSeenSeconds != nil
        return PanelLine(
            text: claudeHookLine(installed: installed, everSeen: everSeen, lastSeenSeconds: lastSeenSeconds),
            severity: healthy ? .nominal : .warning
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
            return "Busy hook: not installed — run scripts/install-claude-busy-hook.sh"
        }
        guard everSeen, let seconds = lastSeenSeconds else {
            return "Busy hook: not seen yet — run scripts/install-claude-busy-hook.sh"
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
            return "Session alerts: on — waiting for the Claude hook (no marker folder to watch yet)"
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
        case .lidAlert?, .test?, nil: return ""
        }
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
    /// missing setup is a warning, Intel (permanently unsupported) is info;
    /// "charging normally" / "paused at the limit" are nominal status.
    nonisolated static func chargeLimitCaption(for state: ChargeLimitFeatureState) -> PanelLine? {
        guard let text = featureMessage(for: state) else { return nil }
        let severity: PanelSeverity
        switch state {
        case .error: severity = .error
        case .setupRequired: severity = .warning
        case .notSupported: severity = .info
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
