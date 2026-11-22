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
        // Track B / B2 (lid-close alert) — the keys the lid-guard feature
        // adds; cooldown, budgets, and paths stay code constants. The topic and
        // server keys replaced `lidGuardRecipient` in the B4 ntfy swap; since
        // issue #103 the topic is in the keychain and its key is retired.
        #expect(DefaultsKey.lidGuardEnabled == "lidGuardEnabled")
        #expect(DefaultsKey.lidGuardNtfyServer == "lidGuardNtfyServer")
        #expect(DefaultsKey.lidGuardPrimedAt == "lidGuardPrimedAt")
        // Track C (Claude finish alert) — ONE toggle; it shares the lid-guard
        // topic / server / primed-at above instead of adding its own.
        #expect(DefaultsKey.claudeFinishAlertEnabled == "claudeFinishAlertEnabled")
        // Issue #34 — the session alerts' run floor (finish + waiting).
        #expect(DefaultsKey.finishAlertMinimumRunSeconds == "finishAlertMinimumRunSeconds")
        // F3 stage 1 — the phone transport toggle (default off).
        #expect(DefaultsKey.phoneTransportEnabled == "phoneTransportEnabled")
        // Slice W (issue #78) — the Settings window's last pane (UI state).
        #expect(DefaultsKey.settingsSelectedPane == "settingsSelectedPane")
        // Issue #111 — the update check's three keys (the interval, the host
        // and the cap are code constants).
        #expect(DefaultsKey.updateCheckAutoEnabled == "updateCheckAutoEnabled")
        #expect(DefaultsKey.updateCheckLastAttempt == "updateCheckLastAttempt")
        #expect(DefaultsKey.updateCheckLatestTag == "updateCheckLatestTag")
        // The 2026-10-18 redesign's `menuPanelStyle` scaffold is no longer a
        // live key — retired at the design freeze (RetiredDefaultsKey).
    }

    /// Issue #111: the automatic-check toggle reads unset as ON without
    /// writing it; what the controller writes reads back (an integer written
    /// by hand reads as its seconds), and the choice survives a relaunch.
    @Test func updateCheckKeysRoundTrip() {
        withDefaults { defaults in
            let running = ReleaseVersion(bundleVersion: "1.6.0")!
            let first = UpdateCheckController(running: running, defaults: defaults, checker: ScriptedReleaseChecker())
            #expect(first.autoEnabled)
            #expect(defaults.object(forKey: DefaultsKey.updateCheckAutoEnabled) == nil, "the default is computed")
            first.setAutoEnabled(false)
            #expect(!UpdateCheckController(running: running, defaults: defaults, checker: ScriptedReleaseChecker())
                .autoEnabled, "survives a relaunch")
            first.setAutoEnabled(true)
            #expect(defaults.bool(forKey: DefaultsKey.updateCheckAutoEnabled))

            let key = DefaultsKey.updateCheckLastAttempt
            #expect(first.lastAttempt == nil)
            defaults.set(1_800_000_000.5, forKey: key)
            #expect(first.lastAttempt == 1_800_000_000.5)
            defaults.set(1_700_000_000, forKey: key)
            #expect(first.lastAttempt == 1_700_000_000)
            defaults.set("yesterday", forKey: key)
            #expect(first.lastAttempt == nil, "junk reads as never — it can only make a check due")

            defaults.set("v1.7.0", forKey: DefaultsKey.updateCheckLatestTag)
            #expect(first.knownNewer?.tag == "v1.7.0")
        }
    }

    /// Track C toggle: unset reads as OFF (the feature never auto-arms), the
    /// default is computed rather than eagerly written, and a stored value
    /// survives a relaunch (a second controller on the same defaults).
    @Test func claudeFinishAlertDefaultsFalseAndRoundTrips() {
        withDefaults { defaults in
            let first = LidGuardHarness(defaults: defaults, sender: RecordingMessageSender())
            #expect(!first.controller.finishAlertEnabled)
            #expect(first.controller.finishAlertArmingState == .off)
            #expect(defaults.object(forKey: DefaultsKey.claudeFinishAlertEnabled) == nil,
                    "the default is computed, not eagerly written")

            first.controller.setFinishAlertEnabled(true)
            #expect(defaults.bool(forKey: DefaultsKey.claudeFinishAlertEnabled))
            #expect(LidGuardHarness(defaults: defaults, sender: RecordingMessageSender())
                .controller.finishAlertEnabled, "survives a relaunch")
            // Its own key: the lid-guard toggle is untouched.
            #expect(defaults.object(forKey: DefaultsKey.lidGuardEnabled) == nil)

            first.controller.setFinishAlertEnabled(false)
            #expect(!LidGuardHarness(defaults: defaults, sender: RecordingMessageSender())
                .controller.finishAlertEnabled)
        }
    }

    /// Issue #34: the session alerts' run floor, through the controller the
    /// app builds (`makeIfEnabled`, on an isolated suite — the controller is
    /// never reconciled, so nothing is watched). Unset reads as 60 and is not
    /// eagerly written; a stored value is clamped on READ (29 → 30, 601 →
    /// 600) and junk reads as 60. Every read is LIVE: the one controller built
    /// at launch follows each later write — no rebuild, so no restart.
    @Test func finishAlertMinimumRunDefaultsTo60AndClampsOnRead() {
        withLidGuardHarness { lid in
            let built = FinishAlertController.makeIfEnabled(
                debugBattery: false, lidGuard: lid.controller, sender: RecordingMessageSender(),
                connectivity: ConnectivitySimulator(), stayAwakeMirror: ObservedStayAwakeMirror(),
                defaults: lid.defaults)
            guard let finish = built else {
                Issue.record("makeIfEnabled must build the controller here")
                return
            }
            #expect(finish.minimumRunSeconds == 60)
            #expect(lid.defaults.object(forKey: DefaultsKey.finishAlertMinimumRunSeconds) == nil,
                    "the default is computed, not eagerly written")
            for (stored, expected) in [(29, 30), (30, 30), (120, 120), (600, 600), (601, 600)] {
                lid.defaults.set(stored, forKey: DefaultsKey.finishAlertMinimumRunSeconds)
                #expect(finish.minimumRunSeconds == expected, "stored \(stored)")
            }
            lid.defaults.set("junk", forKey: DefaultsKey.finishAlertMinimumRunSeconds)
            #expect(finish.minimumRunSeconds == 60, "a non-integer falls back to the default")
            lid.defaults.set(90.5, forKey: DefaultsKey.finishAlertMinimumRunSeconds)
            #expect(finish.minimumRunSeconds == 60, "so does a fraction")
            lid.defaults.removeObject(forKey: DefaultsKey.finishAlertMinimumRunSeconds)
            #expect(finish.minimumRunSeconds == 60, "missing again ⇒ the default")
        }
    }

    /// F3 stage 1 toggle: unset reads as OFF (alerts keep the ntfy path), the
    /// default is computed rather than eagerly written, and a stored value
    /// survives a relaunch (a second composite on the same defaults). Its own
    /// key: no ntfy setting is touched.
    @Test func phoneTransportDefaultsFalseAndRoundTrips() {
        withDefaults { defaults in
            let first = CompositeMessageSender(ntfy: RecordingMessageSender(), phone: RecordingMessageSender(),
                                               defaults: defaults, isEntitled: { false })
            #expect(!first.phoneTransportEnabled)
            #expect(defaults.object(forKey: DefaultsKey.phoneTransportEnabled) == nil,
                    "the default is computed, not eagerly written")

            first.setPhoneTransportEnabled(true)
            #expect(defaults.bool(forKey: DefaultsKey.phoneTransportEnabled))
            let relaunched = CompositeMessageSender(ntfy: RecordingMessageSender(), phone: RecordingMessageSender(),
                                                    defaults: defaults, isEntitled: { false })
            #expect(relaunched.phoneTransportEnabled, "survives a relaunch")
            for key in [DefaultsKey.lidGuardEnabled, RetiredDefaultsKey.lidGuardNtfyTopic, DefaultsKey.lidGuardNtfyServer,
                        DefaultsKey.lidGuardPrimedAt, DefaultsKey.claudeFinishAlertEnabled] {
                #expect(defaults.object(forKey: key) == nil, "'\(key)' was touched by the phone toggle")
            }

            first.setPhoneTransportEnabled(false)
            #expect(!relaunched.phoneTransportEnabled, "read live, never cached")
        }
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
            for key in [DefaultsKey.lidGuardEnabled, RetiredDefaultsKey.lidGuardNtfyTopic,
                        DefaultsKey.lidGuardNtfyServer, DefaultsKey.lidGuardPrimedAt] {
                #expect(harness.defaults.object(forKey: key) == nil, "defaults are computed, not eagerly written")
            }
            #expect(harness.topicStore.storedValue == nil, "nor is anything written to the keychain")
            #expect(harness.topicStore.writeCount == 0 && harness.topicStore.deleteCount == 0)
        }
    }

    @Test func lidGuardSettingsRoundTripAcrossInstances() {
        let suite = "com.muratalkan.napcat.tests.lidguard.roundtrip"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        // One "keychain" across both instances, as on a real relaunch.
        let keychain = FakeTopicStore()

        let first = LidGuardHarness(defaults: defaults, sender: RecordingMessageSender(), topicStore: keychain)
        first.controller.setEnabled(true)
        first.controller.setServer("  https://ntfy.example.com/  ")
        first.controller.setTopic("  napcat-lid-8f3k2p  ")
        first.controller.sendTestMessage()
        #expect(first.controller.armingState == .armed)

        // A second controller on the same defaults + keychain = an app relaunch.
        let second = LidGuardHarness(defaults: defaults, sender: RecordingMessageSender(), topicStore: keychain)
        #expect(second.controller.isEnabled)
        #expect(second.controller.storedTopic == "napcat-lid-8f3k2p", "stored trimmed, not raw")
        #expect(keychain.storedValue == "napcat-lid-8f3k2p", "the topic persists in the keychain…")
        #expect(defaults.object(forKey: RetiredDefaultsKey.lidGuardNtfyTopic) == nil, "…and never in defaults")
        #expect(second.controller.storedServer == "https://ntfy.example.com", "stored normalized")
        #expect(second.controller.primedAt == first.controller.primedAt)
        #expect(second.controller.armingState == .armed)
    }

    /// Hand-edited or corrupted values must read back safely and leave the
    /// feature inert rather than crashing or half-arming.
    @Test func junkLidGuardValuesReadBackSane() {
        // A keychain item that is not text reads as no topic…
        let unreadable = FakeTopicStore()
        unreadable.setReadAnswer(.failed(status: errSecDecode))
        withLidGuardHarness(topicStore: unreadable) { harness in
            harness.defaults.set(true, forKey: DefaultsKey.lidGuardEnabled)
            #expect(harness.controller.storedTopic == "", "an unreadable item reads as no topic")
            #expect(harness.controller.armingState == .needsTopic)
        }
        // …and a hand-edited, unusable one never arms.
        withLidGuardHarness(topicStore: FakeTopicStore("has/slash")) { harness in
            harness.defaults.set(true, forKey: DefaultsKey.lidGuardEnabled)
            harness.defaults.set(harness.clock.now, forKey: DefaultsKey.lidGuardPrimedAt)
            #expect(harness.controller.armingState == .needsTopic, "an unusable topic never arms")
        }
        withLidGuardHarness(topicStore: FakeTopicStore("napcat-lid-8f3k2p")) { harness in
            let controller = harness.controller
            harness.defaults.set(true, forKey: DefaultsKey.lidGuardEnabled)
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

    // MARK: - Issue #103: the topic's one-time move into the keychain

    /// Thread-safe append-only log for store observers.
    private final class LockedLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ entry: String) {
            lock.lock()
            items.append(entry)
            lock.unlock()
        }
        var entries: [String] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    /// A lid guard built on `defaults` + `store` — what a launch does.
    private func launch(_ defaults: UserDefaults, _ store: FakeTopicStore) -> LidGuardController {
        LidGuardHarness(defaults: defaults, sender: RecordingMessageSender(), topicStore: store).controller
    }

    /// The order is write → verified read-back → delete: the plaintext key is
    /// still there while the keychain is written AND while it is read back,
    /// and gone only afterwards. The verified value is the session's topic —
    /// no second read.
    @Test func aPlaintextTopicMovesToTheKeychainThenTheKeyIsDeleted() {
        withDefaults { defaults in
            defaults.set("napcat-legacy-4k8q2z", forKey: RetiredDefaultsKey.lidGuardNtfyTopic)
            defaults.set(1_700_000_000.0, forKey: DefaultsKey.lidGuardPrimedAt)
            let store = FakeTopicStore()
            let seen = LockedLog()
            store.setObserver { operation in
                let present = defaults.object(forKey: RetiredDefaultsKey.lidGuardNtfyTopic) != nil
                seen.append("\(operation):\(present ? "key present" : "key gone")")
            }

            let controller = launch(defaults, store)
            #expect(seen.entries == ["write:key present", "read:key present"],
                    "the key must outlive the write AND the verifying read")
            #expect(defaults.object(forKey: RetiredDefaultsKey.lidGuardNtfyTopic) == nil, "then it is deleted")
            #expect(store.storedValue == "napcat-legacy-4k8q2z")
            #expect(store.readCount == 1, "the verifying read doubles as the startup read")
            #expect(controller.storedTopic == "napcat-legacy-4k8q2z")
            #expect(controller.primedAt == 1_700_000_000, "the same topic, so it stays primed")

            // The next launch finds nothing to move and just reads.
            let next = FakeTopicStore("napcat-legacy-4k8q2z")
            #expect(launch(defaults, next).storedTopic == "napcat-legacy-4k8q2z")
            #expect(next.readCount == 1 && next.writeCount == 0 && next.deleteCount == 0)
        }
    }

    /// A refused write keeps the plaintext key (the topic is never lost),
    /// still serves as this session's topic so the alerts keep working, and
    /// is retried at the next launch — where it then moves.
    @Test func aRefusedWriteKeepsTheKeyAndTheNextLaunchRetries() {
        withDefaults { defaults in
            defaults.set("napcat-legacy-4k8q2z", forKey: RetiredDefaultsKey.lidGuardNtfyTopic)
            let store = FakeTopicStore()
            store.setFailWrites(true)

            #expect(TopicKeychainMigration.run(defaults: defaults, store: store) == .kept("napcat-legacy-4k8q2z"))
            #expect(defaults.string(forKey: RetiredDefaultsKey.lidGuardNtfyTopic) == "napcat-legacy-4k8q2z")
            #expect(store.storedValue == nil)
            #expect(store.readCount == 0, "no read-back after a refused write")
            #expect(launch(defaults, store).storedTopic == "napcat-legacy-4k8q2z", "this session still has its topic")
            #expect(defaults.string(forKey: RetiredDefaultsKey.lidGuardNtfyTopic) == "napcat-legacy-4k8q2z")

            // The unconditional retired-key sweep never takes it either.
            DefaultsMigration.removeRetiredKeys(in: defaults)
            #expect(defaults.string(forKey: RetiredDefaultsKey.lidGuardNtfyTopic) == "napcat-legacy-4k8q2z")

            store.setFailWrites(false)
            #expect(launch(defaults, store).storedTopic == "napcat-legacy-4k8q2z")
            #expect(store.storedValue == "napcat-legacy-4k8q2z")
            #expect(defaults.object(forKey: RetiredDefaultsKey.lidGuardNtfyTopic) == nil, "moved on the retry")
        }
    }

    /// A write that "succeeds" but does not read back identically — or not
    /// at all — is not trusted: the key stays.
    @Test func anUnverifiedWriteKeepsTheKey() {
        for answer in [TopicStoreRead.found("napcat-something-else"), .notFound, .failed(status: errSecUserCanceled)] {
            withDefaults { defaults in
                defaults.set("napcat-legacy-4k8q2z", forKey: RetiredDefaultsKey.lidGuardNtfyTopic)
                let store = FakeTopicStore()
                store.setReadAnswer(answer)
                #expect(TopicKeychainMigration.run(defaults: defaults, store: store) == .kept("napcat-legacy-4k8q2z"),
                        "read-back \(answer)")
                #expect(defaults.string(forKey: RetiredDefaultsKey.lidGuardNtfyTopic) == "napcat-legacy-4k8q2z")
            }
        }
    }

    /// The plaintext value is the newest one the user saved (only an older
    /// NapCat writes it), so it replaces an older keychain item; an empty one
    /// — a cleared topic — deletes the item, verified gone before the key is.
    @Test func theLegacyValueWinsOverAnOlderKeychainItem() {
        withDefaults { defaults in
            defaults.set("napcat-newer-9d3k1m", forKey: RetiredDefaultsKey.lidGuardNtfyTopic)
            let store = FakeTopicStore("napcat-older-2b7x5c")
            #expect(launch(defaults, store).storedTopic == "napcat-newer-9d3k1m")
            #expect(store.storedValue == "napcat-newer-9d3k1m")
        }
        withDefaults { defaults in
            defaults.set("", forKey: RetiredDefaultsKey.lidGuardNtfyTopic)
            let store = FakeTopicStore("napcat-older-2b7x5c")
            #expect(TopicKeychainMigration.run(defaults: defaults, store: store) == .moved(""))
            #expect(store.storedValue == nil && store.deleteCount == 1 && store.writeCount == 0)
            #expect(defaults.object(forKey: RetiredDefaultsKey.lidGuardNtfyTopic) == nil)

            defaults.set("", forKey: RetiredDefaultsKey.lidGuardNtfyTopic)
            store.replaceValue("napcat-older-2b7x5c")
            store.setFailDeletes(true)
            #expect(TopicKeychainMigration.run(defaults: defaults, store: store) == .kept(""))
            #expect(defaults.object(forKey: RetiredDefaultsKey.lidGuardNtfyTopic) != nil, "a refused delete keeps the key")
        }
    }

    /// A non-string value under the key never was a usable topic (it read as
    /// none): it is deleted without touching the keychain, and the session's
    /// topic is whatever the keychain holds.
    @Test func aNonStringLegacyValueIsDiscarded() {
        withDefaults { defaults in
            defaults.set([1, 2], forKey: RetiredDefaultsKey.lidGuardNtfyTopic)
            let store = FakeTopicStore("napcat-kept-6h1v8n")
            #expect(launch(defaults, store).storedTopic == "napcat-kept-6h1v8n")
            #expect(defaults.object(forKey: RetiredDefaultsKey.lidGuardNtfyTopic) == nil)
            #expect(store.writeCount == 0 && store.deleteCount == 0 && store.readCount == 1)
        }
    }

    /// An item the keychain will not return (Deny on the Allow dialog, a
    /// locked keychain) starts the session with no topic — and nothing about
    /// it is rewritten: saving the editor's (empty) prefill unchanged must not
    /// delete the item the user could not read this time.
    @Test func anUnreadableItemIsNeverDeletedOrRewritten() {
        withDefaults { defaults in
            let store = FakeTopicStore("napcat-real-3n6p9w")
            store.setReadAnswer(.failed(status: errSecUserCanceled))
            let controller = launch(defaults, store)
            #expect(controller.storedTopic == "")
            #expect(controller.setTopic("") == .empty)
            #expect(store.storedValue == "napcat-real-3n6p9w")
            #expect(store.writeCount == 0 && store.deleteCount == 0)
        }
    }

    /// The ordering, made structural: the retired topic key is NOT in the
    /// unconditional sweep (which runs first at launch), it is deleted in
    /// exactly one place — the migration, after the verified write — and no
    /// live code can read it as a setting, so a stray value under it can only
    /// ever be moved into the keychain, never used from the plist.
    @Test func theRetiredTopicKeyIsDeletedOnlyByTheVerifiedMove() throws {
        #expect(!RetiredDefaultsKey.all.contains(RetiredDefaultsKey.lidGuardNtfyTopic))
        withDefaults { defaults in
            for key in RetiredDefaultsKey.all { defaults.set("x", forKey: key) }
            defaults.set("napcat-legacy-4k8q2z", forKey: RetiredDefaultsKey.lidGuardNtfyTopic)
            #expect(DefaultsMigration.removeRetiredKeys(in: defaults) == RetiredDefaultsKey.all)
            #expect(defaults.string(forKey: RetiredDefaultsKey.lidGuardNtfyTopic) == "napcat-legacy-4k8q2z",
                    "the sweep must never delete the not-yet-moved topic")
        }

        let sources = try LidGuardStructureTests.swiftSources()
        for (name, text) in sources where text.contains("RetiredDefaultsKey.lidGuardNtfyTopic") || text.contains("\"lidGuardNtfyTopic\"") {
            #expect(name == "DefaultsKeys.swift", "\(name) reads the retired plaintext topic key")
        }
        let keys = try #require(sources.first { $0.name == "DefaultsKeys.swift" }).text
        let migration = try #require(LidGuardStructureTests.memberRange("static func run(defaults: UserDefaults, store: TopicStore)", in: keys))
        let body = keys[migration]
        #expect(body.components(separatedBy: "defaults.removeObject(forKey: key)").count - 1 == 2,
                "the migration deletes the key in two places only: junk, and after the verified move")
        let write = try #require(body.range(of: "store.write(legacy)"))
        let verify = try #require(body.range(of: "store.read() =="))
        let delete = try #require(body.range(of: "defaults.removeObject(forKey: key)\n        return .moved(legacy)"))
        #expect(write.lowerBound < verify.lowerBound && verify.lowerBound < delete.lowerBound,
                "write, then verify, then delete")
    }

    /// Launch order (NapCatApp): the unconditional retired-key sweep, then
    /// the crash-failsafe reconciliation, THEN the lid guard — whose
    /// construction moves and reads the topic, the only keychain access at
    /// launch (it can wait on the Allow dialog, so it must not delay the
    /// failsafe). The real store is handed in there and nowhere else.
    @Test func theKeychainMoveRunsAfterTheSweepAndTheFailsafeReconciliation() throws {
        let sources = try LidGuardStructureTests.swiftSources()
        let app = try #require(sources.first { $0.name == "NapCatApp.swift" }).text
        let realStore = "KeychainTopicStore." + "login" + "Keychain"
        let sweep = try #require(app.range(of: "DefaultsMigration.removeRetiredKeys(in: defaults)"))
        let reconcile = try #require(app.range(of: "        reconcileAtLaunch()\n"))
        let lidGuard = try #require(app.range(of: "LidGuardController.makeIfEnabled("))
        let handOff = try #require(app.range(of: "topicStore: \(realStore)\n"))
        #expect(sweep.lowerBound < reconcile.lowerBound && reconcile.lowerBound < lidGuard.lowerBound
                && lidGuard.lowerBound < handOff.lowerBound)
        for (name, text) in sources where text.contains(realStore) {
            #expect(name == "NapCatApp.swift" || name == "KeychainTopicStore.swift",
                    "\(name) uses the real keychain store — only the app wiring may")
        }
        #expect(app.components(separatedBy: realStore).count - 1 == 1, "handed in exactly once")
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
            defaults.set("napcat-lid-8f3k2p", forKey: RetiredDefaultsKey.lidGuardNtfyTopic)

            #expect(DefaultsMigration.removeRetiredKeys(in: defaults) == ["lidGuardRecipient"])
            #expect(defaults.object(forKey: RetiredDefaultsKey.lidGuardRecipient) == nil)
            // Live settings are untouched — and so is the not-yet-moved topic.
            #expect(defaults.bool(forKey: DefaultsKey.lidGuardEnabled))
            #expect(defaults.string(forKey: RetiredDefaultsKey.lidGuardNtfyTopic) == "napcat-lid-8f3k2p")
        }
    }

    /// Design freeze (2026-10-18): the curation-only `menuPanelStyle` picker
    /// is retired — the panel is one fixed layout and nothing reads the key —
    /// so a plist that still holds it ("a", "c", or a stale "b") is cleaned up
    /// at startup, in the same run as every other retired key.
    @Test func theRetiredPanelStyleKeyIsDeletedAtStartup() {
        withDefaults { defaults in
            defaults.set("c", forKey: RetiredDefaultsKey.menuPanelStyle)
            defaults.set("+15550000000", forKey: RetiredDefaultsKey.lidGuardRecipient)
            defaults.set(75, forKey: DefaultsKey.limit)

            #expect(DefaultsMigration.removeRetiredKeys(in: defaults) == ["lidGuardRecipient", "menuPanelStyle"],
                    "every retired key, in `RetiredDefaultsKey.all` order")
            #expect(defaults.object(forKey: RetiredDefaultsKey.menuPanelStyle) == nil)
            #expect(defaults.object(forKey: RetiredDefaultsKey.lidGuardRecipient) == nil)
            #expect(defaults.integer(forKey: DefaultsKey.limit) == 75, "live settings are untouched")

            defaults.set("b", forKey: RetiredDefaultsKey.menuPanelStyle)
            #expect(DefaultsMigration.removeRetiredKeys(in: defaults) == ["menuPanelStyle"], "alone, too")
            #expect(DefaultsMigration.removeRetiredKeys(in: defaults).isEmpty, "a second run is a no-op")
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

    /// The retired key strings are locked (a typo would leave the real one in
    /// place forever) and must never collide with a LIVE key — the migration
    /// deletes what it lists.
    @Test func retiredKeyStringsAreLockedAndDisjointFromTheLiveSet() throws {
        #expect(RetiredDefaultsKey.lidGuardRecipient == "lidGuardRecipient")
        #expect(RetiredDefaultsKey.menuPanelStyle == "menuPanelStyle")
        #expect(RetiredDefaultsKey.lidGuardNtfyTopic == "lidGuardNtfyTopic")
        #expect(RetiredDefaultsKey.all == ["lidGuardRecipient", "menuPanelStyle"])
        let live = [DefaultsKey.limit, DefaultsKey.limitEnabled, DefaultsKey.stayAwakeIntent,
                    DefaultsKey.heatWarningAcknowledged, DefaultsKey.debugBattery,
                    DefaultsKey.lidGuardEnabled,
                    DefaultsKey.lidGuardNtfyServer, DefaultsKey.lidGuardPrimedAt,
                    DefaultsKey.claudeFinishAlertEnabled, DefaultsKey.finishAlertMinimumRunSeconds,
                    DefaultsKey.phoneTransportEnabled, DefaultsKey.settingsSelectedPane]
        for key in RetiredDefaultsKey.all + [RetiredDefaultsKey.lidGuardNtfyTopic] {
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
