import Foundation
@testable import NapCatPhone
import Testing
import UIKit

/// How Settings is reached (#92): a gear in the main screen's toolbar opens
/// it as a sheet, drawn in the chosen palette. SwiftUI composition cannot be
/// driven headlessly, so the composition is locked over the source, and the
/// lock is run against mutated copies so it can fail.
@Suite struct SettingsReachabilityTests {
    static let rootFile = "\(CloudKitStructureTests.appDir)/NapCatPhoneApp.swift"

    /// Comments removed and whitespace collapsed: the code's shape only.
    static func flat(_ text: String) -> String {
        CloudKitStructureTests.codeOnly(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func rootCode() throws -> String {
        let app = try CloudKitStructureTests.swiftFiles(under: CloudKitStructureTests.appDir)
        return try #require(app.first { $0.path == rootFile }).text
    }

    static let stack = "NavigationStack { ReceiverScreen(alerts: feed.alerts, connection: feed.connection, fetch: feed.fetch)"
    static let gear = ".toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsGearButton { showsSettings = true } } }"
    /// AMENDED (S-PAIR-C1.6, #172): Settings is handed the live inbox's
    /// pairing, for its Pair with Mac row. AMENDED (#194): and the root's
    /// remote-approvals switch, bound, for its row.
    static let sheet = ".sheet(isPresented: $showsSettings) { "
        + "SettingsScreen(palette: $palette, notifications: feed.notificationPermission, pairing: inbox.pairing, "
        + "approvals: $approvals) }"
    static let palette = ".environment(\\.theme, ThemeID.fallback.theme(palette: palette))"

    /// The main screen sits in a navigation stack whose toolbar's trailing
    /// item is the gear; the gear raises the sheet flag; the sheet holds
    /// Settings with the stored palette and the feed's permission; and the
    /// palette is applied outside the sheet, so Settings is drawn in it.
    static func compositionFailures(_ text: String) -> [String] {
        let code = flat(text)
        var failures: [String] = []
        for (name, shape) in [("stack", stack), ("gear", gear), ("sheet", sheet), ("palette", palette)]
        where !code.contains(shape) {
            failures.append("missing \(name): \(shape)")
        }
        if let toolbar = code.range(of: gear), let stackRange = code.range(of: stack),
           toolbar.lowerBound < stackRange.upperBound {
            failures.append("the gear must be on the main screen inside the stack")
        }
        if let sheetRange = code.range(of: sheet), let paletteRange = code.range(of: palette),
           paletteRange.lowerBound < sheetRange.upperBound {
            failures.append("the palette must be applied outside the sheet")
        }
        return failures
    }

    @Test func theGearOpensSettingsAsASheetInThePalette() throws {
        let failures = Self.compositionFailures(try Self.rootCode())
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func theCompositionLockCatchesEachBreach() throws {
        let code = try Self.rootCode()
        let mutants = [
            code.replacingOccurrences(of: "ToolbarItem(placement: .topBarTrailing)", with: "ToolbarItem(placement: .bottomBar)"),
            code.replacingOccurrences(of: "SettingsGearButton { showsSettings = true }", with: "SettingsGearButton { }"),
            code.replacingOccurrences(of: ".sheet(isPresented:", with: ".fullScreenCover(isPresented:"),
            code.replacingOccurrences(of: "notifications: feed.notificationPermission", with: "notifications: .on"),
            code.replacingOccurrences(of: "pairing: inbox.pairing", with: "pairing: nil"),
            code.replacingOccurrences(of: "approvals: $approvals)", with: "approvals: .constant(true))"),
            code.replacingOccurrences(of: "NavigationStack {", with: "Group {"),
        ]
        for mutant in mutants {
            #expect(mutant != code, "a mutation did not apply")
            #expect(!Self.compositionFailures(mutant).isEmpty)
        }
        // The palette applied inside the sheet only: Settings would still be
        // themed, the main screen would not.
        let moved = code
            .replacingOccurrences(of: "        .environment(\\.theme, ThemeID.fallback.theme(palette: palette))\n", with: "")
            .replacingOccurrences(of: "approvals: $approvals)\n",
                                  with: "approvals: $approvals)\n.environment(\\.theme, ThemeID.fallback.theme(palette: palette))\n")
        #expect(moved != code)
        #expect(!Self.compositionFailures(moved).isEmpty)
        // The palette applied before (inside) the sheet modifier.
        let early = code
            .replacingOccurrences(of: "        .environment(\\.theme, ThemeID.fallback.theme(palette: palette))\n", with: "")
            .replacingOccurrences(of: "        .sheet(isPresented:",
                                  with: "        .environment(\\.theme, ThemeID.fallback.theme(palette: palette))\n        .sheet(isPresented:")
        #expect(early != code)
        #expect(Self.compositionFailures(early) == ["the palette must be applied outside the sheet"])
    }

    /// Settings has one way in: only the root builds it (besides its own
    /// previews), and only the gear (or the screenshot launch argument)
    /// raises the flag.
    @Test func theRootIsTheOnlyWayIn() throws {
        let app = try CloudKitStructureTests.swiftFiles(under: CloudKitStructureTests.appDir)
        let builders = app.filter { Self.flat($0.text).contains("SettingsScreen(palette:") }.map(\.path)
        #expect(builders == [Self.rootFile, "\(CloudKitStructureTests.appDir)/Settings/SettingsScreen.swift"])
        let root = Self.flat(try Self.rootCode())
        #expect(CloudKitStructureTests.occurrences(of: "showsSettings = true", in: root) == 1)
        #expect(root.contains("init(feed: AlertFeed, inbox: RequestInbox, pairing: FixturePairing? = nil, opensSettings: Bool = false)"))
        #expect(root.contains("private let opensSettings = LaunchOptions.fromLaunchArguments().screen == .settings"))
    }

    /// The Mac panel's settings glyph, in the theme's icon family; VoiceOver
    /// reads the screen's name.
    @Test func theGearIsTheMacPanelsGlyph() {
        #expect(SettingsGearButton.symbol == "gearshape")
        #expect(UIImage(systemName: SettingsGearButton.symbol) != nil)
        #expect(UIImage(systemName: "\(SettingsGearButton.symbol).fill") != nil)
        #expect(SettingsScreen.title == "Settings")
    }

    // MARK: The screenshot launch argument

    @Test func aLaunchOpensOnTheMainScreenByDefault() {
        #expect(LaunchOptions().screen == .receiver)
        #expect(LaunchOptions { _ in nil }.screen == .receiver)
        #expect(LaunchOptions { $0 == "NapCatScreen" ? "drawer" : nil } == LaunchOptions())
    }

    /// `-NapCatScreen settings` opens Settings and changes nothing else; in
    /// particular it never forces fixtures on a device build.
    @Test func theScreenArgumentOpensSettingsAndNothingElse() {
        let options = LaunchOptions { $0 == "NapCatScreen" ? "settings" : nil }
        #expect(options.screen == .settings)
        #expect(options.fixtureRequested == false)
        #expect(AlertSourceKind.select(options: options, liveCapable: true) == .cloudKit)
        var expected = LaunchOptions()
        expected.screen = .settings
        #expect(options == expected)
    }
}
