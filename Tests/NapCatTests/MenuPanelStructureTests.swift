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
/// hero-size gauge with the charge-state glyph (curation round 2 + its fix),
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

    /// The layout must render the four surfaced-line components (the
    /// top-level home of every Details line that can be a problem — Track C
    /// added the session-alerts one) plus the Details content and the ONE
    /// footer row that carries the disclosure and the always-visible Quit.
    @Test func thePanelGivesProblemLinesATopLevelHome() throws {
        let body = try Self.layoutBody()
        for component in ["ClaudeSurfacedLines(", "LidAlertSurfacedLines(", "SessionAlertsSurfacedLines(",
                          "SurfacedLaunchAtLogin(", "PanelDetailsContent(", "PanelFooterRow("] {
            #expect(body.contains(component), "\(Self.layout) is missing \(component)")
        }
        #expect(Self.occurrences(of: "PanelFooterRow(", in: body) == 1, "ONE footer row")
        #expect(Self.occurrences(of: "PanelDetailsContent(", in: body) == 1, "ONE Details content")
        // The layout renders no disclosure of its own — the footer row is the
        // only home, so the panel has exactly ONE disclosure.
        #expect(!(try Self.code(Self.layoutFile)).contains("PanelDetailsDisclosure("),
                "the layout renders a second disclosure")
    }

    /// Curation round 1 (2026-10-18): Details sits on the LEFT of the panel's
    /// last row with Quit on the RIGHT. The footer holds the ONLY disclosure
    /// and the ONLY Quit button in the panel, and it is the LAST thing —
    /// expanded Details content (and a surfaced Launch at Login) render above
    /// it, so Quit can never be pushed out of view.
    @Test func theFooterRowHoldsTheOneDisclosureAndQuitAndComesLast() throws {
        let views = try Self.allViewCode()
        #expect(Self.occurrences(of: "PanelDetailsDisclosure(", in: views) == 1, "exactly ONE disclosure in the panel")
        #expect(Self.occurrences(of: "Button(\"Quit NapCat\")", in: views) == 1, "exactly ONE Quit button")
        let footer = try #require(Self.structChunk("PanelFooterRow", in: try Self.code("MenuPanelView.swift")))
        let disclosure = try #require(footer.range(of: "PanelDetailsDisclosure("), "the disclosure lives in the footer")
        let spacer = try #require(footer.range(of: "Spacer("))
        let quit = try #require(footer.range(of: "Button(\"Quit NapCat\")"), "Quit lives in the footer")
        #expect(footer.contains("HStack("), "one row")
        #expect(disclosure.lowerBound < spacer.lowerBound && spacer.lowerBound < quit.lowerBound,
                "Details on the left, Spacer, Quit on the right")
        #expect(footer.contains(".keyboardShortcut(\"q\", modifiers: .command)"))

        let body = try Self.layoutBody()
        let footerCall = try #require(body.range(of: "PanelFooterRow(model: model)"), "no footer row")
        for above in ["PanelDetailsContent(", "SurfacedLaunchAtLogin("] {
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
        let pairs: [(accessor: String, twinHome: String)] = [
            ("model.hookStatus", claudeTwins),
            ("model.lidTopicStatus", lidTwins),
            ("model.lidServerStatus", lidTwins),
            ("model.lidLastSend(", lidTwins),
            ("model.finishAlertLastSend(", sessionTwins),
        ]
        for (accessor, twinHome) in pairs {
            let uses = Self.occurrences(of: accessor, in: details)
            #expect(uses == 1, "\(accessor) should appear once in Details, found \(uses)")
            #expect(details.contains("TuckedLine(line: \(accessor)"), "\(accessor) is rendered raw inside Details")
            #expect(twinHome.contains("SurfacedLine(line: \(accessor)"), "\(accessor) has no top-level twin")
        }
        // The Claude status row is never a Details line (only the deleted
        // Status Hero tucked it): the layout renders it at top level,
        // unconditionally — no placement filter that could ever hide it.
        #expect(!details.contains("model.claudeStatus"), "the Claude row must stay top level")
        let layout = try Self.layoutBody()
        #expect(Self.occurrences(of: "ClaudeStatusRow(model: model)", in: layout) == 1)
        #expect(!layout.contains("placement(ofDetailsLine: model.claudeStatus"))
        // Launch at Login moves as a whole row on the same placement rule.
        #expect(details.contains("placement(ofDetailsLine: model.launchAtLoginCaption"))
        let surfacedLogin = try #require(Self.structChunk("SurfacedLaunchAtLogin", in: source))
        #expect(surfacedLogin.contains("placement(ofDetailsLine: caption.severity) == .topLevel"))
        // The two filters are complementary by construction.
        let tucked = try #require(Self.structChunk("TuckedLine", in: source))
        let surfaced = try #require(Self.structChunk("SurfacedLine", in: source))
        #expect(tucked.contains("placement(ofDetailsLine: line.severity) == .details"))
        #expect(surfaced.contains("placement(ofDetailsLine: line.severity) == .topLevel"))
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

    /// F3 (2026-10-18): the Pause detection kill switch exists ONCE, inside the
    /// Details content — out of casual reach. (The top-level "Detection paused"
    /// row is the mapping's job, tested in MenuPanelPresentationTests.)
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

    @Test func theDisclosureIsLabelledForVoiceOver() throws {
        let source = try Self.code("MenuPanelView.swift")
        let disclosure = try #require(Self.structChunk("PanelDetailsDisclosure", in: source))
        #expect(disclosure.contains(".accessibilityLabel(\"Details\")"))
        #expect(disclosure.contains(".accessibilityValue(expanded ? \"Expanded\" : \"Collapsed\")"))
        #expect(disclosure.contains(".accessibilityHint("))
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
