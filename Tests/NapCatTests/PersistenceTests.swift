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
