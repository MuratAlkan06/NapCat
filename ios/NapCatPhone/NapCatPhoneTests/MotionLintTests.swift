import Foundation
@testable import NapCatPhone
import SwiftUI
import Testing

/// Motion on the receiver (#118): rows that arrive while the list is on
/// screen move on the theme's entrance tokens and nothing else, nothing
/// moves under Reduce Motion, and every animation and transition in the app
/// passes through a Reduce Motion gate. SwiftUI cannot be driven headlessly,
/// so the gate is checked as values and the wiring as source, each lock
/// also run against mutants.
@Suite struct MotionLintTests {
    typealias Source = CloudKitStructureTests.Source

    static let dir = CloudKitStructureTests.appDir
    static let screenFile = "\(dir)/Screen/ReceiverScreen.swift"
    static let captionFile = "\(dir)/Screen/CaptionLine.swift"

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

    // MARK: The lint: every animation and transition is gated

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
        // Not vacuous: the scan sees both animated sites.
        let sites = app.filter { CloudKitStructureTests.codeOnly($0.text).contains(".animation(") }.map(\.path)
        #expect(sites == [Self.screenFile, "\(Self.dir)/Screen/StaggeredEntrance.swift"])
    }

    @Test func theMotionLintCatchesEachBreach() throws {
        let app = try CloudKitStructureTests.swiftFiles(under: Self.dir)
        let breaches = [
            ".animation(.default, value: alerts)",
            ".animation(theme.entrance, value: alerts)",
            ".transition(.slide)",
            ".transition(.opacity.combined(with: .offset(y: 8)))",
            "withAnimation { flag = true }",
        ]
        for breach in breaches {
            let mutated = app.map { ($0.path, $0.text + "\n\(breach)\n") }
            #expect(!Self.motionFailures(mutated).isEmpty, "missed: \(breach)")
        }
        // A comment may name them.
        #expect(Self.motionFailures(app.map { ($0.path, $0.text + "\n// withAnimation, .animation(.default)\n") }).isEmpty)
    }

    // MARK: The screen's wiring

    static let wiring = [
        "@Environment(\\.accessibilityReduceMotion) private var reduceMotion",
        ".transition(ListMotion.transition(theme, reduceMotion: reduceMotion))",
        ".animation(ListMotion.animation(theme, reduceMotion: reduceMotion), value: alerts)",
        "if let cap = Self.capLine(rowCount: alerts.count) { CaptionLine(line: cap) }",
    ]
    static let spoken = ".accessibilityElement(children: .ignore) .accessibilityLabel(line.spoken)"

    static func wiringFailures(screen: String, caption: String) -> [String] {
        let code = SettingsReachabilityTests.flat(screen)
        var failures = wiring.filter { !code.contains($0) }.map { "missing: \($0)" }
        if !SettingsReachabilityTests.flat(caption).contains(spoken) { failures.append("the caption is not one spoken line") }
        return failures
    }

    /// Rows insert through the gated transition, the list animates its rows
    /// through the gated curve, and the cap line is a caption: one
    /// VoiceOver element that reads the line.
    @Test func theListAnimatesInsertionsAndSaysItsCap() throws {
        let app = try CloudKitStructureTests.swiftFiles(under: Self.dir)
        let screen = try #require(app.first { $0.path == Self.screenFile }).text
        let caption = try #require(app.first { $0.path == Self.captionFile }).text
        #expect(Self.wiringFailures(screen: screen, caption: caption).isEmpty,
                "\(Self.wiringFailures(screen: screen, caption: caption))")
        let mutants = [
            (screen.replacingOccurrences(
                of: "            .animation(ListMotion.animation(theme, reduceMotion: reduceMotion), value: alerts)\n",
                with: ""), caption),
            (screen.replacingOccurrences(of: "CaptionLine(line: cap)", with: "Text(cap.text)"), caption),
            (screen, caption.replacingOccurrences(of: ".accessibilityLabel(line.spoken)", with: "")),
        ]
        for (mutantScreen, mutantCaption) in mutants {
            #expect(mutantScreen != screen || mutantCaption != caption, "a mutation did not apply")
            #expect(!Self.wiringFailures(screen: mutantScreen, caption: mutantCaption).isEmpty)
        }
    }
}
