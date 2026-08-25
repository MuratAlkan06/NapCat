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
        // Track B / B2 (lid-close alert) — the only three keys the feature
        // adds; cooldown, budgets, and paths stay code constants.
        #expect(DefaultsKey.lidGuardEnabled == "lidGuardEnabled")
        #expect(DefaultsKey.lidGuardRecipient == "lidGuardRecipient")
        #expect(DefaultsKey.lidGuardPrimedAt == "lidGuardPrimedAt")
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

    /// Unset defaults must read as "off, no recipient, never primed" — the
    /// feature never auto-arms.
    @Test func lidGuardDefaultsToDisarmed() {
        withLidGuardHarness { harness in
            #expect(!harness.controller.isEnabled)
            #expect(harness.controller.storedRecipient == "")
            #expect(harness.controller.primedAt == 0)
            #expect(harness.controller.armingState == .off)
            #expect(!harness.controller.isObservingSleep)
            for key in [DefaultsKey.lidGuardEnabled, DefaultsKey.lidGuardRecipient, DefaultsKey.lidGuardPrimedAt] {
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
        first.controller.setRecipient("  you@example.com  ")
        first.controller.sendTestMessage()
        #expect(first.controller.armingState == .armed)

        // A second controller on the same defaults = an app relaunch.
        let second = LidGuardHarness(defaults: defaults, sender: RecordingMessageSender())
        #expect(second.controller.isEnabled)
        #expect(second.controller.storedRecipient == "you@example.com", "stored trimmed, not raw")
        #expect(second.controller.primedAt == first.controller.primedAt)
        #expect(second.controller.armingState == .armed)
    }

    /// Hand-edited or corrupted values must read back safely and leave the
    /// feature inert rather than crashing or half-arming.
    @Test func junkLidGuardValuesReadBackSane() {
        withLidGuardHarness { harness in
            let controller = harness.controller
            harness.defaults.set(true, forKey: DefaultsKey.lidGuardEnabled)

            harness.defaults.set([1, 2], forKey: DefaultsKey.lidGuardRecipient)
            #expect(controller.storedRecipient == "", "a non-string value reads as no recipient")
            #expect(controller.armingState == .needsRecipient)

            harness.defaults.set("has\nnewline", forKey: DefaultsKey.lidGuardRecipient)
            #expect(controller.armingState == .needsRecipient, "an unusable address never arms")

            harness.defaults.set("+15551234567", forKey: DefaultsKey.lidGuardRecipient)
            harness.defaults.set("junk", forKey: DefaultsKey.lidGuardPrimedAt)
            #expect(controller.primedAt == 0)
            #expect(controller.armingState == .needsTestSend)

            harness.defaults.set(1_700_000_000.0, forKey: DefaultsKey.lidGuardPrimedAt)
            #expect(controller.armingState == .armed)
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
