// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import ServiceManagement
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
    private func withModel(_ body: (MenuStateModel, UserDefaults) throws -> Void) rethrows {
        let suite = "com.muratalkan.napcat.tests.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let power = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        let limiter = ChargeLimiter(power: power, isAppleSilicon: true, defaults: defaults)
        let model = MenuStateModel(power: power, sleep: SleepStateController(), limiter: limiter,
                                   screenLock: ScreenLockController())
        try body(model, defaults)
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
    static let settingsFiles = ["SettingsContent.swift", "SettingsPanes.swift", "SettingsWindowController.swift"]
    /// The Settings window's SwiftUI view file.
    static let settingsViewFile = "SettingsPanes.swift"
    /// Where the panes are composed (the only place a pane picks its lines).
    static let compositionFile = "SettingsContent.swift"

    // MARK: - Composition: the General pane

    static let lockAvailableLine = PanelLine(
        text: "Lock Screen: available — locks and turns the display off; the Mac keeps running", severity: .nominal)
    static let lockUnavailableLine = PanelLine(
        text: "Locking is unavailable on this version of macOS — use Apple menu › Lock Screen (⌃⌘Q).",
        severity: .warning)
    static let approvalCaption = PanelLine(
        text: "Waiting for approval in System Settings › General › Login Items.", severity: .warning)
    static let notFoundCaption = PanelLine(
        text: "Login item not found — toggle again to re-register this copy of NapCat.", severity: .warning)

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
                                   PanelLine(text: "Charging normally — will pause at the limit.", severity: .nominal)),
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
                                   PanelLine(text: "Charging is paused at the limit.", severity: .nominal)),
                       lockScreen(lockAvailableLine),
                   ]),
        GeneralRow(name: "login not found, setup required", login: .notFound, feature: .setupRequired, limit: 90,
                   limitOn: true, lock: true, sections: [
                       startup(false, notFoundCaption),
                       chargeLimit("Pause charging at 90%", on: true, limit: 90, sliderEnabled: true, PanelLine(
                           text: "One-time setup needed: run “sudo ./scripts/setup.sh” in the NapCat folder, then reopen this menu.",
                           severity: .warning)),
                       lockScreen(lockAvailableLine),
                   ]),
        GeneralRow(name: "Intel", login: .enabled, feature: .notSupported, limit: 90, limitOn: true, lock: true,
                   sections: [
                       startup(true),
                       chargeLimit("Pause charging at 90%", on: true, switchEnabled: false, limit: 90,
                                   sliderEnabled: false, PanelLine(
                                       text: "Charge limiting needs an Apple Silicon Mac. Stay Awake still works here.",
                                       severity: .info)),
                       lockScreen(lockAvailableLine),
                   ]),
        GeneralRow(name: "no charge-control key (#58)", login: .enabled, feature: .controlUnavailable, limit: 75,
                   limitOn: false, lock: true, sections: [
                       startup(true),
                       chargeLimit("Pause charging at 75%", on: false, limit: 75, sliderEnabled: false, PanelLine(
                           text: "Charge limiting isn't available on this version of macOS.", severity: .info)),
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

    /// The model's wrapper feeds the pure composition its own mirrors, and
    /// re-composes on every refresh (the header follows the slider).
    @Test @MainActor func theModelComposesTheGeneralPaneFromItsMirrors() {
        withModel { model, _ in
            #expect(model.settingsPanes == [.general])
            #expect(model.settingsContent(for: .general) == model.generalPane)
            #expect(model.generalPane == MenuStateModel.generalPane(
                loginStatus: model.loginItemStatus, featureState: model.featureState, limit: model.limit,
                limitEnabled: model.limitEnabled, lockAvailable: model.lockScreenAvailable))
            model.setLimitEnabled(true)
            model.setLimit(75)
            model.refresh()
            let rows = model.generalPane.sections.flatMap(\.rows)
            #expect(rows.contains { row in
                if case let .chargeLimit(header, isOn, _, limit, sliderEnabled, _) = row {
                    return header == "Pause charging at 75%" && isOn && limit == 75 && sliderEnabled
                }
                return false
            }, "\(rows)")
        }
    }

    // MARK: - The panes, their symbols, the restored pane

    @Test func thePanesAreLockedInToolbarOrder() {
        // Stored raw values: a rename would orphan every stored selection.
        #expect(SettingsPane.allCases.map(\.rawValue) == ["general"])
        #expect(SettingsPane.allCases.map(\.title) == ["General"])
        #expect(SettingsPane.allCases.map(\.symbol) == ["gearshape"])
        for pane in SettingsPane.allCases {
            #expect(NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil) != nil,
                    "\(pane.symbol) does not resolve")
        }
    }

    @Test(arguments: [
        ("unset", nil, SettingsPane.general),
        ("general", "general", .general),
        ("unknown pane", "advanced", .general),
        ("wrong case", "General", .general),
        ("not a string", 3, .general),
    ] as [(String, (any Sendable)?, SettingsPane)])
    func theRestoredPane(name: String, stored: (any Sendable)?, expected: SettingsPane) {
        #expect(SettingsPane.restored(stored: stored, available: SettingsPane.allCases) == expected, "\(name)")
    }

    @Test func restorationFallsBackToTheFirstAvailablePane() {
        #expect(SettingsPane.restored(stored: "general", available: []) == .general)
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
    /// flush (a send attempt), the turn-on reset and the panel re-fit.
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
                     "finishAlert?.reconcile()", "model.refresh()"]
        for (name, text) in [("menuWillOpen", menuOpen), ("settingsWindowBecameKey", settings)] {
            let positions = try reads.map { read in
                try #require(text.range(of: read), "'\(read)' missing from \(name)").lowerBound
            }
            #expect(positions == positions.sorted(), "\(name) reads in a different order")
        }
        for panelOnly in ["menuOpened", "panelOpened", "refitToContent", "sendTestMessage", ".send("] {
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
        #expect(MenuStateModel.detailsBadge(severities) == badge)
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
        #expect(views.contains("model.settingsContent(for: selection.pane)"))
        for token in ["severity ==", "severity !=", ".severity", "placement(ofDetailsLine:", "SurfacedLine(",
                      "TuckedLine(", "featureState", "loginItemStatus"] {
            #expect(!views.contains(token), "'\(token)' in a Settings view — the composition decides")
        }
        // No motion of its own: pane switches and caption changes snap.
        for token in [".animation(", "withAnimation", ".transition("] {
            #expect(!views.contains(token), "'\(token)' — the Settings window does not animate")
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
    ]

    static func settingsLineMappings() throws -> Set<String> {
        let composition = try Self.code(Self.compositionFile)
        return try Self.panelLineMembers().filter { name in
            composition.range(of: #"\b\#(name)\b"#, options: .regularExpression) != nil
        }
    }

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
