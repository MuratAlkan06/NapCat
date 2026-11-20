// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Lint-style locks for the menu panel (SwiftUI layout cannot be driven
/// headlessly, so the pure mappings are unit-tested in
/// MenuPanelPresentationTests and their USE is locked here). Re-locked
/// around Panel 2.0 slice P (owner pick "c cards", 2026-11-20 — it
/// superseded the 2026-10-18 Quiet Rows freeze): the panel is ONE fixed
/// layout of two cards and a footer, the topic never reaches a view, every
/// Settings line that can be a problem has ONE top-level home below the
/// cards, the footer (gear · Claude status · Quit) comes last outside the
/// cards, the header is the hero-size gauge with the charge-state glyph and
/// carries the Lock Screen button in its top-right corner, nothing of the
/// retired Details disclosure survives, motion is gated on Reduce Motion,
/// and colors are system/semantic only (plus the cards' one measured boost).
struct MenuPanelStructureTests {
    /// Every SwiftUI view file of the panel. A new view file must be added
    /// here AND to the LidGuard / ClaudeDetection scanned-file sets. (The
    /// Settings window's files are a separate surface with their own locks:
    /// `SettingsWindowTests.settingsFiles`.)
    static let viewFiles = ["MenuPanelView.swift", "MenuPanelVariants.swift"]
    /// The panel's one layout since Panel 2.0 slice P.
    static let layout = "GroupedCardsPanel"
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

    /// Whitespace-flattened source: comment lines (blanked by `codeOnly`) and
    /// indentation drop out, so a lock reads the code's shape only.
    static func flat(_ text: some StringProtocol) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Every card in `text`, in order: each `PanelCard {` or `PanelGroup(`
    /// call up to its matching closing brace.
    static func cardBlocks(in text: String) -> [Range<String.Index>] {
        var blocks: [Range<String.Index>] = []
        var from = text.startIndex
        while let opener = ["PanelCard {", "PanelGroup("]
            .compactMap({ text.range(of: $0, range: from..<text.endIndex) })
            .min(by: { $0.lowerBound < $1.lowerBound }),
            let brace = text.range(of: "{", range: opener.lowerBound..<text.endIndex) {
            var depth = 0
            var index = brace.lowerBound
            var end: String.Index?
            while index < text.endIndex {
                if text[index] == "{" { depth += 1 }
                if text[index] == "}" {
                    depth -= 1
                    if depth == 0 { end = text.index(after: index); break }
                }
                index = text.index(after: index)
            }
            guard let end else { break }
            blocks.append(opener.lowerBound..<end)
            from = end
        }
        return blocks
    }

    /// The row titles a chunk of layout renders, in order.
    static func rowTitles(_ text: some StringProtocol) -> [String] {
        String(text).components(separatedBy: "PanelRow(symbol: ").dropFirst().map { chunk in
            chunk.components(separatedBy: "title: \"").dropFirst().first?.prefix { $0 != "\"" }.description ?? "?"
        }
    }

    // MARK: - One fixed layout

    /// Panel 2.0 slice P: MenuPanelView renders the grouped-cards layout
    /// unconditionally. The 2026-10-18 variant picker and its plumbing stay
    /// gone, and so does everything the Details disclosure took with it —
    /// the disclosure, its content, its badge, its in-memory state, its
    /// chevron, the placement tier named after it, the panel's slider and
    /// readout roll, the Details-only phone checkbox, the 76pt header and its
    /// lock inset — from the code, not merely unused (comments may still name
    /// them as history). The retired `menuPanelStyle` key survives ONLY in
    /// `RetiredDefaultsKey`, where the startup migration deletes it.
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
        for token in ["QuietRowsPanel", "PanelDetailsDisclosure", "PanelDetailsContent", "TuckedLine", "detailsExpanded",
                      "setDetailsExpanded", "detailsBadge", "detailsLabel", "plainDetailsLabel", "DetailsGroupHeader",
                      "PanelSymbol.disclosure", "ofDetailsLine", ".details", "PanelMotion.chevron", "ChargeLimitSlider",
                      "ChargeLimitReadout", "limitReadout", "PhoneTransportToggle", "headerLockInset", "minHeight: 76"] {
            #expect(!panelCode.contains(token), "'\(token)' — retired with the Details disclosure (slice P)")
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

    /// The layout renders the five surfaced-line components — the top-level
    /// home of every Settings line that can be a problem (Track C added the
    /// session-alerts one, the 2026-10-21 declutter the General one for the
    /// Lock Screen line) — each exactly once, OUTSIDE the cards: below the
    /// last card and above the ONE footer row, right over the gear that
    /// opens their Settings pane.
    @Test func thePanelGivesProblemLinesATopLevelHomeBelowTheCards() throws {
        let body = try Self.layoutBody()
        let cards = Self.cardBlocks(in: body)
        #expect(cards.count == 2, "the Power card and the Alerts card")
        let footer = try #require(body.range(of: "PanelFooterRow(model: model)"), "no footer row")
        #expect(Self.occurrences(of: "PanelFooterRow(", in: body) == 1, "ONE footer row")
        let lastCardEnd = try #require(cards.last).upperBound
        for component in ["ClaudeSurfacedLines(", "LidAlertSurfacedLines(", "SessionAlertsSurfacedLines(",
                          "GeneralSurfacedLines(", "SurfacedLaunchAtLogin("] {
            #expect(Self.occurrences(of: component, in: body) == 1, "\(component) must render exactly once")
            let at = try #require(body.range(of: component), "\(Self.layout) is missing \(component)")
            #expect(lastCardEnd <= at.lowerBound, "\(component) must render below the cards")
            #expect(at.upperBound <= footer.lowerBound, "\(component) must render above the footer")
            for card in cards {
                #expect(!body[card].contains(component), "\(component) renders inside a card")
            }
        }
    }

    /// Panel 2.0 slice P: the panel's LAST row sits OUTSIDE the cards — the
    /// Settings gear first, then the Claude status caption, the Spacer, then
    /// Quit on the right, and nothing else (no icon button beside Quit, where
    /// it reads as part of the Quit control — the 2026-10-22 lesson; Lock
    /// Screen lives in the header: `theLockScreenButtonSitsInTheHeaderTopRightCorner`).
    /// It holds the ONLY gear, status caption and Quit button in the panel.
    /// It must not read as a third card in light mode: neither the row nor
    /// Quit draws a fill — Quit is the panel's plain press-fade look, its hit
    /// area the footer row's full height. And it comes LAST, so Quit can never
    /// be pushed out of view.
    @Test func theFooterRowHoldsTheGearTheStatusAndQuitAndComesLast() throws {
        let views = try Self.allViewCode()
        #expect(Self.occurrences(of: "Text(\"Quit NapCat\")", in: views) == 1, "exactly ONE Quit button")
        #expect(Self.occurrences(of: "model.quit()", in: views) == 1)
        #expect(Self.occurrences(of: "SettingsGearButton(", in: views) == 1, "exactly ONE Settings gear")
        #expect(Self.occurrences(of: "PanelFooterStatus(", in: views) == 1, "exactly ONE status caption")
        let footer = try #require(Self.structChunk("PanelFooterRow", in: try Self.code("MenuPanelView.swift")))
        #expect(!footer.contains("LockScreenButton("), "Lock Screen lives in the header, not the footer")
        let row = try #require(footer.range(of: "HStack(alignment: .center, spacing: PanelMetrics.regular) {"))
        let gear = try #require(footer.range(of: "SettingsGearButton(model: model)"), "the gear lives in the footer")
        let status = try #require(footer.range(of: "PanelFooterStatus(model: model)"), "the status lives in the footer")
        let spacer = try #require(footer.range(of: "Spacer(minLength: PanelMetrics.regular)"))
        let quit = try #require(footer.range(of: "Button { model.quit() } label: {"), "Quit lives in the footer")
        #expect(Self.occurrences(of: "HStack(", in: footer) == 1, "one row — no nested button group")
        #expect(gear.lowerBound < status.lowerBound && status.lowerBound < spacer.lowerBound
                && spacer.lowerBound < quit.lowerBound,
                "the gear, the status, the Spacer, then Quit on the right")
        for gap in [footer[row.upperBound..<gear.lowerBound], footer[gear.upperBound..<status.lowerBound],
                    footer[status.upperBound..<spacer.lowerBound], footer[spacer.upperBound..<quit.lowerBound]] {
            #expect(gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "nothing else sits in the footer — the gear, the status, the Spacer, Quit")
        }
        #expect(Self.flat(footer[quit.lowerBound...]).hasPrefix(
            "Button { model.quit() } label: { Text(\"Quit NapCat\") .font(.caption)"
            + " .frame(minHeight: PanelMetrics.iconButtonSize) .contentShape(Rectangle()) }"
            + " .buttonStyle(PanelPressFadeButtonStyle()) .keyboardShortcut(\"q\", modifiers: .command) }"),
                "Quit: plain press-fade text, its hit area the footer row's height, ⌘Q — and the last control")
        for token in [".background", ".overlay", "PanelCard", "PanelGroup", ".controlSize(", ".bordered", "Divider()",
                      "Color("] {
            #expect(!footer.contains(token), "'\(token)' — the footer and Quit draw no fill (never a third card)")
        }

        let body = try Self.layoutBody()
        let footerCall = try #require(body.range(of: "PanelFooterRow(model: model)"), "no footer row")
        for card in Self.cardBlocks(in: body) {
            #expect(card.upperBound <= footerCall.lowerBound, "the footer sits below — outside — the cards")
        }
        // Nothing follows the footer inside the main column: only the closing
        // brace before the column's own modifiers.
        let tail = body[footerCall.upperBound...]
        let beforeModifiers = tail.range(of: ".padding(").map { tail[..<$0.lowerBound] } ?? tail
        #expect(beforeModifiers.trimmingCharacters(in: .whitespacesAndNewlines) == "}",
                "the footer row must be the panel's last row")
    }

    /// Slice P (owner pick "c cards"): `PanelCard` is the panel's ONE
    /// container — radius 8 with continuous corners, 10pt padding, its
    /// features `rowSpacing` apart, the full-opacity `quaternarySystemFill`
    /// PLUS the one measured boost layer (4.5% black light / 3.2% white
    /// dark — 1.166:1 / 1.188:1 in the pick render; the system fill alone was
    /// the 1.06:1 invisible card), a 0.5pt separator hairline. `PanelGroup`
    /// is a `.caption` semibold secondary header `tight` above a card.
    @Test func theCardIsThePanelsOneContainer() throws {
        #expect(PanelMetrics.cardRadius == 8 && PanelMetrics.cardPadding == 10 && PanelMetrics.cardStroke == 0.5)
        #expect(PanelMetrics.cardBoostLight == 0.045 && PanelMetrics.cardBoostDark == 0.032)
        let source = try Self.code("MenuPanelView.swift")
        let card = try #require(Self.structChunk("PanelCard", in: source))
        for token in [
            "let shape = RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous)",
            "VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {",
            ".padding(PanelMetrics.cardPadding)",
            ".frame(maxWidth: .infinity, alignment: .leading)",
            "shape.fill(Color(nsColor: .quaternarySystemFill))",
            "shape.fill(Self.boost(colorScheme))",
            ".overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: PanelMetrics.cardStroke))",
            "? Color.white.opacity(PanelMetrics.cardBoostDark)",
            ": Color.black.opacity(PanelMetrics.cardBoostLight)",
        ] {
            #expect(card.contains(token), "'\(token)' not found — the card treatment was rewired")
        }
        let group = try #require(Self.structChunk("PanelGroup", in: source))
        #expect(Self.flat(group).contains("VStack(alignment: .leading, spacing: PanelMetrics.tight) {"
                                          + " PanelGroupHeader(title: title) PanelCard(content: content) }"))
        let header = try #require(Self.structChunk("PanelGroupHeader", in: source))
        #expect(Self.flat(header).contains("Text(title) .font(.caption) .fontWeight(.semibold) .foregroundStyle(.secondary)"
                                           + " .accessibilityAddTraits(.isHeader)"))
        // The one container family: no other rounded fill in the panel.
        let views = try Self.allViewCode()
        #expect(Self.occurrences(of: "RoundedRectangle(", in: views) == 1, "only the card draws a rounded shape")
        #expect(Self.occurrences(of: ".quaternarySystemFill", in: views) == 1)
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

    /// The header (curation round 2, kept through Panel 2.0): ONE battery
    /// header, the FIRST thing in the first card (the Power card), the
    /// full-size ring (no 0.8 scale, no 44pt frame), the desktop symbol at
    /// the same footprint, and the "Battery N%" headline + charging line
    /// beside it. Slice P dropped the 76pt minimum height — centred in it,
    /// the 58pt ring sat 9pt down, which inside the card's 10pt padding was
    /// 19pt of dead space above it — so the header hugs the ring. The compact
    /// size and Status Hero's activity text are gone, so there is no geometry
    /// or text knob left to flip back.
    @Test func theHeaderIsTheHeroGaugeWithTheHeadline() throws {
        let body = try Self.layoutBody()
        #expect(Self.occurrences(of: "BatteryHeader(", in: body) == 1, "ONE battery header")
        #expect(body.contains("BatteryHeader(model: model)"), "no size / content knob to pass")
        let power = try #require(Self.cardBlocks(in: body).first)
        #expect(Self.flat(body[power]).hasPrefix("PanelCard { BatteryHeader(model: model)"),
                "the header opens the Power card")

        let header = try #require(Self.structChunk("BatteryHeader", in: try Self.code("MenuPanelView.swift")))
        for token in ["enum Size", "enum Content", "var size", "var content", ".compact", ".activity",
                      "heroActivity", "switch "] {
            #expect(!header.contains(token), "'\(token)' — the header has one geometry and one text column")
        }
        #expect(!header.contains("minHeight"), "no minimum height: the dead space above the ring stays gone")

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
    /// an OVERLAY in the battery header's top-trailing corner. An overlay
    /// takes no room in the header row, so the header — its HStack (default
    /// centre alignment, `loose` spacing) — keeps its layout. Since slice P
    /// the header hugs the ring, so the button's top shares the ring's top
    /// line with no inset. (The button's own shape:
    /// `lockScreenIsAnIconOnlyButtonForwardingToTheModel`.)
    @Test func theLockScreenButtonSitsInTheHeaderTopRightCorner() throws {
        #expect(Self.occurrences(of: "LockScreenButton(", in: try Self.allViewCode()) == 1,
                "exactly ONE Lock Screen button")
        // `body` is the part of the header above `gauge`.
        let (body, _, _) = try Self.batteryHeaderParts()
        #expect(Self.occurrences(of: "LockScreenButton(", in: body) == 1, "Lock Screen lives in the battery header")

        // ONE HStack with the exact literal (an `alignment:` argument would
        // break it), and no frame on it: the header hugs the ring.
        #expect(Self.occurrences(of: "HStack(", in: body) == 1, "ONE header row")
        let row = try #require(body.range(of: "HStack(spacing: PanelMetrics.loose) {"),
                               "the header HStack keeps its default centre alignment and loose spacing")
        #expect(!body.contains(".frame("), "no frame on the header row")

        // The button is an overlay hung directly off the row's VoiceOver
        // element — never a child of the row, which would shift the ring and
        // the text.
        #expect(Self.occurrences(of: ".overlay(", in: body) == 1)
        let sort = try #require(body.range(of: ".accessibilitySortPriority(1)"))
        let overlay = try #require(body.range(of: ".overlay(alignment: .topTrailing) {"),
                                   "the button sits in the header's top-right corner")
        #expect(row.upperBound < sort.lowerBound)
        #expect(body[sort.upperBound..<overlay.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "the overlay is attached to the header row itself")
        let close = try #require(body[overlay.upperBound...].range(of: "}"))
        let content = body[overlay.upperBound..<close.lowerBound]
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(content == "LockScreenButton(model: model)",
                "the overlay holds exactly the button, its top on the ring's top line — got '\(content)'")
    }

    /// UI audit M1a (2026-11-19): VoiceOver used to meet the header as the
    /// ring ("Battery", "85%") and then the headline ("Battery 85%") and the
    /// charging line, so the percent was read twice. The header ROW is now
    /// ONE element: children ignored, labelled "Battery", valued by
    /// `BatteryHeader.spokenValue` — the percent once, then the charging
    /// line, from the same mappings the text column shows. The modifiers sit
    /// on the row, before its overlay, so the Lock Screen button stays
    /// outside the element: its own button. The row outranks it
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
                              + " .overlay(alignment: .topTrailing) {"),
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

    /// Every Settings line that can be a problem reaches the panel through
    /// ONE `SurfacedLine` twin (rendered only while non-nominal) and nowhere
    /// else — no view renders it raw — so each problem shows exactly once.
    @Test func everySettingsLineSurfacesThroughOneTwin() throws {
        let source = try Self.code("MenuPanelView.swift")
        let views = try Self.allViewCode()
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
            ("model.lockScreenStatus", generalTwins),
        ]
        for (accessor, twinHome) in pairs {
            #expect(Self.occurrences(of: accessor, in: views) == 1, "\(accessor) must render exactly once in the panel")
            #expect(twinHome.contains("SurfacedLine(line: \(accessor)"), "\(accessor) has no top-level twin")
        }
        // The Claude status is not a Settings-resident line: it is the
        // footer's own caption, rendered ONCE, unconditionally — no placement
        // filter that could ever hide it — and a paused label carries the
        // severity icon + tint itself.
        #expect(Self.occurrences(of: "model.footerLabel", in: views) == 1, "the label renders exactly once")
        let status = try #require(Self.structChunk("PanelFooterStatus", in: source))
        #expect(status.contains("if let label = model.footerLabel {"), "the footer renders the status")
        #expect(status.contains("Text(label.text)"))
        #expect(status.contains("MenuStateModel.severitySymbol(label.severity)"), "paused shows the ⚠︎ icon")
        #expect(status.contains("PanelSeverityTint.color(label.severity)"), "…in the warning tint")
        #expect(status.contains(".lineLimit(1)"), "one line beside Quit")
        #expect(!status.contains("placement("), "a placement filter could hide the Claude status")
        // Launch at Login moves as a whole row on the same placement rule; the
        // twin and it are the panel's only placement filters.
        let surfacedLogin = try #require(Self.structChunk("SurfacedLaunchAtLogin", in: source))
        #expect(surfacedLogin.contains("placement(ofSettingsLine: caption.severity) == .topLevel"))
        let surfaced = try #require(Self.structChunk("SurfacedLine", in: source))
        #expect(surfaced.contains("if let line, MenuStateModel.placement(ofSettingsLine: line.severity) == .topLevel"))
        #expect(Self.occurrences(of: "placement(ofSettingsLine:", in: views) == 2)
    }

    /// Declutter (2026-10-21): Lock Screen left the controls tier. It is an
    /// ICON-ONLY button (tooltip + VoiceOver label carry its name) with the
    /// same action and the same disabled rule, forwarding to the model only —
    /// MenuContentView keeps the one dismissal gateway (locked in
    /// ScreenLockControllerTests / ScaffoldTests). Since slice P it IS the
    /// panel's `PanelIconButton` (15pt glyph, 28pt target, 36pt hit area —
    /// #47: the bordered small button hit-tested at its 35×19pt bezel only).
    /// Its placement — the battery header's top-right corner since
    /// 2026-10-22 — is locked in `theLockScreenButtonSitsInTheHeaderTopRightCorner`.
    @Test func lockScreenIsAnIconOnlyButtonForwardingToTheModel() throws {
        let button = try #require(Self.structChunk("LockScreenButton", in: try Self.code("MenuPanelView.swift")))
        let shape: String = [
            "PanelIconButton(symbol: PanelSymbol.lockScreen, label: \"Lock Screen\") { model.lockScreen() }",
            ".disabled(!MenuStateModel.lockScreenPresentation(available: model.lockScreenAvailable).enabled)",
            ".accessibilityHint(",
        ].joined(separator: " ")
        #expect(Self.flat(button).contains(shape), "the shared icon button, its disabled rule, then its hint")
        #expect(!button.contains("Text("), "icon-only — no visible title")
        #expect(Self.occurrences(of: "Button(", in: button) == 1 && !button.contains("Button {"),
                "no button of its own — only the shared PanelIconButton")
        for token in [".controlSize(", ".bordered", "cancelTracking", "request"] {
            #expect(!button.contains(token), "'\(token)' — the button only forwards to model.lockScreen()")
        }
        #expect(Self.occurrences(of: "model.lockScreen()", in: try Self.allViewCode()) == 1)
    }

    /// Slice W (issue #78): `PanelIconButton` is the panel's shared icon-only
    /// button — a 28pt circular target, the 15pt medium glyph alone in the
    /// primary color (tertiary while disabled: the plain look has no bezel to
    /// grey out), the plain look with the shared press fade, and its name as
    /// tooltip and VoiceOver label. Slice P (issue #47): its label is the
    /// 36pt hit circle, and a negative padding of (36 − 28) / 2 hands the
    /// layout back the 28pt footprint — measured by synthetic clicks at 0.5pt
    /// steps: ≈36pt across and down for the lock and the gear, in the panel.
    /// Its two users: the Settings gear and the Lock Screen button.
    @Test func panelIconButtonIsTheSharedCircularIconButton() throws {
        let button = try #require(Self.structChunk("PanelIconButton", in: try Self.code("MenuPanelView.swift")))
        let shape: String = [
            "Button(action: action) { Image(systemName: symbol)",
            ".font(.system(size: PanelMetrics.iconButtonGlyph, weight: .medium))",
            ".foregroundStyle(isEnabled ? HierarchicalShapeStyle.primary : .tertiary)",
            ".frame(width: PanelMetrics.iconButtonHitArea, height: PanelMetrics.iconButtonHitArea)",
            ".contentShape(Circle()) } .buttonStyle(PanelPressFadeButtonStyle())",
            ".padding(-(PanelMetrics.iconButtonHitArea - PanelMetrics.iconButtonSize) / 2)",
            ".help(label) .accessibilityLabel(label)",
        ].joined(separator: " ")
        #expect(Self.flat(button).contains(shape), "the shared icon button was rewired")
        #expect(button.contains("@Environment(\\.isEnabled) private var isEnabled"))
        #expect(!button.contains("Text("), "icon-only — no visible title")
        #expect(PanelMetrics.iconButtonSize == 28 && PanelMetrics.iconButtonGlyph == 15)
        #expect(PanelMetrics.iconButtonHitArea == 36, "the 36pt hit area (C10, #47)")
        #expect(PanelMetrics.iconButtonBadge < PanelMetrics.iconButtonGlyph, "the badge stays smaller than the glyph")
        let views = try Self.allViewCode()
        #expect(Self.occurrences(of: "PanelIconButton(", in: views) == 2, "the gear and the lock are its users")
        #expect(Self.occurrences(of: "PanelIconButton(symbol: PanelSymbol.settings", in: views) == 1)
        #expect(Self.occurrences(of: "PanelIconButton(symbol: PanelSymbol.lockScreen", in: views) == 1)
    }

    /// Slice W, the iron rule extended to the gear: it renders the Settings
    /// badge — the worst Settings-resident severity, as a severity symbol in
    /// its tint, exactly once in the panel — and NEVER a line, so a problem
    /// still surfaces exactly once, through the surfaced twins above. It only
    /// forwards to the model (MenuContentView keeps the one dismissal
    /// gateway).
    @Test func theSettingsGearOnlyBadgesAndForwards() throws {
        let views = try Self.allViewCode()
        let gear = try #require(Self.structChunk("SettingsGearButton", in: try Self.code("MenuPanelView.swift")))
        #expect(gear.contains("PanelIconButton(symbol: PanelSymbol.settings, label: \"Settings\") { model.openSettings() }"))
        #expect(gear.contains("let badge = model.settingsBadge"))
        #expect(gear.contains(".overlay(alignment: .topTrailing) {"))
        #expect(gear.contains("if let symbol = MenuStateModel.severitySymbol(badge) {"))
        #expect(gear.contains(".foregroundStyle(PanelSeverityTint.color(badge))"))
        #expect(gear.contains(".accessibilityValue(MenuStateModel.severityAccessibilityPrefix(badge) ?? \"\")"),
                "the badge is spoken, never color alone")
        for token in ["PanelCaptionLine(", "SurfacedLine(", "TuckedLine(", "Text(", ".text", "cancelTracking",
                      "request", "setDetailsExpanded"] {
            #expect(!gear.contains(token), "'\(token)' — the gear only badges and forwards")
        }
        #expect(Self.occurrences(of: "model.settingsBadge", in: views) == 1, "the Settings badge renders once")
        #expect(Self.occurrences(of: "model.openSettings()", in: views) == 1, "one gear opens Settings")
        let model = try Self.code("MenuStateModel.swift")
        #expect(Self.flat(model).contains("func openSettings() { requestOpenSettings?() }"), "a pure forward")
        let owner = try Self.code("MenuContentView.swift")
        #expect(owner.contains("model.requestOpenSettings = { [weak self] in self?.showSettings(nil) }"),
                "the gear takes the ⌘, route — the one dismissal gateway")
    }

    /// Slice P (owner pick "c cards"): TWO cards and no dividers. The Power
    /// card — no group header: its first line, the "Battery N%" headline,
    /// names it (the "Power" label was judged redundant) — holds Stay Awake
    /// then Charge Limit; the Alerts card, under its "Alerts" header, holds
    /// Lid alert then Session alerts. No row sits outside a card.
    @Test func theCardsHoldStayAwakeChargeLimitThenLidAndSession() throws {
        let body = try Self.layoutBody()
        let cards = Self.cardBlocks(in: body)
        try #require(cards.count == 2, "the Power card and the Alerts card")
        #expect(Self.rowTitles(body[cards[0]]) == ["Stay Awake", "Charge Limit"], "got \(Self.rowTitles(body[cards[0]]))")
        #expect(Self.rowTitles(body[cards[1]]) == ["Lid alert", "Session alerts"], "got \(Self.rowTitles(body[cards[1]]))")
        #expect(Self.rowTitles(body) == ["Stay Awake", "Charge Limit", "Lid alert", "Session alerts"],
                "no row outside the cards")
        #expect(body[cards[0]].hasPrefix("PanelCard {"), "the Power card has no group header")
        #expect(body[cards[1]].hasPrefix("PanelGroup(title: \"Alerts\") {"), "the Alerts card has its header")
        #expect(Self.occurrences(of: "PanelGroup(", in: body) == 1 && Self.occurrences(of: "PanelCard {", in: body) == 1)
        #expect(!body.contains("Divider()"), "the cards are the grouping — no dividers")
    }

    /// Track C (C4): the "Session alerts" row sits in the Alerts card
    /// DIRECTLY under the Lid alert row — same PanelRow shape (symbol, title,
    /// toggle), its status as a non-nominal-only caption under it. Its
    /// surfaced History twin lives below the cards with the others. It is the
    /// ONLY place the session toggle is rendered.
    @Test func theSessionAlertsRowSitsDirectlyUnderTheLidRow() throws {
        let body = try Self.layoutBody()
        let alerts = try #require(Self.cardBlocks(in: body).last)
        let card = body[alerts]
        let lidRow = try #require(card.range(of: "PanelRow(symbol: PanelSymbol.lidAlert, title: \"Lid alert\")"))
        let sessionRow = try #require(
            card.range(of: "PanelRow(symbol: PanelSymbol.sessionAlerts, title: \"Session alerts\")"),
            "the Session alerts row is missing from the Alerts card")
        #expect(lidRow.upperBound < sessionRow.lowerBound, "Session alerts renders below Lid alert")
        // Nothing renders between the two rows except the lid row's caption.
        let between = card[lidRow.upperBound..<sessionRow.lowerBound]
        #expect(!between.contains("PanelRow(") && !between.contains("Surfaced"),
                "only the lid row's own caption sits between Lid alert and Session alerts")
        // The session feature: toggle, then its status caption.
        let tail = card[sessionRow.upperBound...]
        let toggle = try #require(tail.range(of: "SessionAlertsToggle(model: model)"))
        let caption = try #require(tail.range(of: "indentedCaption(model.finishAlertStatus)"))
        #expect(toggle.lowerBound < caption.lowerBound)
        #expect(!tail.contains("SessionAlertsSurfacedLines("), "the History twin lives below the cards")
        #expect(Self.occurrences(of: "SessionAlertsToggle(", in: try Self.allViewCode()) == 1,
                "the session toggle is rendered exactly once, in the layout")
        // The toggle forwards to the model (and MenuContentView), never to a
        // panel-local or dismissing path.
        let toggleView = try #require(Self.structChunk("SessionAlertsToggle", in: try Self.code("MenuPanelView.swift")))
        #expect(toggleView.contains("set: { model.setFinishAlertEnabled($0) }"))
        #expect(!toggleView.contains("cancelTracking"))
    }

    /// Issue #34 non-goal: the session alerts' run floor is never set in the
    /// panel — only in the "ntfy settings…" editor (MenuContentView) and,
    /// since slice W, in Settings › Alerts (SettingsWindowTests). No panel
    /// view renders or edits it. Since slice P the panel has no
    /// "ntfy settings…" button either: Settings › Alerts is the editor's
    /// button home (the alert toggles' priming flow still reaches it).
    @Test func theRunFloorNeverReachesThePanel() throws {
        let views = try Self.allViewCode()
        for token in ["finishAlertMinimumRunSeconds", "minimumRunSeconds", "sessionAlertsFloor",
                      "SessionAlertsFloorGroup"] {
            #expect(!views.contains(token), "'\(token)' in a panel view — the floor lives in the ntfy settings editor")
        }
        #expect(!views.contains("model.editLidGuardSettings()"), "the editor's button lives in Settings › Alerts")
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

    /// F3 (2026-10-18): the Pause detection kill switch stays out of casual
    /// reach. Since slice P it is not in the panel at all — Settings › Claude
    /// carries it, on the same model action (SettingsWindowTests). (The
    /// top-level "Claude: paused" footer caption is the mapping's job, tested
    /// in MenuPanelPresentationTests.)
    @Test func pauseDetectionLivesOnlyInSettings() throws {
        let views = try Self.allViewCode()
        for token in ["setDetectionPaused(", "Toggle(\"Pause detection\"", "pauseDetectionCaption"] {
            #expect(!views.contains(token), "'\(token)' in a panel view — Pause detection lives in Settings › Claude")
        }
        #expect(try Self.code("SettingsPanes.swift").contains("set: { model.setDetectionPaused($0) }"), "vacuity")
    }

    /// F3 stage 1: the "Phone alerts (beta)" checkbox lives in Settings ›
    /// Alerts only since slice P (its Details home is gone) — no panel view
    /// renders or flips it.
    @Test func thePhoneToggleLivesOnlyInSettings() throws {
        let views = try Self.allViewCode()
        for token in ["setPhoneTransportEnabled(", "phoneTransportToggleTitle", "phoneTransportToggleHint"] {
            #expect(!views.contains(token), "'\(token)' in a panel view — the phone toggle lives in Settings › Alerts")
        }
        #expect(try Self.code("SettingsPanes.swift").contains("set: { model.setPhoneTransportEnabled($0) }"), "vacuity")
        #expect(MenuStateModel.phoneTransportToggleTitle == "Phone alerts (beta)")
    }

    // MARK: - Motion, color, Dynamic Type, VoiceOver

    /// The values a panel animation may be keyed on, each one moved only by
    /// the user. Observed state (pmset, battery, the limiter's work, Claude,
    /// send outcomes) never animates: it snaps. Slice P closed the list down
    /// to the press: the Details chevron left with the disclosure, and the
    /// charge-limit readout's exemption (owner ruling f — "the limit is the
    /// slider's own value") left with the panel slider. The limit is set in
    /// Settings now, so in the panel it is observed state, and a roll would
    /// only ever play as the menu opened.
    static let userDrivenAnimationKeys: [String: String] = [
        "configuration.isPressed": "a button's press state",
    ]
    static let gatedMotionCap = 0.2

    /// Every animated line, one by one: the Reduce-Motion-nil ease-out
    /// pattern, at most `gatedMotionCap`, keyed on a value from
    /// `userDrivenAnimationKeys`, and each key animated in ONE place. No
    /// `withAnimation` anywhere.
    static func motionGateFailures(views: String) -> [String] {
        var failures: [String] = []
        if views.contains("withAnimation") {
            failures.append("'withAnimation' — observed-state snaps must never animate")
        }
        let animated = views.split(separator: "\n").filter { $0.contains(".animation(") }
        if animated.isEmpty { failures.append("vacuity: the press fade animates") }
        var keyed: [String: Int] = [:]
        for line in animated {
            guard line.contains(".animation(reduceMotion ? nil : .easeOut(duration: ") else {
                failures.append("not gated on Reduce Motion, or not an ease-out: \(line)")
                continue
            }
            let duration = line.components(separatedBy: "duration: ").dropFirst().first
                .flatMap { Double($0.prefix { "0123456789.".contains($0) }) }
            if (duration ?? 1) > Self.gatedMotionCap {
                failures.append("animation longer than 200ms: \(line)")
            }
            let key = line.components(separatedBy: ", value: ").dropFirst().last
                .map { String($0.trimmingCharacters(in: .whitespaces).dropLast()) } ?? ""
            guard Self.userDrivenAnimationKeys[key] != nil else {
                failures.append("keyed on '\(key)', which the user does not drive — observed state never animates: \(line)")
                continue
            }
            keyed[key, default: 0] += 1
        }
        for (key, count) in keyed where count > 1 {
            failures.append("'\(key)' animates in \(count) places — one animation per user-driven value")
        }
        return failures
    }

    /// Motion ≤200ms ease-out or none, always behind Reduce Motion, and never
    /// on an observed-state change. Owner ruling (f)'s PanelMotion shape still
    /// governs: any number of animations may pass, but each one has the gated
    /// ease-out shape and is keyed on a value the user drives
    /// (`userDrivenAnimationKeys` — since slice P, only the press).
    @Test func motionIsGatedAndShort() throws {
        let views = try Self.allViewCode()
        #expect(Self.motionGateFailures(views: views).isEmpty, "\(Self.motionGateFailures(views: views))")
        #expect(Self.userDrivenAnimationKeys.keys.sorted() == ["configuration.isPressed"],
                "the user-driven keys are a closed list")

        // Tested on a fixed panel (independent of which animations the
        // source ships): a press fade passes.
        let press = "\nlet press = Text(\"x\").animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)"
        #expect(Self.motionGateFailures(views: press).isEmpty, "a press fade is user-driven")

        let line = { (tail: String) in "\nlet canary = Text(\"x\")" + tail }
        let canaries: [(name: String, views: String)] = [
            ("withAnimation", views + line(".onTapGesture { withAnimation { } }")),
            ("an animation keyed on the observed pmset state",
             views + line(".animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.stayAwakeObserved)")),
            ("an animation keyed on the battery",
             views + line(".animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.batteryPercent)")),
            ("the retired readout roll, keyed on the limit set in Settings",
             views + line(".animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.limit)")),
            ("the retired chevron", views + line(".animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: expanded)")),
            ("an animation keyed on the limit toggle",
             views + line(".animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.limitEnabled)")),
            ("an animation not gated on Reduce Motion",
             views + line(".animation(.easeOut(duration: 0.1), value: configuration.isPressed)")),
            ("a linear animation",
             views + line(".animation(reduceMotion ? nil : .linear(duration: 0.1), value: configuration.isPressed)")),
            ("a 250 ms animation",
             views + line(".animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: configuration.isPressed)")),
            ("a second animation on the same key",
             views + line(".animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)")),
            ("an animation with no value key", views + line(".animation(reduceMotion ? nil : .easeOut(duration: 0.1))")),
        ]
        for canary in canaries {
            #expect(!Self.motionGateFailures(views: canary.views).isEmpty, "canary '\(canary.name)' was NOT caught")
        }
    }

    /// #67: the panel's motion, codified in `PanelMotion`. Every animated line
    /// is the Reduce-Motion-nil ease-out pattern and spells one of
    /// `PanelMotion`'s animation durations, within `PanelMotion.maxDuration`.
    /// The press fade lives in one style, which the icon buttons and Quit
    /// use; the Charge Limit value SNAPS (slice P: no roll without the panel
    /// slider). Zero motion on open / close: no view animates its insertion
    /// or removal (`.transition(`), nothing animates through a transaction or
    /// imperatively, and the hosting view's re-fit snaps to the new size.
    static func motionFailures(views: String, owner: String) -> [String] {
        var failures: [String] = []
        let durations = [PanelMotion.pressFade]
        let animated = views.split(separator: "\n").filter { $0.contains(".animation(") }
        if animated.isEmpty { failures.append("vacuity: the press fade animates") }
        for line in animated {
            guard line.contains(".animation(reduceMotion ? nil : .easeOut(duration: ") else {
                failures.append("not the Reduce-Motion-nil ease-out pattern: \(line)")
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
        let pressStyle = Self.structChunk("PanelPressFadeButtonStyle", in: views) ?? ""
        if !pressStyle.contains(".opacity(configuration.isPressed ? PanelMotion.pressedOpacity : 1)")
            || !pressStyle.contains(
                ".animation(reduceMotion ? nil : .easeOut(duration: \(PanelMotion.pressFade)), value: configuration.isPressed)") {
            failures.append("the press fade must dim to PanelMotion.pressedOpacity over PanelMotion.pressFade")
        }
        let iconButton = Self.structChunk("PanelIconButton", in: views) ?? ""
        let footer = Self.structChunk("PanelFooterRow", in: views) ?? ""
        if !iconButton.contains(".buttonStyle(PanelPressFadeButtonStyle())")
            || !footer.contains(".buttonStyle(PanelPressFadeButtonStyle())") {
            failures.append("the icon buttons and Quit must use the press-fade style")
        }
        let value = Self.structChunk("ChargeLimitValue", in: views) ?? ""
        if value.isEmpty || !value.contains(".monospacedDigit()") || value.contains(".contentTransition(")
            || value.contains(".animation(") {
            failures.append("the Charge Limit value must be monospaced and snap")
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
        #expect(PanelMotion.pressFade <= PanelMotion.maxDuration && PanelMotion.pressFade <= Self.gatedMotionCap)
        #expect(PanelMotion.pressedOpacity == 0.7)
        let canaries: [(name: String, views: String, owner: String)] = [
            ("an insertion transition", views + "\nlet canary = Text(\"x\").transition(.opacity)", owner),
            ("the press fade off its PanelMotion duration",
             views.replacingOccurrences(of: "duration: 0.1), value: configuration.isPressed",
                                        with: "duration: 0.12), value: configuration.isPressed"), owner),
            ("the icon buttons and Quit back on the plain style",
             views.replacingOccurrences(of: ".buttonStyle(PanelPressFadeButtonStyle())", with: ".buttonStyle(.plain)"), owner),
            ("the Charge Limit value rolling again",
             views.replacingOccurrences(of: "Text(MenuStateModel.chargeLimitValueText(limit: model.limit))",
                                        with: "Text(MenuStateModel.chargeLimitValueText(limit: model.limit))"
                                            + ".contentTransition(.numericText(value: Double(model.limit)))"), owner),
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

    /// #67: the test send acknowledges through ONE wrapper,
    /// `SendFeedbackButton` — since slice P rendered only by Settings ›
    /// Alerts (SettingsWindowTests), never by the panel. The wrapper keeps its
    /// promises: every phase's label is laid out (the current one shown, the
    /// rest hidden), so the widest reserves the width; the phase moves only
    /// through the pure mapping; the existing outcome pipeline ends
    /// "Sending…"; the "Sent" hold is `PanelMotion.sentRevert`; nothing
    /// animates; and the only action is `model.sendLidGuardTestMessage()`.
    @Test func theTestSendAcknowledgesThroughOneWrapper() throws {
        let source = try Self.code("MenuPanelView.swift")
        let views = try Self.allViewCode()
        #expect(Self.occurrences(of: "SendFeedbackButton(", in: views) == 0, "the panel renders no test-send button")
        #expect(!views.contains("Button(\"Send test message\")"), "no bare test-send button")
        #expect(Self.occurrences(of: "model.sendLidGuardTestMessage()", in: views) == 1, "only the wrapper's own action")
        #expect(Self.occurrences(of: "SendFeedbackButton(", in: try Self.code("SettingsPanes.swift")) == 1,
                "Settings › Alerts renders the one test-send button")

        let button = try #require(Self.structChunk("SendFeedbackButton", in: source))
        for token in [
            "ForEach(TestSendPhase.allCases, id: \\.self)",
            "if candidate == phase {",
            "label.hidden()",
            "phase = MenuStateModel.testSendPhase(phase, on: .tapped)\n            model.sendLidGuardTestMessage()",
            "var controlSize: ControlSize = .small",
            ".controlSize(controlSize)",
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
        for token in [".animation(", "fixedSize", "cancelTracking", "request"] {
            #expect(!button.contains(token), "'\(token)' in the test-send wrapper")
        }
    }

    /// Slice P: the Charge Limit row shows the limit as a monospaced VALUE
    /// before its switch — `ChargeLimitValue`, rendered once — and no slider:
    /// the limit is set in Settings › General (whose own slider forwards to
    /// the same model action, SettingsWindowTests).
    @Test func theChargeLimitRowShowsTheValueAndNoSlider() throws {
        let views = try Self.allViewCode()
        let body = try Self.layoutBody()
        #expect(Self.occurrences(of: "ChargeLimitValue(", in: views) == 1, "ONE value")
        #expect(Self.flat(body).contains("PanelRow(symbol: PanelSymbol.chargeLimit, title: \"Charge Limit\") {"
                                         + " ChargeLimitValue(model: model) ChargeLimitToggle(model: model) }"),
                "the value sits in the Charge Limit row, before its switch")
        #expect(Self.occurrences(of: "MenuStateModel.chargeLimitValueText(", in: views) == 1,
                "the value text renders only through ChargeLimitValue")
        let value = try #require(Self.structChunk("ChargeLimitValue", in: try Self.code("MenuPanelView.swift")))
        for token in ["Text(MenuStateModel.chargeLimitValueText(limit: model.limit))", ".monospacedDigit()",
                      ".foregroundStyle(.secondary)"] {
            #expect(value.contains(token), "'\(token)' — the value's look")
        }
        for token in ["model.setLimit(", "MenuStateModel.limitLabel(", "in: 50...100"] {
            #expect(!views.contains(token), "'\(token)' — the charge-limit slider lives in Settings, not the panel")
        }
    }

    /// Owner ruling (e): the Stay Awake row's caption slot is
    /// `StayAwakeCaptionSlot`, in the Stay Awake feature at the title indent,
    /// where the unreadable warning has always rendered. It is the ONLY view
    /// that observes the turn-on feedback; the switch never sees it, so a flip
    /// cannot re-render the switch.
    @Test func theStayAwakeSlotOwnsTheTurnOnCaption() throws {
        let views = try Self.allViewCode()
        let body = try Self.layoutBody()
        #expect(Self.flat(body).contains("StayAwakeToggle(model: model) }"
                                         + " StayAwakeCaptionSlot(model: model, turnOn: model.stayAwakeTurnOn)"
                                         + " .padding(.leading, PanelMetrics.titleIndent) }"),
                "the slot hangs directly under the Stay Awake row, inside its feature")
        #expect(Self.occurrences(of: "StayAwakeCaptionSlot(", in: views) == 1, "ONE slot")
        #expect(Self.occurrences(of: "model.stayAwakeTurnOn", in: views) == 1, "the feedback reaches only the slot")
        #expect(Self.occurrences(of: "StayAwakeTurnOnFeedback", in: views) == 1, "one observer of the feedback")
        #expect(!views.contains("stayAwakeCaption("), "the slot mapping replaced the bare caption")

        let source = try Self.code("MenuPanelView.swift")
        let slot = try #require(Self.structChunk("StayAwakeCaptionSlot", in: source))
        #expect(slot.contains("@ObservedObject var turnOn: StayAwakeTurnOnFeedback"))
        #expect(slot.contains("MenuStateModel.stayAwakeSlot(observed: model.stayAwakeObserved, turnOn: turnOn.phase)"),
                "the slot composes the pure precedence mapping; it never classifies")
        #expect(slot.contains("PanelCaptionLine(line: line)"), "the panel's own caption line, nominal style included")
        let toggle = try #require(Self.structChunk("StayAwakeToggle", in: source))
        #expect(!toggle.contains("turnOn") && !toggle.contains("TurnOn"), "the switch never observes the feedback")
        #expect(toggle.contains("get: { MenuStateModel.stayAwakeToggle(forObserved: model.stayAwakeObserved).isOn }"),
                "the switch still renders the OBSERVED state")
    }

    /// Owner ruling (e): the DISABLE path is unchanged. Turning OFF never
    /// touches the turn-on feedback: the model's only new statement is gated
    /// on `desired`, and MenuContentView's three stay-awake functions — the
    /// one route to the privileged command — never mention it (the disable
    /// branch keeps its exact text). The owner wires only the reset on menu
    /// open, and the model's refresh feeds the observed state in as the
    /// confirm.
    @Test func theDisablePathNeverTouchesTheTurnOnFeedback() throws {
        let model = try Self.code("MenuStateModel.swift")
        #expect(Self.flat(model).contains("func setStayAwake(_ desired: Bool) {"
                                          + " if desired { stayAwakeTurnOn.flippedOn() }"
                                          + " requestStayAwakeToggle?(desired) }"),
                "flipping OFF only forwards, as before")
        #expect(Self.occurrences(of: "stayAwakeTurnOn.flippedOn()", in: model) == 1)
        #expect(Self.flat(model).contains("stayAwakeObserved = sleep.observedSleepDisabled"
                                          + " stayAwakeTurnOn.observed(stayAwakeObserved)"),
                "refresh feeds the observed state in, right after mirroring it")

        let owner = try Self.code("MenuContentView.swift")
        #expect(owner.contains("if sleep.refreshObservedState() == true {\n"
                               + "            applyStayAwake(false)\n"
                               + "        } else if"),
                "the disable branch keeps its exact text")
        for function in ["toggleStayAwake", "applyStayAwake", "handleStayAwakeOutcome"] {
            let start = try #require(owner.range(of: "func \(function)("), "\(function) not found")
            let tail = owner[start.upperBound...]
            let end = tail.range(of: "\n    private func ")?.lowerBound ?? tail.endIndex
            let chunk = tail[..<end]
            #expect(!chunk.contains("stayAwakeTurnOn") && !chunk.contains("flippedOn"),
                    "'\(function)' reaches the turn-on feedback — the command path must stay as it was")
        }
        #expect(Self.occurrences(of: "stayAwakeTurnOn", in: owner) == 1, "only the menu-open reset")
        let open = try #require(owner.range(of: "func menuWillOpen("))
        let reset = try #require(owner.range(of: "model.stayAwakeTurnOn.panelOpened()"))
        let refreshCall = try #require(owner[reset.upperBound...].range(of: "model.refresh()"))
        #expect(open.upperBound < reset.lowerBound && reset.upperBound <= refreshCall.lowerBound,
                "menu open resets the feedback before it refreshes")
    }

    /// System materials and semantic colors only — the ONE exception being
    /// the card's measured boost layer, a black or white opacity inside
    /// `PanelCard` (`theCardIsThePanelsOneContainer`).
    @Test func systemColorsOnly() throws {
        let views = try Self.allViewCode()
        for token in ["Color(red", "Color(hue", "Color(white", "Color(\"", "Color(#", "hex", "#colorLiteral",
                      "NSColor(", "UIColor", ".rgb"] {
            #expect(!views.contains(token), "'\(token)' — use system materials / semantic colors only")
        }
        let card = try #require(Self.structChunk("PanelCard", in: try Self.code("MenuPanelView.swift")))
        for absolute in ["Color.black", "Color.white", ".black", ".white", ".gray"] {
            #expect(Self.occurrences(of: absolute, in: views) == Self.occurrences(of: absolute, in: card),
                    "'\(absolute)' outside the card's boost layer")
        }
        #expect(Self.occurrences(of: "Color.black", in: card) == 1 && Self.occurrences(of: "Color.white", in: card) == 1)
    }

    /// Canon C8 (slice P): exactly four text roles in the panel. `.headline`
    /// is the battery headline alone; `.body` (the default) the row titles;
    /// `.caption` every status; `.caption2` at most once. No `.callout` (the
    /// Charge Limit value moved to `.caption`) and no other text style. Glyph
    /// sizes are not roles: the four `.system(size:)` glyphs (row symbols,
    /// the icon buttons' glyph, the gear badge, the ring interior) and the
    /// desktop symbol's `.largeTitle`.
    @Test func thePanelUsesFourTypeRoles() throws {
        let views = try Self.allViewCode()
        let styles = views.components(separatedBy: ".font(.").dropFirst()
            .map { String($0.prefix { $0.isLetter || $0.isNumber }) }
        let roles = Set(styles).subtracting(["system", "largeTitle"])
        #expect(roles.isSubset(of: ["headline", "body", "caption", "caption2"]), "text styles in use: \(roles.sorted())")
        #expect(roles.contains("headline") && roles.contains("caption"), "vacuity")
        #expect(Self.occurrences(of: ".font(.headline)", in: views) == 1, "the headline role is the battery's alone")
        let (header, _, _) = try Self.batteryHeaderParts()
        #expect(header.contains("MenuStateModel.batteryHeadline(hasBattery: model.hasBattery, percent: model.batteryPercent))\n"
                                + "                    .font(.headline)"))
        #expect(Self.occurrences(of: ".caption2", in: views) <= 1, "caption2 at most once")
        #expect(!views.contains("callout"), "no .callout")
        #expect(Self.occurrences(of: ".font(.system(size:", in: views) == 4, "glyph sizes only")
        #expect(Self.occurrences(of: ".font(.largeTitle)", in: views) == 1, "the desktop symbol only")
        let value = try #require(Self.structChunk("ChargeLimitValue", in: try Self.code("MenuPanelView.swift")))
        #expect(value.contains(".font(.caption)"), "the Charge Limit value is a caption")
        let row = try #require(Self.structChunk("PanelRow", in: try Self.code("MenuPanelView.swift")))
        #expect(Self.flat(row).contains("Text(title) .layoutPriority(1)"), "row titles keep the default body role")
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

    /// The footer's Claude status is ONE VoiceOver element whose label is
    /// the status itself, with the severity spoken first when it is not
    /// nominal ("Warning: Claude: paused") — never color alone.
    @Test func theFooterStatusSpeaksTheClaudeStatus() throws {
        let status = try #require(Self.structChunk("PanelFooterStatus", in: try Self.code("MenuPanelView.swift")))
        #expect(status.contains(".accessibilityElement(children: .ignore)"), "one element, not its parts")
        #expect(status.contains(".accessibilityLabel(PanelSeverityTint.spoken(label))"))
        #expect(PanelSeverityTint.spoken(MenuStateModel.claudeFooterLabel(inFlight: false, paused: true))
                == "Warning: Claude: paused")
        #expect(PanelSeverityTint.spoken(MenuStateModel.claudeFooterLabel(inFlight: true, paused: false))
                == "Claude: running")
    }
}
