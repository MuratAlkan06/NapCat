import ServiceManagement
import os

/// Launch-at-login via SMAppService.mainApp (PLAN.md ADR §11 / P5).
///
/// SMAppService is the SOURCE OF TRUTH — nothing is persisted in
/// UserDefaults (a stored flag could only ever disagree with the real
/// Background Items state; the P2/P3 "render observed state, never cached
/// intent" rule applies here too).
///
/// `status` is a cached snapshot, refreshed on menu open and after every
/// register/unregister. The cache exists so that merely CONSTRUCTING this
/// controller (as unit tests building the menu do) never queries the live
/// service — tests must not touch the user's Background Items state.
@MainActor
final class LoginItemController {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "loginitem")

    /// Last observed status; `.notRegistered` until the first `refresh()`.
    private(set) var status: SMAppService.Status = .notRegistered

    /// Re-reads the live status (menu open + after mutations).
    @discardableResult
    func refresh() -> SMAppService.Status {
        status = SMAppService.mainApp.status
        return status
    }

    /// Registers/unregisters the main app as a login item, then refreshes.
    /// Errors are logged and reflected through the refreshed status — the UI
    /// renders whatever state the service actually reports.
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                Self.logger.notice("login item registered")
            } else {
                try SMAppService.mainApp.unregister()
                Self.logger.notice("login item unregistered")
            }
        } catch {
            Self.logger.error("login item \(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    /// `.requiresApproval` guidance: deep-link to System Settings › General
    /// › Login Items so the user can approve NapCat.
    func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
