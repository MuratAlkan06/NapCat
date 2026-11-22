// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Issue #111, part 2: the pure cadence. No timers exist; an opportunistic
/// check (menu or Settings open) runs only while automatic checks are on and
/// the last ATTEMPT — failed ones included — is at least 24 h old.
struct UpdateCadenceTests {
    static let day = 86_400.0
    static let now = 1_800_000_000.0

    @Test func theIntervalIsTwentyFourHours() {
        #expect(UpdateCadence.interval == Self.day)
    }

    @Test(arguments: [
        ("never attempted", true, nil as Double?, true),
        ("just attempted", true, UpdateCadenceTests.now, false),
        ("an hour ago", true, UpdateCadenceTests.now - 3_600, false),
        ("one second short of a day", true, UpdateCadenceTests.now - UpdateCadenceTests.day + 1, false),
        ("exactly a day", true, UpdateCadenceTests.now - UpdateCadenceTests.day, true),
        ("three days ago", true, UpdateCadenceTests.now - 3 * UpdateCadenceTests.day, true),
        ("the clock was set back a week", true, UpdateCadenceTests.now + 7 * UpdateCadenceTests.day, true),
        ("the clock was set back a second", true, UpdateCadenceTests.now + 1, true),
        ("off, never attempted", false, nil, false),
        ("off, three days ago", false, UpdateCadenceTests.now - 3 * UpdateCadenceTests.day, false),
        ("off, clock set back", false, UpdateCadenceTests.now + UpdateCadenceTests.day, false),
    ] as [(String, Bool, Double?, Bool)])
    func theOpportunisticCheck(name: String, autoEnabled: Bool, lastAttempt: Double?, due: Bool) {
        #expect(UpdateCadence.opportunisticCheckDue(autoEnabled: autoEnabled, lastAttempt: lastAttempt, now: Self.now)
                == due, "\(name)")
    }

    /// Unset is ON (the default); a stored Bool is itself; junk is OFF — a
    /// hand-edited value never turns network traffic on.
    @Test(arguments: [
        ("unset", nil, true),
        ("true", true, true),
        ("false", false, false),
        ("NSNumber 1", NSNumber(value: 1), true),
        ("NSNumber 0", NSNumber(value: 0), false),
        ("NSNumber 7", NSNumber(value: 7), false),
        ("the string YES", "YES", false),
        ("the string true", "true", false),
        ("a date", Date(timeIntervalSince1970: 0), false),
    ] as [(String, (any Sendable)?, Bool)])
    func theStoredToggle(name: String, stored: (any Sendable)?, expected: Bool) {
        #expect(UpdateCadence.autoEnabled(stored: stored) == expected, "\(name)")
    }

    @Test(arguments: [
        ("unset", nil, nil as Double?),
        ("epoch seconds", 1_800_000_000.5, 1_800_000_000.5),
        ("an integer, as defaults hands it back", NSNumber(value: 1_800_000_000), 1_800_000_000),
        ("zero", 0.0, 0),
        ("infinity", Double.infinity, nil),
        ("NaN", Double.nan, nil),
        ("a string", "1800000000", nil),
        ("a date", Date(timeIntervalSince1970: 5), nil),
    ] as [(String, (any Sendable)?, Double?)])
    func theStoredAttemptTime(name: String, stored: (any Sendable)?, expected: Double?) {
        #expect(UpdateCadence.lastAttempt(stored: stored) == expected, "\(name)")
    }

    /// A junk attempt time reads as "never", so it can only make a check
    /// due — never silence it.
    @Test func aJunkAttemptTimeIsNeverAttempted() {
        for junk: (any Sendable)? in ["soon", Double.nan, Date()] {
            #expect(UpdateCadence.opportunisticCheckDue(
                autoEnabled: true, lastAttempt: UpdateCadence.lastAttempt(stored: junk), now: Self.now))
        }
    }

    /// The cadence file is PURE: no import, no I/O, no clock, no scheduling.
    @Test func theCadenceFileIsPureAndSchedulesNothing() throws {
        let text = LidGuardStructureTests.codeOnly(try String(
            contentsOf: LidGuardStructureTests.sourcesDir().appendingPathComponent("UpdateCadence.swift"),
            encoding: .utf8))
        #expect(text.contains("enum UpdateCadence"), "vacuity")
        for token in ["import ", "UserDefaults", "URLSession", "URLRequest", "URL(", "FileManager", "Date(",
                      "ProcessInfo", "Logger", "DispatchQueue", "Task", "Timer", "asyncAfter", "repeating",
                      "makeTimerSource", "sleep("] {
            #expect(!text.contains(token), "'\(token)' in UpdateCadence.swift — the cadence stays pure")
        }
    }
}
