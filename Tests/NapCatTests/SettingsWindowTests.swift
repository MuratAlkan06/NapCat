// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import ServiceManagement
import SwiftUI
import Testing
@testable import NapCat

/// The Settings window (Panel 2.0 slice W, issue #78): what each pane shows
/// per state (composition tables over the pure mappings), the restored pane
/// and its key, ⌘, from the open menu and from the main menu, activation
/// hygiene for an LSUIElement app, the refresh on becoming key, and the
/// structural locks the panel's lints apply to every menu file.
///
/// No test here puts a window on screen or activates the test runner: the
/// window's AppKit side effects go through recording `SettingsWindowHooks`.
struct SettingsWindowTests {
    // MARK: - Helpers

    /// What the hooks saw, in order.
    @MainActor
    final class HookLog {
        var events: [String] = []
    }

    @MainActor
    static func recordingHooks(_ log: HookLog) -> SettingsWindowHooks {
        SettingsWindowHooks(
            activate: { log.events.append("activate") },
            present: { _ in log.events.append("present") },
            afterClose: { log.events.append("afterClose") }
        )
    }

    /// A model over the debug simulator on an isolated defaults suite. The
    /// real ScreenLockController (resolution only — side-effect free) keeps
    /// the Lock Screen line nominal.
    @MainActor
    private func withModel(
        detection: ClaudeActivityController? = nil,
        lidGuard: LidGuardController? = nil,
        finishAlert: FinishAlertController? = nil,
        phoneTransport: CompositeMessageSender? = nil,
        remoteApprovals: RemoteApprovalsController? = nil,
        _ body: (MenuStateModel, UserDefaults) throws -> Void
    ) rethrows {
        let suite = "com.muratalkan.napcat.tests.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let power = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        let limiter = ChargeLimiter(power: power, isAppleSilicon: true, defaults: defaults)
        let model = MenuStateModel(power: power, sleep: SleepStateController(), limiter: limiter,
                                   screenLock: ScreenLockController(), detection: detection, lidGuard: lidGuard,
                                   finishAlert: finishAlert, phoneTransport: phoneTransport, remoteApprovals: remoteApprovals)
        try body(model, defaults)
    }

    /// A finish-alert controller over fakes only (no watcher, no network, no
    /// marker dir), its run floor read from `defaults` like the app's.
    @MainActor
    static func makeFinishAlert(_ lid: LidGuardHarness, markerDir: URL? = nil) -> FinishAlertController {
        let factory = WatcherFactory()
        let defaults = lid.defaults
        return FinishAlertController(
            store: FakeMarkerStore(),
            markerDirURL: markerDir ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("napcat-settings-absent-\(UUID().uuidString)"),
            config: lid.controller, sender: RecordingMessageSender(),
            makeWatcher: { factory.make($0) }, scheduler: ManualScheduler(), now: { 1_800_000_000 },
            minimumRunSeconds: {
                FinishAlertPolicy.minimumRunSeconds(stored: defaults.object(forKey: DefaultsKey.finishAlertMinimumRunSeconds))
            })
    }

    /// The model's whole Settings content, as text — for "never the topic".
    @MainActor
    static func everyPaneAsText(_ model: MenuStateModel) -> String {
        model.settingsPanes.map { String(describing: model.settingsContent(for: $0, now: 1_000_000)) }
            .joined(separator: "\n")
    }

    /// The menu owner, built like ScaffoldTests builds it (simulator power,
    /// isolated defaults) with recording window hooks.
    @MainActor
    private func withMenuContent(_ body: (MenuContentView, HookLog) async throws -> Void) async rethrows {
        let suite = "com.muratalkan.napcat.tests.settings.menu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let simulator = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        let limiter = ChargeLimiter(power: simulator, isAppleSilicon: true, defaults: defaults)
        let log = HookLog()
        let menuContent = MenuContentView(sleep: SleepStateController(), watchdog: WatchdogController(),
                                          power: simulator, limiter: limiter, simulator: simulator,
                                          defaults: defaults, settingsHooks: Self.recordingHooks(log))
        try await body(menuContent, log)
    }

    /// ⌘, as AppKit delivers it.
    static func commandComma() throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: ",",
                                      charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43))
    }

    static func code(_ file: String) throws -> String {
        try MenuPanelStructureTests.code(file)
    }

    static func occurrences(of token: String, in text: String) -> Int {
        MenuPanelStructureTests.occurrences(of: token, in: text)
    }

    /// Every Settings source file. A new one must be added here (and is then
    /// covered by the scans below and by the LidGuard / ClaudeDetection file
    /// sets).
    /// S-PAIR-C1 (#168): the pairing sheet hangs off the window — its file
    /// is a Settings file under every Settings lock (motion included).
    static let settingsFiles = ["SettingsContent.swift", "SettingsPanes.swift", "SettingsWindowController.swift",
                                "PairingSheet.swift"]
    /// The Settings window's SwiftUI view file.
    static let settingsViewFile = "SettingsPanes.swift"
    /// Where the panes are composed (the only place a pane picks its lines).
    static let compositionFile = "SettingsContent.swift"

    // MARK: - Composition: the General pane

    static let lockAvailableLine = PanelLine(
        text: "Lock Screen: available — locks and turns the display off; the Mac keeps running", severity: .nominal)
    static let lockUnavailableLine = PanelLine(
        text: "Lock Screen: unavailable on this version of macOS — use Apple menu › Lock Screen (⌃⌘Q)",
        severity: .warning)
    static let approvalCaption = PanelLine(
        text: "Waiting for approval — System Settings › General › Login Items", severity: .warning)
    static let notFoundCaption = PanelLine(
        text: "Not found — toggle again to re-register this copy of NapCat", severity: .warning)

    static func startup(_ isOn: Bool, _ caption: PanelLine? = nil, shortcut: Bool = false) -> SettingsSection {
        SettingsSection(title: "Startup",
                        rows: [.launchAtLogin(isOn: isOn, caption: caption, showsSettingsShortcut: shortcut)])
    }

    static func chargeLimit(_ header: String, on: Bool, switchEnabled: Bool = true, limit: Int,
                            sliderEnabled: Bool, _ caption: PanelLine?) -> SettingsSection {
        SettingsSection(title: "Charge Limit", rows: [
            .chargeLimit(header: header, isOn: on, switchEnabled: switchEnabled, limit: limit,
                         sliderEnabled: sliderEnabled, caption: caption),
        ])
    }

    static func lockScreen(_ line: PanelLine) -> SettingsSection {
        SettingsSection(title: "Lock Screen", rows: [.line(line)])
    }

    struct GeneralRow: CustomTestStringConvertible, Sendable {
        let name: String
        let login: SMAppService.Status
        let feature: ChargeLimitFeatureState
        let limit: Int
        let limitOn: Bool
        let lock: Bool
        let sections: [SettingsSection]
        var testDescription: String { name }
    }

    /// Every login status, every charge-limit feature state (the Intel,
    /// setup-required and unavailable captions included), both lock states.
    static let generalRows: [GeneralRow] = [
        GeneralRow(name: "nominal", login: .enabled, feature: .active, limit: 90, limitOn: true, lock: true,
                   sections: [
                       startup(true),
                       chargeLimit("Pause charging at 90%", on: true, limit: 90, sliderEnabled: true,
                                   PanelLine(text: "Charging — pauses at the limit", severity: .nominal)),
                       lockScreen(lockAvailableLine),
                   ]),
        GeneralRow(name: "everything off", login: .notRegistered, feature: .off, limit: 90, limitOn: false,
                   lock: true, sections: [
                       startup(false),
                       chargeLimit("Pause charging at 90%", on: false, limit: 90, sliderEnabled: false, nil),
                       lockScreen(lockAvailableLine),
                   ]),
        GeneralRow(name: "login needs approval, paused at the limit", login: .requiresApproval, feature: .paused,
                   limit: 80, limitOn: true, lock: true, sections: [
                       startup(false, approvalCaption, shortcut: true),
                       chargeLimit("Pause charging at 80%", on: true, limit: 80, sliderEnabled: true,
                                   PanelLine(text: "Paused at the limit", severity: .nominal)),
                       lockScreen(lockAvailableLine),
                   ]),
        GeneralRow(name: "login not found, setup required", login: .notFound, feature: .setupRequired, limit: 90,
                   limitOn: true, lock: true, sections: [
                       startup(false, notFoundCaption),
                       chargeLimit("Pause charging at 90%", on: true, limit: 90, sliderEnabled: true, PanelLine(
                           text: "Setup needed — run “sudo ./scripts/setup.sh” in the NapCat folder, then reopen this menu",
                           severity: .warning)),
                       lockScreen(lockAvailableLine),
                   ]),
        GeneralRow(name: "Intel", login: .enabled, feature: .notSupported, limit: 90, limitOn: true, lock: true,
                   sections: [
                       startup(true),
                       chargeLimit("Pause charging at 90%", on: true, switchEnabled: false, limit: 90,
                                   sliderEnabled: false, PanelLine(
                                       text: "Unavailable — needs an Apple Silicon Mac; Stay Awake still works here",
                                       severity: .info)),
                       lockScreen(lockAvailableLine),
                   ]),
        // #84: the firmware gates charge control — the header stays, the
        // switch and slider give way to ONE plain note (no severity line).
        GeneralRow(name: "no charge-control key (#58)", login: .enabled, feature: .controlUnavailable, limit: 75,
                   limitOn: false, lock: true, sections: [
                       startup(true),
                       SettingsSection(title: "Charge Limit", rows: [.note("Unavailable on this version of macOS")]),
                       lockScreen(lockAvailableLine),
                   ]),
        GeneralRow(name: "a write failed, no limit", login: .enabled, feature: .error("The charge-limit write failed."),
                   limit: 100, limitOn: true, lock: true, sections: [
                       startup(true),
                       chargeLimit("No limit — charge to 100%", on: true, limit: 100, sliderEnabled: true,
                                   PanelLine(text: "The charge-limit write failed.", severity: .error)),
                       lockScreen(lockAvailableLine),
                   ]),
        GeneralRow(name: "desktop Mac, no lock API", login: .enabled, feature: .hidden, limit: 90, limitOn: true,
                   lock: false, sections: [
                       startup(true),
                       lockScreen(lockUnavailableLine),
                   ]),
    ]

    @Test(arguments: generalRows)
    func theGeneralPaneComposition(row: GeneralRow) {
        let pane = MenuStateModel.generalPane(loginStatus: row.login, featureState: row.feature, limit: row.limit,
                                              limitEnabled: row.limitOn, lockAvailable: row.lock)
        #expect(pane == SettingsPaneContent(sections: row.sections, footnote: nil))
    }

    /// The table covers every login status and every feature state.
    @Test func theGeneralTableCoversEveryState() {
        let logins = Set(Self.generalRows.map { "\($0.login.rawValue)" })
        #expect(logins.count == 4, "every SMAppService status")
        let features = Self.generalRows.map(\.feature)
        for state: ChargeLimitFeatureState in [.hidden, .notSupported, .setupRequired, .controlUnavailable, .off,
                                               .active, .paused, .error("The charge-limit write failed.")] {
            #expect(features.contains(state), "\(state)")
        }
        #expect(Set(Self.generalRows.map(\.lock)) == [false, true])
    }

    /// #84, every feature state: the panel hides the Charge Limit row ONLY
    /// without a battery (ADR §12) or while the firmware gates control, and
    /// Settings › General carries the one note ONLY for the gated state —
    /// every other state shows the row and keeps the controls in Settings,
    /// so a lifted gate always brings the row back.
    @Test(arguments: [ChargeLimitFeatureState.hidden, .notSupported, .setupRequired, .controlUnavailable, .off,
                      .active, .paused, .error("The charge-limit write failed.")])
    func onlyNoBatteryAndTheFirmwareGateHideTheChargeLimitRow(state: ChargeLimitFeatureState) throws {
        let visible = MenuStateModel.chargeLimitRowVisible(for: state)
        let pane = MenuStateModel.generalPane(loginStatus: .enabled, featureState: state, limit: 80,
                                              limitEnabled: true, lockAvailable: true)
        let charge = pane.sections.filter { $0.title == "Charge Limit" }
        let notes = pane.sections.flatMap(\.rows).filter { row in
            if case .note = row { return true }
            return false
        }
        switch state {
        case .hidden:
            #expect(!visible)
            #expect(charge.isEmpty && notes.isEmpty, "no battery: no Charge Limit anywhere")
        case .controlUnavailable:
            #expect(!visible)
            #expect(MenuStateModel.chargeLimitCaption(for: state) == nil)
            #expect(charge == [SettingsSection(title: "Charge Limit",
                                               rows: [.note(MenuStateModel.chargeControlUnavailableText)])])
        default:
            #expect(visible, "\(state) shows the row")
            #expect(notes.isEmpty, "\(state) carries no note")
            let row = try #require(charge.first?.rows.first, "\(state) keeps the Charge Limit group")
            #expect(charge.count == 1 && charge[0].rows.count == 1)
            guard case .chargeLimit = row else {
                Issue.record("\(state): the controls, not \(row)")
                return
            }
        }
    }

    /// The model's wrapper feeds the pure composition its own mirrors, and
    /// re-composes on every refresh (the header follows the slider).
    @Test @MainActor func theModelComposesTheGeneralPaneFromItsMirrors() {
        withModel { model, _ in
            #expect(model.settingsPanes == [.general], "no lid guard (debugBattery wiring): General only")
            #expect(model.settingsContent(for: .general, now: 0) == model.generalPane(now: 0))
            #expect(model.generalPane(now: 0) == MenuStateModel.generalPane(
                loginStatus: model.loginItemStatus, featureState: model.featureState, limit: model.limit,
                limitEnabled: model.limitEnabled, lockAvailable: model.lockScreenAvailable))
            model.setLimitEnabled(true)
            model.setLimit(75)
            model.refresh()
            let rows = model.generalPane(now: 0).sections.flatMap(\.rows)
            #expect(rows.contains { row in
                if case let .chargeLimit(header, isOn, _, limit, sliderEnabled, _) = row {
                    return header == "Pause charging at 75%" && isOn && limit == 75 && sliderEnabled
                }
                return false
            }, "\(rows)")
        }
    }

    // MARK: - Composition: General › Updates (issue #111)

    static let updateDisclosure = "Contacts api.github.com about once a day, when you open the menu or Settings. "
        + "The request exposes your IP address, the app name and version in the User-Agent, and standard macOS "
        + "HTTPS headers; nothing else is sent. Nothing is downloaded or installed."

    static func updates(_ isOn: Bool, checking: Bool = false, _ caption: String) -> SettingsSection {
        SettingsSection(title: "Updates", rows: [
            .updateCheck(checking: checking, caption: caption),
            .updateAuto(isOn: isOn, disclosure: updateDisclosure),
        ])
    }

    /// The passive caption, every state: C2 fragments, state word first.
    @Test(arguments: [
        ("checking wins", true, UpdateCheckResult.failed as UpdateCheckResult?, "v1.7.0" as String?, 0.0 as Double?,
         "Checking…"),
        ("a failed check, a newer one known", false, .failed, "v1.7.0", 0, "Couldn’t check — try again later"),
        ("a failed check", false, .failed, nil, 0, "Couldn’t check — try again later"),
        ("available this session", false, .available, "v1.7.0", 0,
         "Update available — v1.7.0; Check for Updates… opens its release page"),
        ("known from an earlier session", false, nil, "v2.0.1", 0,
         "Update available — v2.0.1; Check for Updates… opens its release page"),
        ("up to date, two hours ago", false, .upToDate, nil, 1_000_000 - 7_200, "Up to date — checked 2h ago"),
        ("up to date, just now", false, .upToDate, nil, 1_000_000 - 5, "Up to date — checked just now"),
        ("an earlier session's attempt", false, nil, nil, 1_000_000 - 3 * 86_400, "Checked 3d ago"),
        ("never", false, nil, nil, nil, "Not checked yet"),
    ] as [(String, Bool, UpdateCheckResult?, String?, Double?, String)])
    func theUpdateCaption(name: String, checking: Bool, result: UpdateCheckResult?, newer: String?,
                          lastAttempt: Double?, caption: String) {
        #expect(MenuStateModel.updateCheckCaption(checking: checking, lastResult: result,
                                                  newer: newer.flatMap(ReleaseVersion.init(tag:)),
                                                  lastAttempt: lastAttempt, now: 1_000_000) == caption, "\(name)")
    }

    /// The disclosure names the host and everything the request exposes —
    /// and the README's privacy note says the same, word for word.
    @Test func theUpdateDisclosureIsPlainAboutTheRequest() throws {
        #expect(MenuStateModel.updateCheckDisclosure == Self.updateDisclosure)
        let readme = try String(contentsOf: LidGuardStructureTests.repoRoot().appendingPathComponent("README.md"),
                                encoding: .utf8)
        let flat = readme.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let exposes = "The request exposes your IP address, the app name and version in the User-Agent, "
            + "and standard macOS HTTPS headers; nothing else is sent."
        #expect(MenuStateModel.updateCheckDisclosure.contains(exposes))
        #expect(flat.contains(exposes), "the README's privacy note must say exactly what Settings says")
        #expect(flat.contains("defaults write com.muratalkan.napcat updateCheckAutoEnabled -bool NO"))
        #expect(flat.contains("## Network use and privacy"))
    }

    /// Updates is General's last group, and only while the check exists.
    @Test func theUpdatesGroupClosesTheGeneralPane() {
        let base = MenuStateModel.generalPane(loginStatus: .enabled, featureState: .active, limit: 90,
                                              limitEnabled: true, lockAvailable: true)
        let with = MenuStateModel.generalPane(loginStatus: .enabled, featureState: .active, limit: 90,
                                              limitEnabled: true, lockAvailable: true,
                                              updates: (autoEnabled: true, checking: false, caption: "Not checked yet"))
        #expect(with == SettingsPaneContent(sections: base.sections + [Self.updates(true, "Not checked yet")],
                                            footnote: nil))
        #expect(!base.sections.contains { $0.title == "Updates" }, "no update check (debugBattery mode): no group")
        let off = MenuStateModel.generalPane(loginStatus: .enabled, featureState: .hidden, limit: 90,
                                             limitEnabled: true, lockAvailable: false,
                                             updates: (autoEnabled: false, checking: true, caption: "Checking…"))
        #expect(off.sections.last == Self.updates(false, checking: true, "Checking…"))
    }

    /// Through the model: the group follows the controller — checking, then
    /// the answer — and both controls reach it.
    @Test @MainActor func theModelComposesTheUpdatesGroupFromItsController() async throws {
        let suite = "com.muratalkan.napcat.tests.settings.update.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = ScriptedReleaseChecker()
        let running = try #require(ReleaseVersion(bundleVersion: "1.6.0"))
        let update = UpdateCheckController(running: running, defaults: defaults, checker: checker,
                                           now: { 1_000_000 }, openReleasePage: { _ in })
        let power = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        let model = MenuStateModel(power: power, sleep: SleepStateController(),
                                   limiter: ChargeLimiter(power: power, isAppleSilicon: true, defaults: defaults),
                                   screenLock: ScreenLockController(), updateCheck: update)
        update.setChangeHandler { model.refresh() }
        #expect(model.settingsPanes == [.general], "Updates is a group of General, not a pane")
        #expect(model.settingsContent(for: .general, now: 1_000_000).sections.last == Self.updates(true, "Not checked yet"))

        model.checkForUpdates()
        #expect(model.generalPane(now: 1_000_000).sections.last == Self.updates(true, checking: true, "Checking…"))
        checker.answer(.latest(try #require(ReleaseVersion(tag: "v1.6.0"))))
        await drainMain()
        #expect(model.generalPane(now: 1_000_000 + 120).sections.last == Self.updates(true, "Up to date — checked 2m ago"))

        model.setUpdateCheckAutoEnabled(false)
        #expect(model.generalPane(now: 1_000_000).sections.last?.rows.last
                == .updateAuto(isOn: false, disclosure: Self.updateDisclosure))
    }

    // MARK: - Composition: the Alerts pane

    static let secrecyNote = "Anyone who knows your topic name can read — and post to — your alerts. "
        + "Pick a long, unguessable name and keep it private."
    static let presets = [30, 60, 120, 300, 600]
    static let noLidSend = PanelLine(text: "Last message: none since NapCat started", severity: .nominal)
    static let noSessionSend = PanelLine(text: "Last session alert: none since NapCat started", severity: .nominal)
    static let topicSet = PanelLine(text: "Topic: set (hidden — it is the password to your feed)", severity: .nominal)

    static func destination(_ server: PanelLine, _ topic: PanelLine) -> SettingsSection {
        SettingsSection(title: "Destination", rows: [.line(server), .line(topic), .ntfyButtons])
    }

    static func floorSection(_ seconds: Int, choices: [Int] = presets) -> SettingsSection {
        SettingsSection(title: "Session alerts", rows: [
            .minimumRun(label: "Only alert for runs longer than:", seconds: seconds, choices: choices,
                        caption: "Shorter runs finish silently."),
        ])
    }

    static func history(_ lines: PanelLine...) -> SettingsSection {
        SettingsSection(title: "History", rows: lines.map(SettingsRow.line))
    }

    static func phoneSection(_ isOn: Bool) -> SettingsSection {
        SettingsSection(title: nil, rows: [
            .phoneAlerts(title: "Phone alerts (beta)", isOn: isOn,
                         hint: "Sends alerts to the NapCat iPhone app through your iCloud first; ntfy stays the fallback."),
        ])
    }

    struct AlertsRow: CustomTestStringConvertible, Sendable {
        let name: String
        let server: PanelLine
        let topic: PanelLine
        let lidLastSend: PanelLine
        let session: (minimumRunSeconds: Int, lastSend: PanelLine)?
        let phone: (isOn: Bool, line: PanelLine?)?
        let sections: [SettingsSection]
        var testDescription: String { name }
    }

    /// Lid guard only (no finish alert, no composite) up to everything wired,
    /// a non-preset floor, and the problem lines (every one at its own
    /// severity — Settings renders lines in full).
    static let alertsRows: [AlertsRow] = {
        let server = PanelLine(text: "Server: https://ntfy.sh", severity: .nominal)
        let unusableServer = PanelLine(
            text: "Server: not usable — it must be an https address like https://ntfy.sh", severity: .warning)
        let unusableTopic = PanelLine(
            text: "Topic: not usable — letters, digits, “_” and “-” only, max 64 characters", severity: .warning)
        let refused = PanelLine(
            text: "Last message: refused by the server 2m ago (HTTP 403) — check the topic and server", severity: .error)
        let accepted = PanelLine(text: "Last message: accepted by ntfy 2m ago", severity: .nominal)
        let noPhone = PanelLine(text: "Phone alert: none since NapCat started", severity: .nominal)
        let unentitled = PanelLine(
            text: "Phone alerts: unavailable in this build — it is not signed for iCloud, so alerts go to ntfy",
            severity: .info)
        return [
            AlertsRow(name: "lid guard only, fresh", server: server,
                      topic: PanelLine(text: "Topic: none set", severity: .nominal), lidLastSend: noLidSend,
                      session: nil, phone: nil, sections: [
                          destination(server, PanelLine(text: "Topic: none set", severity: .nominal)),
                          history(noLidSend),
                      ]),
            AlertsRow(name: "everything wired, phone off", server: server, topic: topicSet, lidLastSend: accepted,
                      session: (60, noSessionSend), phone: (false, nil), sections: [
                          destination(server, topicSet), floorSection(60), history(accepted, noSessionSend),
                          phoneSection(false),
                      ]),
            AlertsRow(name: "a stored non-preset floor, phone on", server: server, topic: topicSet,
                      lidLastSend: accepted, session: (90, noSessionSend), phone: (true, noPhone), sections: [
                          destination(server, topicSet), floorSection(90, choices: [30, 60, 90, 120, 300, 600]),
                          history(accepted, noSessionSend, noPhone), phoneSection(true),
                      ]),
            AlertsRow(name: "problems render in full", server: unusableServer, topic: unusableTopic,
                      lidLastSend: refused, session: (600, noSessionSend), phone: (true, unentitled), sections: [
                          destination(unusableServer, unusableTopic), floorSection(600),
                          history(refused, noSessionSend, unentitled), phoneSection(true),
                      ]),
        ]
    }()

    @Test(arguments: alertsRows)
    func theAlertsPaneComposition(row: AlertsRow) {
        let pane = MenuStateModel.alertsPane(server: row.server, topic: row.topic, lidLastSend: row.lidLastSend,
                                             sessionAlerts: row.session, phone: row.phone)
        #expect(pane == SettingsPaneContent(sections: row.sections, footnote: Self.secrecyNote))
    }

    /// The table's lines are the mappings' own output (no second vocabulary).
    @Test func theAlertsTableLinesAreTheMappingsOwn() {
        #expect(MenuStateModel.lidAlertServerStatus("") == PanelLine(text: "Server: https://ntfy.sh", severity: .nominal))
        #expect(MenuStateModel.lidAlertServerStatus("http://ntfy.sh").severity == .warning)
        #expect(MenuStateModel.lidAlertTopicStatus("napcat-x") == Self.topicSet)
        #expect(MenuStateModel.lidAlertTopicStatus("bad/topic").severity == .warning)
        #expect(MenuStateModel.lidAlertLastSend(outcome: .rejected(403), at: 999_880, now: 1_000_000).text
                == "Last message: refused by the server 2m ago (HTTP 403) — check the topic and server")
        #expect(MenuStateModel.lidAlertTopicSecrecyNote == Self.secrecyNote)
        #expect(MenuStateModel.sessionAlertsFloorPresets == Self.presets)
        #expect(MenuStateModel.phoneTransportToggleTitle == "Phone alerts (beta)")
    }

    /// Through the model, wired as in the app (lid guard + finish alert +
    /// composite): the Alerts tab exists, the pane is the composition of the
    /// model's own accessors, and the TOPIC never reaches it — only whether
    /// one is set.
    @Test @MainActor func theModelComposesTheAlertsPaneWithoutTheTopic() {
        withLidGuardHarness { lid in
            lid.arm()
            lid.defaults.set(true, forKey: DefaultsKey.claudeFinishAlertEnabled)
            let composite = CompositeMessageSender(ntfy: RecordingMessageSender(), phone: RecordingMessageSender(),
                                                   defaults: lid.defaults, isEntitled: { false })
            withModel(lidGuard: lid.controller, finishAlert: Self.makeFinishAlert(lid),
                      phoneTransport: composite) { model, _ in
                #expect(model.settingsPanes == [.general, .alerts])
                let now = 1_000_000.0
                #expect(model.settingsContent(for: .alerts, now: now) == MenuStateModel.alertsPane(
                    server: model.lidServerStatus, topic: model.lidTopicStatus, lidLastSend: model.lidLastSend(now: now),
                    sessionAlerts: (model.finishAlertMinimumRunSeconds, model.finishAlertLastSend(now: now)),
                    phone: (model.phoneTransportEnabled, model.phoneAlertStatus(now: now))))
                #expect(model.lidTopicStatus == Self.topicSet, "vacuity: a topic is stored")
                let text = Self.everyPaneAsText(model)
                #expect(!text.contains("napcat-lid-8f3k2p"), "the topic is the feed's password — never rendered")
            }
        }
    }

    /// The popup saves through the ntfy editor's own save path: the one
    /// clamp, written only when it changed, and the pane follows.
    @Test @MainActor func theRunFloorPopupSavesThroughTheEditorsSavePath() {
        withLidGuardHarness { lid in
            lid.arm()
            lid.defaults.set(true, forKey: DefaultsKey.claudeFinishAlertEnabled)
            let simulator = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
            let limiter = ChargeLimiter(power: simulator, isAppleSilicon: true, defaults: lid.defaults)
            let menuContent = MenuContentView(
                sleep: SleepStateController(), watchdog: WatchdogController(), power: simulator, limiter: limiter,
                lidGuard: lid.controller, finishAlert: Self.makeFinishAlert(lid), defaults: lid.defaults,
                settingsHooks: Self.recordingHooks(HookLog()))
            let model = menuContent.model
            #expect(model.finishAlertMinimumRunSeconds == 60)

            model.setFinishAlertMinimumRunSeconds(60)
            #expect(lid.defaults.object(forKey: DefaultsKey.finishAlertMinimumRunSeconds) == nil,
                    "the untouched default is never eagerly written")
            model.setFinishAlertMinimumRunSeconds(300)
            #expect(lid.defaults.integer(forKey: DefaultsKey.finishAlertMinimumRunSeconds) == 300)
            #expect(model.finishAlertMinimumRunSeconds == 300, "the mirror follows at once")
            #expect(model.alertsPane(now: 0).sections.flatMap(\.rows).contains(
                .minimumRun(label: "Only alert for runs longer than:", seconds: 300, choices: Self.presets,
                            caption: "Shorter runs finish silently.")))
            model.setFinishAlertMinimumRunSeconds(29)
            #expect(lid.defaults.integer(forKey: DefaultsKey.finishAlertMinimumRunSeconds) == 30, "the one clamp")
        }
    }

    // MARK: - Composition: the Claude pane

    static let pauseCaption =
        "Stops reading Claude busy markers. While paused the lid and session alerts cannot fire."
    static let busyHookSection = SettingsSection(title: "Busy hook", rows: [
        .hookInstall(intro: "Run this in Terminal from the NapCat repository, then open a new Claude session:",
                     command: "./scripts/install-claude-busy-hook.sh",
                     note: "Installed from the disk image? Clone github.com/MuratAlkan06/NapCat first."),
    ])

    struct ClaudeRow: CustomTestStringConvertible, Sendable {
        let name: String
        let status: PanelLine
        let hook: PanelLine
        let hookVersion: PanelLine?
        let awake: PanelLine?
        let paused: Bool
        let detection: [SettingsRow]
        var testDescription: String { name }
    }

    /// Running with a current hook, idle and holding awake, paused, and the
    /// hook problems (each line at its own severity).
    static let claudeRows: [ClaudeRow] = {
        let running = PanelLine(text: "Claude: running", severity: .nominal)
        let idle = PanelLine(text: "Claude: idle", severity: .nominal)
        let paused = PanelLine(text: "Claude: paused", severity: .warning)
        let seen = PanelLine(text: "Busy hook: last seen 1m ago", severity: .nominal)
        let current = PanelLine(text: "Busy hook: installed copy is current", severity: .nominal)
        let awake = PanelLine(text: "Claude is holding the Mac awake", severity: .nominal)
        let missing = PanelLine(
            text: "Busy hook: not installed — run install-claude-busy-hook.sh from the NapCat repository",
            severity: .warning)
        let outOfDate = PanelLine(text: "Busy hook: installed copy is out of date — re-run "
                                      + "scripts/install-claude-busy-hook.sh and open a new Claude session",
                                  severity: .warning)
        let pause = { (isOn: Bool) in SettingsRow.pauseDetection(isOn: isOn, caption: pauseCaption) }
        return [
            ClaudeRow(name: "running, hook current", status: running, hook: seen, hookVersion: current, awake: nil,
                      paused: false, detection: [.line(running), .line(seen), .line(current), pause(false)]),
            ClaudeRow(name: "idle, holding awake", status: idle, hook: seen, hookVersion: current, awake: awake,
                      paused: false,
                      detection: [.line(idle), .line(seen), .line(current), .line(awake), pause(false)]),
            ClaudeRow(name: "paused", status: paused, hook: seen, hookVersion: current, awake: nil, paused: true,
                      detection: [.line(paused), .line(seen), .line(current), pause(true)]),
            ClaudeRow(name: "no hook (no version line)", status: idle, hook: missing, hookVersion: nil, awake: nil,
                      paused: false, detection: [.line(idle), .line(missing), pause(false)]),
            ClaudeRow(name: "an out-of-date copy", status: running, hook: seen, hookVersion: outOfDate, awake: nil,
                      paused: false, detection: [.line(running), .line(seen), .line(outOfDate), pause(false)]),
        ]
    }()

    @Test(arguments: claudeRows)
    func theClaudePaneComposition(row: ClaudeRow) {
        let pane = MenuStateModel.claudePane(status: row.status, hook: row.hook, hookVersion: row.hookVersion,
                                             awake: row.awake, paused: row.paused)
        #expect(pane == SettingsPaneContent(sections: [
            SettingsSection(title: "Detection", rows: row.detection), Self.busyHookSection,
        ], footnote: nil))
    }

    /// The table's lines are the mappings' own output, and the installer
    /// pointer is the command the disk image's READ ME gives — for a script
    /// that exists.
    @Test func theClaudeTableLinesAreTheMappingsOwn() throws {
        #expect(MenuStateModel.claudeFooterLabel(inFlight: true, paused: false).text == "Claude: running")
        #expect(MenuStateModel.claudeFooterLabel(inFlight: true, paused: true)
                == PanelLine(text: "Claude: paused", severity: .warning))
        #expect(MenuStateModel.claudeHookStatus(installed: false, everSeen: false, lastSeenSeconds: nil,
                                                lidAlertEnabled: true, sessionAlertsEnabled: false).text
                == "Busy hook: not installed — run install-claude-busy-hook.sh from the NapCat repository")
        #expect(MenuStateModel.claudeHookVersionStatus(installedVersion: 1, expectedVersion: 2, markerDirExists: true)?
            .text.contains("out of date") == true)
        #expect(MenuStateModel.pauseDetectionCaption == Self.pauseCaption)

        let command = MenuStateModel.claudeHookInstallCommand
        let root = LidGuardStructureTests.repoRoot()
        #expect(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent(String(command.dropFirst(2))).path),
                "\(command) must name the real installer")
        let packager = try String(contentsOf: root.appendingPathComponent("scripts/make-dmg.sh"), encoding: .utf8)
        #expect(packager.contains("    \(command)\n"), "the READ ME gives the same command")
    }

    /// Through the model: the Claude tab exists exactly with the detection
    /// stack, and the pane is the composition of the model's own accessors.
    @Test @MainActor func theModelComposesTheClaudePane() throws {
        let markerDir = FileManager.default.temporaryDirectory.appendingPathComponent("napcat-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: markerDir) }
        let detection = ClaudeActivityController(store: StubMarkerStore(), prober: StubProber(),
                                                 assertions: StubAssertions(holdingAwake: true), markerDirURL: markerDir)
        detection.sample()
        withModel(detection: detection) { model, _ in
            #expect(model.settingsPanes == [.general, .claude])
            #expect(model.settingsContent(for: .claude, now: 0) == MenuStateModel.claudePane(
                status: MenuStateModel.claudeFooterLabel(inFlight: model.claudeTaskInFlight,
                                                         paused: model.claudeDetectionPaused),
                hook: model.hookStatus, hookVersion: model.hookVersionStatus, awake: model.claudeAwakeLine,
                paused: model.claudeDetectionPaused))
            #expect(model.claudeAwakeLine != nil, "vacuity: the awake fact is shown")

            // The Settings switch takes the panel's own route (the owner
            // re-gates the finish alert on the pause notification).
            var notified = 0
            model.onDetectionPausedChange = { notified += 1 }
            model.setDetectionPaused(true)
            #expect(notified == 1 && model.claudeDetectionPaused)
            #expect(model.claudePane.sections.first?.rows.first == .line(
                PanelLine(text: "Claude: paused", severity: .warning)))
            model.setDetectionPaused(false)
        }
    }

    /// F4 slice S2, through the model with the real toggle over a scratch
    /// socket (ApprovalsWorld — no defaults, keychain or home of its own):
    /// the Settings group follows the OBSERVED phase, the policy line comes
    /// with the reading taken while on and leaves with the kill switch, and —
    /// a Settings fact in this slice, even unreadable — it raises no gear
    /// badge. The row's own status never counts toward the badge — the panel
    /// row is its home.
    @Test @MainActor func theModelMirrorsTheRemoteApprovalsToggle() throws {
        let markerDir = FileManager.default.temporaryDirectory.appendingPathComponent("napcat-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: markerDir) }
        let detection = ClaudeActivityController(store: StubMarkerStore(), prober: StubProber(),
                                                 assertions: StubAssertions(holdingAwake: false), markerDirURL: markerDir)
        detection.sample()
        let world = try ApprovalsWorld()
        world.finding = .unreadable
        try withModel(detection: detection, remoteApprovals: world.controller) { model, _ in
            let hint = MenuStateModel.remoteApprovalsHint
            #expect(model.remoteApprovalsVisible)
            #expect(!model.remoteApprovalsEnabled)
            #expect(model.remoteApprovalsPolicyLine == nil, "off: no probe, so no reading")
            #expect(model.claudePane.sections.last?.rows == [.remoteApprovals(isOn: false, caption: nil, hint: hint)])
            #expect(!model.settingsResidentSeverities(.claude).contains(.info))

            model.setRemoteApprovalsEnabled(true)
            #expect(model.remoteApprovalsEnabled)
            let policy = try #require(model.remoteApprovalsPolicyLine)
            #expect(policy == MenuStateModel.remoteApprovalsPolicyLine(finding: .unreadable))
            #expect(model.claudePane.sections.last?.rows == [
                .remoteApprovals(isOn: true, caption: MenuStateModel.remoteApprovalsStatus(phase: .listening), hint: hint),
                .line(policy),
            ])
            #expect(policy.severity == .nominal && !model.settingsResidentSeverities(.claude).contains(.info),
                    "the unreadable reading is a Settings fact, and the row's info status is not counted: no badge")

            model.setRemoteApprovalsEnabled(false)
            #expect(!model.remoteApprovalsEnabled)
            #expect(model.remoteApprovalsPolicyLine == nil)
            #expect(!world.socketExists, "the Settings switch is the kill switch too")
        }
    }

    // MARK: - The panes, their symbols, the restored pane

    @Test func thePanesAreLockedInToolbarOrder() {
        // Stored raw values: a rename would orphan every stored selection.
        #expect(SettingsPane.allCases.map(\.rawValue) == ["general", "alerts", "claude"])
        #expect(SettingsPane.allCases.map(\.title) == ["General", "Alerts", "Claude"])
        #expect(SettingsPane.allCases.map(\.symbol) == ["gearshape", "bell", "terminal"])
        #expect(MenuStateModel.settingsPanes(alertsVisible: true, claudeVisible: true) == [.general, .alerts, .claude])
        #expect(MenuStateModel.settingsPanes(alertsVisible: false, claudeVisible: true) == [.general, .claude])
        #expect(MenuStateModel.settingsPanes(alertsVisible: true, claudeVisible: false) == [.general, .alerts])
        #expect(MenuStateModel.settingsPanes(alertsVisible: false, claudeVisible: false) == [.general],
                "debugBattery wiring: General only")
        for pane in SettingsPane.allCases {
            #expect(NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil) != nil,
                    "\(pane.symbol) does not resolve")
        }
    }

    @Test(arguments: [
        ("unset", nil, SettingsPane.general),
        ("general", "general", .general),
        ("alerts", "alerts", .alerts),
        ("claude", "claude", .claude),
        ("unknown pane", "advanced", .general),
        ("wrong case", "General", .general),
        ("not a string", 3, .general),
    ] as [(String, (any Sendable)?, SettingsPane)])
    func theRestoredPane(name: String, stored: (any Sendable)?, expected: SettingsPane) {
        #expect(SettingsPane.restored(stored: stored, available: SettingsPane.allCases) == expected, "\(name)")
    }

    @Test func restorationFallsBackToTheFirstAvailablePane() {
        #expect(SettingsPane.restored(stored: "general", available: []) == .general)
        #expect(SettingsPane.restored(stored: "alerts", available: [.general]) == .general,
                "a pane this wiring does not show (debugBattery mode) is never restored")
        #expect(SettingsPane.restored(stored: "claude", available: [.general, .alerts]) == .general)
    }

    /// The controller opens on the stored pane; picking a pane stores it.
    /// Opening alone writes nothing — the default is computed.
    @Test @MainActor func theLastPaneIsStoredOnlyWhenPicked() throws {
        try withModel { model, defaults in
            let controller = SettingsWindowController(model: model, defaults: defaults,
                                                      hooks: Self.recordingHooks(HookLog()))
            #expect(controller.selection.pane == .general)
            controller.show()
            #expect(defaults.object(forKey: DefaultsKey.settingsSelectedPane) == nil,
                    "opening the window must not write the key")
            controller.select(.general)
            #expect(defaults.string(forKey: DefaultsKey.settingsSelectedPane) == "general")
            let window = try #require(controller.window)
            #expect(window.title == "General")
            window.delegate = nil
        }
    }

    // MARK: - The window

    /// A preference-style toolbar window: one tab per pane with its symbol,
    /// the active pane selected and naming the window, fixed width, built
    /// once and reused.
    @Test @MainActor func theWindowIsAToolbarTabbedSettingsWindow() throws {
        try withModel { model, defaults in
            let log = HookLog()
            let controller = SettingsWindowController(model: model, defaults: defaults,
                                                      hooks: Self.recordingHooks(log))
            #expect(controller.window == nil, "built lazily, on the first show")
            controller.show()
            let window = try #require(controller.window)
            defer { window.delegate = nil }
            #expect(window.toolbarStyle == .preference)
            #expect(window.title == "General")
            #expect(window.contentViewController?.title == "General")
            let toolbar = try #require(window.toolbar)
            #expect(!toolbar.allowsUserCustomization)
            #expect(toolbar.displayMode == .iconAndLabel)
            #expect(toolbar.items.map(\.itemIdentifier) == model.settingsPanes.map(SettingsWindowController.toolbarIdentifier))
            #expect(toolbar.items.map(\.label) == model.settingsPanes.map(\.title))
            #expect(toolbar.items.allSatisfy { $0.image != nil })
            #expect(toolbar.selectedItemIdentifier == SettingsWindowController.toolbarIdentifier(.general))

            window.layoutIfNeeded()
            #expect(abs(window.contentLayoutRect.width - SettingsMetrics.width) < 1,
                    "fixed \(SettingsMetrics.width) pt, got \(window.contentLayoutRect.width)")
            #expect(window.contentLayoutRect.height > 100, "the pane's own height")

            controller.show()
            #expect(controller.window === window, "reused, never rebuilt")
        }
    }

    /// With the lid guard wired the window has an Alerts tab: picking it
    /// shows the pane, retitles the window, selects the tab, stores the pane
    /// — and the window takes the new pane's height (fixed width). A stored
    /// pane is where the next window opens.
    @Test @MainActor func pickingAPaneRetitlesResizesAndStoresIt() throws {
        let suite = "com.muratalkan.napcat.tests.settings.lid.\(UUID().uuidString)"
        let lidDefaults = UserDefaults(suiteName: suite)!
        defer { lidDefaults.removePersistentDomain(forName: suite) }
        let lid = LidGuardHarness(defaults: lidDefaults, sender: RecordingMessageSender())
        lid.arm()
        do {
            try withModel(lidGuard: lid.controller) { model, defaults in
                let controller = SettingsWindowController(model: model, defaults: defaults,
                                                          hooks: Self.recordingHooks(HookLog()))
                controller.show()
                let window = try #require(controller.window)
                defer { window.delegate = nil }
                #expect(window.toolbar?.items.map(\.label) == ["General", "Alerts"])
                Self.settle(window)
                let general = window.contentLayoutRect.size
                let hosted = try #require(window.contentViewController?.view)
                #expect(abs(general.height - hosted.fittingSize.height) < 1, "the window is the pane's height")

                controller.select(.alerts)
                Self.settle(window)
                #expect(controller.selection.pane == .alerts)
                #expect(window.title == "Alerts" && window.contentViewController?.title == "Alerts")
                #expect(window.toolbar?.selectedItemIdentifier == SettingsWindowController.toolbarIdentifier(.alerts))
                #expect(defaults.string(forKey: DefaultsKey.settingsSelectedPane) == "alerts")
                let alerts = window.contentLayoutRect.size
                #expect(abs(alerts.width - SettingsMetrics.width) < 1 && abs(general.width - SettingsMetrics.width) < 1)
                #expect(abs(alerts.height - hosted.fittingSize.height) < 1, "the window follows the pane")
                #expect(alerts.height != general.height, "vacuity: the panes differ in height — \(general) → \(alerts)")

                let reopened = SettingsWindowController(model: model, defaults: defaults,
                                                        hooks: Self.recordingHooks(HookLog()))
                #expect(reopened.selection.pane == .alerts, "the next launch restores the stored pane")
            }
        }
    }

    /// A few layout passes + runloop turns so SwiftUI applies a pane switch.
    @MainActor
    static func settle(_ window: NSWindow) {
        for _ in 0..<6 {
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - Activation hygiene (LSUIElement)

    /// Activate FIRST, then order the window front — every time it is shown.
    /// Closing hands focus back. Neither ever changes the activation policy.
    @Test @MainActor func showActivatesBeforePresentingAndCloseHandsFocusBack() throws {
        try withModel { model, defaults in
            let log = HookLog()
            let controller = SettingsWindowController(model: model, defaults: defaults,
                                                      hooks: Self.recordingHooks(log))
            controller.show()
            #expect(log.events == ["activate", "present"])
            controller.show()
            #expect(log.events == ["activate", "present", "activate", "present"])
            let window = try #require(controller.window)
            window.close()
            #expect(log.events.last == "afterClose")
            #expect(Self.occurrences(of: "afterClose", in: log.events.joined(separator: " ")) == 1)
            controller.show()
            #expect(controller.window === window, "closing only orders it out — the same window comes back")
            window.delegate = nil
        }
    }

    /// No Dock tile and no app-switcher entry, ever: the app is `.accessory`
    /// from launch (plus LSUIElement), NOTHING promotes it, and the window is
    /// neither miniaturizable (a minimised window would be a Dock tile) nor
    /// resizable, and it is never released on close.
    @Test @MainActor func theWindowCanLeaveNoAppSwitcherOrDockGhost() throws {
        for (name, text) in try LidGuardStructureTests.swiftSources() where text.contains("setActivationPolicy") {
            #expect(name == "NapCatApp.swift", "\(name) changes the activation policy")
            #expect(Self.occurrences(of: "setActivationPolicy(", in: text) == 1)
            #expect(text.contains("NSApp.setActivationPolicy(.accessory)"))
        }
        let plist = try String(contentsOf: LidGuardStructureTests.repoRoot().appendingPathComponent("Resources/Info.plist"),
                               encoding: .utf8)
        #expect(plist.contains("<key>LSUIElement</key>\n\t<true/>"))

        try withModel { model, defaults in
            let controller = SettingsWindowController(model: model, defaults: defaults,
                                                      hooks: Self.recordingHooks(HookLog()))
            controller.show()
            let window = try #require(controller.window)
            defer { window.delegate = nil }
            #expect(window.styleMask == [.titled, .closable])
            #expect(!window.isReleasedWhenClosed)
            #expect(window.collectionBehavior.contains(.moveToActiveSpace), "⌘, from another Space brings it here")
        }

        // The live hooks: activate, then key + front; hide on close.
        let source = try Self.code("SettingsWindowController.swift")
        #expect(MenuPanelStructureTests.flat(source).contains(
            "activate: { NSApp.activate() }, present: { $0.makeKeyAndOrderFront(nil) }, afterClose: { NSApp.hide(nil) }"))
        let show = try #require(source.range(of: "func show() {"))
        let body = source[show.upperBound...].prefix { $0 != "}" }
        let activate = try #require(body.range(of: "hooks.activate()"))
        let present = try #require(body.range(of: "hooks.present(window)"))
        #expect(activate.lowerBound < present.lowerBound, "activation must come first")
    }

    // MARK: - Refresh on becoming key

    @Test @MainActor func becomingKeyRunsTheOwnersRefresh() {
        withModel { model, defaults in
            let controller = SettingsWindowController(model: model, defaults: defaults,
                                                      hooks: Self.recordingHooks(HookLog()))
            var refreshes = 0
            controller.onBecameKey = { refreshes += 1 }
            controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            #expect(refreshes == 2, "every time, not only the first")
        }
    }

    /// The owner's refresh mirrors the menu-open reconciliation's READ steps,
    /// in the same order, and leaves out the panel-only ones — the healing
    /// flush (a send attempt), the turn-on reset and the panel re-fit. Issue
    /// #111: both also run the opportunistic update check through its cadence
    /// gate (at most once a day, opt-out) — never the manual check.
    @Test func theSettingsRefreshMirrorsTheMenuOpenReads() throws {
        let owner = try Self.code("MenuContentView.swift")
        #expect(owner.contains("settingsWindow.onBecameKey = { [weak self] in self?.settingsWindowBecameKey() }"))
        func body(of function: String) throws -> String {
            let start = try #require(owner.range(of: "func \(function)("), "\(function) not found")
            let tail = owner[start.upperBound...]
            return String(tail[..<(tail.range(of: "\n    }\n")?.lowerBound ?? tail.endIndex)])
        }
        let menuOpen = try body(of: "menuWillOpen")
        let settings = try body(of: "settingsWindowBecameKey")
        let reads = ["sleep.refreshObservedState()", "power.reprobeChargeControlIfNeeded()", "limiter.evaluate(reason: ",
                     "loginItem.refresh()", "detection?.sample()", "lidGuard?.refreshArming()",
                     "finishAlert?.reconcile()", "remoteApprovals?.refresh()", "updateCheck?.checkIfDue()", "model.refresh()"]
        for (name, text) in [("menuWillOpen", menuOpen), ("settingsWindowBecameKey", settings)] {
            let positions = try reads.map { read in
                try #require(text.range(of: read), "'\(read)' missing from \(name)").lowerBound
            }
            #expect(positions == positions.sorted(), "\(name) reads in a different order")
        }
        for panelOnly in ["menuOpened", "panelOpened", "refitToContent", "sendTestMessage", ".send(", "checkNow",
                          "fetchLatest"] {
            #expect(!settings.contains(panelOnly), "'\(panelOnly)' — focusing the window must stay a pure read")
        }
    }

    // MARK: - ⌘, from anywhere

    /// The open status menu: a HIDDEN item carries ⌘, (the panel item keeps
    /// ⌘Q) and its key equivalent stays live while hidden.
    @Test @MainActor func theOpenMenuCarriesAHiddenCommandCommaItem() async throws {
        try await withMenuContent { menuContent, log in
            let menu = menuContent.menu
            #expect(menu.items.filter { !$0.isHidden }.count == 1, "the panel stays the one visible item")
            let item = try #require(menu.items.first { $0.keyEquivalent == "," })
            #expect(item.isHidden && item.allowsKeyEquivalentWhenHidden)
            #expect(item.keyEquivalentModifierMask == .command)
            #expect(item.target === menuContent)
            #expect(item.action == #selector(MenuContentView.showSettings(_:)))
            #expect(item.isEnabled)

            // Behaviour, not only wiring: the key equivalent reaches the
            // window through the gateway. (Measured: a headless
            // `performKeyEquivalent` matches the hidden item even WITHOUT
            // `allowsKeyEquivalentWhenHidden`, so the flag — which the AppKit
            // docs require for live key matching — is locked above, not here.)
            #expect(menu.performKeyEquivalent(with: try Self.commandComma()))
            await drainMain()  // the gateway presents on a later main-actor turn
            #expect(log.events == ["activate", "present"])
        }
    }

    /// Everywhere else NapCat is active: the main menu's "Settings…" ⌘, —
    /// installed at launch — plus ⌘W and ⌘Q for the window.
    @Test @MainActor func theMainMenuCarriesCommandComma() async throws {
        try await withMenuContent { menuContent, log in
            let main = AppMainMenu.make(settingsTarget: menuContent)
            let items = main.items.compactMap(\.submenu).flatMap(\.items)
            let settings = try #require(items.first { $0.keyEquivalent == "," })
            #expect(settings.title == "Settings…")
            #expect(settings.keyEquivalentModifierMask == .command)
            #expect(settings.target === menuContent)
            #expect(settings.action == #selector(MenuContentView.showSettings(_:)))
            let close = try #require(items.first { $0.keyEquivalent == "w" })
            #expect(close.action == #selector(NSWindow.performClose(_:)) && close.target == nil)
            let quit = try #require(items.first { $0.keyEquivalent == "q" })
            #expect(quit.action == #selector(NSApplication.terminate(_:)) && quit.target == nil)

            #expect(main.performKeyEquivalent(with: try Self.commandComma()))
            await drainMain()  // the gateway presents on a later main-actor turn
            #expect(log.events == ["activate", "present"])
        }
        let app = try Self.code("NapCatApp.swift")
        #expect(app.contains("NSApp.mainMenu = AppMainMenu.make(settingsTarget: menuContent)"),
                "the main menu is installed at launch")
        #expect(app.contains("statusItemController = StatusItemController(menuContent: menuContent)"),
                "…targeting the one menu owner the status item keeps alive")
    }

    /// The footer gear takes the same route as ⌘,.
    @Test @MainActor func theGearOpensTheWindowThroughTheGateway() async throws {
        try await withMenuContent { menuContent, log in
            menuContent.model.openSettings()
            await drainMain()  // the gateway presents on a later main-actor turn
            #expect(log.events == ["activate", "present"])
        }
    }

    // MARK: - The gear badge

    /// General's resident lines: the Launch at Login caption and the Lock
    /// Screen line — every login status × both lock states.
    @Test(arguments: [
        (SMAppService.Status.enabled, true, PanelSeverity.nominal),
        (.notRegistered, true, .nominal),
        (.requiresApproval, true, .warning),
        (.notFound, true, .warning),
        (.enabled, false, .warning),
        (.notRegistered, false, .warning),
        (.requiresApproval, false, .warning),
        (.notFound, false, .warning),
    ])
    func theGeneralGearBadge(login: SMAppService.Status, lock: Bool, badge: PanelSeverity) {
        let severities = MenuStateModel.generalResidentSeverities(loginStatus: login, lockAvailable: lock)
        #expect(severities.count == 2)
        #expect(MenuStateModel.worstSeverity(severities) == badge)
    }

    /// Through the model: nominal at rest; an unavailable lock raises it; a
    /// charge-limit caption does NOT — its home is the panel's Charge Limit
    /// row, where it surfaces and where it is acted on.
    @Test @MainActor func theGearBadgeThroughTheModel() {
        withModel { model, _ in
            #expect(model.settingsBadge == .nominal)
        }
        let suite = "com.muratalkan.napcat.tests.settings.badge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let power = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        // Intel: the charge-limit caption is info — panel-resident.
        let intel = ChargeLimiter(power: power, isAppleSilicon: false, defaults: defaults)
        let intelModel = MenuStateModel(power: power, sleep: SleepStateController(), limiter: intel,
                                        screenLock: ScreenLockController())
        #expect(intelModel.chargeLimitCaption?.severity == .info, "vacuity: a non-nominal charge-limit caption")
        #expect(intelModel.settingsBadge == .nominal, "the charge-limit caption is panel-resident")
        // No lock API wired: the Lock Screen line warns, and so does the gear.
        let noLock = MenuStateModel(power: power, sleep: SleepStateController(), limiter: intel)
        #expect(noLock.lockScreenStatus.severity == .warning)
        #expect(noLock.settingsBadge == .warning)
        #expect(noLock.settingsBadge == noLock.settingsPanes.flatMap(noLock.settingsResidentSeverities).max())
    }

    /// Alerts' resident lines through the model: an armed lid guard is
    /// quiet; a missing topic (the lid status line's fix is the editor) warns;
    /// a refused send is an error; and the detection pause's echo in the lid
    /// line does NOT raise it (the footer label carries the pause).
    @Test @MainActor func theAlertsGearBadgeThroughTheModel() throws {
        withLidGuardHarness { lid in
            lid.arm()
            withModel(lidGuard: lid.controller) { model, _ in
                #expect(model.settingsBadge == .nominal)
            }
        }
        withLidGuardHarness { lid in
            lid.defaults.set(true, forKey: DefaultsKey.lidGuardEnabled)
            lid.controller.refreshArming()
            withModel(lidGuard: lid.controller) { model, _ in
                #expect(model.lidStatus.severity == .warning, "vacuity: needs a topic")
                #expect(model.settingsBadge == .warning)
            }
        }
        withLidGuardHarness(sender: RecordingMessageSender(outcome: .rejected(403))) { lid in
            lid.arm()
            lid.controller.sendTestMessage()
            withModel(lidGuard: lid.controller) { model, _ in
                #expect(model.settingsBadge == .error)
            }
        }
        let markerDir = FileManager.default.temporaryDirectory.appendingPathComponent("napcat-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: markerDir) }
        let detection = ClaudeActivityController(store: StubMarkerStore(), prober: StubProber(),
                                                 assertions: StubAssertions(), markerDirURL: markerDir)
        detection.setPaused(true)
        detection.sample()
        withLidGuardHarness { lid in
            lid.arm()
            withModel(detection: detection, lidGuard: lid.controller) { model, _ in
                #expect(model.lidStatus.severity == .warning && model.lidStatus.text.hasPrefix("Cannot fire"),
                        "vacuity: the pause's echo")
                #expect(model.settingsResidentSeverities(.alerts).allSatisfy { $0 == .nominal })
            }
        }
    }

    /// The gear badge's INDEPENDENT oracle — the retired Details badge's own
    /// derivation, kept here when the disclosure left the panel (slice P):
    /// the worst severity over every Settings-resident line read through the
    /// model's public line accessors (the problems the panel surfaces below
    /// its cards), plus the lid and session status lines with the pause's
    /// echo removed — never through `settingsResidentSeverities`.
    @MainActor static func badgeOracle(_ model: MenuStateModel, now: Double) -> PanelSeverity {
        let lines: [PanelLine?] = [model.launchAtLoginCaption, model.lockScreenStatus]
            + (model.claudeDetectionVisible ? [model.hookStatus, model.claudeAwakeLine, model.hookVersionStatus] : [])
        var severities = lines.compactMap { $0?.severity }
        if model.lidGuardVisible {
            severities.append(MenuStateModel.lidAlertStatus(for: model.lidGuardArming, lastOutcome: model.lidGuardLastOutcome,
                                                            detectionPaused: false).severity)
            severities += [model.lidTopicStatus.severity, model.lidServerStatus.severity, model.lidLastSend(now: now).severity]
        }
        if model.finishAlertVisible {
            let session = MenuStateModel.finishAlertStatus(
                for: model.finishAlertDisplayState, lastOutcome: model.finishAlertLastOutcome,
                lastOutcomeAt: model.finishAlertLastOutcomeAt, lidLastOutcome: model.lidGuardLastOutcome,
                lidLastOutcomeAt: model.lidGuardLastOutcomeAt)
            severities.append(model.finishAlertDisplayState == .paused ? .nominal : session.severity)
            severities.append(model.finishAlertLastSend(now: now).severity)
        }
        if let phone = model.phoneAlertStatus(now: now) { severities.append(phone.severity) }
        return severities.max() ?? .nominal
    }

    /// THE BADGE AGREEMENT (slice W, re-anchored in slice P): with every pane
    /// in place the gear's Settings-resident set is exactly the oracle's set
    /// — the same lines, the pause's echoes excluded the same way — so the
    /// badge never disagrees with the problems the panel surfaces. Every
    /// subsystem state that can raise it, through the model.
    @Test @MainActor func theGearBadgeAgreesWithItsOracle() throws {
        func detection(hook: Bool = true, version: Int?? = nil, holding: Bool = false, paused: Bool = false,
                       _ body: (ClaudeActivityController, URL) throws -> Void) throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("napcat-settings-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = StubMarkerStore(hookInstalled: hook)
            if let version { store.installedVersion = version }
            let controller = ClaudeActivityController(store: store, prober: StubProber(),
                                                      assertions: StubAssertions(holdingAwake: holding), markerDirURL: dir)
            controller.setPaused(paused)
            controller.sample()
            try body(controller, dir)
        }
        func check(_ model: MenuStateModel, _ expected: PanelSeverity, _ name: String) {
            #expect(model.settingsPanes.count == 1 + (model.lidGuardVisible ? 1 : 0) + (model.claudeDetectionVisible ? 1 : 0))
            #expect(model.settingsBadge == Self.badgeOracle(model, now: 1_000_000), "\(name): the badge disagrees")
            #expect(model.settingsBadge == expected, "\(name)")
        }

        withModel { model, _ in check(model, .nominal, "debugBattery wiring") }
        let suite = "com.muratalkan.napcat.tests.settings.agree.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let power = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        let limiter = ChargeLimiter(power: power, isAppleSilicon: true, defaults: defaults)
        check(MenuStateModel(power: power, sleep: SleepStateController(), limiter: limiter), .warning, "no lock API")

        try detection(holding: true) { claude, _ in
            withModel(detection: claude) { model, _ in check(model, .nominal, "healthy hook, holding awake") }
        }
        try detection(version: .some(ClaudeBusyConstants.hookVersion - 1)) { claude, _ in
            withModel(detection: claude) { model, _ in check(model, .warning, "an out-of-date hook copy") }
        }
        try detection(version: .some(ClaudeBusyConstants.hookVersion + 1)) { claude, _ in
            withModel(detection: claude) { model, _ in check(model, .info, "a newer hook copy") }
        }
        try detection(hook: false) { claude, _ in
            withModel(detection: claude) { model, _ in check(model, .nominal, "no hook, both alerts off (H1)") }
            withLidGuardHarness { lid in
                lid.arm()
                withModel(detection: claude, lidGuard: lid.controller) { model, _ in
                    check(model, .warning, "no hook, lid alert on")
                }
            }
        }
        try detection(paused: true) { claude, markerDir in
            withLidGuardHarness { lid in
                lid.arm()
                lid.defaults.set(true, forKey: DefaultsKey.claudeFinishAlertEnabled)
                // The finish alert reads the SAME DISABLED flag (its marker
                // dir is the detection's), so the session line is `.paused`.
                let finish = Self.makeFinishAlert(lid, markerDir: markerDir)
                withModel(detection: claude, lidGuard: lid.controller, finishAlert: finish) { model, _ in
                    #expect(model.footerLabel?.severity == .warning, "vacuity: paused")
                    #expect(model.finishAlertDisplayState == .paused && model.lidStatus.severity == .warning,
                            "vacuity: both echoes warn at top level")
                    check(model, .nominal, "paused — its echoes never count")
                }
            }
        }
        try detection { claude, _ in
            withLidGuardHarness(sender: RecordingMessageSender(outcome: .rejected(403))) { lid in
                lid.arm()
                lid.controller.sendTestMessage()
                withModel(detection: claude, lidGuard: lid.controller) { model, _ in
                    check(model, .error, "a refused lid send")
                }
            }
            // An UNCONFIRMED lid send while armed: the lid status line does
            // not downgrade (it still reads armed), so the History line is
            // the badge's SOLE warning raiser. (A refused send cannot show
            // this: its status line raises the badge to the same error.)
            withLidGuardHarness(sender: RecordingMessageSender(outcome: .timedOutUnconfirmed)) { lid in
                lid.arm()
                lid.controller.sendTestMessage()
                withModel(detection: claude, lidGuard: lid.controller) { model, _ in
                    #expect(model.lidGuardArming == .armed && model.lidStatus.severity == .nominal,
                            "vacuity: armed, and the status line is not downgraded")
                    #expect(model.lidLastSend(now: lid.clock.now).severity == .warning,
                            "vacuity: the History line warns")
                    check(model, .warning, "an unconfirmed lid send")
                }
            }
            withLidGuardHarness { lid in
                lid.arm()
                let composite = CompositeMessageSender(ntfy: RecordingMessageSender(), phone: RecordingMessageSender(),
                                                       defaults: lid.defaults, isEntitled: { false })
                composite.setPhoneTransportEnabled(true)
                withModel(detection: claude, lidGuard: lid.controller, phoneTransport: composite) { model, _ in
                    check(model, .info, "phone alerts on in an unentitled build")
                }
            }
        }
    }

    /// Issue #111: the update state is NOMINAL under the iron rule. A known
    /// newer release shows the panel's one INFO line and nothing else; a
    /// failed check shows nothing at all — and neither ever raises the gear
    /// badge (which still agrees with its oracle).
    @Test @MainActor func theUpdateStateNeverRaisesTheGearBadge() async throws {
        for (stored, answer, line) in [
            ("v1.7.0" as String?, ReleaseCheckOutcome.failed(.transport),
             PanelLine(text: "Update available — v1.7.0", severity: .info) as PanelLine?),
            (nil, .failed(.httpStatus(403)), nil),
            (nil, .latest(ReleaseVersion(tag: "v2.0.0")!), PanelLine(text: "Update available — v2.0.0", severity: .info)),
            (nil, .latest(ReleaseVersion(tag: "v1.6.0")!), nil),
        ] {
            let suite = "com.muratalkan.napcat.tests.settings.updatebadge.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            if let stored { defaults.set(stored, forKey: DefaultsKey.updateCheckLatestTag) }
            let checker = ScriptedReleaseChecker()
            let update = UpdateCheckController(running: try #require(ReleaseVersion(bundleVersion: "1.6.0")),
                                               defaults: defaults, checker: checker, now: { 1_000_000 },
                                               openReleasePage: { _ in })
            let power = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
            let model = MenuStateModel(power: power, sleep: SleepStateController(),
                                       limiter: ChargeLimiter(power: power, isAppleSilicon: true, defaults: defaults),
                                       screenLock: ScreenLockController(), updateCheck: update)
            update.checkNow()
            checker.answer(answer)
            await drainMain()
            model.refresh()
            #expect(model.updateCheckLastResult != nil, "vacuity: the check finished")
            #expect(model.updateAvailableLine == line, "\(answer)")
            #expect(model.settingsBadge == .nominal, "\(answer): the update state never raises the badge")
            #expect(model.settingsBadge == Self.badgeOracle(model, now: 1_000_000))
        }
    }

    /// The session lane's own problems raise the gear badge, the lid half
    /// healthy: a refused session alert (an error — the status line and the
    /// History line both raise it), and an UNCONFIRMED one (a warning), whose
    /// status line stays armed, so the History line is the SOLE raiser.
    @Test(arguments: [
        (MessageSendOutcome.rejected(403), PanelSeverity.error, PanelSeverity.error),
        (.timedOutUnconfirmed, .nominal, .warning),
    ])
    @MainActor func aSessionSendProblemRaisesTheGearBadge(outcome: MessageSendOutcome, status: PanelSeverity,
                                                          badge: PanelSeverity) async throws {
        typealias H = FinishAlertHarness
        try await withFinishAlertHarness(sender: RecordingMessageSender(outcome: outcome)) { h in
            h.store.put(H.s1, ts: H.t0 - 600)
            h.controller.reconcile()
            h.store.remove(H.s1)
            await h.settle()
            #expect(h.controller.lastSendOutcome == outcome)
            #expect(h.pendingRetries.isEmpty, "neither outcome is retried")
            let suite = "com.muratalkan.napcat.tests.settings.session.\(UUID().uuidString)"
            let lidDefaults = UserDefaults(suiteName: suite)!
            defer { lidDefaults.removePersistentDomain(forName: suite) }
            let lid = LidGuardHarness(defaults: lidDefaults, sender: RecordingMessageSender())
            lid.arm()
            lidDefaults.set(true, forKey: DefaultsKey.claudeFinishAlertEnabled)
            withModel(lidGuard: lid.controller, finishAlert: h.controller) { model, _ in
                #expect(model.lidStatus.severity == .nominal, "vacuity: the lid half is healthy")
                #expect(model.finishAlertStatus.severity == status, "vacuity: the session status line")
                #expect(model.finishAlertLastSend(now: Double(H.t0) + 120).severity == badge,
                        "vacuity: the History line")
                #expect(model.settingsBadge == badge)
                #expect(model.settingsBadge == Self.badgeOracle(model, now: Double(H.t0) + 120))
            }
        }
    }

    /// Both routes reach the window through the one dismissal gateway.
    @Test func showSettingsGoesThroughTheDismissalGateway() throws {
        let owner = try Self.code("MenuContentView.swift")
        #expect(MenuPanelStructureTests.flat(owner).contains(
            "@objc func showSettings(_ sender: Any?) { closeMenuThenPresent { [weak self] in self?.settingsWindow.show() } }"))
        #expect(Self.occurrences(of: "settingsWindow.show()", in: owner) == 1)
    }

    // MARK: - Structure: the panel's rules apply to every Settings file

    @Test func everySettingsFileExists() throws {
        let names = Set(try LidGuardStructureTests.swiftSources().map(\.name))
        for file in Self.settingsFiles {
            #expect(names.contains(file), "\(file) is not in Sources/NapCat — update the file list")
        }
        for file in Self.settingsFiles {
            #expect(LidGuardStructureTests.menuFiles.contains(file), "\(file) must be in the menu-file capability scan")
            #expect(LidGuardStructureTests.logScannedFiles.contains(file), "\(file) must be in the topic-log scan")
        }
    }

    /// The topic is a password: no Settings file can even name it.
    @Test func settingsCannotReadTheTopic() throws {
        for file in Self.settingsFiles {
            let text = try Self.code(file)
            #expect(!text.contains("lidGuardTopic"), "\(file) names the secret topic mirror")
            #expect(!text.contains("storedTopic"), "\(file) reaches for the stored topic")
        }
    }

    @Test func settingsUseSystemColorsOnly() throws {
        let views = try Self.code(Self.settingsViewFile)
        for token in ["Color(red", "Color(hue", "Color(white", "Color(\"", "Color(#", "hex", "#colorLiteral",
                      "NSColor(", "UIColor", ".rgb"] {
            #expect(!views.contains(token), "'\(token)' — use system materials / semantic colors only")
        }
    }

    /// The panes never classify: every status line comes from the
    /// composition, and the views carry no severity decision of their own.
    @Test func thePanesRenderTheCompositionAndNeverClassify() throws {
        let views = try Self.code(Self.settingsViewFile)
        #expect(views.contains("model.settingsContent(for: selection.pane,"))
        for token in ["severity ==", "severity !=", ".severity", "placement(ofSettingsLine:", "SurfacedLine(",
                      "TuckedLine(", "featureState", "loginItemStatus"] {
            #expect(!views.contains(token), "'\(token)' in a Settings view — the composition decides")
        }
        // No motion of its own: pane switches and caption changes snap. The
        // one animation is a button's press (issue #86) — the panel's
        // sanctioned `PanelMotion.press`, held to the panel's motion locks
        // (MenuPanelStructureTests).
        #expect(Self.occurrences(of: ".animation(", in: views) == 1, "one animation: the buttons' press")
        #expect(MenuPanelStructureTests.motionGateFailures(views: views).isEmpty,
                "\(MenuPanelStructureTests.motionGateFailures(views: views))")
        for token in ["withAnimation", ".transition("] {
            #expect(!views.contains(token), "'\(token)' — the Settings window does not animate")
        }
    }

    /// Issue #86 (owner pick "settings b"): every Settings button is drawn by
    /// `SettingsPressButtonStyle`, so each one presses with the panel's quiet
    /// spring — the bordered pair (ntfy settings…, and the test send through
    /// its wrapper) on the card-family bezel, the Login Items shortcut as a
    /// link. A system style exposes no press state, so none is left on a
    /// Settings button, and those three are the only buttons. The bezel is
    /// the card's treatment — its radius, fill, boost and hairline, no new
    /// color — and a disabled label takes AppKit's disabled control text.
    /// The link look keeps `.link`'s role: a custom style reads as a button
    /// (external AXButton), so the link look — and only it — adds `.isLink`,
    /// which external clients read as AXLink, as on `.link`.
    @Test func everySettingsButtonPressesWithTheQuietSpring() throws {
        let views = try Self.code(Self.settingsViewFile)
        let flat = MenuPanelStructureTests.flat(views)
        #expect(flat.contains("Button(\"Open Login Items Settings…\") { model.openLoginItemsSettings() }"
                              + " .buttonStyle(SettingsPressButtonStyle(look: .link)) .font(.caption)"),
                "the Login Items shortcut presses as a link")
        #expect(flat.contains("case .ntfyButtons: HStack(spacing: PanelMetrics.regular) {"
                              + " Button(\"ntfy settings…\") { model.editLidGuardSettings() }"
                              + " SendFeedbackButton(model: model, controlSize: .regular) }"
                              + " .buttonStyle(SettingsPressButtonStyle(look: .bezel))"),
                "the bordered pair — the test send included — presses on the bezel")
        // Issue #111: "Check for Updates…" is the fourth, on the bezel too.
        #expect(flat.contains("Button(\"Check for Updates…\") { model.checkForUpdates() }"
                              + " .buttonStyle(SettingsPressButtonStyle(look: .bezel)) .disabled(checking)"),
                "the update check presses on the bezel and rests while a check is out")
        // S-PAIR-C1 (#168): the pairing buttons, on the bezel too.
        #expect(flat.contains("case let .pairingButtons(paired): HStack(spacing: PanelMetrics.regular) {"
                              + " Button(paired ? MenuStateModel.pairNewButtonTitle : MenuStateModel.pairButtonTitle)"
                              + " { model.beginPairing() } if paired { Button(MenuStateModel.unpairButtonTitle) { model.unpair() } }"
                              + " } .buttonStyle(SettingsPressButtonStyle(look: .bezel))"),
                "Pair iPhone… / Pair a New iPhone… and Unpair… press on the bezel")
        #expect(Self.occurrences(of: "Button(\"", in: views) == 3 && Self.occurrences(of: "SendFeedbackButton(", in: views) == 1
                && Self.occurrences(of: "Button(paired ? ", in: views) == 1
                && Self.occurrences(of: "Button(MenuStateModel.unpairButtonTitle)", in: views) == 1
                && Self.occurrences(of: "Button(", in: views) == 6
                && Self.occurrences(of: "Button {", in: views) == 0, "the Settings buttons are exactly these six")
        #expect(Self.occurrences(of: ".buttonStyle(", in: views) == 4, "every button under the one style")
        for token in [".buttonStyle(.", "PanelPressFadeButtonStyle", "BorderedButtonStyle", "LinkButtonStyle",
                      "PlainButtonStyle", "onLongPressGesture", "DragGesture", ".gesture(", "NSTrackingArea"] {
            #expect(!views.contains(token), "'\(token)' — the press comes from configuration.isPressed alone")
        }

        let style = try #require(MenuPanelStructureTests.structChunk("SettingsPressButtonStyle", in: views))
        for token in [
            "@Environment(\\.isEnabled) private var isEnabled",
            "let shape = RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous)",
            ".foregroundStyle(ink(.primary))",
            ".padding(.horizontal, SettingsMetrics.bezelPadding)",
            ".frame(height: SettingsMetrics.bezelHeight)",
            "shape.fill(Color(nsColor: .quaternarySystemFill))",
            "shape.fill(PanelCard<EmptyView>.boost(colorScheme))",
            ".overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: PanelMetrics.cardStroke))",
            ".contentShape([.interaction, .focusEffect], shape)",
            ".foregroundStyle(ink(.link))",
            "isEnabled ? AnyShapeStyle(enabled) : AnyShapeStyle(Color(nsColor: .disabledControlTextColor))",
        ] {
            #expect(style.contains(token), "'\(token)' not found — the Settings button look was rewired")
        }
        for token in ["Color.white", "Color.black", "cardBoostLight", "cardBoostDark", ".opacity(0", "Color.accentColor"] {
            #expect(!style.contains(token), "'\(token)' — the bezel reuses the card's colors, nothing new")
        }
        #expect(MenuPanelStructureTests.flat(style).contains(
            "case .link: label .foregroundStyle(ink(.link)) .accessibilityAddTraits(.isLink) }"),
                "the link look must keep the link role (external AXLink, as on .link)")
        #expect(Self.occurrences(of: ".accessibilityAddTraits(.isLink)", in: views) == 1
                && !views.contains("accessibilityRemoveTraits"), "the link role is the link look's alone")
    }

    /// Issue #86: the bezel keeps the native regular push button's footprint
    /// (`SettingsMetrics`, measured on macOS 27.2.1 — "Send test message"
    /// 140 × 24 pt and "ntfy settings…" 110.5 × 24 pt, the system button's
    /// own frames): a fixed 24 pt tall, the label `bezelPadding` in from each
    /// side — disabled too. The link keeps its label's own size, as `.link`
    /// does. The press only scales the drawing, so no size here ever moves.
    @Test @MainActor func theSettingsButtonsKeepTheNativeFootprint() {
        #expect(SettingsMetrics.bezelHeight == 24 && SettingsMetrics.bezelPadding == 12)
        func size(_ view: some View) -> CGSize { NSHostingView(rootView: view).fittingSize }
        for title in ["ntfy settings…", "Send test message"] {
            let label = size(Text(title))
            for enabled in [true, false] {
                let bezel = size(Button(title) {}.buttonStyle(SettingsPressButtonStyle(look: .bezel)).disabled(!enabled))
                #expect(bezel.height == SettingsMetrics.bezelHeight, "\(title): \(bezel)")
                #expect(abs(bezel.width - (label.width + 2 * SettingsMetrics.bezelPadding)) < 0.01,
                        "\(title): \(bezel.width) pt for a \(label.width) pt label")
            }
        }
        let title = "Open Login Items Settings…"
        let link = size(Button(title) {}.buttonStyle(SettingsPressButtonStyle(look: .link)).font(.caption))
        #expect(link == size(Text(title).font(.caption)), "the link is its label's size: \(link)")
    }

    /// #84: the note is a fact, not a control — the info glyph (hidden from
    /// VoiceOver: the text says it all) and the text, both secondary, with
    /// nothing focusable, tappable or actionable. The composition builds it
    /// exactly once, from the existing constant, for the gated state only.
    @Test func theNoteIsAQuietFactForTheGatedStateOnly() throws {
        let views = try Self.code(Self.settingsViewFile)
        #expect(Self.occurrences(of: "case let .note(text):", in: views) == 1)
        let note = try #require(views.components(separatedBy: "case let .note(text):").dropFirst().first?
            .components(separatedBy: "case ").first)
        #expect(MenuPanelStructureTests.flat(note) == [
            "HStack(alignment: .firstTextBaseline, spacing: PanelMetrics.tight) {",
            "Image(systemName: PanelSymbol.info) .accessibilityHidden(true)",
            "Text(text) .fixedSize(horizontal: false, vertical: true) .frame(maxWidth: .infinity, alignment: .leading)",
            "} .foregroundStyle(.secondary)",
        ].joined(separator: " "), "the note was rewired: \(MenuPanelStructureTests.flat(note))")
        let composition = MenuPanelStructureTests.flat(try Self.code(Self.compositionFile))
        #expect(Self.occurrences(of: ".note(", in: composition) == 1, "one note")
        #expect(composition.contains(
            "if featureState == .controlUnavailable { "
                + "sections.append(SettingsSection(title: \"Charge Limit\", rows: [.note(chargeControlUnavailableText)])) "
                + "} else if featureState != .hidden {"),
            "the note replaces the controls for the gated state only")
    }

    /// Every Settings control forwards to the SAME model action as its
    /// panel twin — never a second path to a controller.
    @Test func everySettingsControlForwardsToTheModel() throws {
        let views = try Self.code(Self.settingsViewFile)
        for forward in ["set: { model.setLaunchAtLogin($0) }", "model.openLoginItemsSettings()",
                        "set: { model.setLimitEnabled($0) }", "set: { model.setLimit(Int($0.rounded())) }",
                        "Button(\"ntfy settings…\") { model.editLidGuardSettings() }",
                        "SendFeedbackButton(model: model, controlSize: .regular)",
                        "set: { model.setFinishAlertMinimumRunSeconds($0) }",
                        "set: { model.setPhoneTransportEnabled($0) }", "set: { model.setDetectionPaused($0) }",
                        "Button(\"Check for Updates…\") { model.checkForUpdates() }",
                        "set: { model.setUpdateCheckAutoEnabled($0) }",
                        "set: { model.setRemoteApprovalsEnabled($0) }"] {
            #expect(Self.occurrences(of: forward, in: views) == 1, "'\(forward)' — exactly one Settings control")
        }
        for token in ["cancelTracking", "request", "lidGuard?.", "finishAlert?.", "detection?.", "UserDefaults",
                      "defaults."] {
            #expect(!views.contains(token), "'\(token)' in a Settings view — controls only forward to the model")
        }
    }

    // MARK: - The iron rule: Settings never becomes a problem's only home

    /// Every member of MenuStateModel that yields a `PanelLine`.
    static func panelLineMembers() throws -> Set<String> {
        let source = try Self.code("MenuStateModel.swift")
        let regex = try NSRegularExpression(
            pattern: #"(?:func|var)\s+(\w+)(?:\([^{]*?\))?\s*(?:->|:)\s*PanelLine\??\s*\{"#)
        let range = NSRange(source.startIndex..., in: source)
        return Set(regex.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        })
    }

    /// Each line mapping a Settings pane uses → its ONE top-level home in the
    /// panel. Settings renders lines in full at every severity, but a problem
    /// must still surface in the panel exactly once — so no line may live in
    /// Settings without that home.
    static let panelHomes: [String: String] = [
        "launchAtLoginCaption": "SurfacedLaunchAtLogin(model: model)",
        "chargeLimitCaption": "indentedCaption(model.chargeLimitCaption)",
        "lockScreenStatus": "SurfacedLine(line: model.lockScreenStatus)",
        "lidServerStatus": "SurfacedLine(line: model.lidServerStatus)",
        "lidTopicStatus": "SurfacedLine(line: model.lidTopicStatus)",
        "lidLastSend": "SurfacedLine(line: model.lidLastSend(",
        "finishAlertLastSend": "SurfacedLine(line: model.finishAlertLastSend(",
        "phoneAlertStatus": "SurfacedLine(line: model.phoneAlertStatus(",
        // The Claude status is the footer's own caption, always shown.
        "claudeFooterLabel": "if let label = model.footerLabel {",
        "hookStatus": "SurfacedLine(line: model.hookStatus)",
        "hookVersionStatus": "SurfacedLine(line: model.hookVersionStatus)",
        "claudeAwakeLine": "SurfacedLine(line: model.claudeAwakeLine)",
        // F4 slice S2: the switch's status is the panel row's own caption;
        // the channel-policy reading surfaces below the cards.
        "remoteApprovalsStatus": "indentedCaption(model.remoteApprovalsStatus)",
        "remoteApprovalsPolicyLine": "SurfacedLine(line: model.remoteApprovalsPolicyLine)",
    ]

    static func settingsLineMappings() throws -> Set<String> {
        let composition = try Self.code(Self.compositionFile)
        return try Self.panelLineMembers().filter { name in
            composition.range(of: #"\b\#(name)\b"#, options: .regularExpression) != nil
        }
    }

    /// Doctrine (#84): a permanent hardware limitation is an ABSENCE, not a
    /// problem. A firmware-gated charge limit (`.controlUnavailable`, and that
    /// state ONLY) hides its panel row outright instead of captioning it —
    /// sanctioned, so the missing caption is not a line losing its home. Its
    /// Settings › General note is deliberately a plain string
    /// (`SettingsRow.note`), not a `PanelLine` severity line: it stays outside
    /// this scan, and the iron rule keeps its full force for real problems —
    /// every line that CAN be one still has exactly one top-level home.
    @Test func everySettingsLineHasOneTopLevelHomeInThePanel() throws {
        let members = try Self.panelLineMembers()
        #expect(members.isSuperset(of: ["lockScreenStatus", "hookStatus", "lidLastSend", "claudeHookStatus"]),
                "vacuity: the PanelLine scan finds the model's line mappings — got \(members.sorted())")
        let used = try Self.settingsLineMappings()
        #expect(used == Set(Self.panelHomes.keys), "a Settings line without a declared panel home: \(used.sorted())")
        let panel = try MenuPanelStructureTests.allViewCode()
        for (mapping, home) in Self.panelHomes {
            #expect(Self.occurrences(of: home, in: panel) == 1, "\(mapping): '\(home)' must render exactly once")
        }
    }
}
