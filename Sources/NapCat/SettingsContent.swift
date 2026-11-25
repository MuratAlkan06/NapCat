import NapCatWire
import ServiceManagement

// MARK: - Settings window composition (Panel 2.0 slice W, issue #78)
//
// What each Settings pane shows, composed ONLY from MenuStateModel's existing
// pure mappings: the views in SettingsPanes.swift render these rows and never
// classify anything. Every function here is pure (`nonisolated static`) and
// table-tested in SettingsWindowTests; the model's thin wrappers feed them its
// published mirrors.

/// One pane of the Settings window, in toolbar order. The raw value is what
/// `DefaultsKey.settingsSelectedPane` stores.
enum SettingsPane: String, CaseIterable, Sendable {
    case general
    case alerts
    case claude

    /// The toolbar label — and the window title while the pane is showing.
    var title: String {
        switch self {
        case .general: return "General"
        case .alerts: return "Alerts"
        case .claude: return "Claude"
        }
    }

    /// The toolbar symbol (the render precedent: gearshape / bell / terminal).
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .alerts: return "bell"
        case .claude: return "terminal"
        }
    }

    /// The pane the window opens on: the stored one while it is a known pane
    /// this build shows, otherwise the first available pane. Never a guess
    /// from a junk value.
    nonisolated static func restored(stored: Any?, available: [SettingsPane]) -> SettingsPane {
        let fallback = available.first ?? .general
        guard let raw = stored as? String, let pane = SettingsPane(rawValue: raw), available.contains(pane) else {
            return fallback
        }
        return pane
    }
}

/// One row of a Settings pane (a grouped-form cell). Rows carry the strings
/// and states the mappings produced, so a table test can read a pane's whole
/// content without rendering it.
enum SettingsRow: Equatable, Sendable {
    /// The Launch at Login checkbox (OBSERVED SMAppService status), its
    /// caption while the status needs the user, and the System Settings link.
    case launchAtLogin(isOn: Bool, caption: PanelLine?, showsSettingsShortcut: Bool)
    /// The charge-limit cell: the live header ("Pause charging at 90%") with
    /// the switch, the 50–100 % slider, and the feature caption at any
    /// severity.
    case chargeLimit(header: String, isOn: Bool, switchEnabled: Bool, limit: Int, sliderEnabled: Bool,
                     caption: PanelLine?)
    /// A plain, non-interactive fact in place of a control (issue #84: the
    /// firmware-gated charge limit): an info glyph and the text, both
    /// secondary. A plain string, NOT a `PanelLine`: it carries no severity,
    /// so it never raises the gear badge and needs no panel home.
    case note(String)
    /// A status line in full, at whatever severity its mapping gave it
    /// (severity icon + text when not nominal).
    case line(PanelLine)
    /// "ntfy settings…" — the EXISTING hardened editor (masked topic, server,
    /// validation; not rewritten here) — and the test send with its shipped
    /// feedback (`SendFeedbackButton`).
    case ntfyButtons
    /// The session alerts' run-floor popup (issue #34): the stored floor, the
    /// rows it offers, and the caption under it.
    case minimumRun(label: String, seconds: Int, choices: [Int], caption: String)
    /// The phone transport checkbox (F3 stage 1) and its hint.
    case phoneAlerts(title: String, isOn: Bool, hint: String)
    /// The detection kill switch (F3, 2026-10-18) and what pausing costs.
    case pauseDetection(isOn: Bool, caption: String)
    /// Where the busy hook comes from: the full installer command, the words
    /// around it, and the note for disk-image installs.
    case hookInstall(intro: String, command: String, note: String)
    /// Issue #111: "Check for Updates…" (disabled while a check is out) and
    /// the passive caption beside it. A plain string, like `.note`: the
    /// update state is never a problem, so it carries no severity — no gear
    /// badge, no panel twin.
    case updateCheck(checking: Bool, caption: String)
    /// The automatic-check checkbox and its disclosure of what the request
    /// exposes.
    case updateAuto(isOn: Bool, disclosure: String)
    /// F4 slice S2: the remote-approvals switch (the panel row's twin; off is
    /// the kill switch), its status while on, and what it does.
    case remoteApprovals(isOn: Bool, caption: PanelLine?, hint: String)
    /// F4 slice S-PAIR-C1 (#168): the pairing's state-word-first line, the
    /// paired phone's code (selectable, monospaced, always shown while one is
    /// paired: public by design, the audit anchor) and, never paired, what
    /// pairing does.
    case pairingStatus(line: PanelLine, fingerprint: PairingFingerprint?, hint: String?)
    /// Never paired: Pair iPhone…. Paired: Pair a New iPhone… and Unpair….
    case pairingButtons(paired: Bool)
}

/// One titled group of rows.
struct SettingsSection: Equatable, Sendable {
    let title: String?
    let rows: [SettingsRow]
}

/// A whole pane: its sections, then at most one small footnote.
struct SettingsPaneContent: Equatable, Sendable {
    let sections: [SettingsSection]
    let footnote: String?
}

extension MenuStateModel {
    // MARK: Panes

    /// The panes this wiring can show, in toolbar order: Alerts only with the
    /// lid guard, Claude only with the detection stack (both absent in
    /// debugBattery mode, like their panel rows).
    nonisolated static func settingsPanes(alertsVisible: Bool, claudeVisible: Bool) -> [SettingsPane] {
        [.general] + (alertsVisible ? [.alerts] : []) + (claudeVisible ? [.claude] : [])
    }

    var settingsPanes: [SettingsPane] {
        Self.settingsPanes(alertsVisible: lidGuardVisible, claudeVisible: claudeDetectionVisible)
    }

    /// `now` dates the History lines' relative times.
    func settingsContent(for pane: SettingsPane, now: Double) -> SettingsPaneContent {
        switch pane {
        case .general: return generalPane(now: now)
        case .alerts: return alertsPane(now: now)
        case .claude: return claudePane
        }
    }

    // MARK: General

    /// `now` dates the Updates caption's "checked 2h ago".
    func generalPane(now: Double) -> SettingsPaneContent {
        Self.generalPane(loginStatus: loginItemStatus, featureState: featureState, limit: limit,
                         limitEnabled: limitEnabled, lockAvailable: lockScreenAvailable,
                         updates: updateCheckVisible ? (
                             autoEnabled: updateCheckAutoEnabled, checking: updateCheckInFlight,
                             caption: Self.updateCheckCaption(checking: updateCheckInFlight,
                                                              lastResult: updateCheckLastResult,
                                                              newer: updateKnownNewer,
                                                              lastAttempt: updateCheckLastAttempt, now: now)) : nil)
    }

    /// Startup (Launch at Login, relocated from Details › General), Charge
    /// Limit (hidden entirely without a battery — ADR §12 — with the same
    /// enable rules as the panel's controls and every feature caption; one
    /// note in place of the controls while the firmware gates charge
    /// control — #84), Lock Screen availability, and (issue #111) Updates —
    /// the check button with its caption, then the automatic-check checkbox
    /// with its disclosure — while the update check exists (nil in
    /// debugBattery mode).
    nonisolated static func generalPane(
        loginStatus: SMAppService.Status,
        featureState: ChargeLimitFeatureState,
        limit: Int,
        limitEnabled: Bool,
        lockAvailable: Bool,
        updates: (autoEnabled: Bool, checking: Bool, caption: String)? = nil
    ) -> SettingsPaneContent {
        let login = launchAtLoginPresentation(for: loginStatus)
        var sections = [SettingsSection(title: "Startup", rows: [
            .launchAtLogin(isOn: login.isOn, caption: launchAtLoginCaption(for: loginStatus),
                           showsSettingsShortcut: login.showSettingsShortcut),
        ])]
        if featureState == .controlUnavailable {
            // #84: nothing here can act, so the switch and the slider give
            // way to the one note. The saved toggle and limit stay stored for
            // when the menu-open probe sees the keys again.
            sections.append(SettingsSection(title: "Charge Limit", rows: [.note(chargeControlUnavailableText)]))
        } else if featureState != .hidden {
            let supported = featureState != .notSupported
            sections.append(SettingsSection(title: "Charge Limit", rows: [
                .chargeLimit(header: limitLabel(limit: limit), isOn: limitEnabled, switchEnabled: supported,
                             limit: limit, sliderEnabled: supported && limitEnabled,
                             caption: chargeLimitCaption(for: featureState)),
            ]))
        }
        sections.append(SettingsSection(title: "Lock Screen", rows: [.line(lockScreenStatus(available: lockAvailable))]))
        if let updates {
            sections.append(SettingsSection(title: "Updates", rows: [
                .updateCheck(checking: updates.checking, caption: updates.caption),
                .updateAuto(isOn: updates.autoEnabled, disclosure: updateCheckDisclosure),
            ]))
        }
        return SettingsPaneContent(sections: sections, footnote: nil)
    }

    // MARK: Alerts

    func alertsPane(now: Double) -> SettingsPaneContent {
        Self.alertsPane(
            server: lidServerStatus,
            topic: lidTopicStatus,
            lidLastSend: lidLastSend(now: now),
            sessionAlerts: finishAlertVisible
                ? (minimumRunSeconds: finishAlertMinimumRunSeconds, lastSend: finishAlertLastSend(now: now)) : nil,
            phone: phoneTransportVisible ? (isOn: phoneTransportEnabled, line: phoneAlertStatus(now: now)) : nil)
    }

    /// Destination (the server and topic lines — the topic NEVER echoed —
    /// then the existing ntfy editor and the test send), the session alerts'
    /// run floor, History (the last message per lane), the Phone alerts
    /// (beta) checkbox, and the topic-secrecy note as the pane's one
    /// footnote. The session and phone parts exist only while their
    /// controllers do (nil in debugBattery mode, like their panel rows).
    nonisolated static func alertsPane(
        server: PanelLine,
        topic: PanelLine,
        lidLastSend: PanelLine,
        sessionAlerts: (minimumRunSeconds: Int, lastSend: PanelLine)?,
        phone: (isOn: Bool, line: PanelLine?)?
    ) -> SettingsPaneContent {
        var sections = [SettingsSection(title: "Destination", rows: [.line(server), .line(topic), .ntfyButtons])]
        if let sessionAlerts {
            let floor = sessionAlerts.minimumRunSeconds
            sections.append(SettingsSection(title: sessionAlertsFloorGroupTitle, rows: [
                .minimumRun(label: sessionAlertsFloorLabel, seconds: floor,
                            choices: sessionAlertsFloorChoices(seconds: floor), caption: sessionAlertsFloorCaption),
            ]))
        }
        var history: [SettingsRow] = [.line(lidLastSend)]
        if let sessionAlerts { history.append(.line(sessionAlerts.lastSend)) }
        if let line = phone?.line { history.append(.line(line)) }
        sections.append(SettingsSection(title: "History", rows: history))
        if let phone {
            sections.append(SettingsSection(title: nil, rows: [
                .phoneAlerts(title: phoneTransportToggleTitle, isOn: phone.isOn, hint: phoneTransportToggleHint),
            ]))
        }
        return SettingsPaneContent(sections: sections, footnote: lidAlertTopicSecrecyNote)
    }

    // MARK: Claude

    var claudePane: SettingsPaneContent {
        Self.claudePane(status: Self.claudeFooterLabel(inFlight: claudeTaskInFlight, paused: claudeDetectionPaused),
                        hook: hookStatus, hookVersion: hookVersionStatus, awake: claudeAwakeLine,
                        paused: claudeDetectionPaused,
                        approvals: remoteApprovalsVisible
                            ? (isOn: remoteApprovalsEnabled, status: remoteApprovalsStatus,
                               policy: remoteApprovalsPolicyLine) : nil,
                        pairing: pairingPane)
    }

    /// Detection (the Claude status — the footer label's own words — the
    /// hook liveness and version lines, the holding-awake fact, then the
    /// Pause detection switch with its cost), the busy hook's installer
    /// pointer with the full command, and (F4 slice S2, while the toggle
    /// exists — not in debugBattery mode) Remote approvals: the switch with
    /// its status while on and its hint, then the channel-policy line while
    /// a reading exists — and (S-PAIR-C1, #168, while the pairing controller
    /// exists, whatever the switch says) the pairing rows: its line, with
    /// the paired code, then its buttons.
    nonisolated static func claudePane(
        status: PanelLine,
        hook: PanelLine,
        hookVersion: PanelLine?,
        awake: PanelLine?,
        paused: Bool,
        approvals: (isOn: Bool, status: PanelLine, policy: PanelLine?)? = nil,
        pairing: PairingPaneState? = nil
    ) -> SettingsPaneContent {
        var detection: [SettingsRow] = [.line(status), .line(hook)]
        if let hookVersion { detection.append(.line(hookVersion)) }
        if let awake { detection.append(.line(awake)) }
        detection.append(.pauseDetection(isOn: paused, caption: pauseDetectionCaption))
        var sections = [
            SettingsSection(title: "Detection", rows: detection),
            SettingsSection(title: "Busy hook", rows: [
                .hookInstall(intro: claudeHookInstallIntro, command: claudeHookInstallCommand,
                             note: claudeHookInstallNote),
            ]),
        ]
        if let approvals {
            var rows: [SettingsRow] = [.remoteApprovals(isOn: approvals.isOn, caption: approvals.isOn ? approvals.status : nil,
                                                        hint: remoteApprovalsHint)]
            if let policy = approvals.policy { rows.append(.line(policy)) }
            if let pairing { rows += pairingRows(pairing) }
            sections.append(SettingsSection(title: remoteApprovalsToggleTitle, rows: rows))
        }
        return SettingsPaneContent(sections: sections, footnote: nil)
    }

    // MARK: Pairing (S-PAIR-C1, #168)

    nonisolated static let pairingNotPairedLine = "Not paired — remote answers need a paired iPhone"
    nonisolated static let pairingNotPairedHint =
        "Pairing stores the iPhone's public key on this Mac. Nothing is armed by pairing, and nothing leaves this Mac."
    nonisolated static let pairingRunningLine = "Pairing — scan the code with your iPhone"
    nonisolated static let pairingRotatingLine = "Rotating — the current pairing keeps working until you confirm the new code"
    nonisolated static let pairButtonTitle = "Pair iPhone…"
    nonisolated static let pairNewButtonTitle = "Pair a New iPhone…"
    nonisolated static let unpairButtonTitle = "Unpair…"
    nonisolated static let unpairAlertTitle = "Unpair iPhone?"
    nonisolated static let unpairAlertText =
        "NapCat deletes the stored key and stops remote approvals through the kill switch. Pairing again takes about two minutes."
    nonisolated static let unpairAlertConfirm = "Unpair"
    nonisolated static let unpairAlertCancel = "Cancel"

    /// `Paired — iPhone, since Nov 24, 2026`.
    nonisolated static func pairingPairedLine(since: Date) -> String {
        "Paired — iPhone, since " + since.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// The pairing's status line: every state is nominal (never paired is
    /// the default, not a problem), so it raises no gear badge. ("Changed"
    /// is reserved: no honest signal for it exists, so it is not shown.)
    nonisolated static func pairingStatusLine(_ pane: PairingPaneState) -> PanelLine {
        switch pane {
        case .notPaired: return PanelLine(text: pairingNotPairedLine, severity: .nominal)
        case .pairing: return PanelLine(text: pairingRunningLine, severity: .nominal)
        case .paired(_, let since): return PanelLine(text: pairingPairedLine(since: since), severity: .nominal)
        case .rotating: return PanelLine(text: pairingRotatingLine, severity: .nominal)
        }
    }

    nonisolated static func pairingRows(_ pane: PairingPaneState) -> [SettingsRow] {
        switch pane {
        case .notPaired, .pairing:
            return [.pairingStatus(line: pairingStatusLine(pane), fingerprint: nil, hint: pairingNotPairedHint),
                    .pairingButtons(paired: false)]
        case .paired(let fingerprint, _), .rotating(let fingerprint, _):
            return [.pairingStatus(line: pairingStatusLine(pane), fingerprint: fingerprint, hint: nil), .pairingButtons(paired: true)]
        }
    }
}
