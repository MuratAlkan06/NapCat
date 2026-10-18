// AppKit, not Foundation (CLT cross-import overlay — PLAN.md decision log).
import AppKit
import Testing
@testable import NapCat

/// P5 persistence audit: PLAN.md §11's settings round-trip through
/// UserDefaults, key strings are locked (a silent rename would orphan every
/// user's stored settings), and out-of-range stored values read back sane.
@MainActor
struct PersistenceTests {
    /// §11's complete key set, byte-locked. Launch-at-login is deliberately
    /// absent: SMAppService is the source of truth, nothing in defaults.
    @Test func defaultsKeyStringsAreLocked() {
        #expect(DefaultsKey.limit == "limit")
        #expect(DefaultsKey.limitEnabled == "limitEnabled")
        #expect(DefaultsKey.stayAwakeIntent == "stayAwakeIntent")
        #expect(DefaultsKey.heatWarningAcknowledged == "heatWarningAcknowledged")
        #expect(DefaultsKey.debugBattery == "debugBattery")
        // Track B / B2 (lid-close alert) — the only four keys the feature
        // adds; cooldown, budgets, and paths stay code constants. The topic and
        // server keys replaced `lidGuardRecipient` in the B4 ntfy swap.
        #expect(DefaultsKey.lidGuardEnabled == "lidGuardEnabled")
        #expect(DefaultsKey.lidGuardNtfyTopic == "lidGuardNtfyTopic")
        #expect(DefaultsKey.lidGuardNtfyServer == "lidGuardNtfyServer")
        #expect(DefaultsKey.lidGuardPrimedAt == "lidGuardPrimedAt")
        // 2026-10-18 menu-panel redesign — CURATION-ONLY scaffold, removed at
        // design freeze (it then moves to RetiredDefaultsKey).
        #expect(DefaultsKey.menuPanelStyle == "menuPanelStyle")
    }

    /// Fresh isolated defaults per test; the suite file is removed again.
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "com.muratalkan.napcat.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    /// Adapter disconnected → setLimit/setEnabled evaluations emit no writes;
    /// this stays a pure persistence test.
    private func makeLimiter(_ defaults: UserDefaults) -> ChargeLimiter {
        ChargeLimiter(
            power: DebugPowerSimulator(batteryPercent: 80, adapterConnected: false),
            isAppleSilicon: true,
            defaults: defaults
        )
    }

    @Test func limitDefaultsTo90WhenUnset() {
        withDefaults { defaults in
            #expect(makeLimiter(defaults).limit == 90)
            #expect(defaults.object(forKey: DefaultsKey.limit) == nil,
                    "the default is computed, not eagerly written")
        }
    }

    @Test func limitRoundTripsAcrossInstances() {
        withDefaults { defaults in
            makeLimiter(defaults).setLimit(75)
            #expect(defaults.integer(forKey: DefaultsKey.limit) == 75)
            // A second limiter on the same defaults = app relaunch.
            #expect(makeLimiter(defaults).limit == 75)
        }
    }

    @Test func limitClampsOnWrite() {
        withDefaults { defaults in
            let limiter = makeLimiter(defaults)
            limiter.setLimit(45)
            #expect(limiter.limit == 50)
            #expect(defaults.integer(forKey: DefaultsKey.limit) == 50)
            limiter.setLimit(105)
            #expect(limiter.limit == 100)
            #expect(defaults.integer(forKey: DefaultsKey.limit) == 100)
        }
    }

    @Test func outOfRangeOrJunkStoredLimitReadsBackSane() {
        withDefaults { defaults in
            // e.g. hand-edited plist or a future migration bug.
            defaults.set(30, forKey: DefaultsKey.limit)
            #expect(makeLimiter(defaults).limit == 50, "stored below range clamps up")
            defaults.set(250, forKey: DefaultsKey.limit)
            #expect(makeLimiter(defaults).limit == 100, "stored above range clamps down")
            defaults.set("junk", forKey: DefaultsKey.limit)
            #expect(makeLimiter(defaults).limit == 90, "non-integer falls back to the default")
        }
    }

    // MARK: - Track B / B2 (lid-close alert)

    /// Unset defaults must read as "off, no topic, public server, never
    /// primed" — the feature never auto-arms.
    @Test func lidGuardDefaultsToDisarmed() {
        withLidGuardHarness { harness in
            #expect(!harness.controller.isEnabled)
            #expect(harness.controller.storedTopic == "")
            #expect(harness.controller.storedServer == LidGuardTuning.defaultNtfyServer)
            #expect(harness.controller.storedDestination == nil)
            #expect(harness.controller.primedAt == 0)
            #expect(harness.controller.armingState == .off)
            #expect(!harness.controller.isObservingSleep)
            for key in [DefaultsKey.lidGuardEnabled, DefaultsKey.lidGuardNtfyTopic,
                        DefaultsKey.lidGuardNtfyServer, DefaultsKey.lidGuardPrimedAt] {
                #expect(harness.defaults.object(forKey: key) == nil, "defaults are computed, not eagerly written")
            }
        }
    }

    @Test func lidGuardSettingsRoundTripAcrossInstances() {
        let suite = "com.muratalkan.napcat.tests.lidguard.roundtrip"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = LidGuardHarness(defaults: defaults, sender: RecordingMessageSender())
        first.controller.setEnabled(true)
        first.controller.setServer("  https://ntfy.example.com/  ")
        first.controller.setTopic("  napcat-lid-8f3k2p  ")
        first.controller.sendTestMessage()
        #expect(first.controller.armingState == .armed)

        // A second controller on the same defaults = an app relaunch.
        let second = LidGuardHarness(defaults: defaults, sender: RecordingMessageSender())
        #expect(second.controller.isEnabled)
        #expect(second.controller.storedTopic == "napcat-lid-8f3k2p", "stored trimmed, not raw")
        #expect(second.controller.storedServer == "https://ntfy.example.com", "stored normalized")
        #expect(second.controller.primedAt == first.controller.primedAt)
        #expect(second.controller.armingState == .armed)
    }

    /// Hand-edited or corrupted values must read back safely and leave the
    /// feature inert rather than crashing or half-arming.
    @Test func junkLidGuardValuesReadBackSane() {
        withLidGuardHarness { harness in
            let controller = harness.controller
            harness.defaults.set(true, forKey: DefaultsKey.lidGuardEnabled)

            harness.defaults.set([1, 2], forKey: DefaultsKey.lidGuardNtfyTopic)
            #expect(controller.storedTopic == "", "a non-string value reads as no topic")
            #expect(controller.armingState == .needsTopic)

            harness.defaults.set("has/slash", forKey: DefaultsKey.lidGuardNtfyTopic)
            #expect(controller.armingState == .needsTopic, "an unusable topic never arms")

            harness.defaults.set("napcat-lid-8f3k2p", forKey: DefaultsKey.lidGuardNtfyTopic)
            harness.defaults.set([1, 2], forKey: DefaultsKey.lidGuardNtfyServer)
            #expect(controller.storedServer == LidGuardTuning.defaultNtfyServer,
                    "a non-string server falls back to the public instance")

            harness.defaults.set("http://insecure.example.com", forKey: DefaultsKey.lidGuardNtfyServer)
            #expect(controller.armingState == .needsTopic, "an unusable server never arms")

            harness.defaults.removeObject(forKey: DefaultsKey.lidGuardNtfyServer)
            harness.defaults.set("junk", forKey: DefaultsKey.lidGuardPrimedAt)
            #expect(controller.primedAt == 0)
            #expect(controller.armingState == .needsTestSend)

            harness.defaults.set(1_700_000_000.0, forKey: DefaultsKey.lidGuardPrimedAt)
            #expect(controller.armingState == .armed)
        }
    }

    // MARK: - Retired keys (one-time startup migration)

    /// `lidGuardRecipient` held the user's own phone number / Apple ID before
    /// the B4 ntfy swap. Nothing reads it any more, but a retired key does not
    /// leave the preferences plist on its own — so startup deletes it. The
    /// VALUE is never read or logged; the migration reports key NAMES only,
    /// which is what makes it testable at all.
    @Test func theRetiredRecipientKeyIsDeletedAtStartup() {
        withDefaults { defaults in
            // An obviously invented stand-in — no real address is involved.
            defaults.set("+15550000000", forKey: RetiredDefaultsKey.lidGuardRecipient)
            defaults.set(true, forKey: DefaultsKey.lidGuardEnabled)
            defaults.set("napcat-lid-8f3k2p", forKey: DefaultsKey.lidGuardNtfyTopic)

            #expect(DefaultsMigration.removeRetiredKeys(in: defaults) == ["lidGuardRecipient"])
            #expect(defaults.object(forKey: RetiredDefaultsKey.lidGuardRecipient) == nil)
            // Live settings are untouched.
            #expect(defaults.bool(forKey: DefaultsKey.lidGuardEnabled))
            #expect(defaults.string(forKey: DefaultsKey.lidGuardNtfyTopic) == "napcat-lid-8f3k2p")
        }
    }

    /// Idempotent: the ordinary case (nothing retired stored) removes nothing
    /// and reports nothing, so the migration is silent on every later launch.
    @Test func theRetiredKeyMigrationIsIdempotentAndSilentWhenThereIsNothingToDo() {
        withDefaults { defaults in
            #expect(DefaultsMigration.removeRetiredKeys(in: defaults).isEmpty)
            defaults.set("+15550000000", forKey: RetiredDefaultsKey.lidGuardRecipient)
            #expect(DefaultsMigration.removeRetiredKeys(in: defaults).count == 1)
            #expect(DefaultsMigration.removeRetiredKeys(in: defaults).isEmpty, "a second run is a no-op")
        }
    }

    /// The retired key string is locked (a typo would leave the real one in
    /// place forever) and must never collide with a LIVE key — the migration
    /// deletes what it lists.
    @Test func retiredKeyStringsAreLockedAndDisjointFromTheLiveSet() throws {
        #expect(RetiredDefaultsKey.lidGuardRecipient == "lidGuardRecipient")
        #expect(RetiredDefaultsKey.all == ["lidGuardRecipient"])
        let live = [DefaultsKey.limit, DefaultsKey.limitEnabled, DefaultsKey.stayAwakeIntent,
                    DefaultsKey.heatWarningAcknowledged, DefaultsKey.debugBattery,
                    DefaultsKey.lidGuardEnabled, DefaultsKey.lidGuardNtfyTopic,
                    DefaultsKey.lidGuardNtfyServer, DefaultsKey.lidGuardPrimedAt,
                    DefaultsKey.menuPanelStyle]
        for key in RetiredDefaultsKey.all {
            #expect(!live.contains(key), "'\(key)' is still in use — it must not be deleted at startup")
        }

        // …and the migration is actually wired into launch (it cannot be
        // exercised headlessly: running the delegate would build the real app).
        let app = try String(
            contentsOf: LidGuardStructureTests.sourcesDir().appendingPathComponent("NapCatApp.swift"),
            encoding: .utf8
        )
        #expect(app.contains("DefaultsMigration.removeRetiredKeys(in: defaults)"),
                "the startup migration must run in applicationDidFinishLaunching")
    }

    /// Uninstalling must take the settings with it: `lidGuardNtfyTopic` is a
    /// BEARER CREDENTIAL (ntfy has no accounts — whoever knows the topic can
    /// read and post to that feed), so leaving it in the preferences plist
    /// after an uninstall leaves a live credential behind.
    ///
    /// Text lint only: `scripts/uninstall.sh` is USER-RUN with sudo and is
    /// never executed by the test suite.
    @Test func theUninstallerDeletesTheStoredSettingsWithoutPrintingThem() throws {
        let script = try String(
            contentsOf: LidGuardStructureTests.repoRoot().appendingPathComponent("scripts/uninstall.sh"),
            encoding: .utf8
        )
        #expect(script.contains("DEFAULTS_DOMAIN=\"com.muratalkan.napcat\""))
        #expect(script.contains("defaults delete \"$DEFAULTS_DOMAIN\""),
                "the uninstaller must delete NapCat's settings, topic included")
        // …and it must never PRINT them: every defaults invocation is silenced.
        for line in script.split(separator: "\n") where line.contains("/usr/bin/defaults ") {
            #expect(line.contains(">/dev/null"),
                    "a defaults invocation must not print stored values: \(line)")
        }
    }

    @Test func limitEnabledDefaultsFalseAndRoundTrips() {
        withDefaults { defaults in
            let limiter = makeLimiter(defaults)
            #expect(!limiter.enabled)
            limiter.setEnabled(true)
            #expect(defaults.bool(forKey: DefaultsKey.limitEnabled))
            #expect(makeLimiter(defaults).enabled, "survives a relaunch")
            limiter.setEnabled(false)
            #expect(!makeLimiter(defaults).enabled)
        }
    }
}
