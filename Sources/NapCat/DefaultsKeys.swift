import Foundation

/// UserDefaults keys (PLAN.md §11) — the complete set; nothing else is
/// persisted. Launch-at-login is deliberately NOT stored here: SMAppService
/// is the source of truth and is queried live (P5 decision).
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

    // MARK: Track B / B2 — lid-close alert (the ONLY keys the feature adds;
    // cooldown, budgets, and marker paths are code constants, not settings).

    /// Whether the lid-close alert feature is switched on. Armed additionally
    /// requires a valid recipient AND a successful test send.
    static let lidGuardEnabled = "lidGuardEnabled"
    /// The user's own iMessage address (phone number or Apple ID). Validated
    /// before use; an invalid value leaves the feature inert.
    static let lidGuardRecipient = "lidGuardRecipient"
    /// Unix epoch seconds of the last SUCCESSFUL config-time test send; 0 =
    /// never primed. Priming is what proves the Automation (TCC) grant exists,
    /// so the first send is never the lid-close one.
    static let lidGuardPrimedAt = "lidGuardPrimedAt"
}
