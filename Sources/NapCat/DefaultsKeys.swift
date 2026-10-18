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
    /// requires a usable ntfy topic AND a successful test send.
    static let lidGuardEnabled = "lidGuardEnabled"
    /// The user's ntfy topic — SECRET: on ntfy the topic name is the only
    /// password on the feed, so it is never logged and never rendered into a
    /// menu caption. Validated against `^[A-Za-z0-9_-]{1,64}$` before use; an
    /// invalid value leaves the feature inert.
    static let lidGuardNtfyTopic = "lidGuardNtfyTopic"
    /// The ntfy server origin (https only). Unset reads back as
    /// `LidGuardTuning.defaultNtfyServer` — the public instance.
    static let lidGuardNtfyServer = "lidGuardNtfyServer"
    /// Unix epoch seconds of the last SUCCESSFUL config-time test send; 0 =
    /// never primed. Priming is what proves the topic is really subscribed on
    /// the user's phone, so the first message on it is never the lid-close one.
    static let lidGuardPrimedAt = "lidGuardPrimedAt"
}

/// Keys NapCat used to write and no longer does. They are listed here — rather
/// than forgotten — because a retired key does not disappear from the
/// preferences plist on its own: it sits there until something deletes it.
enum RetiredDefaultsKey {
    /// B2's iMessage recipient (the user's own phone number or Apple ID — PII).
    /// Retired by the B4 ntfy channel swap, which replaced it with
    /// `lidGuardNtfyTopic` + `lidGuardNtfyServer`. There is no migration of the
    /// VALUE (a phone number is not a topic); it is simply deleted.
    static let lidGuardRecipient = "lidGuardRecipient"

    /// The menu-panel layout variant picker ("a" / "c"), a CURATION-ONLY
    /// scaffold of the 2026-10-18 redesign. Retired at the design freeze the
    /// same day (the user kept A "Quiet Rows"; the panel is now one fixed
    /// layout and nothing reads this key). Not sensitive — deleted only so a
    /// dead key does not linger in the plist.
    static let menuPanelStyle = "menuPanelStyle"

    /// Everything `DefaultsMigration.removeRetiredKeys` cleans up.
    static let all = [lidGuardRecipient, menuPanelStyle]
}

/// One-time startup cleanup of retired keys (PLAN.md §11).
enum DefaultsMigration {
    /// Deletes every retired key that is still present. Idempotent — a second
    /// run finds nothing and removes nothing.
    ///
    /// The values are NEVER read, compared, or logged: this runs in-process
    /// under the user's own identity purely to stop a retired identifier from
    /// lingering in the plist. The return value carries key NAMES only, so the
    /// migration can be unit-tested (and its log line counted) without any
    /// value ever being touched.
    @discardableResult
    static func removeRetiredKeys(in defaults: UserDefaults) -> [String] {
        var removed: [String] = []
        for key in RetiredDefaultsKey.all where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            removed.append(key)
        }
        return removed
    }
}
