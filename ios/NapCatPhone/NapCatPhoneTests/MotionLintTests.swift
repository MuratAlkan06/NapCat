import Foundation
@testable import NapCatPhone
import SwiftUI
import Testing

/// Motion on the receiver (#118): a row that arrives while the list is on
/// screen moves on the theme's entrance tokens, alone (nothing animates the
/// list as a whole), nothing moves under Reduce Motion, and every animation
/// and transition in the app passes through a Reduce Motion gate. SwiftUI
/// cannot be driven headlessly, so the gate is checked as values and the
/// wiring as source, each lock also run against mutants.
@Suite struct MotionLintTests {
    typealias Source = CloudKitStructureTests.Source

    static let dir = CloudKitStructureTests.appDir
    static let screenFile = "\(dir)/Screen/ReceiverScreen.swift"
    static let captionFile = "\(dir)/Screen/CaptionLine.swift"
    static let motionFile = "\(dir)/Screen/StaggeredEntrance.swift"

    // MARK: The gate, as values

    @Test(arguments: PaletteID.allCases)
    func liveInsertionsUseTheEntranceTokens(_ palette: PaletteID) {
        let theme = ThemeID.fallback.theme(palette: palette)
        #expect(ListMotion.animation(theme, reduceMotion: false) == theme.entrance)
        #expect(ListMotion.rise(theme, reduceMotion: false) == theme.entranceOffset)
    }

    @Test(arguments: PaletteID.allCases)
    func reduceMotionMakesLiveInsertionsInert(_ palette: PaletteID) {
        let theme = ThemeID.fallback.theme(palette: palette)
        #expect(ListMotion.animation(theme, reduceMotion: true) == nil)
        #expect(ListMotion.rise(theme, reduceMotion: true) == nil)
    }

    /// Each row draws over every row below it, so a row rising into its
    /// place passes over its lower neighbor, never under it.
    @Test func eachRowStacksAboveTheRowsBelowIt() {
        for index in 0..<AlertFeed.listLimit {
            #expect(ListMotion.stacking(index: index) > ListMotion.stacking(index: index + 1))
        }
    }

    // MARK: The lint: every animation and transition is gated, and none
    // animates the list as a whole

    /// A call's argument text: from `open` (just after its "(") to the
    /// matching ")".
    static func arguments(from open: String.Index, in code: String) -> String {
        var depth = 1
        var index = open
        while index < code.endIndex {
            switch code[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return String(code[open..<index]) }
            default: break
            }
            index = code.index(after: index)
        }
        return String(code[open...])
    }

    /// Whether an `.animation(_:value:)` is keyed on the rows or on the
    /// state derived from them. Such an animation runs for EVERY change the
    /// list's update makes (rows already listed sliding, their text
    /// cross-fading, the card's layers fading apart), not just the arriving
    /// row's; that row animates through its own transition instead.
    static func keyedOnTheList(_ args: String) -> Bool {
        guard let value = args.range(of: "value:") else { return false }
        return args[value.upperBound...].range(of: #"\b(alerts|list)\b"#, options: .regularExpression) != nil
    }

    static func motionFailures(_ sources: [Source]) -> [String] {
        var failures: [String] = []
        for (path, text) in sources {
            let code = CloudKitStructureTests.codeOnly(text)
            if code.contains("withAnimation") { failures.append("\(path) uses withAnimation") }
            for call in [".animation(", ".transition("] {
                var start = code.startIndex
                while let range = code.range(of: call, range: start..<code.endIndex) {
                    let args = arguments(from: range.upperBound, in: code)
                    if !args.contains("reduceMotion") {
                        failures.append("\(path): \(call)\(args)) is not gated on Reduce Motion")
                    }
                    if call == ".animation(" && keyedOnTheList(args) {
                        failures.append("\(path): \(call)\(args)) animates the whole list")
                    }
                    start = range.upperBound
                }
            }
        }
        return failures
    }

    @Test func everyAnimationAndTransitionIsGatedOnReduceMotion() throws {
        let app = try CloudKitStructureTests.swiftFiles(under: Self.dir)
        let failures = Self.motionFailures(app)
        #expect(failures.isEmpty, "\(failures)")
        // Not vacuous: the scan sees the one animated site, the entrance
        // and the arriving row's transition. The screen animates nothing
        // itself.
        let sites = app.filter { CloudKitStructureTests.codeOnly($0.text).contains(".animation(") }.map(\.path)
        #expect(sites == [Self.motionFile])
    }

    @Test func theMotionLintCatchesEachBreach() throws {
        let app = try CloudKitStructureTests.swiftFiles(under: Self.dir)
        let breaches = [
            ".animation(.default, value: alerts)",
            ".animation(theme.entrance, value: alerts)",
            ".transition(.slide)",
            ".transition(.opacity.combined(with: .offset(y: 8)))",
            "withAnimation { flag = true }",
            // Gated, but keyed on the whole list.
            ".animation(ListMotion.animation(theme, reduceMotion: reduceMotion), value: alerts)",
            ".animation(ListMotion.animation(theme, reduceMotion: reduceMotion), value: alerts.map(\\.id))",
            ".animation(reduceMotion ? nil : theme.entrance, value: list)",
        ]
        for breach in breaches {
            let mutated = app.map { ($0.path, $0.text + "\n\(breach)\n") }
            #expect(!Self.motionFailures(mutated).isEmpty, "missed: \(breach)")
        }
        // A comment may name them, and a gated animation keyed on its own
        // value passes.
        #expect(Self.motionFailures(app.map { ($0.path, $0.text + "\n// withAnimation, .animation(.default)\n") }).isEmpty)
        #expect(Self.motionFailures(app.map {
            ($0.path, $0.text + "\n.animation(reduceMotion ? nil : theme.entrance, value: revealed)\n")
        }).isEmpty)
    }

    /// The review's tearing (#128): the screen's whole stack animated on
    /// `alerts`, so every change an insertion made moved. Putting that
    /// modifier back where it was fails the lint.
    @Test func reWideningTheAnimationToTheListFails() throws {
        let app = try CloudKitStructureTests.swiftFiles(under: Self.dir)
        let anchor = "            .padding(.horizontal, theme.margin)\n"
        let widened = app.map { source -> Source in
            guard source.path == Self.screenFile else { return source }
            return (source.path, source.text.replacingOccurrences(
                of: anchor,
                with: "            .animation(ListMotion.animation(theme, reduceMotion: reduceMotion), value: alerts)\n" + anchor))
        }
        #expect(widened.map(\.text) != app.map(\.text), "the mutation did not apply")
        #expect(Self.motionFailures(app).isEmpty)
        #expect(!Self.motionFailures(widened).isEmpty)
    }

    // MARK: The screen's wiring

    /// Each row: one flattened card (a fade never shows the shadow through
    /// the fill), over the rows below it, inserted through the gated
    /// transition.
    static let wiring = [
        "@Environment(\\.accessibilityReduceMotion) private var reduceMotion",
        "AlertRow(alert: alert) .themedCard() .compositingGroup() .staggeredEntrance(index: index, revealed: revealed) "
            + ".zIndex(ListMotion.stacking(index: index)) .transition(ListMotion.transition(theme, reduceMotion: reduceMotion))",
        "if let cap = Self.capLine(rowCount: alerts.count) { CaptionLine(line: cap) }",
    ]
    /// The transition: identity under Reduce Motion; otherwise it carries
    /// the gated curve itself, and fades and lowers the row while drawing.
    static let transitionWiring = [
        "guard let rise = rise(theme, reduceMotion: reduceMotion) else { return .identity }",
        "AnyTransition(ArrivingRow(rise: rise).animation(animation(theme, reduceMotion: reduceMotion)))",
        ".opacity(phase.isIdentity ? 1 : 0) .visualEffect { effect, _ in effect.offset(y: lowered) }",
    ]
    static let spoken = ".accessibilityElement(children: .ignore) .accessibilityLabel(line.spoken)"

    static func wiringFailures(screen: String, caption: String, motion: String) -> [String] {
        let code = SettingsReachabilityTests.flat(screen)
        var failures = wiring.filter { !code.contains($0) }.map { "missing: \($0)" }
        let motionCode = SettingsReachabilityTests.flat(motion)
        failures += transitionWiring.filter { !motionCode.contains($0) }.map { "missing: \($0)" }
        if !SettingsReachabilityTests.flat(caption).contains(spoken) { failures.append("the caption is not one spoken line") }
        return failures
    }

    /// Rows insert through the gated transition as flattened cards stacked
    /// over their lower neighbors, the arriving row carries its own curve,
    /// and the cap line is a caption: one VoiceOver element that reads the
    /// line.
    @Test func theListAnimatesInsertionsAndSaysItsCap() throws {
        let app = try CloudKitStructureTests.swiftFiles(under: Self.dir)
        let screen = try #require(app.first { $0.path == Self.screenFile }).text
        let caption = try #require(app.first { $0.path == Self.captionFile }).text
        let motion = try #require(app.first { $0.path == Self.motionFile }).text
        #expect(Self.wiringFailures(screen: screen, caption: caption, motion: motion).isEmpty,
                "\(Self.wiringFailures(screen: screen, caption: caption, motion: motion))")
        let mutants = [
            (screen.replacingOccurrences(of: "                                .compositingGroup()\n", with: ""), caption, motion),
            (screen.replacingOccurrences(of: "                                .zIndex(ListMotion.stacking(index: index))\n",
                                         with: ""), caption, motion),
            (screen.replacingOccurrences(of: "CaptionLine(line: cap)", with: "Text(cap.text)"), caption, motion),
            (screen, caption.replacingOccurrences(of: ".accessibilityLabel(line.spoken)", with: ""), motion),
            (screen, caption, motion.replacingOccurrences(
                of: "ArrivingRow(rise: rise).animation(animation(theme, reduceMotion: reduceMotion))",
                with: "ArrivingRow(rise: rise)")),
            (screen, caption, motion.replacingOccurrences(
                of: ".visualEffect { effect, _ in effect.offset(y: lowered) }", with: ".offset(y: lowered)")),
        ]
        for (mutantScreen, mutantCaption, mutantMotion) in mutants {
            #expect(mutantScreen != screen || mutantCaption != caption || mutantMotion != motion,
                    "a mutation did not apply")
            #expect(!Self.wiringFailures(screen: mutantScreen, caption: mutantCaption, motion: mutantMotion).isEmpty)
        }
    }
}
