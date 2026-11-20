// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// F3 stage 1 — the panel side of the phone transport: one Details checkbox
/// ("Phone alerts (beta)", default off) and ONE line from a closed
/// vocabulary. Off renders nothing new and changes no badge; on-but-unusable
/// and failed / unconfirmed attempts escape Details (the iron rule). Fakes
/// only — no CloudKit, no network.
@MainActor
struct PhoneTransportPanelTests {
    // MARK: - The pure mapping

    struct LineRow: CustomTestStringConvertible, Sendable {
        let name: String
        let enabled: Bool
        let available: Bool
        let outcome: MessageSendOutcome?
        let at: Double?
        let expected: PanelLine?
        var testDescription: String { name }
    }

    nonisolated static let now = 1_000_000.0

    nonisolated static let lineRows: [LineRow] = [
        LineRow(name: "off", enabled: false, available: true, outcome: .sendFailed("x"), at: 999_880, expected: nil),
        LineRow(name: "off, unentitled", enabled: false, available: false, outcome: nil, at: nil, expected: nil),
        LineRow(name: "on, unentitled", enabled: true, available: false, outcome: nil, at: nil,
                expected: PanelLine(text: "Phone alerts: unavailable in this build — it is not signed for iCloud, "
                                        + "so alerts go to ntfy", severity: .info)),
        LineRow(name: "on, nothing yet", enabled: true, available: true, outcome: nil, at: nil,
                expected: PanelLine(text: "Phone alert: none since NapCat started", severity: .nominal)),
        LineRow(name: "accepted", enabled: true, available: true, outcome: .accepted, at: 999_880,
                expected: PanelLine(text: "Phone alert: accepted by iCloud 2m ago", severity: .nominal)),
        LineRow(name: "unconfirmed", enabled: true, available: true, outcome: .timedOutUnconfirmed, at: 999_995,
                expected: PanelLine(text: "Phone alert: unconfirmed just now — it may still reach your phone",
                                    severity: .warning)),
        LineRow(name: "failed", enabled: true, available: true,
                outcome: .sendFailed(CloudKitMessageSender.notSignedInText), at: 999_880,
                expected: PanelLine(text: "Phone alert: failed 2m ago — this Mac is not signed in to iCloud; "
                                        + "ntfy was used instead", severity: .warning)),
        LineRow(name: "refused (not produced by the CloudKit sender; total anyway)", enabled: true, available: true,
                outcome: .rejected(403), at: 999_880,
                expected: PanelLine(text: "Phone alert: refused by iCloud 2m ago", severity: .warning)),
        LineRow(name: "outcome without a time reads as none", enabled: true, available: true,
                outcome: .sendFailed("x"), at: nil,
                expected: PanelLine(text: "Phone alert: none since NapCat started", severity: .nominal)),
    ]

    @Test(arguments: lineRows)
    func phoneLineTable(_ row: LineRow) {
        let line = MenuStateModel.phoneAlertLine(enabled: row.enabled, available: row.available,
                                                 outcome: row.outcome, at: row.at, now: Self.now)
        #expect(line == row.expected)
        // The badge's clock-free severity always agrees with the line.
        #expect(MenuStateModel.phoneAlertSeverity(enabled: row.enabled, available: row.available,
                                                  outcome: row.outcome, at: row.at)
                == (row.expected?.severity ?? .nominal))
    }

    /// The line never carries anything but the fixed words, an age and a
    /// fixed failure sentence — no address, no topic, no record content.
    @Test func phoneLinesCarryNoAddressOrContent() {
        for row in Self.lineRows {
            guard let text = row.expected?.text else { continue }
            for token in ["http", "ntfy.sh", "topic", "iCloud.com", "Alert", "-1800"] {
                #expect(!text.contains(token), "'\(token)' in '\(text)'")
            }
        }
    }

    // MARK: - Through the real model

    struct Rig {
        let lid: LidGuardHarness
        let phone: ScriptedSender
        let probe: CallCounter
        let composite: CompositeMessageSender
    }

    /// An armed lid guard on an isolated suite, its sender being a composite
    /// over two scripted transports; the model is built the way the app
    /// builds it.
    private func withRig(entitled: Bool = true, phoneOutcome: MessageSendOutcome = .accepted,
                         _ body: (Rig, MenuStateModel) throws -> Void) throws {
        let suite = "com.muratalkan.napcat.tests.phone.panel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = TransportLog()
        let phone = ScriptedSender("phone", log: log, outcome: phoneOutcome)
        let probe = CallCounter()
        let composite = CompositeMessageSender(ntfy: ScriptedSender("ntfy", log: log), phone: phone,
                                               defaults: defaults,
                                               isEntitled: {
                                                   probe.bump()
                                                   return entitled
                                               },
                                               now: { 1_800_000_000 })
        let lid = LidGuardHarness(defaults: defaults, sender: composite)
        lid.arm()
        let power = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        let model = MenuStateModel(power: power, sleep: SleepStateController(),
                                   limiter: ChargeLimiter(power: power, isAppleSilicon: true, defaults: defaults),
                                   screenLock: ScreenLockController(), lidGuard: lid.controller,
                                   phoneTransport: composite)
        try #require(model.lockScreenAvailable, "canary: see lockSymbolResolvesOnThisMachine")
        try body(Rig(lid: lid, phone: phone, probe: probe, composite: composite), model)
    }

    /// TOGGLE OFF (the default): the panel is what it was — no phone line,
    /// the same badge and lines as a model without the composite, and the
    /// entitlement probe is never consulted.
    @Test func offAddsNoLineAndChangesNoBadge() throws {
        try withRig { rig, model in
            #expect(model.phoneTransportVisible)
            #expect(!model.phoneTransportEnabled)
            #expect(model.phoneAlertStatus(now: Self.now) == nil)
            let power = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
            let without = MenuStateModel(power: power, sleep: SleepStateController(),
                                         limiter: ChargeLimiter(power: power, isAppleSilicon: true,
                                                                defaults: rig.lid.defaults),
                                         screenLock: ScreenLockController(), lidGuard: rig.lid.controller)
            #expect(!without.phoneTransportVisible && without.phoneAlertStatus(now: Self.now) == nil)
            #expect(model.detailsBadge == without.detailsBadge)
            #expect(model.lidStatus == without.lidStatus)
            #expect(model.lidLastSend(now: Self.now) == without.lidLastSend(now: Self.now))
            #expect(rig.probe.count == 0, "nothing is probed while the toggle is off")
        }
    }

    /// On, in an unentitled build (every ad-hoc `make` build): the info line
    /// surfaces and raises the badge, and the alerts still go to ntfy.
    @Test func onInAnUnentitledBuildSaysSoAtTopLevel() throws {
        try withRig(entitled: false) { rig, model in
            model.setPhoneTransportEnabled(true)
            #expect(rig.lid.defaults.bool(forKey: DefaultsKey.phoneTransportEnabled), "the checkbox persists")
            #expect(model.phoneTransportEnabled && !model.phoneTransportAvailable)
            let line = try #require(model.phoneAlertStatus(now: Self.now))
            #expect(line.severity == .info)
            #expect(MenuStateModel.placement(ofDetailsLine: line.severity) == .topLevel)
            #expect(model.detailsBadge == .info)
            rig.lid.controller.sendTestMessage()
            #expect(rig.phone.sends.isEmpty, "unentitled: the phone transport is never asked")
        }
    }

    /// On and entitled: the last CloudKit attempt is what the line reports;
    /// a definitive failure surfaces as a warning (ntfy carried the alert).
    @Test func aFailedPhoneAttemptSurfacesAndRaisesTheBadge() throws {
        try withRig(phoneOutcome: .sendFailed(CloudKitMessageSender.unreachableText)) { rig, model in
            model.setPhoneTransportEnabled(true)
            #expect(model.phoneAlertStatus(now: Self.now)
                    == PanelLine(text: "Phone alert: none since NapCat started", severity: .nominal))
            #expect(MenuStateModel.placement(ofDetailsLine: .nominal) == .details)

            rig.lid.controller.sendTestMessage()
            model.refresh()
            #expect(rig.phone.sends.count == 1)
            let line = try #require(model.phoneAlertStatus(now: 1_800_000_000))
            #expect(line == PanelLine(text: "Phone alert: failed just now — iCloud could not be reached; "
                                          + "ntfy was used instead", severity: .warning))
            #expect(MenuStateModel.placement(ofDetailsLine: line.severity) == .topLevel)
            #expect(model.detailsBadge >= .warning)
        }
    }

    @Test func anAcceptedPhoneAttemptStaysTucked() throws {
        try withRig { rig, model in
            model.setPhoneTransportEnabled(true)
            rig.lid.controller.sendTestMessage()
            model.refresh()
            let line = try #require(model.phoneAlertStatus(now: 1_800_000_000))
            #expect(line == PanelLine(text: "Phone alert: accepted by iCloud just now", severity: .nominal))
            #expect(MenuStateModel.placement(ofDetailsLine: line.severity) == .details)
            model.setPhoneTransportEnabled(false)
            #expect(model.phoneAlertStatus(now: 1_800_000_000) == nil, "off again: no line")
        }
    }

    /// The composite tells its owner after every CloudKit attempt, so an open
    /// menu republishes (MenuContentView wires this to `model.refresh()`).
    @Test func aPhoneAttemptNotifiesTheChangeHandler() throws {
        try withRig { rig, _ in
            let calls = CallCounter()
            rig.composite.setChangeHandler { calls.bump() }
            rig.composite.setPhoneTransportEnabled(true)
            rig.lid.controller.sendTestMessage()
            #expect(calls.count == 1)
            rig.composite.setChangeHandler(nil)
            rig.lid.controller.sendTestMessage()
            #expect(calls.count == 1)
        }
    }

    /// Without a lid guard (debugBattery wiring) there is no delivery group,
    /// so the toggle and its line are absent — even with the key stored on.
    @Test func withoutTheLidGuardThereIsNoPhoneUI() {
        let suite = "com.muratalkan.napcat.tests.phone.panel.absent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: DefaultsKey.phoneTransportEnabled)
        let power = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        let model = MenuStateModel(power: power, sleep: SleepStateController(),
                                   limiter: ChargeLimiter(power: power, isAppleSilicon: true, defaults: defaults),
                                   screenLock: ScreenLockController())
        #expect(!model.phoneTransportVisible)
        #expect(model.phoneAlertStatus(now: Self.now) == nil)
    }
}
