import AppKit
import Testing
@testable import NapCat

/// Menu scaffold tests (Swift Testing — XCTest is unavailable with
/// Command Line Tools only; see PLAN.md decision log 2026-07-09).
/// Construction only — no test here (or anywhere) may invoke sudo or spawn
/// the real watchdog; the power interface is always the simulator, so
/// building these objects runs no external process.
@MainActor
struct ScaffoldTests {
    /// Isolated defaults suite so tests never touch com.muratalkan.napcat.
    private static let testSuite = "com.muratalkan.napcat.tests"

    private func makeMenuContent(simulator: DebugPowerSimulator = DebugPowerSimulator(batteryPercent: 80,
                                                                                        adapterConnected: true))
        -> MenuContentView {
        let defaults = UserDefaults(suiteName: Self.testSuite)!
        defaults.removePersistentDomain(forName: Self.testSuite)
        let limiter = ChargeLimiter(power: simulator, isAppleSilicon: true, defaults: defaults)
        return MenuContentView(
            sleep: SleepStateController(),
            watchdog: WatchdogController(),
            power: simulator,
            limiter: limiter,
            simulator: simulator,
            defaults: defaults
        )
    }

    /// The bundle's marketing version is a plain `MAJOR.MINOR.PATCH` (the
    /// value itself is bumped per release and deliberately not locked here).
    @Test func bundleShortVersionIsSemantic() throws {
        let url = URL(fileURLWithPath: #filePath)   // Tests/NapCatTests/<this file>
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let plist = try PropertyListSerialization.propertyList(from: try Data(contentsOf: url), format: nil)
        let version = try #require((plist as? [String: Any])?["CFBundleShortVersionString"] as? String)
        #expect(version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
                "CFBundleShortVersionString '\(version)' must be MAJOR.MINOR.PATCH")
    }

    @Test func placeholderIconIsTemplateAtIconPointHeight() {
        let icon = StatusItemController.placeholderIcon()
        #expect(icon.isTemplate, "menu bar icon must be a template image")
        #expect(StatusItemController.iconPointHeight == 21, "locked render size (user decision 2026-07-10)")
        #expect(icon.size == NSSize(
            width: StatusItemController.iconPointHeight,
            height: StatusItemController.iconPointHeight
        ))
    }

    /// UI audit M1b (2026-11-19): the status item's button — only the cat
    /// image, no text — is named "NapCat" for VoiceOver and shows it as a
    /// tooltip. Headless on a plain NSButton (a test must never add an item
    /// to the real menu bar); the lint half locks that the controller names
    /// its real button at creation, before the frame load can bail out to
    /// the placeholder icon.
    @Test func statusItemButtonIsNamedForVoiceOverAndHover() throws {
        let button = NSButton(image: StatusItemController.placeholderIcon(), target: nil, action: nil)
        #expect(button.toolTip == nil && button.accessibilityLabel() != "NapCat", "vacuity: an unnamed image button")
        StatusItemController.nameButton(button)
        #expect(button.accessibilityLabel() == "NapCat")
        #expect(button.toolTip == "NapCat")
        // Every animation frame swaps the image; the name stays.
        button.image = StatusItemController.placeholderIcon()
        #expect(button.accessibilityLabel() == "NapCat")
        #expect(button.toolTip == "NapCat")

        let source = LidGuardStructureTests.codeOnly(try String(
            contentsOf: LidGuardStructureTests.sourcesDir().appendingPathComponent("StatusItemController.swift"),
            encoding: .utf8
        ))
        let start = try #require(source.range(of: "init(menuContent: MenuContentView) {"), "init not found")
        let end = try #require(source[start.upperBound...].range(of: "\n    }\n"))
        let initBody = source[start.upperBound..<end.lowerBound]
        let created = try #require(initBody.range(of: "statusItem = NSStatusBar.system.statusItem("))
        let named = try #require(initBody.range(of: "if let button = statusItem.button { Self.nameButton(button) }"),
                                 "the controller must name its status item's button")
        let frames = try #require(initBody.range(of: "guard"), "the frame-load guard not found")
        #expect(created.upperBound < named.lowerBound && named.upperBound < frames.lowerBound,
                "named right after creation, before the frame load can fall back to the placeholder")
        #expect(Self.occurrences(of: "Self.nameButton(", in: source) == 1)
    }

    /// P3b: the menu is a single view-based item hosting the SwiftUI panel.
    /// Slice W (issue #78) adds ONE more item that is never drawn: the hidden
    /// ⌘, key item (SettingsWindowTests), so the panel stays the only VISIBLE
    /// item.
    @Test func menuHostsExactlyOneSwiftUIPanelItem() throws {
        let menuContent = makeMenuContent()
        let menu = menuContent.menu
        #expect(menu.items.filter { !$0.isHidden }.count == 1)
        #expect(menu.items.count == 2)
        #expect(menu.items[1].isHidden && menu.items[1].keyEquivalent == ",", "the only other item is the hidden ⌘, item")

        let panelItem = menu.items[0]
        // Types spelled as strings: `import SwiftUI` next to `import Testing`
        // would pull in another CLT-missing cross-import overlay. Since the
        // 2026-10-18 redesign the item view is MenuPanelHostingView (an
        // NSHostingView subclass that re-fits the open menu), so the chain of
        // superclasses must still contain NSHostingView<MenuPanelView>.
        let view = try #require(panelItem.view)
        var chain: [String] = []
        var cls: AnyClass? = type(of: view)
        while let current = cls {
            chain.append(String(describing: current))
            cls = class_getSuperclass(current)
        }
        #expect(chain.first?.contains("MenuPanelHostingView") == true, "got \(chain)")
        #expect(chain.contains { $0.contains("NSHostingView") && $0.contains("MenuPanelView") }, "got \(chain)")
        #expect(panelItem.isEnabled)
        // The hosted panel must have laid out to a real size.
        #expect((panelItem.view?.frame.width ?? 0) > 0)
        #expect((panelItem.view?.frame.height ?? 0) > 0)
    }

    /// 2026-10-18 redesign — the NSMenu height problem. The panel's height
    /// changes while the menu is OPEN (a caption appearing after an async
    /// outcome); a frame measured once at menuWillOpen used to clip.
    /// MenuPanelHostingView re-fits itself in the first layout pass that sees
    /// new content (NSMenu follows an item view's frame live — NSMenuItem.h).
    /// Since slice P removed the Details disclosure, the content that grows
    /// here is a caption: the simulator's charge control turning
    /// unavailable (setup required) adds the Charge Limit row's warning.
    /// Driven headlessly in an offscreen window: no menu is shown, nothing
    /// is clicked, and the simulator runs no privileged command.
    @Test func panelRefitsItsHeightWhenACaptionAppearsWhileOpen() throws {
        let simulator = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        let menuContent = makeMenuContent(simulator: simulator)
        let view = try #require(menuContent.menu.items[0].view)
        let window = Self.offscreenHost(view)
        defer { window.contentView = nil }

        Self.settle(view)
        let quiet = view.frame.height
        #expect(abs(quiet - view.fittingSize.height) < 1)

        simulator.chargeControlReadiness = .setupRequired
        menuContent.model.refresh()
        #expect(menuContent.model.chargeLimitCaption?.severity == .warning, "vacuity: the caption is a warning")
        Self.settle(view)
        #expect(view.frame.height > quiet + 10, "the caption must grow the panel")
        #expect(abs(view.frame.height - view.fittingSize.height) < 1, "frame must match content — no clipping")

        simulator.chargeControlReadiness = .ready
        menuContent.model.refresh()
        Self.settle(view)
        #expect(abs(view.frame.height - quiet) < 1, "the caption leaving must not leave dead space")
    }

    private static func offscreenHost(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 1200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 1200))
        window.contentView = container
        container.addSubview(view)
        view.setFrameOrigin(.zero)
        return window
    }

    /// A few layout passes + runloop turns so SwiftUI applies pending state.
    private static func settle(_ view: NSView) {
        for _ in 0..<4 {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// ⌘Q stays wired even though Quit is a SwiftUI button: the hosting item
    /// carries the key equivalent and terminates via the responder chain.
    @Test func commandQTerminatesThroughTheHostingItem() {
        let menuContent = makeMenuContent()
        let panelItem = menuContent.menu.items[0]
        #expect(panelItem.keyEquivalent == "q")
        #expect(panelItem.keyEquivalentModifierMask == .command)
        #expect(panelItem.action == #selector(NSApplication.terminate(_:)))
        #expect(panelItem.target == nil, "nil target → responder chain → NSApplication")
    }

    @Test func menuIsItsOwnDelegateForOpenReconciliation() {
        let menuContent = makeMenuContent()
        // menuWillOpen re-reads pmset -g and re-evaluates the limiter on
        // every open (ADR §6).
        #expect(menuContent.menu.delegate === menuContent)
    }

    @Test func modelStartsFromObservedStateNotIntent() {
        let menuContent = makeMenuContent()
        // No pmset -g read has happened yet in this fresh controller, so the
        // observed state is unknown → toggle off WITH caption, never a
        // cached-intent checkmark.
        #expect(menuContent.model.stayAwakeObserved == nil)
        let mapped = MenuStateModel.stayAwakeToggle(forObserved: menuContent.model.stayAwakeObserved)
        #expect(!mapped.isOn)
        #expect(mapped.caption != nil)
    }

    /// Regression lock for the 2026-07-10 UX fix: toggling Stay Awake used
    /// to close the menu because toggleStayAwake() called
    /// menu.cancelTracking() unconditionally before deciding anything.
    /// Lint-style (NSMenu tracking cannot be driven headlessly): the
    /// happy-path functions must contain no menu-dismissal, alert, or
    /// app-activation call, and the single cancelTracking call in the file
    /// must live inside closeMenuThenPresent — the one modal-flow gateway.
    @Test func stayAwakeToggleHappyPathNeverClosesTheMenu() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)  // Tests/NapCatTests/<this file>
            .deletingLastPathComponent()                 // Tests/NapCatTests
            .deletingLastPathComponent()                 // Tests
            .deletingLastPathComponent()                 // repo root
            .appendingPathComponent("Sources/NapCat/MenuContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        // Guard against path drift making the test vacuous.
        try #require(source.contains("final class MenuContentView"))

        let happyPathFunctions = ["toggleStayAwake", "applyStayAwake", "handleStayAwakeOutcome"]
        let forbidden = ["cancelTracking", "NSAlert", "runModal", "NSApp.activate", "activate("]
        for function in happyPathFunctions {
            let body = try #require(Self.functionChunk(named: function, in: source),
                                    "function \(function) not found — rewiring must keep this lock updated")
            for token in forbidden {
                #expect(!body.contains(token),
                        "'\(token)' in \(function) — the happy path must keep the menu open")
            }
        }

        // Exactly one dismissal call in the whole file, inside the gateway.
        let dismissals = source.components(separatedBy: "cancelTracking").count - 1
        #expect(dismissals == 1, "expected exactly one cancelTracking call, found \(dismissals)")
        let gateway = try #require(Self.functionChunk(named: "closeMenuThenPresent", in: source))
        #expect(gateway.contains("cancelTracking"),
                "the one dismissal must live in closeMenuThenPresent")
    }

    /// Same lock extended to the Track B / B2 controls (2026-08-24, updated for
    /// the B4 ntfy swap): the lid-alert toggle and the test-send button must
    /// keep the menu OPEN, and the ntfy settings editor — the one genuinely
    /// modal B2 flow — must go through `closeMenuThenPresent` rather than
    /// dismissing on its own. The "exactly one cancelTracking" assertion above
    /// still holds because the settings prompt reuses that single gateway.
    @Test func lidAlertHappyPathsNeverCloseTheMenu() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/NapCat/MenuContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        try #require(source.contains("final class MenuContentView"))

        // Track C: the Session alerts toggle (shared priming) keeps it open too.
        let happyPathFunctions = ["toggleLidAlert", "sendLidAlertTestMessage", "toggleSessionAlerts"]
        let forbidden = ["cancelTracking", "NSAlert", "runModal", "NSApp.activate", "activate("]
        for function in happyPathFunctions {
            let body = try #require(Self.functionChunk(named: function, in: source),
                                    "function \(function) not found — rewiring must keep this lock updated")
            for token in forbidden {
                #expect(!body.contains(token),
                        "'\(token)' in \(function) — the happy path must keep the menu open")
            }
        }

        // The modal ntfy editor dismisses ONLY via the shared gateway.
        let prompt = try #require(Self.functionChunk(named: "promptForLidAlertSettings", in: source))
        #expect(prompt.contains("closeMenuThenPresent"))
        #expect(!prompt.contains("cancelTracking"))
        #expect(!prompt.contains("runModal"), "the modal itself lives in presentLidAlertSettingsPrompt")
    }

    /// M1 regression lock (security review 2026-09-09): the ntfy editor used to
    /// call `setServer`/`setTopic` and DISCARD their validation results, so an
    /// unusable value silently kept the old configuration while the panel went
    /// on claiming the feature was armed. The modal must now consult the
    /// validation before it commits anything. Lint-style: an AppKit modal
    /// session cannot be driven headlessly, so the pure mapping is unit-tested
    /// in MenuStateModelTests and its USE is locked here.
    @Test func theNtfySettingsModalValidatesBeforeItCommits() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/NapCat/MenuContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let body = try #require(Self.functionChunk(named: "presentLidAlertSettingsPrompt", in: source))

        #expect(body.contains("MenuStateModel.lidAlertSettingsError("),
                "the modal must surface an invalid field instead of dropping it")
        // Order matters: the validation must be consulted BEFORE either setter.
        let checkedAt = try #require(body.range(of: "lidAlertSettingsError("))
        for setter in ["lidGuard.setServer(", "lidGuard.setTopic("] {
            let setAt = try #require(body.range(of: setter), "\(setter) not found — keep this lock updated")
            #expect(checkedAt.lowerBound < setAt.lowerBound,
                    "\(setter) runs before the validation check — an invalid value would commit silently")
        }
    }

    /// Issue #34: the session alerts' run floor rides the SAME editor and the
    /// SAME Save. Lint-style (the modal cannot be driven headlessly): the
    /// group is built only while session alerts exist, prefilled from the
    /// model's mirror; the floor is saved after the validation check and only
    /// on that path; and the key is written in exactly one place, through the
    /// policy's clamp, only when it changed. The topic row, its validation
    /// and its setters are untouched (locked above and in
    /// TopicFieldVisibilityTests).
    @Test func theSessionAlertsFloorIsSavedWithTheNtfySettingsAfterValidation() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/NapCat/MenuContentView.swift")
        let source = LidGuardStructureTests.codeOnly(try String(contentsOf: sourceURL, encoding: .utf8))

        let prompt = try #require(Self.functionChunk(named: "presentLidAlertSettingsPrompt", in: source))
        #expect(prompt.contains("minimumRunSeconds: model.finishAlertVisible ? model.finishAlertMinimumRunSeconds : nil"),
                "prefilled from the model's mirror, and only while session alerts exist")
        let checkedAt = try #require(prompt.range(of: "lidAlertSettingsError("))
        let savedAt = try #require(prompt.range(of: "saveSessionAlertsFloor(seconds)"))
        #expect(checkedAt.lowerBound < savedAt.lowerBound, "the floor must not save before the validation check")
        // Slice W (issue #78): Settings › Alerts' popup forwards to the SAME
        // save path — one definition, the editor's call, the popup's forward.
        #expect(Self.occurrences(of: "saveSessionAlertsFloor(", in: source) == 3,
                "one definition, the editor's call, the Settings popup's forward")
        #expect(source.contains("model.requestSessionAlertsFloorChange = { [weak self] seconds in\n"
                                + "            self?.saveSessionAlertsFloor(seconds)\n"
                                + "            self?.model.refresh()\n"
                                + "        }"), "the popup's forward saves through it, then republishes")

        let editor = try #require(Self.functionChunk(named: "runLidAlertSettingsEditor", in: source))
        #expect(editor.contains("entry.minimumRunSeconds.map { SessionAlertsFloorGroup(seconds: $0, width: 300) }"))
        #expect(editor.contains("if let floorGroup { stack.addSubview(floorGroup.view) }"))
        #expect(editor.contains("floorGroup?.view.frame.width"), "the editor is as wide as the group's row")
        #expect(editor.contains("minimumRunSeconds: floorGroup?.seconds"), "Save hands the popup's choice back")

        let save = try #require(Self.functionChunk(named: "saveSessionAlertsFloor", in: source))
        let clamp = try #require(save.range(of: "FinishAlertPolicy.minimumRunSeconds(stored: seconds)"))
        let unchanged = try #require(save.range(of: "guard floor != model.finishAlertMinimumRunSeconds else { return }"))
        let write = try #require(save.range(of: "defaults.set(floor, forKey: DefaultsKey.finishAlertMinimumRunSeconds)"))
        #expect(clamp.lowerBound < unchanged.lowerBound && unchanged.lowerBound < write.lowerBound)
        #expect(Self.occurrences(of: "DefaultsKey.finishAlertMinimumRunSeconds", in: source) == 1,
                "the key is written in exactly one place in the menu")

        // The group never sees the topic: its class names no topic at all.
        let start = try #require(source.range(of: "final class SessionAlertsFloorGroup"))
        let tail = source[start.upperBound...]
        let group = tail[..<(tail.range(of: "\nfinal class ")?.lowerBound ?? tail.endIndex)]
        #expect(group.contains("@objc func chose("), "vacuity: the chunk is the group class")
        #expect(!group.lowercased().contains("topic"), "the floor group must never touch the topic")
        #expect(!source.contains("NSStepper"), "the floor is a preset popup, not a stepper")
    }

    /// Issue #34, headless: the editor's floor group at the default. One
    /// popup of exactly the five presets with "1 minute" pre-selected, under
    /// the "Session alerts" title, after the exact label and above the exact
    /// caption (small, secondary). VoiceOver: a fixed name, the selected
    /// row's text as the value — kept current by the popup's action.
    @Test func theSessionAlertsFloorGroupOffersFivePresetsWithOneMinuteSelected() {
        let group = SessionAlertsFloorGroup(seconds: 60, width: 300)
        #expect(group.popup.itemTitles == ["30 seconds", "1 minute", "2 minutes", "5 minutes", "10 minutes"])
        #expect(group.popup.itemArray.map(\.tag) == [30, 60, 120, 300, 600])
        #expect(!group.popup.pullsDown)
        #expect(group.popup.titleOfSelectedItem == "1 minute")
        #expect(group.seconds == 60)
        #expect(group.titleLabel.stringValue == "Session alerts")
        #expect(group.rowLabel.stringValue == "Only alert for runs longer than:")
        #expect(group.caption.stringValue == "Shorter runs finish silently.")
        #expect(group.caption.font?.pointSize == NSFont.smallSystemFontSize)
        #expect(group.caption.textColor == .secondaryLabelColor)
        #expect(group.popup.accessibilityLabel() == "Minimum run before alerting")
        #expect(group.popup.accessibilityValue() as? String == "1 minute")
        #expect(group.popup.target === group)
        #expect(group.popup.action == #selector(SessionAlertsFloorGroup.chose(_:)))

        group.popup.selectItem(withTag: 300)
        group.chose(group.popup)
        #expect(group.seconds == 300, "Save hands the chosen preset back")
        #expect(group.popup.accessibilityValue() as? String == "5 minutes")

        // The prefill goes through the one clamp rule, like every read — an
        // out-of-range value lands on a bound, which is a preset.
        for (stored, title) in [(29, "30 seconds"), (601, "10 minutes")] {
            let clamped = SessionAlertsFloorGroup(seconds: stored, width: 300)
            #expect(clamped.popup.numberOfItems == 5, "\(stored) s")
            #expect(clamped.popup.titleOfSelectedItem == title, "\(stored) s")
        }
    }

    /// Issue #34, headless: a stored floor that is not a preset (90, written
    /// with `defaults write`) shows as ONE extra row, in order and selected.
    /// Untouched, Save hands 90 back unchanged, and the save path writes only
    /// a changed floor (locked above) — so opening the editor never rewrites
    /// the stored value.
    @Test func aStoredNonPresetFloorShowsAsItsOwnSelectedRow() {
        let group = SessionAlertsFloorGroup(seconds: 90, width: 300)
        #expect(group.popup.itemTitles
                == ["30 seconds", "1 minute", "1 min 30 s", "2 minutes", "5 minutes", "10 minutes"])
        #expect(group.popup.indexOfSelectedItem == 2)
        #expect(group.popup.titleOfSelectedItem == "1 min 30 s")
        #expect(group.seconds == 90, "untouched, Save returns the stored value as it is")
        #expect(group.popup.accessibilityValue() as? String == "1 min 30 s")

        group.popup.selectItem(withTag: 120)
        group.chose(group.popup)
        #expect(group.seconds == 120, "an explicit choice replaces it")
    }

    /// Issue #34, headless: the group's geometry. Label then popup on one row
    /// and one baseline, neither truncated (the group widens past the
    /// editor's 300 pt instead); the title above and the caption below, both
    /// flush with the label — nothing overlapping, nothing outside the view.
    @Test func theSessionAlertsFloorGroupLaysOutOneRowBetweenTitleAndCaption() {
        for seconds in [60, 90] {
            let group = SessionAlertsFloorGroup(seconds: seconds, width: 300)
            let bounds = group.view.bounds
            #expect(bounds.width >= 300)
            for view in [group.titleLabel, group.rowLabel, group.popup, group.caption] {
                #expect(view.superview === group.view)
                #expect(bounds.contains(view.frame), "\(view.frame) leaves the group's \(bounds)")
            }
            #expect(group.rowLabel.frame.width >= group.rowLabel.fittingSize.width, "the label is not truncated")
            #expect(group.popup.frame.width >= group.popup.fittingSize.width, "the popup is not truncated")
            #expect(group.rowLabel.frame.maxX < group.popup.frame.minX)
            let labelBaseline = group.rowLabel.frame.maxY - group.rowLabel.firstBaselineOffsetFromTop
            let popupBaseline = group.popup.frame.maxY - group.popup.firstBaselineOffsetFromTop
            #expect(abs(labelBaseline - popupBaseline) < 0.5, "label and popup title share a baseline")
            #expect(group.caption.frame.maxY <= min(group.rowLabel.frame.minY, group.popup.frame.minY))
            #expect(group.titleLabel.frame.minY >= max(group.rowLabel.frame.maxY, group.popup.frame.maxY))
            #expect(group.titleLabel.frame.minX == 0 && group.rowLabel.frame.minX == 0 && group.caption.frame.minX == 0)
        }
    }

    private static func occurrences(of token: String, in text: String) -> Int {
        text.components(separatedBy: token).count - 1
    }

    /// UI audit H2 (2026-11-19): someone who installed from the disk image has
    /// no clone, so the Setup Required alert tells them to clone first and
    /// points at the disk image's READ ME, which must therefore carry the
    /// commands (setup, and the optional Claude hook for the phone alerts).
    /// The hook lines name the repository instead of a bare repo-relative
    /// path. Lint-style: the alert is an AppKit modal and the READ ME is a
    /// heredoc in the packaging script.
    @Test func firstRunGuidanceReachesDiskImageUsers() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let menu = try String(contentsOf: root.appendingPathComponent("Sources/NapCat/MenuContentView.swift"),
                              encoding: .utf8)
        let alert = try #require(Self.functionChunk(named: "presentSetupRequiredAlert", in: menu))
        #expect(alert.contains("sudo ./scripts/setup.sh"))
        #expect(alert.contains("Installed from the disk image? Clone github.com/MuratAlkan06/NapCat"))
        #expect(alert.contains("the READ ME on the disk image has the exact commands."))

        let packager = try String(contentsOf: root.appendingPathComponent("scripts/make-dmg.sh"), encoding: .utf8)
        let start = try #require(packager.range(of: "cat > \"$STAGE/READ ME.txt\" <<EOF\n"), "READ ME heredoc not found")
        let tail = packager[start.upperBound...]
        let end = try #require(tail.range(of: "\nEOF\n"), "READ ME heredoc is not terminated")
        let readMe = String(tail[..<end.lowerBound])
        for command in ["git clone --branch v$VERSION https://github.com/MuratAlkan06/NapCat.git",
                        "sudo ./scripts/setup.sh", "./scripts/install-claude-busy-hook.sh"] {
            #expect(readMe.contains(command), "the READ ME lost '\(command)'")
        }
        #expect(readMe.contains("Optional: phone alerts for Claude Code"))
        #expect(readMe.contains("\"ntfy settings...\""), "the READ ME names the menu item that sets the alerts up")
        let plainASCII = readMe.unicodeScalars.allSatisfy { $0.isASCII }
        #expect(plainASCII, "READ ME.txt stays plain ASCII")

        // Not installed, and installed but never seen: both name the fix.
        for installed in [false, true] {
            let line = MenuStateModel.claudeHookLine(installed: installed, everSeen: false, lastSeenSeconds: nil)
            #expect(line.hasSuffix("— run install-claude-busy-hook.sh from the NapCat repository"), "\(line)")
            #expect(!line.contains("scripts/"), "a bare repo-relative path means nothing outside a clone")
        }
    }

    /// Menu-open must stay off the network: the panel renders stored config and
    /// the last recorded outcome, never a live probe. (Before B4 this slot held
    /// the silent Automation-permission probe; the ntfy channel has nothing to
    /// probe, and a menu-open request would be a per-open network call.)
    @Test func menuOpenPerformsNoNetworkIO() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/NapCat/MenuContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let body = try #require(Self.functionChunk(named: "menuWillOpen", in: source))
        for token in ["sendTestMessage", "URLSession", "dataTask",
                      "probeAutomationPermission", "refreshAutomationPermission"] {
            #expect(!body.contains(token), "'\(token)' in menuWillOpen — opening the menu must not send anything")
        }
    }

    /// Source chunk from `func <name>(` to the next function declaration
    /// (or end of file) — coarse but stable for lint-style assertions.
    private static func functionChunk(named name: String, in source: String) -> String? {
        guard let start = source.range(of: "func \(name)(") else { return nil }
        let tail = source[start.upperBound...]
        let boundaries = ["\n    private func ", "\n    func ", "\n    static func ", "\n    nonisolated static func "]
        let end = boundaries
            .compactMap { tail.range(of: $0)?.lowerBound }
            .min() ?? tail.endIndex
        return String(tail[..<end])
    }

    @Test func debugSectionVisibleOnlyWithSimulator() {
        let menuContent = makeMenuContent()
        #expect(menuContent.model.debugControlsVisible, "built with a simulator here")

        // Real-interface wiring (simulator: nil) hides the debug section.
        let defaults = UserDefaults(suiteName: Self.testSuite)!
        let power = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        let limiter = ChargeLimiter(power: power, isAppleSilicon: true, defaults: defaults)
        let model = MenuStateModel(power: power, sleep: SleepStateController(), limiter: limiter, simulator: nil)
        #expect(!model.debugControlsVisible)
    }
}
