import Foundation
@testable import NapCatPhone
import Testing
import UIKit

/// Settings (#92): its fixed copy, About's version and link, and structural
/// locks over its source. Each lock is also run against a mutated copy, so a
/// lock that could never fail fails here instead.
@Suite struct SettingsScreenTests {
    typealias Source = CloudKitStructureTests.Source

    static let settingsDir = "\(CloudKitStructureTests.appDir)/Settings"

    static func settingsSources() throws -> [Source] {
        try CloudKitStructureTests.swiftFiles(under: settingsDir)
    }

    @Test func theScanSeesTheSettingsCode() throws {
        let paths = try Self.settingsSources().map(\.path)
        #expect(paths == ["\(Self.settingsDir)/AppVersion.swift", "\(Self.settingsDir)/SettingsScreen.swift"])
    }

    @Test func theScreenSaysExactlyThis() {
        #expect(SettingsScreen.title == "Settings")
        #expect(SettingsScreen.done == "Done")
        #expect([SettingsScreen.appearanceHeader, SettingsScreen.notificationsHeader, SettingsScreen.aboutHeader]
            == ["Appearance", "Notifications", "About"])
        #expect(SettingsScreen.paletteLabel == "Palette")
        #expect(SettingsScreen.statusLabel == "Status")
        #expect(SettingsScreen.versionLabel == "Version")
        #expect(SettingsScreen.siteLabel == "Website")
        #expect(UIImage(systemName: LinkOutLabel.symbol) != nil)
    }

    // MARK: About

    @Test func theSiteLinkIsTheProjectSite() throws {
        let site = try #require(SettingsScreen.siteURL)
        #expect(site.absoluteString == "https://muratalkan06.github.io/NapCat/")
        #expect(site.scheme == "https")
    }

    /// About shows the build that is running: the host app's own Info.plist.
    @Test func aboutReadsTheVersionAndBuildFromTheBundle() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let marketing = try #require(info["CFBundleShortVersionString"] as? String)
        let build = try #require(info["CFBundleVersion"] as? String)
        let version = AppVersion(bundle: .main)
        #expect(version == AppVersion(info: info))
        #expect(version.text == "\(marketing) (\(build))")
        #expect(version.spoken == "\(marketing), build \(build)")
        #expect(version.marketing != AppVersion.unknown && version.build != AppVersion.unknown)
    }

    @Test func versionTextFormatsAndFallsBack() {
        let version = AppVersion(info: ["CFBundleShortVersionString": "2.3.4", "CFBundleVersion": "17"])
        #expect(version.text == "2.3.4 (17)")
        #expect(version.spoken == "2.3.4, build 17")
        #expect(AppVersion(info: [:]).text == "unknown (unknown)")
        #expect(AppVersion(info: ["CFBundleVersion": 3]).build == "unknown")
    }

    // MARK: Lock 1: no iCloud, no network

    /// Each pattern is a way to reach iCloud or the network, or to reach
    /// the feed (which does). Settings works only on what it is handed.
    static let offLimits: [String] = [
        #"\bimport\s+(CloudKit|Network)\b"#,
        #"\bCK[A-Z]\w*"#,
        #"\bNW[A-Z]\w*"#,
        #"\bURLSession\b"#,
        #"\bURLRequest\b"#,
        #"\b(Data|String)\(contentsOf:"#,
        #"\bAlertFeed\b"#,
        #"\bAlertSource\b"#,
        #"\bNotificationGate\b"#,
        #"\b(refresh|receivePush|fetch\w*)\("#,
    ]

    static func networkFailures(_ sources: [Source]) -> [String] {
        violations(of: offLimits, in: sources)
    }

    static func violations(of patterns: [String], in sources: [Source]) -> [String] {
        var failures: [String] = []
        for source in sources {
            let code = CloudKitStructureTests.codeOnly(source.text)
            for pattern in patterns where code.range(of: pattern, options: .regularExpression) != nil {
                failures.append("\(source.path) matches \(pattern)")
            }
        }
        return failures
    }

    @Test func settingsHasNoCloudKitOrNetworkCalls() throws {
        let failures = Self.networkFailures(try Self.settingsSources())
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func theNetworkLockCatchesEachBreach() throws {
        let clean = try Self.settingsSources()
        let breaches = [
            "import CloudKit",
            // (Never a container here: CloudKitStructureTests forbids tests to name one.)
            "let operation = CKQueryOperation(query: query)",
            "let monitor = NWPathMonitor()",
            "_ = URLSession.shared.dataTask(with: url)",
            "let request = URLRequest(url: url)",
            "let page = try Data(contentsOf: url)",
            "let feed: AlertFeed",
            "Task { await feed.refresh() }",
            "_ = try await source.fetchRecent()",
        ]
        for breach in breaches {
            let mutated = clean.map { ($0.path, $0.text + "\n\(breach)\n") }
            #expect(!Self.networkFailures(mutated).isEmpty, "missed: \(breach)")
        }
        // A comment may name them.
        #expect(Self.networkFailures(clean.map { ($0.path, $0.text + "\n// URLSession, CKRecord\n") }).isEmpty)
    }

    // MARK: Lock 2: theme tokens only

    /// A color, font or system style spelled in place instead of read from
    /// the theme.
    static let literalStyle: [String] = [
        #"\bColor\("#,
        #"\bColor\.\w"#,
        #"\bUIColor\b"#,
        #"\.font\(\."#,
        #"\bFont\.\w"#,
        #"\.(foregroundStyle|tint|background)\(\.[a-z]"#,
        #"\b(spacing|padding)\b[:(]\s*\d"#,
    ]

    @Test func settingsReadsEveryColorAndFontFromTheTheme() throws {
        let failures = Self.violations(of: Self.literalStyle, in: try Self.settingsSources())
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func theThemeLockCatchesEachBreach() throws {
        let clean = try Self.settingsSources()
        for breach in [".foregroundStyle(Color(red: 1, green: 0, blue: 0))", ".tint(Color.blue)",
                       ".font(.system(size: 13))", ".foregroundStyle(.secondary)", "HStack(spacing: 6) {}",
                       ".padding(12)", "let c = UIColor.red"] {
            let mutated = clean.map { ($0.path, $0.text + "\n\(breach)\n") }
            #expect(!Self.violations(of: Self.literalStyle, in: mutated).isEmpty, "missed: \(breach)")
        }
    }

    // MARK: Lock 3: the version is read, never spelled; the permission is shared

    static let versionLiteral = #""\d+\.\d+(\.\d+)?( \(\d+\))?""#

    @Test func aboutNeverSpellsAVersionAndUsesTheSharedPermission() throws {
        let sources = try Self.settingsSources()
        #expect(Self.violations(of: [Self.versionLiteral], in: sources).isEmpty)
        #expect(!Self.violations(of: [Self.versionLiteral], in: [("Mutant.swift", #"let v = "0.1.0 (1)""#)]).isEmpty)
        let screen = try #require(sources.first { $0.path.hasSuffix("/SettingsScreen.swift") })
        let code = CloudKitStructureTests.codeOnly(screen.text)
        #expect(code.contains("var version = AppVersion(bundle: .main)"))
        #expect(code.contains("NotificationSettingsButton(title: notifications.action)"))
        #expect(code.contains("Form {"))
        #expect(code.contains(".pickerStyle(.inline)"))
    }
}
