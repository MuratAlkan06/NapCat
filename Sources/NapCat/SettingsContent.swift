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

    /// The toolbar label — and the window title while the pane is showing.
    var title: String {
        switch self {
        case .general: return "General"
        case .alerts: return "Alerts"
        }
    }

    /// The toolbar symbol (the render precedent: gearshape / bell / terminal).
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .alerts: return "bell"
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
    /// lid guard (absent in debugBattery mode, like its panel rows).
    nonisolated static func settingsPanes(alertsVisible: Bool) -> [SettingsPane] {
        [.general] + (alertsVisible ? [.alerts] : [])
    }

    var settingsPanes: [SettingsPane] { Self.settingsPanes(alertsVisible: lidGuardVisible) }

    /// `now` dates the History lines' relative times.
    func settingsContent(for pane: SettingsPane, now: Double) -> SettingsPaneContent {
        switch pane {
        case .general: return generalPane
        case .alerts: return alertsPane(now: now)
        }
    }

    // MARK: General

    var generalPane: SettingsPaneContent {
        Self.generalPane(loginStatus: loginItemStatus, featureState: featureState, limit: limit,
                         limitEnabled: limitEnabled, lockAvailable: lockScreenAvailable)
    }

    /// Startup (Launch at Login, relocated from Details › General), Charge
    /// Limit (hidden entirely without a battery — ADR §12 — with the same
    /// enable rules as the panel's controls and every feature caption), and
    /// Lock Screen availability.
    nonisolated static func generalPane(
        loginStatus: SMAppService.Status,
        featureState: ChargeLimitFeatureState,
        limit: Int,
        limitEnabled: Bool,
        lockAvailable: Bool
    ) -> SettingsPaneContent {
        let login = launchAtLoginPresentation(for: loginStatus)
        var sections = [SettingsSection(title: "Startup", rows: [
            .launchAtLogin(isOn: login.isOn, caption: launchAtLoginCaption(for: loginStatus),
                           showsSettingsShortcut: login.showSettingsShortcut),
        ])]
        if featureState != .hidden {
            let supported = featureState != .notSupported
            sections.append(SettingsSection(title: "Charge Limit", rows: [
                .chargeLimit(header: limitLabel(limit: limit), isOn: limitEnabled, switchEnabled: supported,
                             limit: limit, sliderEnabled: supported && limitEnabled,
                             caption: chargeLimitCaption(for: featureState)),
            ]))
        }
        sections.append(SettingsSection(title: "Lock Screen", rows: [.line(lockScreenStatus(available: lockAvailable))]))
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
}
