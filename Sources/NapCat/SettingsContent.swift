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

    /// The toolbar label — and the window title while the pane is showing.
    var title: String {
        switch self {
        case .general: return "General"
        }
    }

    /// The toolbar symbol (the render precedent: gearshape / bell / terminal).
    var symbol: String {
        switch self {
        case .general: return "gearshape"
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

    /// The panes this wiring can show, in toolbar order.
    nonisolated static func settingsPanes() -> [SettingsPane] {
        [.general]
    }

    var settingsPanes: [SettingsPane] { Self.settingsPanes() }

    func settingsContent(for pane: SettingsPane) -> SettingsPaneContent {
        switch pane {
        case .general: return generalPane
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
}
