// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Lint-style locks for the 2026-10-18 menu-panel redesign (SwiftUI layout
/// cannot be driven headlessly, so the pure mappings are unit-tested in
/// MenuPanelPresentationTests and their USE is locked here):
/// the panel is ONE fixed layout (design freeze), the topic never reaches a
/// view, the layout gives problem lines a top-level home, the ONE disclosure
/// shares the last row with Quit (curation round 1), the header is the
/// hero-size gauge with the charge-state glyph (curation round 2 + its fix)
/// and carries the Lock Screen button in its top-right corner (2026-10-22),
/// Details only ever tucks NOMINAL lines, Pause detection lives in Details
/// (F3), motion is gated on Reduce Motion, and colors are system/semantic
/// only.
struct MenuPanelStructureTests {
    /// Every SwiftUI view file of the panel. A new view file must be added
    /// here AND to the LidGuard / ClaudeDetection scanned-file sets.
    static let viewFiles = ["MenuPanelView.swift", "MenuPanelVariants.swift"]
    /// The panel's one layout since the 2026-10-18 design freeze (the user
    /// kept A "Quiet Rows"; B and C were deleted).
    static let layout = "QuietRowsPanel"
    static let layoutFile = "MenuPanelVariants.swift"

    static func layoutBody() throws -> String {
        try #require(Self.structChunk(layout, in: try Self.code(layoutFile)), "\(layout) not found — keep this lock updated")
    }

    static func code(_ file: String) throws -> String {
        LidGuardStructureTests.codeOnly(try String(
            contentsOf: LidGuardStructureTests.sourcesDir().appendingPathComponent(file),
            encoding: .utf8
        ))
    }

    static func allViewCode() throws -> String {
        try viewFiles.map(code).joined(separator: "\n")
    }

    /// Source of one top-level `struct <name>` declaration, up to the next
    /// top-level declaration — coarse but stable for lint assertions.
    static func structChunk(_ name: String, in source: String) -> String? {
        guard let start = source.range(of: "\nstruct \(name):") ?? source.range(of: "\nstruct \(name)<") else {
            return nil
        }
        let tail = source[start.upperBound...]
        let end = ["\nstruct ", "\nenum ", "\nfinal class ", "\nprivate final class "]
            .compactMap { tail.range(of: $0)?.lowerBound }
            .min() ?? tail.endIndex
        return String(tail[..<end])
    }

    static func occurrences(of token: String, in text: String) -> Int {
        text.components(separatedBy: token).count - 1
    }

    // MARK: - Design freeze: one fixed layout

    /// Design freeze (2026-10-18): MenuPanelView renders the Quiet Rows layout
    /// unconditionally; the variant picker, the losing layout, its hero-only
    /// mapping and its plumbing are gone from the code (comments may still
    /// name them as history); and the retired `menuPanelStyle` key survives
    /// ONLY in `RetiredDefaultsKey`, where the startup migration deletes it.
    @Test func thePanelIsOneFixedLayout() throws {
        let root = try #require(Self.structChunk("MenuPanelView", in: try Self.code("MenuPanelView.swift")))
        #expect(Self.occurrences(of: "\(Self.layout)(model: model)", in: root) == 1, "the root renders the one layout")
        #expect(!root.contains("switch") && !root.contains("if "), "the root must not choose between layouts")
        #expect(Self.occurrences(of: "\nstruct ", in: try Self.code(Self.layoutFile)) == 1,
                "\(Self.layoutFile) holds exactly one layout")

        let panelCode = try (Self.viewFiles + ["MenuStateModel.swift", "MenuContentView.swift"])
            .map(Self.code).joined(separator: "\n")
        for token in ["StatusHeroPanel", "MenuPanelStyle", "panelStyle", "PanelStylePreviewRow",
                      "Panel style (preview)", "heroActivity", "includesClaudeStatus", "menuPanelStyle"] {
            #expect(!panelCode.contains(token), "'\(token)' — scrapped at the design freeze")
        }
        // Declutter amendment (2026-10-21): the tier-1 Claude row (with its
        // "where to undo it" hint and its "— keeping Mac awake" mapping) and
        // the titled Lock Screen row + caption are gone, not merely unused.
        for token in ["ClaudeStatusRow", "claudeStatus", "PanelSymbol.claude",
                      "PanelRow(symbol: PanelSymbol.lockScreen", "Button(\"Lock\")", "lockScreenCaption"] {
            #expect(!panelCode.contains(token), "'\(token)' — scrapped at the 2026-10-21 declutter")
        }

        for (name, text) in try LidGuardStructureTests.swiftSources() where text.contains("menuPanelStyle") {
            #expect(name == "DefaultsKeys.swift", "'menuPanelStyle' is read or written in \(name)")
        }
        let keys = try Self.code("DefaultsKeys.swift")
        let live = try #require(keys.range(of: "enum DefaultsKey {")).upperBound
        let retired = try #require(keys.range(of: "enum RetiredDefaultsKey {"))
        #expect(!keys[live..<retired.lowerBound].contains("menuPanelStyle"), "menuPanelStyle is no longer a live key")
        #expect(keys[retired.upperBound...].contains("static let menuPanelStyle = \"menuPanelStyle\""),
                "menuPanelStyle is retired, so the startup migration deletes it")
    }

    // MARK: - The topic is a password

    /// The secret mirror is `private` on the model (compile-time: no view can
    /// read it) and no view file even names it.
    @Test func viewsCannotReadTheTopic() throws {
        let model = try String(
            contentsOf: LidGuardStructureTests.sourcesDir().appendingPathComponent("MenuStateModel.swift"),
            encoding: .utf8
        )
        #expect(model.contains("@Published private var lidGuardTopic"),
                "the topic mirror must stay private to the model")
        let views = try Self.allViewCode()
        #expect(!views.contains("lidGuardTopic"), "a view file names the secret topic mirror")
        #expect(!views.contains("storedTopic"), "a view file reaches for the stored topic")
    }

    // MARK: - The iron rule, structurally

    /// The layout must render the five surfaced-line components (the
    /// top-level home of every Details line that can be a problem — Track C
    /// added the session-alerts one, the 2026-10-21 declutter the General one
    /// for the Lock Screen line) plus the Details content and the ONE footer
    /// row that carries the disclosure and the always-visible Quit.
    @Test func thePanelGivesProblemLinesATopLevelHome() throws {
        let body = try Self.layoutBody()
        for component in ["ClaudeSurfacedLines(", "LidAlertSurfacedLines(", "SessionAlertsSurfacedLines(",
                          "GeneralSurfacedLines(", "SurfacedLaunchAtLogin(", "PanelDetailsContent(",
                          "PanelFooterRow("] {
            #expect(body.contains(component), "\(Self.layout) is missing \(component)")
            #expect(Self.occurrences(of: component, in: body) == 1, "\(component) rendered more than once")
        }
        #expect(Self.occurrences(of: "PanelFooterRow(", in: body) == 1, "ONE footer row")
        #expect(Self.occurrences(of: "PanelDetailsContent(", in: body) == 1, "ONE Details content")
        // The layout renders no disclosure of its own — the footer row is the
        // only home, so the panel has exactly ONE disclosure.
        #expect(!(try Self.code(Self.layoutFile)).contains("PanelDetailsDisclosure("),
                "the layout renders a second disclosure")
    }

    /// Curation round 1 (2026-10-18): Details sits on the LEFT of the panel's
    /// last row with Quit on the RIGHT, and Quit stays the last control. Lock
    /// Screen amendment (2026-10-22): the icon-only Lock Screen button left
    /// the footer for the header's top-right corner (locked in
    /// `theLockScreenButtonSitsInTheHeaderTopRightCorner`), so the footer is
    /// the disclosure, the Spacer and Quit — nothing else. It holds the ONLY
    /// disclosure and the ONLY Quit button in the panel, and it is the LAST
    /// thing — expanded Details content and the surfaced twins (Claude,
    /// General, Launch at Login) render above it, so Quit can never be pushed
    /// out of view.
    @Test func theFooterRowHoldsTheOneDisclosureAndQuitAndComesLast() throws {
        let views = try Self.allViewCode()
        #expect(Self.occurrences(of: "PanelDetailsDisclosure(", in: views) == 1, "exactly ONE disclosure in the panel")
        #expect(Self.occurrences(of: "Button(\"Quit NapCat\")", in: views) == 1, "exactly ONE Quit button")
        let footer = try #require(Self.structChunk("PanelFooterRow", in: try Self.code("MenuPanelView.swift")))
        #expect(!footer.contains("LockScreenButton("), "Lock Screen lives in the header, not the footer")
        let disclosure = try #require(footer.range(of: "PanelDetailsDisclosure(model: model)"),
                                      "the disclosure lives in the footer")
        let spacer = try #require(footer.range(of: "Spacer(minLength: PanelMetrics.regular)"))
        let quit = try #require(footer.range(of: "Button(\"Quit NapCat\")"), "Quit lives in the footer")
        #expect(Self.occurrences(of: "HStack(", in: footer) == 1, "one row — no nested button group")
        #expect(disclosure.lowerBound < spacer.lowerBound && spacer.lowerBound < quit.lowerBound,
                "Details on the left, Spacer, then Quit on the right")
        #expect(footer[disclosure.upperBound..<spacer.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && footer[spacer.upperBound..<quit.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "nothing else sits in the footer — the disclosure, the Spacer, Quit")
        #expect(Self.occurrences(of: "Button", in: footer) == 1, "Quit is the footer's only button")
        let afterQuit = footer[quit.upperBound...]
        #expect(!afterQuit.contains("Button") && !afterQuit.contains("(model: model)"),
                "Quit stays the last (rightmost) control")
        #expect(footer.contains(".keyboardShortcut(\"q\", modifiers: .command)"))

        let body = try Self.layoutBody()
        let footerCall = try #require(body.range(of: "PanelFooterRow(model: model)"), "no footer row")
        for above in ["PanelDetailsContent(", "ClaudeSurfacedLines(", "GeneralSurfacedLines(",
                      "SurfacedLaunchAtLogin("] {
            let position = try #require(body.range(of: above), "missing \(above)")
            #expect(position.lowerBound < footerCall.lowerBound, "\(above) must render ABOVE the footer")
        }
        // Nothing follows the footer inside the main column: only the closing
        // brace before the column's own modifiers.
        let tail = body[footerCall.upperBound...]
        let beforeModifiers = tail.range(of: ".padding(").map { tail[..<$0.lowerBound] } ?? tail
        #expect(beforeModifiers.trimmingCharacters(in: .whitespacesAndNewlines) == "}",
                "the footer row must be the panel's last row")
    }

    /// `BatteryHeader` split into its three parts: the text column (before
    /// `gauge`), the ring geometry (`gauge`), and the ring interior.
    static func batteryHeaderParts() throws -> (text: String, ring: String, interior: String) {
        let header = try #require(Self.structChunk("BatteryHeader", in: try Self.code("MenuPanelView.swift")))
        let ringStart = try #require(header.range(of: "private var gauge"), "BatteryHeader.gauge not found")
        let interiorStart = try #require(header.range(of: "private var ringInterior"),
                                         "BatteryHeader.ringInterior not found")
        #expect(ringStart.lowerBound < interiorStart.lowerBound, "keep `gauge` above `ringInterior`")
        return (String(header[..<ringStart.lowerBound]),
                String(header[ringStart.lowerBound..<interiorStart.lowerBound]),
                String(header[interiorStart.lowerBound...]))
    }

    /// The frozen header (curation round 2, kept at the design freeze): ONE
    /// battery header in the layout, the full-size ring (no 0.8 scale, no
    /// 44pt frame) in a 76pt-min header, the desktop symbol at the same
    /// footprint, and the "Battery N%" headline + charging line beside it.
    /// The compact size and Status Hero's activity text are gone, so there is
    /// no geometry or text knob left to flip back.
    @Test func theHeaderIsTheHeroGaugeWithTheHeadline() throws {
        let body = try Self.layoutBody()
        #expect(Self.occurrences(of: "BatteryHeader(", in: body) == 1, "ONE battery header")
        #expect(body.contains("BatteryHeader(model: model)"), "no size / content knob to pass")

        let header = try #require(Self.structChunk("BatteryHeader", in: try Self.code("MenuPanelView.swift")))
        for token in ["enum Size", "enum Content", "var size", "var content", ".compact", ".activity",
                      "heroActivity", "switch "] {
            #expect(!header.contains(token), "'\(token)' — the header has one geometry and one text column")
        }
        #expect(header.contains(".frame(minHeight: 76)"), "the ~76pt hero header")

        let (textColumn, ring, _) = try Self.batteryHeaderParts()
        #expect(Self.occurrences(of: "MenuStateModel.batteryHeadline(", in: textColumn) == 1, "the headline")
        #expect(Self.occurrences(of: "chargingLine", in: textColumn) >= 2, "the charging line (declared + used)")
        #expect(Self.occurrences(of: "Gauge(value:", in: ring) == 1, "ONE ring")
        #expect(ring.contains(".gaugeStyle(.accessoryCircularCapacity)"))
        for token in [".scaleEffect(", "width: 44", "height: 44", ".title2"] {
            #expect(!ring.contains(token), "'\(token)' is the deleted compact geometry")
        }
        #expect(ring.contains(".font(.largeTitle)") && ring.contains(".frame(width: 60, height: 60)"),
                "the desktop symbol keeps the hero footprint")
    }

    /// Curation round 2 fix (2026-10-18 — "you removed the battery icon"),
    /// kept at the freeze: the ring holds the charge-state glyph (bolt while
    /// charging, battery otherwise) at 12pt and NEVER the percent, which the
    /// headline already states — the percent appears exactly once.
    @Test func theRingHoldsTheChargeStateGlyphNotThePercent() throws {
        let (textColumn, ring, interior) = try Self.batteryHeaderParts()

        #expect(Self.occurrences(of: "currentValueLabel: {\n                ringInterior\n            }", in: ring) == 1,
                "the ring's currentValueLabel must be exactly `ringInterior`")
        for token in ["Text(percent)", "Image(systemName: model.isCharging"] {
            #expect(!ring.contains(token), "the ring draws its own interior ('\(token)') — use `ringInterior`")
        }

        #expect(interior.contains("Image(systemName: model.isCharging ? PanelSymbol.charging : PanelSymbol.battery)"),
                "the ring holds the charge-state glyph")
        #expect(interior.contains(".font(.system(size: 12))"), "at the pre-round-2 glyph-to-ring proportion")
        #expect(!interior.contains("percent") && !interior.contains("Text("),
                "the ring must not repeat the percent the headline states")
        #expect(textColumn.contains("MenuStateModel.batteryHeadline(hasBattery: model.hasBattery, percent: model.batteryPercent)"),
                "the headline states the percent")
    }

    /// Lock Screen amendment (2026-10-22, user ruling "battery header stays
    /// same, lock goes to top right"): the panel's ONE Lock Screen button is
    /// an OVERLAY in the battery header's top-trailing corner, its top inset
    /// by `PanelMetrics.headerLockInset` onto the ring's top line. An overlay
    /// takes no room in the header row, so the frozen header — its HStack
    /// (default centre alignment, `loose` spacing) and 76pt minimum height —
    /// stays exactly as it was. (The button's own shape:
    /// `lockScreenIsAnIconOnlyButtonForwardingToTheModel`.)
    @Test func theLockScreenButtonSitsInTheHeaderTopRightCorner() throws {
        #expect(Self.occurrences(of: "LockScreenButton(", in: try Self.allViewCode()) == 1,
                "exactly ONE Lock Screen button")
        // `body` is the part of the header above `gauge`.
        let (body, _, _) = try Self.batteryHeaderParts()
        #expect(Self.occurrences(of: "LockScreenButton(", in: body) == 1, "Lock Screen lives in the battery header")

        // The frozen header row, unchanged: ONE HStack with the exact literal
        // (an `alignment:` argument would break it), then the 76pt frame.
        #expect(Self.occurrences(of: "HStack(", in: body) == 1, "ONE header row")
        let row = try #require(body.range(of: "HStack(spacing: PanelMetrics.loose) {"),
                               "the header HStack keeps its default centre alignment and loose spacing")
        let frame = try #require(body.range(of: ".frame(minHeight: 76)"), "the ~76pt hero header")
        #expect(row.upperBound < frame.lowerBound)

        // The button is an overlay hung directly off that frame — never a
        // child of the row, which would shift the ring and the text.
        #expect(Self.occurrences(of: ".overlay(", in: body) == 1)
        let overlay = try #require(body.range(of: ".overlay(alignment: .topTrailing) {"),
                                   "the button sits in the header's top-right corner")
        #expect(body[frame.upperBound..<overlay.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "the overlay is attached to the header row's frame")
        let close = try #require(body[overlay.upperBound...].range(of: "}"))
        let content = body[overlay.upperBound..<close.lowerBound]
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(content == "LockScreenButton(model: model) .padding(.top, PanelMetrics.headerLockInset)",
                "the overlay holds exactly the button, inset onto the ring's top line — got '\(content)'")
        #expect(PanelMetrics.headerLockInset > 0 && PanelMetrics.headerLockInset < 76 / 2,
                "the button sits below the panel edge, in the header's top half")
    }

    /// UI audit M1a (2026-11-19): VoiceOver used to meet the header as the
    /// ring ("Battery", "85%") and then the headline ("Battery 85%") and the
    /// charging line, so the percent was read twice. The header ROW is now
    /// ONE element: children ignored, labelled "Battery", valued by
    /// `BatteryHeader.spokenValue` — the percent once, then the charging
    /// line, from the same mappings the text column shows. The modifiers sit
    /// on the row, before the 76pt frame and its overlay, so the Lock Screen
    /// button stays outside the element: its own button. The row outranks it
    /// in the reading order (sort priority 1 — measured on the accessibility
    /// tree: without it the button, which shares the row's top edge, is read
    /// first), so VoiceOver meets "Battery" and then "Lock Screen". Neither
    /// the ring nor the desktop symbol carries accessibility of its own.
    @Test func theBatteryHeaderIsOneVoiceOverElement() throws {
        let (body, ring, interior) = try Self.batteryHeaderParts()
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(flat.contains("Spacer(minLength: 0) } .accessibilityElement(children: .ignore)"
                              + " .accessibilityLabel(\"Battery\") .accessibilityValue(Self.spokenValue("),
                "the header row itself is the element — not the ring, not the text column")
        #expect(flat.contains("adapterConnected: model.adapterConnected )) .accessibilitySortPriority(1)"
                              + " .frame(minHeight: 76) .overlay(alignment: .topTrailing) {"),
                "the element is closed before the frame, so the overlaid Lock Screen button stays its own, read after it")
        for token in [".accessibilityElement(", ".accessibilityLabel(", ".accessibilityValue(", ".accessibilitySortPriority("] {
            #expect(Self.occurrences(of: token, in: body) == 1, "'\(token)' — the header has ONE element")
        }
        let button = try #require(Self.structChunk("LockScreenButton", in: try Self.code("MenuPanelView.swift")))
        #expect(!button.contains(".accessibilitySortPriority("), "the button keeps the default priority, below the row")
        #expect(!ring.contains(".accessibility") && !interior.contains(".accessibility"),
                "the ring and the desktop symbol are part of the header element, never elements of their own")

        // The value: the percent exactly once, then the charging line.
        let cases: [(hasBattery: Bool, percent: Int?, charging: Bool, adapter: Bool, spoken: String)] = [
            (true, 85, false, false, "85%, On battery"),
            (true, 62, true, true, "62%, Charging"),
            (true, 100, false, true, "100%, Fully charged"),
            (true, 80, false, true, "80%, On AC power — not charging"),
            (true, nil, false, false, "—, On battery"),
            (false, nil, false, true, "Desktop Mac — no battery"),
        ]
        for c in cases {
            let spoken = BatteryHeader.spokenValue(hasBattery: c.hasBattery, percent: c.percent,
                                                   isCharging: c.charging, adapterConnected: c.adapter)
            #expect(spoken == c.spoken)
            #expect(spoken.hasSuffix(MenuStateModel.chargingStatusLine(
                hasBattery: c.hasBattery, percent: c.percent, isCharging: c.charging, adapterConnected: c.adapter)),
                "the charging line is the visible one, not a second vocabulary")
            if let percent = c.percent {
                #expect(Self.occurrences(of: "\(percent)%", in: spoken) == 1, "the percent is spoken once")
            }
        }
    }

    /// Inside Details, every line that can be a problem goes through
    /// `TuckedLine` (absent while non-nominal) — never rendered raw — and its
    /// top-level twin goes through `SurfacedLine`. Same accessor, opposite
    /// filter, so each line renders exactly once.
    @Test func detailsOnlyTucksAndTheSurfacedTwinsExist() throws {
        let source = try Self.code("MenuPanelView.swift")
        let details = try #require(Self.structChunk("PanelDetailsContent", in: source))
        let claudeTwins = try #require(Self.structChunk("ClaudeSurfacedLines", in: source))
        let lidTwins = try #require(Self.structChunk("LidAlertSurfacedLines", in: source))
        let sessionTwins = try #require(Self.structChunk("SessionAlertsSurfacedLines", in: source))
        let generalTwins = try #require(Self.structChunk("GeneralSurfacedLines", in: source))
        let pairs: [(accessor: String, twinHome: String)] = [
            ("model.hookStatus", claudeTwins),
            // S7: the installed hook copy's version (out of date / no stamp
            // are warnings, so it needs the top-level twin like hookStatus).
            ("model.hookVersionStatus", claudeTwins),
            // 2026-10-21: the awake fact left the glance tier (always nominal,
            // so its twin never renders — it gets one anyway, no special case).
            ("model.claudeAwakeLine", claudeTwins),
            ("model.lidTopicStatus", lidTwins),
            ("model.lidServerStatus", lidTwins),
            ("model.lidLastSend(", lidTwins),
            ("model.finishAlertLastSend(", sessionTwins),
            // F3 stage 1: the phone transport line sits with the shared
            // delivery settings, so its twin joins theirs.
            ("model.phoneAlertStatus(", lidTwins),
            // 2026-10-21: Lock Screen availability moved to Details › General.
            ("model.lockScreenStatus", generalTwins),
        ]
        for (accessor, twinHome) in pairs {
            let uses = Self.occurrences(of: accessor, in: details)
            #expect(uses == 1, "\(accessor) should appear once in Details, found \(uses)")
            #expect(details.contains("TuckedLine(line: \(accessor)"), "\(accessor) is rendered raw inside Details")
            #expect(twinHome.contains("SurfacedLine(line: \(accessor)"), "\(accessor) has no top-level twin")
        }
        // The Claude status is never a Details line (only the deleted Status
        // Hero tucked it). Since 2026-10-21 it is the disclosure's own text:
        // rendered ONCE, by the footer's disclosure, unconditionally — no
        // placement filter and no expanded-only branch that could ever hide
        // it — and a paused label carries the severity icon + tint itself.
        let views = try Self.allViewCode()
        #expect(Self.occurrences(of: "model.detailsLabel", in: views) == 1, "the label renders exactly once")
        let disclosure = try #require(Self.structChunk("PanelDetailsDisclosure", in: source))
        #expect(disclosure.contains("let label = model.detailsLabel"), "the footer disclosure renders the status")
        #expect(disclosure.contains("Text(label.text)"))
        #expect(disclosure.contains("MenuStateModel.severitySymbol(label.severity)"), "paused shows the ⚠︎ icon")
        #expect(disclosure.contains("PanelSeverityTint.color(label.severity)"), "…in the warning tint")
        for hiding in ["placement(ofDetailsLine:", "if expanded", "if model.detailsExpanded"] {
            #expect(!disclosure.contains(hiding), "'\(hiding)' could hide the Claude status")
        }
        // Footer width (measured at the 300pt panel): when label + badge do
        // not fit beside Quit, the BADGE yields before the label would
        // truncate — the status text is never the part that truncates.
        #expect(disclosure.contains("ViewThatFits(in: .horizontal)"))
        let withBadge = try #require(disclosure.range(of: "statusLine(label, badge: badge)"))
        let withoutBadge = try #require(disclosure.range(of: "statusLine(label, badge: .nominal)"))
        #expect(withBadge.lowerBound < withoutBadge.lowerBound, "prefer label + badge, then the label alone")
        // Launch at Login moves as a whole row on the same placement rule.
        #expect(details.contains("placement(ofDetailsLine: model.launchAtLoginCaption"))
        let surfacedLogin = try #require(Self.structChunk("SurfacedLaunchAtLogin", in: source))
        #expect(surfacedLogin.contains("placement(ofDetailsLine: caption.severity) == .topLevel"))
        // The two filters are complementary by construction (an absent line
        // renders in neither).
        let tucked = try #require(Self.structChunk("TuckedLine", in: source))
        let surfaced = try #require(Self.structChunk("SurfacedLine", in: source))
        #expect(tucked.contains("if let line, MenuStateModel.placement(ofDetailsLine: line.severity) == .details"))
        #expect(surfaced.contains("if let line, MenuStateModel.placement(ofDetailsLine: line.severity) == .topLevel"))
    }

    /// Declutter (2026-10-21): Lock Screen left the controls tier. It is an
    /// ICON-ONLY button (tooltip + VoiceOver label carry its name) with the
    /// same action and the same disabled rule, forwarding to the model only —
    /// MenuContentView keeps the one dismissal gateway (locked in
    /// ScreenLockControllerTests / ScaffoldTests). Its placement — the battery
    /// header's top-right corner since 2026-10-22 — is locked in
    /// `theLockScreenButtonSitsInTheHeaderTopRightCorner`.
    @Test func lockScreenIsAnIconOnlyButtonForwardingToTheModel() throws {
        let button = try #require(Self.structChunk("LockScreenButton", in: try Self.code("MenuPanelView.swift")))
        #expect(button.contains("Button { model.lockScreen() } label: {"))
        #expect(button.contains("Image(systemName: PanelSymbol.lockScreen)"))
        #expect(!button.contains("Text(") && !button.contains("Button(\""), "icon-only — no visible title")
        #expect(button.contains(".help(\"Lock Screen\")"))
        #expect(button.contains(".accessibilityLabel(\"Lock Screen\")"))
        #expect(button.contains(".accessibilityHint("))
        #expect(button.contains(
            ".disabled(!MenuStateModel.lockScreenPresentation(available: model.lockScreenAvailable).enabled)"))
        for token in ["cancelTracking", "setDetailsExpanded", "request"] {
            #expect(!button.contains(token), "'\(token)' — the button only forwards to model.lockScreen()")
        }
        #expect(Self.occurrences(of: "model.lockScreen()", in: try Self.allViewCode()) == 1)
    }

    /// Declutter (2026-10-21): the controls tier is exactly Stay Awake ·
    /// Charge Limit · Lid alert · Session alerts, in that order, between the
    /// panel's (at most) two Dividers.
    @Test func theControlsTierIsStayAwakeChargeLimitLidAndSession() throws {
        let body = try Self.layoutBody()
        let titles = body.components(separatedBy: "PanelRow(symbol: ").dropFirst().map { chunk in
            chunk.components(separatedBy: "title: \"").dropFirst().first?.prefix { $0 != "\"" }.description ?? "?"
        }
        #expect(titles == ["Stay Awake", "Charge Limit", "Lid alert", "Session alerts"], "got \(titles)")
        #expect(Self.occurrences(of: "Divider()", in: body) == 2, "at most two Dividers")
    }

    /// Track C (C4): the "Session alerts" row is a controls-tier row DIRECTLY
    /// under the Lid alert row — same PanelRow shape (symbol, title, toggle),
    /// its status as a non-nominal-only caption, and its surfaced twin under
    /// it. It sits above the Divider that opens the Details tier, and it is
    /// the ONLY place the session toggle is rendered.
    @Test func theSessionAlertsRowSitsDirectlyUnderTheLidRow() throws {
        let body = try Self.layoutBody()
        let lidRow = try #require(body.range(of: "PanelRow(symbol: PanelSymbol.lidAlert, title: \"Lid alert\")"))
        let sessionRow = try #require(
            body.range(of: "PanelRow(symbol: PanelSymbol.sessionAlerts, title: \"Session alerts\")"),
            "the Session alerts row is missing from the layout")
        #expect(lidRow.upperBound < sessionRow.lowerBound, "Session alerts renders below Lid alert")
        // Nothing renders between the two rows except the lid row's own
        // caption + surfaced lines: the next PanelRow after the lid row is the
        // session row.
        let between = body[lidRow.upperBound..<sessionRow.lowerBound]
        #expect(!between.contains("PanelRow("), "another row sits between Lid alert and Session alerts")
        #expect(!between.contains("Divider()"))
        // The session feature: toggle, status caption, surfaced twin — in that order.
        let tail = body[sessionRow.upperBound...]
        let toggle = try #require(tail.range(of: "SessionAlertsToggle(model: model)"))
        let caption = try #require(tail.range(of: "indentedCaption(model.finishAlertStatus)"))
        let twin = try #require(tail.range(of: "SessionAlertsSurfacedLines(model: model)"))
        #expect(toggle.lowerBound < caption.lowerBound && caption.lowerBound < twin.lowerBound)
        // Still in the controls tier: above the Details tier's Divider, the
        // Details content and the footer.
        let detailsDivider = try #require(body.range(of: "Divider()", options: .backwards))
        #expect(twin.upperBound <= detailsDivider.lowerBound, "the row must stay above the Details tier")
        #expect(Self.occurrences(of: "SessionAlertsToggle(", in: try Self.allViewCode()) == 1,
                "the session toggle is rendered exactly once, in the layout")
        #expect(Self.occurrences(of: "SessionAlertsToggle(model: model)", in: body) == 1)
        // The toggle forwards to the model (and MenuContentView), never to a
        // panel-local or dismissing path.
        let toggleView = try #require(Self.structChunk("SessionAlertsToggle", in: try Self.code("MenuPanelView.swift")))
        #expect(toggleView.contains("set: { model.setFinishAlertEnabled($0) }"))
        #expect(!toggleView.contains("cancelTracking") && !toggleView.contains("setDetailsExpanded"))
    }

    /// Issue #34 non-goal: the session alerts' run floor is set ONLY in the
    /// "ntfy settings…" editor (MenuContentView). No panel view — the
    /// controls tier, the Details tier, the footer — renders or edits it, and
    /// the panel keeps exactly one route to the editor.
    @Test func theRunFloorNeverReachesThePanel() throws {
        let views = try Self.allViewCode()
        for token in ["finishAlertMinimumRunSeconds", "minimumRunSeconds", "sessionAlertsFloor",
                      "SessionAlertsFloorGroup"] {
            #expect(!views.contains(token), "'\(token)' in a panel view — the floor lives in the ntfy settings editor")
        }
        #expect(Self.occurrences(of: "model.editLidGuardSettings()", in: views) == 1,
                "one \"ntfy settings…\" button opens the editor")
        // Vacuity: the editor really carries the group.
        #expect(try Self.code("MenuContentView.swift").contains("SessionAlertsFloorGroup(seconds:"))
    }

    /// Issue #42: a failed Save used to join the validation error into the
    /// alert's informative text, so every re-presented pass came back 2-4
    /// wrapped lines taller. Now the informative text is the explanation
    /// alone on every pass, and the error lives in a caption band reserved on
    /// EVERY pass at the top of the accessory stack — its height measured
    /// (`cellSize(forBounds:)`, like SessionAlertsFloorGroup's caption) for
    /// the worst-case message at the stack width, never a fixed point count,
    /// and before the pass's own text goes in. Lint-style: the modal cannot
    /// be driven headlessly.
    @Test func theNtfyEditorReservesAFixedErrorBand() throws {
        let source = try Self.code("MenuContentView.swift")
        let start = try #require(source.range(of: "func runLidAlertSettingsEditor("), "editor not found — keep this lock updated")
        let tail = source[start.upperBound...]
        let end = ["\n    private func ", "\n    func ", "\n    static func ", "\n    nonisolated static func "]
            .compactMap { tail.range(of: $0)?.lowerBound }
            .min() ?? tail.endIndex
        let editor = String(tail[..<end])
        #expect(editor.contains("alert.runModal()"), "vacuity: the chunk is the editor")

        // The informative text: the constant explanation, never the error.
        #expect(editor.contains("alert.informativeText = Self.lidAlertSettingsExplanation\n"))
        #expect(Self.occurrences(of: "informativeText", in: editor) == 1)
        #expect(!editor.contains(".joined("), "nothing is joined into the dialog's text any more")
        #expect(editor.contains("alert.alertStyle = error == nil ? .informational : .warning"))

        // The band: a small red wrapping caption, sized for the worst case.
        for token in [
            "let errorCaption = NSTextField(wrappingLabelWithString:\n"
                + "            MenuStateModel.lidAlertSettingsError(topic: .invalid, server: .invalid) ?? \"\")",
            "errorCaption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)",
            "errorCaption.textColor = .systemRed",
            "let worstCaseBounds = NSRect(x: 0, y: 0, width: stackWidth, height: .greatestFiniteMagnitude)",
            "errorCaption.cell?.cellSize(forBounds: worstCaseBounds).height",
            "let errorBandY = fieldsY + 54 + PanelMetrics.regular",
            "errorCaption.frame = NSRect(x: 0, y: errorBandY, width: stackWidth, height: errorBandHeight)",
            "errorCaption.stringValue = error ?? \"\"",
            "errorCaption.setAccessibilityElement(!errorCaption.stringValue.isEmpty)",
            "height: errorBandY + errorBandHeight))",
            "\n        stack.addSubview(errorCaption)\n",
        ] {
            #expect(editor.contains(token), "'\(token)' not found — the reserved error band was rewired")
        }
        // Measured BEFORE the pass's own text replaces the worst case, and
        // added on every pass (at the method's top level, not under an `if`).
        let measured = try #require(editor.range(of: "cellSize(forBounds: worstCaseBounds)"))
        let filled = try #require(editor.range(of: "errorCaption.stringValue = error"))
        #expect(measured.upperBound <= filled.lowerBound, "the band must be sized for the worst case, not this pass")
        #expect(Self.occurrences(of: "errorCaption.stringValue =", in: editor) == 1)
        // Nothing that sizes the band or the stack depends on this pass's error.
        for line in editor.split(separator: "\n") where line.contains("errorBand") || line.contains("let stack =") {
            #expect(!line.contains("error ?") && !line.contains("error =="), "pass-dependent geometry: \(line)")
        }
    }

    /// Issue #42, headless: "worst case" really is the tallest message. At
    /// the editor's 300 pt and at a widened stack, neither single-field error
    /// wraps taller than both-fields-invalid, at the band's own font. UI
    /// audit M3 lengthened the topic sentence ("Tick Show to check what you
    /// typed."), so the measured band grew with it; what must hold is that
    /// every pass — nominal, either single error, both — fits the ONE band,
    /// so the frame stays the same across passes. No point count is pinned.
    @Test @MainActor func theBothFieldsErrorIsTheTallestEditorMessage() throws {
        let worst = try #require(MenuStateModel.lidAlertSettingsError(topic: .invalid, server: .invalid))
        #expect(worst.contains("Tick Show to check what you typed."), "the band is measured WITH the M3 hint")
        let singles = [
            "",   // a nominal pass: the band is reserved but empty
            try #require(MenuStateModel.lidAlertSettingsError(topic: .invalid, server: .empty)),
            try #require(MenuStateModel.lidAlertSettingsError(topic: .empty, server: .invalid)),
        ]
        func height(_ text: String, width: CGFloat) -> CGFloat {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
            return ceil(label.cell?.cellSize(forBounds: bounds).height ?? 0)
        }
        for width: CGFloat in [300, 320, 360] {
            let reserved = height(worst, width: width)
            #expect(reserved > height("Nothing was saved.", width: width), "vacuity: the worst case wraps")
            for message in singles {
                #expect(height(message, width: width) <= reserved, "\(width) pt: '\(message)' outgrows the band")
            }
        }
    }

    /// F3 (2026-10-18): the Pause detection kill switch exists ONCE, inside the
    /// Details content — out of casual reach. (The top-level "Claude: paused"
    /// footer label is the mapping's job, tested in MenuPanelPresentationTests.)
    @Test func pauseDetectionToggleLivesOnlyInDetails() throws {
        let views = try Self.allViewCode()
        #expect(Self.occurrences(of: "setDetectionPaused(", in: views) == 1)
        #expect(Self.occurrences(of: "Toggle(\"Pause detection\"", in: views) == 1)
        let details = try #require(Self.structChunk("PanelDetailsContent", in: try Self.code("MenuPanelView.swift")))
        #expect(details.contains("setDetectionPaused("))
        #expect(details.contains("Toggle(\"Pause detection\""))
        // The layout never reaches for it directly.
        #expect(!(try Self.code(Self.layoutFile)).contains("setDetectionPaused"))
    }

    /// F3 stage 1: the "Phone alerts (beta)" checkbox exists ONCE, inside the
    /// Details content's ntfy-alerts group (never in the frozen controls
    /// tier or the layout), only while the composite is wired, with its line
    /// tucked right under it; it forwards to the model and nothing else.
    @Test func thePhoneToggleLivesOnlyInDetails() throws {
        let views = try Self.allViewCode()
        #expect(Self.occurrences(of: "PhoneTransportToggle(", in: views) == 1, "exactly ONE phone toggle")
        #expect(Self.occurrences(of: "model.setPhoneTransportEnabled(", in: views) == 1)
        #expect(!(try Self.code(Self.layoutFile)).contains("PhoneTransport"), "the frozen layout is unchanged")

        let source = try Self.code("MenuPanelView.swift")
        let details = try #require(Self.structChunk("PanelDetailsContent", in: source))
        let gate = try #require(details.range(of: "if model.phoneTransportVisible {"))
        let toggle = try #require(details.range(of: "PhoneTransportToggle(model: model)"))
        let line = try #require(details.range(of: "TuckedLine(line: model.phoneAlertStatus("))
        #expect(gate.upperBound <= toggle.lowerBound && toggle.upperBound <= line.lowerBound,
                "gated, the checkbox, then its line")
        let group = try #require(details.range(of: "private var ntfyAlertsGroup"))
        let nextGroup = try #require(details.range(of: "private var claudeGroup"))
        #expect(group.upperBound < toggle.lowerBound && toggle.upperBound < nextGroup.lowerBound,
                "the toggle sits in the alerts' delivery group")

        let view = try #require(Self.structChunk("PhoneTransportToggle", in: source))
        #expect(view.contains("Toggle(MenuStateModel.phoneTransportToggleTitle, isOn: Binding("))
        #expect(view.contains("set: { model.setPhoneTransportEnabled($0) }"))
        #expect(view.contains(".toggleStyle(.checkbox)"))
        for token in ["cancelTracking", "setDetailsExpanded", "request", "Button"] {
            #expect(!view.contains(token), "'\(token)' — the checkbox only forwards to the model")
        }
        #expect(MenuStateModel.phoneTransportToggleTitle == "Phone alerts (beta)")
    }

    // MARK: - Motion, color, Dynamic Type, VoiceOver

    /// Motion ≤200ms ease-out or none, always behind Reduce Motion, and never
    /// on an observed-state change (no `withAnimation` anywhere — the only
    /// animated value is the disclosure chevron).
    @Test func motionIsGatedAndShort() throws {
        let views = try Self.allViewCode()
        #expect(!views.contains("withAnimation"), "observed-state snaps must never animate")
        let animated = views.split(separator: "\n").filter { $0.contains(".animation(") }
        #expect(animated.count == 1, "only the chevron animates")
        for line in animated {
            #expect(line.contains("reduceMotion ? nil"), "animation not gated on Reduce Motion: \(line)")
            #expect(line.contains("easeOut"))
            let duration = line.components(separatedBy: "duration: ").dropFirst().first
                .flatMap { Double($0.prefix { "0123456789.".contains($0) }) }
            #expect((duration ?? 1) <= 0.2, "animation longer than 200ms: \(line)")
        }
    }

    /// #67: the panel's motion, codified in `PanelMotion`. Every animated line
    /// is the chevron's pattern — nil under Reduce Motion, an ease-out — and
    /// spells one of `PanelMotion`'s animation durations, within
    /// `PanelMotion.maxDuration`; the chevron turns at `PanelMotion.chevron`.
    /// Zero motion on open / close: no view animates its insertion or removal
    /// (`.transition(`), nothing animates through a transaction or
    /// imperatively, and the hosting view's re-fit snaps to the new size.
    static func motionFailures(views: String, owner: String) -> [String] {
        var failures: [String] = []
        let durations = [PanelMotion.chevron, PanelMotion.pressFade]
        let animated = views.split(separator: "\n").filter { $0.contains(".animation(") }
        if animated.isEmpty { failures.append("vacuity: the chevron animates") }
        for line in animated {
            guard line.contains(".animation(reduceMotion ? nil : .easeOut(duration: ") else {
                failures.append("not the chevron's Reduce-Motion-nil ease-out pattern: \(line)")
                continue
            }
            let duration = line.components(separatedBy: "duration: ").dropFirst().first
                .flatMap { Double($0.prefix { "0123456789.".contains($0) }) }
            guard let duration, durations.contains(duration) else {
                failures.append("the duration is not a PanelMotion constant: \(line)")
                continue
            }
            if duration > PanelMotion.maxDuration {
                failures.append("longer than PanelMotion.maxDuration: \(line)")
            }
        }
        let disclosure = Self.structChunk("PanelDetailsDisclosure", in: views) ?? ""
        if !disclosure.contains(".animation(reduceMotion ? nil : .easeOut(duration: \(PanelMotion.chevron)), value: expanded)") {
            failures.append("the chevron must turn at PanelMotion.chevron")
        }
        for token in [".transition(", "withAnimation", "withTransaction", ".transaction", "matchedGeometryEffect",
                      "NSAnimationContext", "animator()"] where (views + "\n" + owner).contains(token) {
            failures.append("'\(token)' — nothing animates the panel's open, close or height change")
        }
        if !owner.contains("        setFrameSize(fitting)\n") {
            failures.append("MenuPanelHostingView's re-fit must snap (a plain setFrameSize)")
        }
        return failures
    }

    @Test func panelMotionCodifiesEveryAnimation() throws {
        let views = try Self.allViewCode()
        let owner = try Self.code("MenuContentView.swift")
        #expect(Self.motionFailures(views: views, owner: owner).isEmpty, "\(Self.motionFailures(views: views, owner: owner))")
        #expect(PanelMotion.chevron <= PanelMotion.maxDuration && PanelMotion.pressFade <= PanelMotion.maxDuration)
        let canaries: [(name: String, views: String, owner: String)] = [
            ("an insertion transition", views + "\nlet canary = Text(\"x\").transition(.opacity)", owner),
            ("the chevron off its PanelMotion duration",
             views.replacingOccurrences(of: "duration: 0.15)", with: "duration: 0.25)"), owner),
            ("an animation not gated on Reduce Motion",
             views + "\nlet canary = Text(\"x\").animation(.easeOut(duration: 0.1), value: 1)", owner),
            ("a transaction", views + "\nlet canary = Text(\"x\").transaction { $0.animation = .default }", owner),
            ("an imperative AppKit animation", views, owner + "\nlet canary = NSAnimationContext.current"),
            ("an animated re-fit", views, owner.replacingOccurrences(
                of: "        setFrameSize(fitting)\n", with: "        animator().setFrameSize(fitting)\n")),
        ]
        for canary in canaries {
            #expect(canary.views != views || canary.owner != owner, "canary setup '\(canary.name)'")
            #expect(!Self.motionFailures(views: canary.views, owner: canary.owner).isEmpty,
                    "canary '\(canary.name)' was NOT caught")
        }
    }

    /// #67: Details renders the test send through `SendFeedbackButton` — once,
    /// beside "ntfy settings…" — and the wrapper keeps its promises: every
    /// phase's label is laid out (the current one shown, the rest hidden), so
    /// the widest reserves the width; the phase moves only through the pure
    /// mapping; the existing outcome pipeline ends "Sending…"; the "Sent" hold
    /// is `PanelMotion.sentRevert`; nothing animates; and the only action is
    /// `model.sendLidGuardTestMessage()`.
    @Test func theTestSendAcknowledgesThroughOneWrapper() throws {
        let source = try Self.code("MenuPanelView.swift")
        let views = try Self.allViewCode()
        let details = try #require(Self.structChunk("PanelDetailsContent", in: source))
        #expect(Self.occurrences(of: "SendFeedbackButton(", in: views) == 1, "ONE test-send button")
        #expect(details.contains("Button(\"ntfy settings…\") { model.editLidGuardSettings() }\n"
                                 + "                    .controlSize(.small)\n"
                                 + "                SendFeedbackButton(model: model)\n"),
                "the wrapper sits beside \"ntfy settings…\" in Details")
        #expect(!views.contains("Button(\"Send test message\")"), "no bare test-send button")
        #expect(Self.occurrences(of: "model.sendLidGuardTestMessage()", in: views) == 1)

        let button = try #require(Self.structChunk("SendFeedbackButton", in: source))
        for token in [
            "ForEach(TestSendPhase.allCases, id: \\.self)",
            "if candidate == phase {",
            "label.hidden()",
            "phase = MenuStateModel.testSendPhase(phase, on: .tapped)\n            model.sendLidGuardTestMessage()",
            ".controlSize(.small)",
            ".disabled(!presentation.enabled)",
            ".onChange(of: model.lidGuardLastOutcomeAt)",
            "on: .outcome(model.lidGuardLastOutcome)",
            ".task(id: phase)",
            "Task.sleep(for: .seconds(PanelMotion.sentRevert))",
            "on: .revertElapsed",
        ] {
            #expect(button.contains(token), "'\(token)' not found — the test-send wrapper was rewired")
        }
        let assignments = button.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("phase = ") }
        #expect(assignments.count == 3, "tap, outcome, hold — got \(assignments)")
        for line in assignments {
            #expect(line.hasPrefix("phase = MenuStateModel.testSendPhase(phase, on: "), "phase moved outside the mapping: \(line)")
        }
        for token in [".animation(", "fixedSize", "cancelTracking", "setDetailsExpanded", "request"] {
            #expect(!button.contains(token), "'\(token)' in the test-send wrapper")
        }
    }

    @Test func systemColorsOnly() throws {
        let views = try Self.allViewCode()
        for token in ["Color(red", "Color(hue", "Color(white", "Color(\"", "Color(#", "hex", "#colorLiteral",
                      "NSColor(", "UIColor", ".rgb"] {
            #expect(!views.contains(token), "'\(token)' — use system materials / semantic colors only")
        }
    }

    /// Growable text may wrap vertically but is never frozen horizontally:
    /// the only bare `.fixedSize()` is on PanelRow's trailing CONTROLS.
    @Test func textIsNeverFixedHorizontally() throws {
        let views = try Self.allViewCode()
        let fixed = views.components(separatedBy: ".fixedSize(").dropFirst()
        #expect(!fixed.isEmpty)
        for occurrence in fixed {
            let call = occurrence.prefix { $0 != ")" }
            #expect(call.isEmpty || call == "horizontal: false, vertical: true",
                    "unexpected .fixedSize(\(call))")
        }
        let bare = Self.occurrences(of: ".fixedSize()", in: views)
        #expect(bare == 1)
        let row = try #require(Self.structChunk("PanelRow", in: try Self.code("MenuPanelView.swift")))
        #expect(row.contains("HStack(spacing: PanelMetrics.regular) { trailing() }\n                .fixedSize()"))
    }

    /// Status-as-disclosure (2026-10-21): the control is still NAMED "Details"
    /// for VoiceOver; its value speaks the Claude status (with the severity
    /// prefix, e.g. "Warning: Claude: paused") plus the expanded state.
    @Test func theDisclosureIsLabelledForVoiceOver() throws {
        let source = try Self.code("MenuPanelView.swift")
        let disclosure = try #require(Self.structChunk("PanelDetailsDisclosure", in: source))
        #expect(disclosure.contains(".accessibilityLabel(\"Details\")"))
        #expect(disclosure.contains(
            #".accessibilityValue("\(PanelSeverityTint.spoken(label)), \(expanded ? "expanded" : "collapsed")")"#))
        #expect(disclosure.contains(".accessibilityHint("))
        #expect(disclosure.contains("\"Shows detection, alert and app settings\""))
        #expect(disclosure.contains(".accessibilityElement(children: .ignore)"), "one element, not its parts")
    }

    // MARK: - Menu-stays-open

    /// The disclosure is pure model state: it never calls a request hook and
    /// never routes through MenuContentView, so it cannot reach the one
    /// dismissal gateway.
    @Test func panelOnlyActionsNeverReachTheDismissalGateway() throws {
        let model = try Self.code("MenuStateModel.swift")
        for function in ["setDetailsExpanded"] {
            let start = try #require(model.range(of: "func \(function)("), "\(function) not found")
            let tail = model[start.upperBound...]
            let end = ["\n    func ", "\n    var ", "\n    nonisolated static func "]
                .compactMap { tail.range(of: $0)?.lowerBound }
                .min() ?? tail.endIndex
            let body = String(tail[..<end])
            #expect(!body.contains("request"), "\(function) must not forward to an AppKit flow")
        }
        let owner = try Self.code("MenuContentView.swift")
        #expect(!owner.contains("setDetailsExpanded"))
    }
}
