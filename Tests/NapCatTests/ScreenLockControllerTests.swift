// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Lock Screen (PLAN.md decision log 2026-08-13).
///
/// NOTHING here ever invokes the resolved lock function or
/// `pmset displaysleepnow` — running the sequence would lock and darken the
/// developer's machine mid-test. Same doctrine as never calling
/// SMAppService.register/unregister: resolve and map, never actuate.
struct ScreenLockControllerTests {
    // MARK: - Frozen mechanism constants

    /// These four strings and two timings ARE the mechanism. Changing any of
    /// them changes what the app dlopen's, which symbol it calls, how it
    /// verifies the lock, and which unprivileged command darkens the display —
    /// so they are byte-locked here (PrivilegedCommandTests pattern).
    @Test func lockMechanismConstantsAreFrozen() {
        #expect(ScreenLockController.loginFrameworkPath
            == "/System/Library/PrivateFrameworks/login.framework/Versions/A/login")
        #expect(ScreenLockController.lockSymbolName == "SACLockScreenImmediate")
        #expect(ScreenLockController.sessionScreenIsLockedKey == "CGSSessionScreenIsLocked")
        #expect(ScreenLockController.displaySleepArgv == ["/usr/bin/pmset", "displaysleepnow"])
        #expect(ScreenLockController.verificationTimeout == 2.0)
        #expect(ScreenLockController.verificationPollInterval == 0.05)
    }

    /// The display-off step must stay unprivileged: it is a plain absolute
    /// path, never routed through the closed privileged-command set.
    @Test func displaySleepIsNotAPrivilegedCommand() {
        let line = ScreenLockController.displaySleepArgv.joined(separator: " ")
        for command in PrivilegedCommand.allCases {
            #expect(command.argv.joined(separator: " ") != line)
        }
        // This slice added no privileged surface (PLAN.md §4 unchanged).
        #expect(PrivilegedCommand.allCases.count == 8)
    }

    // MARK: - OS-drift canary

    /// The whole feature rests on a PRIVATE symbol. Dev hardware == target
    /// hardware, so this test is the early-warning signal that a macOS update
    /// removed or renamed it: when it fails, the app has not broken (the
    /// header button degrades to disabled) but the feature is gone and
    /// PLAN.md must be revisited.
    ///
    /// Resolution is side-effect-free — dlopen + dlsym only. The returned
    /// function is NEVER called here.
    @Test func lockSymbolResolvesOnThisMachine() {
        #expect(ScreenLockController.resolveLockFunction() != nil,
                "\(ScreenLockController.lockSymbolName) no longer resolves — Lock Screen degrades to a disabled header button")
    }

    /// Resolution is cached for the process lifetime (one dlopen, never
    /// dlclose'd), so repeated availability checks are free and stable.
    @Test @MainActor func availabilityIsStableAcrossInstances() {
        let first = ScreenLockController().isAvailable
        let second = ScreenLockController().isAvailable
        #expect(first == second)
        #expect(first == (ScreenLockController.resolveLockFunction() != nil))
    }

    // MARK: - Lock verification parsing (pure)

    @Test func unreadableSessionDictionaryIsUnknownNeverGuessed() {
        #expect(ScreenLockController.screenIsLocked(in: nil) == nil)
    }

    @Test func lockedKeyTrueMeansLocked() {
        let session: [String: Any] = [ScreenLockController.sessionScreenIsLockedKey: true]
        #expect(ScreenLockController.screenIsLocked(in: session) == true)
    }

    @Test func lockedKeyFalseMeansUnlocked() {
        let session: [String: Any] = [ScreenLockController.sessionScreenIsLockedKey: false]
        #expect(ScreenLockController.screenIsLocked(in: session) == false)
    }

    /// macOS OMITS the key entirely while the screen is unlocked (verified on
    /// this machine) — an absent key is a definite "not locked", not unknown.
    @Test func absentLockedKeyMeansUnlocked() {
        let session: [String: Any] = [
            "kCGSSessionOnConsoleKey": true,
            "kCGSSessionUserNameKey": "someone",
        ]
        #expect(ScreenLockController.screenIsLocked(in: session) == false)
    }

    /// The live wrapper reads the PUBLIC CoreGraphics dictionary; verification
    /// depends on it answering definitively (true or false), never "unknown".
    /// Deliberately does NOT assert which — the suite may legitimately run
    /// while the screen is locked (unattended sessions), and a test must never
    /// depend on the developer's current lock state.
    @Test func liveSessionReadAnswersDefinitively() {
        #expect(ScreenLockController.liveScreenIsLocked() != nil)
    }

    // MARK: - Menu presentation (pure mapping)

    @Test func availableMechanismEnablesTheRowWithoutACaption() {
        let presentation = MenuStateModel.lockScreenPresentation(available: true)
        #expect(presentation.enabled)
        #expect(presentation.caption == nil)
    }

    /// Honest degrade: no alternative mechanism exists, so the row must say
    /// why it is dead rather than fail on click.
    @Test func unavailableMechanismDisablesTheRowAndExplainsWhy() {
        let presentation = MenuStateModel.lockScreenPresentation(available: false)
        #expect(!presentation.enabled)
        #expect(presentation.caption != nil)
        #expect(presentation.caption?.contains("macOS") == true)
    }

    /// The SwiftUI button forwards through the hook — it must not run any
    /// lock flow itself (MenuContentView owns dismissal + the async run).
    @Test @MainActor func lockScreenForwardsThroughTheHook() {
        let simulator = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        let defaults = UserDefaults(suiteName: "com.muratalkan.napcat.tests.screenlock")!
        defaults.removePersistentDomain(forName: "com.muratalkan.napcat.tests.screenlock")
        let limiter = ChargeLimiter(power: simulator, isAppleSilicon: true, defaults: defaults)
        let model = MenuStateModel(
            power: simulator,
            sleep: SleepStateController(),
            limiter: limiter,
            simulator: simulator
        )
        var calls = 0
        model.requestLockScreen = { calls += 1 }
        model.lockScreen()
        model.lockScreen()
        #expect(calls == 2)
        #expect(!model.lockScreenAvailable, "no controller injected → header button disabled, never assumed available")
    }

    // MARK: - Structural isolation (lint-style)

    /// Mechanism confinement: everything about dlopen/login.framework and the
    /// display-sleep subprocess lives in ONE file, and that file must add no
    /// privileged surface — no elevation, no privileged helper (same shape as
    /// `simulatorSourceIsStructurallyIsolated`).
    @Test func lockSourceCarriesNoPrivilegedSurface() throws {
        let source = try Self.appSource(named: "ScreenLockController.swift")
        try #require(source.contains("final class ScreenLockController"))

        let lowered = source.lowercased()
        for forbidden in ["sudo", "smc"] {
            #expect(!lowered.contains(forbidden),
                    "forbidden token '\(forbidden)' in ScreenLockController.swift")
        }
        // Order is load-bearing: verify before darkening.
        let lockCall = try #require(lowered.range(of: "lock()"))
        let verify = try #require(lowered.range(of: "waitforverifiedlock()"))
        let darken = try #require(lowered.range(of: "rundisplaysleep()"))
        #expect(lockCall.lowerBound < verify.lowerBound)
        #expect(verify.lowerBound < darken.lowerBound)
    }

    /// The lock click dismisses the menu by design — but only through the
    /// single shared gateway (`closeMenuThenPresent`, also used by the modal
    /// flows: heat warning, setup/failure alerts, the ntfy settings editor),
    /// never by adding a second dismissal call (which is what the 2026-07-10
    /// UX fix removed, and what ScaffoldTests still counts file-wide).
    @Test func lockClickDismissesOnlyThroughTheSingleGateway() throws {
        let source = try Self.appSource(named: "MenuContentView.swift")
        try #require(source.contains("final class MenuContentView"))

        let body = try #require(Self.functionChunk(named: "lockScreen", in: source),
                                "lockScreen() not found — rewiring must keep this lock updated")
        #expect(body.contains("closeMenuThenPresent"),
                "the lock flow must close the menu through the one gateway")
        #expect(!body.contains("cancel" + "Tracking"),
                "no second dismissal call site — reuse the gateway")
        // The sequence is awaited, so the dismissal never waits on it.
        #expect(body.contains("await"))
    }

    // MARK: - Helpers

    private static func appSource(named name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)   // Tests/NapCatTests/<this file>
            .deletingLastPathComponent()            // Tests/NapCatTests
            .deletingLastPathComponent()            // Tests
            .deletingLastPathComponent()            // repo root
            .appendingPathComponent("Sources/NapCat/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Source chunk from `func <name>(` to the next function declaration
    /// (or end of file) — same coarse-but-stable approach as ScaffoldTests.
    private static func functionChunk(named name: String, in source: String) -> String? {
        guard let start = source.range(of: "func \(name)(") else { return nil }
        let tail = source[start.upperBound...]
        let boundaries = ["\n    private func ", "\n    func ", "\n    static func ", "\n    nonisolated static func "]
        let end = boundaries
            .compactMap { tail.range(of: $0)?.lowerBound }
            .min() ?? tail.endIndex
        return String(tail[..<end])
    }
}
