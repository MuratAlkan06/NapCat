import Foundation

/// UserDefaults keys (PLAN.md §11).
enum DefaultsKey {
    /// The user's last stay-awake action through the app. NEVER used to
    /// auto-enable at launch — only to detect that a previous session ended
    /// without a clean disable, so launch reconciliation can revert (ADR §6).
    static let stayAwakeIntent = "stayAwakeIntent"
    /// One-time heat-risk warning acknowledged.
    static let heatWarningAcknowledged = "heatWarningAcknowledged"
    /// Charge limit percent (Int, 50–100 step 5, default 90; 100 = uncapped).
    static let limit = "limit"
    /// Whether the charge-limit feature is enabled.
    static let limitEnabled = "limitEnabled"
    /// Read ONCE at startup (ADR §8): true swaps the entire power interface
    /// for DebugPowerSimulator — restart the app to change modes.
    static let debugBattery = "debugBattery"
}
