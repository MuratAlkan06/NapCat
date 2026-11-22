// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// A `ReleaseChecking` fake: every check is held until the test answers it.
/// Nothing here can reach the network.
final class ScriptedReleaseChecker: ReleaseChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@Sendable (ReleaseCheckOutcome) -> Void] = []
    private var count = 0

    func fetchLatest(completion: @escaping @Sendable (ReleaseCheckOutcome) -> Void) {
        lock.lock()
        pending.append(completion)
        count += 1
        lock.unlock()
    }

    /// How many checks were ever started.
    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// Answers the oldest held check (completion runs on this thread, as it
    /// may on a session queue — the controller hops to the main actor).
    func answer(_ outcome: ReleaseCheckOutcome) {
        lock.lock()
        let next = pending.isEmpty ? nil : pending.removeFirst()
        lock.unlock()
        next?(outcome)
    }
}

/// Issue #111, part 5: the update check's state and its three defaults keys,
/// driven end to end with a scripted checker and a manual clock. A check
/// starts only from `checkNow` (always) or `checkIfDue` (the 24 h cadence);
/// the attempt is recorded at the start; only a MANUAL check that finds a
/// newer release opens its page; the stored tag is re-validated at every read.
@MainActor
struct UpdateCheckControllerTests {
    static let v160 = ReleaseVersion(bundleVersion: "1.6.0")!
    static let v170 = ReleaseVersion(tag: "v1.7.0")!
    static let t0 = 1_800_000_000.0

    @MainActor
    final class Harness {
        let defaults: UserDefaults
        let suite: String
        let checker = ScriptedReleaseChecker()
        var clock = UpdateCheckControllerTests.t0
        var opened: [URL] = []
        var changes = 0
        private(set) var controller: UpdateCheckController!

        init(running: ReleaseVersion = UpdateCheckControllerTests.v160) {
            suite = "com.muratalkan.napcat.tests.update.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            controller = makeController(running: running)
        }

        func makeController(running: ReleaseVersion) -> UpdateCheckController {
            let made = UpdateCheckController(running: running, defaults: defaults, checker: checker,
                                             now: { [unowned self] in self.clock },
                                             openReleasePage: { [unowned self] in self.opened.append($0) })
            made.setChangeHandler { [unowned self] in self.changes += 1 }
            return made
        }

        func answer(_ outcome: ReleaseCheckOutcome) async {
            checker.answer(outcome)
            await drainMain()
        }

        deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    }

    // MARK: Opportunistic checks

    @Test func aFreshInstallChecksOnTheFirstOpenAndRecordsTheAttempt() async {
        let h = Harness()
        #expect(h.controller.autoEnabled, "unset is ON")
        #expect(h.defaults.object(forKey: DefaultsKey.updateCheckAutoEnabled) == nil, "the default is computed")
        #expect(h.controller.lastAttempt == nil && h.controller.knownNewer == nil && h.controller.lastResult == nil)

        h.controller.checkIfDue()
        #expect(h.checker.calls == 1)
        #expect(h.controller.inFlight)
        #expect(h.controller.lastAttempt == Self.t0, "recorded when the check STARTS")
        #expect(h.changes == 1)

        h.controller.checkIfDue()
        h.controller.checkNow()
        #expect(h.checker.calls == 1, "one check at a time")

        await h.answer(.latest(Self.v170))
        #expect(!h.controller.inFlight)
        #expect(h.controller.lastResult == .available)
        #expect(h.defaults.string(forKey: DefaultsKey.updateCheckLatestTag) == "v1.7.0")
        #expect(h.controller.knownNewer == Self.v170)
        #expect(h.opened.isEmpty, "an opportunistic check never opens anything")
        #expect(h.changes == 2)
    }

    @Test func theNextOpportunisticCheckWaitsADay() async {
        let h = Harness()
        h.controller.checkIfDue()
        await h.answer(.latest(Self.v160))
        #expect(h.controller.lastResult == .upToDate)
        for offset in [1.0, 3_600, 86_399] {
            h.clock = Self.t0 + offset
            h.controller.checkIfDue()
        }
        #expect(h.checker.calls == 1, "not due inside 24 h")
        h.clock = Self.t0 + 86_400
        h.controller.checkIfDue()
        #expect(h.checker.calls == 2, "due at 24 h")
        #expect(h.controller.lastAttempt == Self.t0 + 86_400)
    }

    /// A failed attempt counts: an offline Mac does not retry on every open.
    @Test func aFailedCheckAlsoWaitsADayAndKeepsWhatWasKnown() async {
        let h = Harness()
        h.defaults.set("v1.7.0", forKey: DefaultsKey.updateCheckLatestTag)
        h.controller.checkIfDue()
        await h.answer(.failed(.transport))
        #expect(h.controller.lastResult == .failed)
        #expect(h.controller.lastAttempt == Self.t0)
        #expect(h.controller.knownNewer == Self.v170, "a failure never forgets a known release")
        h.clock = Self.t0 + 600
        h.controller.checkIfDue()
        #expect(h.checker.calls == 1)
        // …but the button always works.
        h.controller.checkNow()
        #expect(h.checker.calls == 2)
    }

    @Test func automaticChecksOffMeansNoOpportunisticCheckEver() async {
        let h = Harness()
        h.controller.setAutoEnabled(false)
        #expect(h.defaults.object(forKey: DefaultsKey.updateCheckAutoEnabled) as? Bool == false)
        #expect(!h.controller.autoEnabled)
        for day in 0..<5 {
            h.clock = Self.t0 + Double(day) * 86_400
            h.controller.checkIfDue()
        }
        #expect(h.checker.calls == 0)
        h.controller.checkNow()
        #expect(h.checker.calls == 1, "the button works with automatic checks off")
        await h.answer(.latest(Self.v170))
        #expect(h.opened.map(\.absoluteString) == ["https://github.com/MuratAlkan06/NapCat/releases/tag/v1.7.0"])
    }

    // MARK: Manual checks

    @Test func aManualCheckThatFindsANewerReleaseOpensItsPage() async throws {
        let h = Harness()
        h.controller.checkNow()
        await h.answer(.latest(Self.v170))
        #expect(h.opened.map(\.absoluteString) == ["https://github.com/MuratAlkan06/NapCat/releases/tag/v1.7.0"])
        #expect(h.controller.lastResult == .available)
    }

    @Test func aManualCheckThatFindsNothingNewerOpensNothing() async throws {
        for latest in ["v1.6.0", "v1.5.9"] {
            let h = Harness()
            h.controller.checkNow()
            await h.answer(.latest(try #require(ReleaseVersion(tag: latest))))
            #expect(h.opened.isEmpty, "\(latest)")
            #expect(h.controller.lastResult == .upToDate)
            #expect(h.controller.knownNewer == nil)
            #expect(h.defaults.string(forKey: DefaultsKey.updateCheckLatestTag) == latest)
        }
        let h = Harness()
        h.controller.checkNow()
        await h.answer(.failed(.httpStatus(403)))
        #expect(h.opened.isEmpty && h.controller.lastResult == .failed)
    }

    // MARK: The stored tag, re-validated at read time

    @Test func theStoredTagIsRevalidatedAgainstTheRunningVersion() throws {
        let h = Harness()
        h.defaults.set("v1.7.0", forKey: DefaultsKey.updateCheckLatestTag)
        #expect(h.controller.knownNewer == Self.v170)
        // The same defaults after the upgrade: the line has nothing to say.
        #expect(h.makeController(running: try #require(ReleaseVersion(bundleVersion: "1.7.0"))).knownNewer == nil)
        #expect(h.makeController(running: try #require(ReleaseVersion(bundleVersion: "1.8.0"))).knownNewer == nil)
        for junk: (any Sendable) in ["v1.7.0-beta.1", "1.7.0", "v01.7.0", 170, ["v1.7.0"]] {
            h.defaults.set(junk, forKey: DefaultsKey.updateCheckLatestTag)
            #expect(h.controller.knownNewer == nil, "\(junk)")
        }
    }

    // MARK: The wiring predicate

    @Test func theControllerIsAbsentInDebugModeAndWithoutAVersion() throws {
        let suite = "com.muratalkan.napcat.tests.update.make.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(UpdateCheckController.makeIfEnabled(debugBattery: true, runningVersion: "1.6.0", defaults: defaults) == nil)
        for version in [nil, "", "1.6", "1.6.0-dev", "v1.6.0"] as [String?] {
            #expect(UpdateCheckController.makeIfEnabled(debugBattery: false, runningVersion: version,
                                                        defaults: defaults) == nil, "\(String(describing: version))")
        }
        // Built, never checked: construction alone touches nothing.
        let built = try #require(UpdateCheckController.makeIfEnabled(debugBattery: false, runningVersion: "1.6.0",
                                                                     defaults: defaults))
        #expect(built.running == Self.v160 && !built.inFlight)
        #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("updateCheck") }.isEmpty)
    }

    // MARK: Through the model

    @Test func theModelMirrorsTheControllerAndForwardsBothControls() async {
        let h = Harness()
        let power = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        let limiter = ChargeLimiter(power: power, isAppleSilicon: true, defaults: h.defaults)
        let model = MenuStateModel(power: power, sleep: SleepStateController(), limiter: limiter,
                                   updateCheck: h.controller)
        #expect(model.updateCheckVisible)
        #expect(model.updateCheckAutoEnabled && !model.updateCheckInFlight && model.updateKnownNewer == nil)

        model.checkForUpdates()
        #expect(h.checker.calls == 1)
        #expect(model.updateCheckInFlight && model.updateCheckLastAttempt == Self.t0, "the mirror follows at once")
        await h.answer(.latest(Self.v170))
        model.refresh()
        #expect(!model.updateCheckInFlight && model.updateCheckLastResult == .available)
        #expect(model.updateKnownNewer == Self.v170)

        model.setUpdateCheckAutoEnabled(false)
        #expect(!model.updateCheckAutoEnabled && h.defaults.object(forKey: DefaultsKey.updateCheckAutoEnabled) as? Bool == false)

        let bare = MenuStateModel(power: power, sleep: SleepStateController(), limiter: limiter)
        #expect(!bare.updateCheckVisible && bare.updateKnownNewer == nil, "no controller, nothing to show")
        bare.checkForUpdates()
        #expect(h.checker.calls == 1, "a model without the controller checks nothing")
    }
}
