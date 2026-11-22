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

    // MARK: Track B / B2 — lid-close alert (the ONLY keys the lid-guard feature
    // adds; cooldown, budgets, and marker paths are code constants, not
    // settings). Track C below shares the topic / server / primed-at keys.

    /// Whether the lid-close alert feature is switched on. Armed additionally
    /// requires a usable ntfy topic AND a successful test send. The topic
    /// itself is NOT a defaults key any more: it is a bearer credential, so
    /// it lives in the keychain (`KeychainItemName.ntfyTopic`, issue #103) —
    /// its old key is in `RetiredDefaultsKey`.
    static let lidGuardEnabled = "lidGuardEnabled"
    /// The ntfy server origin (https only). Unset reads back as
    /// `LidGuardTuning.defaultNtfyServer` — the public instance.
    static let lidGuardNtfyServer = "lidGuardNtfyServer"
    /// Unix epoch seconds of the last SUCCESSFUL config-time test send; 0 =
    /// never primed. Priming is what proves the topic is really subscribed on
    /// the user's phone, so the first message on it is never the lid-close one.
    static let lidGuardPrimedAt = "lidGuardPrimedAt"

    // MARK: Track C — Claude finish alert

    /// Whether the Claude session alerts (finish + waiting buzz) are switched
    /// on (Bool, default false). The finish alert reuses the lid-guard topic /
    /// server / primed-at — one ntfy destination, one priming test send — so
    /// this toggle and the run floor below are the only keys it adds; every
    /// other tunable is a code constant, not a setting.
    static let claudeFinishAlertEnabled = "claudeFinishAlertEnabled"
    /// The session alerts' run floor in seconds (Int, issue #34): a run
    /// shorter than this never alerts — neither a finish nor a waiting buzz.
    /// Unset reads as `FinishAlertTuning.minimumRunSeconds` (60); a stored
    /// value is CLAMPED to `FinishAlertTuning.minimumRunSecondsRange` (30–600)
    /// on read, and a non-integer one reads as the default
    /// (`FinishAlertPolicy.minimumRunSeconds(stored:)`). Read live at every
    /// marker diff, so a change applies without a restart.
    static let finishAlertMinimumRunSeconds = "finishAlertMinimumRunSeconds"

    // MARK: F3 stage 1 — phone transport

    /// Whether alerts go to the NapCat iPhone app FIRST — one record in the
    /// owner's private CloudKit database — with ntfy as the fallback (Bool,
    /// default false). It only takes effect in a build entitled for iCloud
    /// (ad-hoc `make` builds are not) with an available iCloud account; OFF —
    /// or unentitled — every alert takes exactly the ntfy path it took before
    /// the key existed. It adds no destination of its own: the ntfy topic /
    /// server / priming above still arm the alerts.
    static let phoneTransportEnabled = "phoneTransportEnabled"

    // MARK: Panel 2.0 slice W — the Settings window

    /// The Settings pane the window last showed (String, a `SettingsPane`
    /// raw value), so it reopens there — across launches too. Written only
    /// when the user picks a pane; unset, unknown, or a pane this wiring does
    /// not show reads as the first pane (`SettingsPane.restored`). UI state
    /// only: nothing else reads it.
    static let settingsSelectedPane = "settingsSelectedPane"
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

    /// The ntfy topic's plaintext home until issue #103 (audit F-2) moved it
    /// to the keychain. Retired — nothing reads it as a setting any more —
    /// but deliberately NOT in `all`: its value is the user's only copy of
    /// the topic until the move has succeeded, so an unconditional startup
    /// delete could lose it. `TopicKeychainMigration` is the one place that
    /// deletes it, and only after a verified keychain write.
    static let lidGuardNtfyTopic = "lidGuardNtfyTopic"

    /// Everything `DefaultsMigration.removeRetiredKeys` deletes outright.
    /// Never add `lidGuardNtfyTopic` here (lint-locked in PersistenceTests).
    static let all = [lidGuardRecipient, menuPanelStyle]
}

/// One-time startup cleanup of retired keys (PLAN.md §11).
enum DefaultsMigration {
    /// Deletes every key in `RetiredDefaultsKey.all` that is still present.
    /// Idempotent — a second run finds nothing and removes nothing. It never
    /// touches `RetiredDefaultsKey.lidGuardNtfyTopic` (not in `all`), so it
    /// is safe to run before the topic's keychain move — it does, first thing
    /// at launch.
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

/// Issue #103 (audit F-2): moves the ntfy topic out of plaintext UserDefaults
/// into the keychain. Runs once per launch, inside the lid guard's
/// construction (`LidGuardController.startupTopic`), after the retired-key
/// cleanup and the crash-failsafe reconciliation.
///
/// ORDER: write to the keychain → read it back and compare → only then
/// delete the defaults key. Any failure keeps the key, so the next launch
/// retries and the topic is never lost. A value found under the key is
/// always the newest one the user saved there (an older NapCat build writes
/// nothing else), so it replaces whatever the keychain holds; an empty one —
/// a topic the user cleared — deletes the item.
///
/// The value is never logged; outcomes carry it only so the caller can use
/// it as this session's topic.
enum TopicKeychainMigration {
    enum Outcome: Equatable, Sendable {
        /// No legacy key — every launch after the first.
        case nothingToMove
        /// Written, read back identical, key deleted. Carries the verified
        /// value: that read-back IS the startup read.
        case moved(String)
        /// The key held no string value (a hand edit that already read as "no
        /// topic"): there is nothing to move, so it is just deleted.
        case discardedJunk
        /// The write failed or the read-back differed: the key is KEPT and the
        /// move is retried at the next launch. Carries the legacy value so the
        /// alerts keep working this session.
        case kept(String)
    }

    static func run(defaults: UserDefaults, store: TopicStore) -> Outcome {
        let key = RetiredDefaultsKey.lidGuardNtfyTopic
        guard defaults.object(forKey: key) != nil else { return .nothingToMove }
        guard let legacy = defaults.string(forKey: key) else {
            defaults.removeObject(forKey: key)
            return .discardedJunk
        }
        // 1. Write (a cleared topic is a delete) …
        guard legacy.isEmpty ? store.delete() : store.write(legacy) else { return .kept(legacy) }
        // 2. … verify by reading it back …
        guard store.read() == (legacy.isEmpty ? .notFound : .found(legacy)) else { return .kept(legacy) }
        // 3. … and only then delete the plaintext copy.
        defaults.removeObject(forKey: key)
        return .moved(legacy)
    }
}
