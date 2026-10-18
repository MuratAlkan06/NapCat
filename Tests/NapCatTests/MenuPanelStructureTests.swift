// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Lint-style locks for the 2026-10-18 menu-panel redesign (SwiftUI layout
/// cannot be driven headlessly, so the pure mappings are unit-tested in
/// MenuPanelPresentationTests and their USE is locked here):
/// the topic never reaches a view, every variant gives problem lines a
/// top-level home, the ONE disclosure shares the last row with Quit
/// (curation round 1), A and C share the hero-size gauge (curation round 2),
/// Details only ever tucks NOMINAL lines, Pause detection
/// lives in Details (F3), motion is gated on Reduce Motion, and colors are
/// system/semantic only.
struct MenuPanelStructureTests {
    /// Every SwiftUI view file of the panel. A new view file must be added
    /// here AND to the LidGuard / ClaudeDetection scanned-file sets.
    static let viewFiles = ["MenuPanelView.swift", "MenuPanelVariants.swift"]
    /// Curation round 1 (2026-10-18) scrapped B "Grouped Cards".
    static let variants = ["QuietRowsPanel", "StatusHeroPanel"]

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

    /// Every variant must render the three surfaced-line components (the
    /// top-level home of every Details line that can be a problem) plus the
    /// Details content and the ONE footer row that carries the disclosure and
    /// the always-visible Quit.
    @Test func everyVariantGivesProblemLinesATopLevelHome() throws {
        let source = try Self.code("MenuPanelVariants.swift")
        for variant in Self.variants {
            let body = try #require(Self.structChunk(variant, in: source), "\(variant) not found — keep this lock updated")
            for component in ["ClaudeSurfacedLines(", "LidAlertSurfacedLines(", "SurfacedLaunchAtLogin(",
                              "PanelDetailsContent(", "PanelFooterRow("] {
                #expect(body.contains(component), "\(variant) is missing \(component)")
            }
            #expect(Self.occurrences(of: "PanelFooterRow(", in: body) == 1, "\(variant): ONE footer row")
            #expect(Self.occurrences(of: "PanelDetailsContent(", in: body) == 1, "\(variant): ONE Details content")
        }
        // No variant renders a disclosure of its own — the footer row is the
        // only home, so every variant has exactly ONE disclosure.
        #expect(!source.contains("PanelDetailsDisclosure("), "a variant renders a second disclosure")
    }

    /// Curation round 1 (2026-10-18): Details sits on the LEFT of the panel's
    /// last row with Quit on the RIGHT. The footer holds the ONLY disclosure
    /// and the ONLY Quit button in the panel, and in every variant it is the
    /// LAST thing — expanded Details content (and a surfaced Launch at Login)
    /// render above it, so Quit can never be pushed out of view.
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

        let source = try Self.code("MenuPanelVariants.swift")
        for variant in Self.variants {
            let body = try #require(Self.structChunk(variant, in: source))
            let footerCall = try #require(body.range(of: "PanelFooterRow(model: model)"), "\(variant) has no footer row")
            for above in ["PanelDetailsContent(", "SurfacedLaunchAtLogin("] {
                let position = try #require(body.range(of: above), "\(variant) is missing \(above)")
                #expect(position.lowerBound < footerCall.lowerBound, "\(variant): \(above) must render ABOVE the footer")
            }
            // Nothing follows the footer inside the main column: only the
            // closing brace before the column's own modifiers.
            let tail = body[footerCall.upperBound...]
            let beforeModifiers = tail.range(of: ".padding(").map { tail[..<$0.lowerBound] } ?? tail
            #expect(beforeModifiers.trimmingCharacters(in: .whitespacesAndNewlines) == "}",
                    "\(variant): the footer row must be the panel's last row")
        }
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

    /// Curation round 2 (2026-10-18): A and C render the SAME hero-size gauge
    /// so the comparison is fair. Ring geometry (`size`) and what the header
    /// says (`content`) are independent knobs: A keeps its "Battery N%"
    /// headline + charging line, C keeps the composed activity line, and the
    /// content choice never changes the ring's geometry.
    @Test func bothVariantsShareTheHeroGaugeAndKeepTheirOwnHeaderText() throws {
        let source = try Self.code("MenuPanelVariants.swift")
        let quiet = try #require(Self.structChunk("QuietRowsPanel", in: source))
        let hero = try #require(Self.structChunk("StatusHeroPanel", in: source))
        for (variant, body) in [("QuietRowsPanel", quiet), ("StatusHeroPanel", hero)] {
            #expect(Self.occurrences(of: "BatteryHeader(", in: body) == 1, "\(variant): ONE battery header")
            #expect(body.contains("BatteryHeader(model: model, size: .hero"), "\(variant): hero-size gauge")
        }
        #expect(quiet.contains("BatteryHeader(model: model, size: .hero)"), "A keeps its headline text")
        #expect(hero.contains("BatteryHeader(model: model, size: .hero, content: .activity)"),
                "C keeps its activity line")

        let (textColumn, ring, _) = try Self.batteryHeaderParts()
        #expect(textColumn.contains("switch content"), "the text column follows `content`")
        #expect(!textColumn.contains("switch size"), "the text column must not follow the gauge size")
        #expect(Self.occurrences(of: "model.heroActivity", in: textColumn) == 1)
        for token in ["switch content", "content ==", "content !=", ".activity", ".headline"] {
            #expect(!ring.contains(token), "the ring geometry must depend on `size` only — found '\(token)'")
        }
    }

    /// Curation round 2 fix (2026-10-18 — "you removed the battery icon"):
    /// the ring's INTERIOR follows `content`, never `size`. A (`.headline`)
    /// gets the pre-round-2 charge-state glyph, C (`.activity`) the percent,
    /// so each variant states the percent exactly once: A in its headline, C
    /// in its ring. Both sizes take the interior from the one helper, so the
    /// ring itself never chooses it (and A/C ring parity stays with `size`).
    @Test func theRingInteriorFollowsContentGlyphForAPercentForC() throws {
        let (textColumn, ring, interior) = try Self.batteryHeaderParts()

        // Every ring's label is the shared interior — no size picks its own.
        let gauges = Self.occurrences(of: "Gauge(value:", in: ring)
        #expect(gauges == 2, "one ring per size (compact, hero)")
        #expect(Self.occurrences(of: "currentValueLabel: {\n                    ringInterior\n                }", in: ring)
                == gauges, "every ring's currentValueLabel must be exactly `ringInterior`")
        for token in ["Text(percent)", "Image(systemName: model.isCharging"] {
            #expect(!ring.contains(token), "the ring draws its own interior ('\(token)') — use `ringInterior`")
        }

        // The interior switches on `content` only.
        #expect(interior.contains("switch content"), "the ring interior follows `content`")
        for token in ["switch size", "size ==", "size !=", ".hero", ".compact"] {
            #expect(!interior.contains(token), "the ring interior must not follow `size` — found '\(token)'")
        }
        let headlineCase = try #require(interior.range(of: "case .headline:"))
        let activityCase = try #require(interior.range(of: "case .activity:"))
        #expect(headlineCase.lowerBound < activityCase.lowerBound)
        let glyphArm = interior[headlineCase.upperBound..<activityCase.lowerBound]
        let percentArm = interior[activityCase.upperBound...]
        #expect(glyphArm.contains("Image(systemName: model.isCharging ? PanelSymbol.charging : PanelSymbol.battery)"),
                "A's ring holds the charge-state glyph")
        #expect(!glyphArm.contains("percent"), "A's ring must not repeat the percent its headline states")
        #expect(percentArm.contains("Text(percent).monospacedDigit()"), "C's ring states the percent")
        #expect(!percentArm.contains("Image("), "C's ring holds the percent only")

        // Text column: the percent is in A's headline and nowhere in C's text.
        let textHeadline = try #require(textColumn.range(of: "case .headline:"))
        let textActivity = try #require(textColumn.range(of: "case .activity:"))
        #expect(textColumn[textHeadline.upperBound..<textActivity.lowerBound].contains("MenuStateModel.batteryHeadline("))
        let activityText = textColumn[textActivity.upperBound...]
        let activityTextEnd = activityText.range(of: "Spacer(").map { activityText[..<$0.lowerBound] } ?? activityText
        #expect(!activityTextEnd.contains("batteryHeadline") && !activityTextEnd.contains("percent"),
                "C's text column must not state the percent — its ring does")
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
        let pairs: [(accessor: String, twinHome: String)] = [
            ("model.hookStatus", claudeTwins),
            ("model.lidTopicStatus", lidTwins),
            ("model.lidServerStatus", lidTwins),
            ("model.lidLastSend(", lidTwins),
        ]
        for (accessor, twinHome) in pairs {
            let uses = Self.occurrences(of: accessor, in: details)
            #expect(uses == 1, "\(accessor) should appear once in Details, found \(uses)")
            #expect(details.contains("TuckedLine(line: \(accessor)"), "\(accessor) is rendered raw inside Details")
            #expect(twinHome.contains("SurfacedLine(line: \(accessor)"), "\(accessor) has no top-level twin")
        }
        // Variant C's nominal Claude row: tucked here, surfaced by the variant.
        #expect(Self.occurrences(of: "model.claudeStatus", in: details) == 1)
        #expect(details.contains("TuckedLine(line: model.claudeStatus)"))
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
        // The variant layouts never reach for it directly.
        #expect(!(try Self.code("MenuPanelVariants.swift")).contains("setDetectionPaused"))
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

    @Test func disclosureAndStylePickerAreLabelledForVoiceOver() throws {
        let source = try Self.code("MenuPanelView.swift")
        let disclosure = try #require(Self.structChunk("PanelDetailsDisclosure", in: source))
        #expect(disclosure.contains(".accessibilityLabel(\"Details\")"))
        #expect(disclosure.contains(".accessibilityValue(expanded ? \"Expanded\" : \"Collapsed\")"))
        #expect(disclosure.contains(".accessibilityHint("))
        let picker = try #require(Self.structChunk("PanelStylePreviewRow", in: source))
        #expect(picker.contains(".accessibilityLabel(\"Panel style (preview)\")"))
        #expect(picker.contains(".accessibilityValue("))
    }

    // MARK: - Menu-stays-open

    /// The disclosure and the style preview are pure model state: they never
    /// call a request hook and never route through MenuContentView, so they
    /// cannot reach the one dismissal gateway.
    @Test func panelOnlyActionsNeverReachTheDismissalGateway() throws {
        let model = try Self.code("MenuStateModel.swift")
        for function in ["setDetailsExpanded", "cyclePanelStyle"] {
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
        #expect(!owner.contains("cyclePanelStyle"))
    }
}
