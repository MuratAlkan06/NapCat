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
/// top-level home, Details only ever tucks NOMINAL lines, Pause detection
/// lives in Details (F3), motion is gated on Reduce Motion, and colors are
/// system/semantic only.
struct MenuPanelStructureTests {
    /// Every SwiftUI view file of the panel. A new view file must be added
    /// here AND to the LidGuard / ClaudeDetection scanned-file sets.
    static let viewFiles = ["MenuPanelView.swift", "MenuPanelVariants.swift"]
    static let variants = ["QuietRowsPanel", "GroupedCardsPanel", "StatusHeroPanel"]

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
    /// one disclosure, its content, and the always-visible Quit footer.
    @Test func everyVariantGivesProblemLinesATopLevelHome() throws {
        let source = try Self.code("MenuPanelVariants.swift")
        for variant in Self.variants {
            let body = try #require(Self.structChunk(variant, in: source), "\(variant) not found — keep this lock updated")
            for component in ["ClaudeSurfacedLines(", "LidAlertSurfacedLines(", "SurfacedLaunchAtLogin(",
                              "PanelDetailsDisclosure(", "PanelDetailsContent(", "QuitFooter("] {
                #expect(body.contains(component), "\(variant) is missing \(component)")
            }
            #expect(Self.occurrences(of: "PanelDetailsDisclosure(", in: body) == 1, "\(variant): ONE disclosure")
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
