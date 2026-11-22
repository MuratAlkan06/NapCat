import Foundation
import Testing

/// The app's privacy manifest (#96), NapCatPhone/PrivacyInfo.xcprivacy.
///
/// It declares no tracking and no collected data, and exactly the
/// required-reason API categories the shipped code touches. "Shipped code"
/// is the app's own sources plus NapCatWire, which is linked into the app.
/// Each category is found by scanning that code for the API names Apple
/// lists for it. The scan errs towards finding too much: a match means
/// "look at this", and the fix is either a declaration with the right
/// reason or a narrower token.
@Suite struct PrivacyManifestTests {
    static let manifestPath = "ios/NapCatPhone/NapCatPhone/PrivacyInfo.xcprivacy"
    static let shippedSourceDirs = ["ios/NapCatPhone/NapCatPhone", "Sources/NapCatWire"]

    static let userDefaults = "NSPrivacyAccessedAPICategoryUserDefaults"

    /// Apple's required-reason API categories, each with the regular
    /// expression that finds its APIs in Swift code ("Describing use of
    /// required reason API"). The C calls must be followed by "(", so a
    /// variable named `stat` does not count.
    static let categoryPatterns: [String: String] = [
        "NSPrivacyAccessedAPICategoryFileTimestamp":
            #"\b(creationDate|modificationDate|fileModificationDate|contentModificationDateKey|creationDateKey|getattrlist|getattrlistbulk|fgetattrlist|getattrlistat)\b|\b(stat|fstat|fstatat|lstat)\s*\("#,
        "NSPrivacyAccessedAPICategorySystemBootTime":
            #"\b(systemUptime|mach_absolute_time)\b"#,
        "NSPrivacyAccessedAPICategoryDiskSpace":
            #"\b(volumeAvailableCapacityKey|volumeAvailableCapacityForImportantUsageKey|volumeAvailableCapacityForOpportunisticUsageKey|volumeTotalCapacityKey|systemFreeSize|systemSize|getattrlist|fgetattrlist|getattrlistat)\b|\b(statfs|statvfs|fstatfs|fstatvfs)\s*\("#,
        "NSPrivacyAccessedAPICategoryActiveKeyboards":
            #"\bactiveInputModes\b"#,
        // @AppStorage reads and writes UserDefaults too.
        userDefaults:
            #"\b(UserDefaults|NSUserDefaults|AppStorage)\b"#,
    ]

    /// The categories `sources` touch. Comments are ignored, so a doc
    /// comment may name an API.
    static func touchedCategories(in sources: [CloudKitStructureTests.Source]) throws -> Set<String> {
        var touched: Set<String> = []
        for (category, pattern) in categoryPatterns {
            let regex = try NSRegularExpression(pattern: pattern)
            for source in sources {
                let code = CloudKitStructureTests.codeOnly(source.text)
                if regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                    touched.insert(category)
                    break
                }
            }
        }
        return touched
    }

    static func manifest(_ data: Data) throws -> [String: Any] {
        try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    static func checkoutManifest() throws -> [String: Any] {
        try manifest(Data(contentsOf: CloudKitStructureTests.repoRoot.appendingPathComponent(manifestPath)))
    }

    /// Category to reasons, as declared.
    static func declaredReasons(_ manifest: [String: Any]) throws -> [String: [String]] {
        let entries = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: [String]] = [:]
        for entry in entries {
            #expect(Set(entry.keys) == ["NSPrivacyAccessedAPIType", "NSPrivacyAccessedAPITypeReasons"])
            let category = try #require(entry["NSPrivacyAccessedAPIType"] as? String)
            #expect(reasons[category] == nil, "\(category) is declared twice")
            reasons[category] = try #require(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
        }
        return reasons
    }

    @Test func theManifestDeclaresNoTrackingAndNoCollectedData() throws {
        let manifest = try Self.checkoutManifest()
        #expect(Set(manifest.keys) == [
            "NSPrivacyAccessedAPITypes",
            "NSPrivacyCollectedDataTypes",
            "NSPrivacyTracking",
            "NSPrivacyTrackingDomains",
        ])
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
        #expect((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
    }

    /// Exactly the touched categories are declared. UserDefaults is read
    /// for the app's own launch arguments only (LaunchOptions), which is
    /// reason CA92.1.
    @Test func theManifestDeclaresExactlyTheTouchedCategories() throws {
        var sources: [CloudKitStructureTests.Source] = []
        for directory in Self.shippedSourceDirs {
            sources += try CloudKitStructureTests.swiftFiles(under: directory)
        }
        #expect(sources.contains { $0.path.hasSuffix("/LaunchOptions.swift") })
        #expect(sources.contains { $0.path == CloudKitStructureTests.wireFile })
        let touched = try Self.touchedCategories(in: sources)
        let declared = try Self.declaredReasons(Self.checkoutManifest())
        #expect(Set(declared.keys) == touched)
        #expect(touched == [Self.userDefaults])
        #expect(declared[Self.userDefaults] == ["CA92.1"])
    }

    /// The scan itself can fail: each category is found in a one-line
    /// source, and comments and look-alike names are not.
    @Test func theScanFindsEachCategoryAndIgnoresComments() throws {
        func scan(_ text: String) throws -> Set<String> {
            try Self.touchedCategories(in: [("Mutant.swift", text)])
        }
        #expect(try scan("let t = ProcessInfo.processInfo.systemUptime")
            == ["NSPrivacyAccessedAPICategorySystemBootTime"])
        #expect(try scan("let d = attributes[.modificationDate]") == ["NSPrivacyAccessedAPICategoryFileTimestamp"])
        #expect(try scan("var s = stat(); _ = lstat (path, &s)") == ["NSPrivacyAccessedAPICategoryFileTimestamp"])
        #expect(try scan("let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey]")
            == ["NSPrivacyAccessedAPICategoryDiskSpace"])
        #expect(try scan("_ = statvfs(path, &info)") == ["NSPrivacyAccessedAPICategoryDiskSpace"])
        #expect(try scan("_ = UITextInputMode.activeInputModes") == ["NSPrivacyAccessedAPICategoryActiveKeyboards"])
        #expect(try scan(#"@AppStorage("k") var k = false"#) == [Self.userDefaults])
        #expect(try scan("let d = UserDefaults.standard") == [Self.userDefaults])
        #expect(try scan("// UserDefaults, systemUptime and stat( in a comment").isEmpty)
        #expect(try scan("let stat = 1; let systemUptimeLabel = \"\"; let userDefaultsKey = 2").isEmpty)
    }

    /// The build copies the committed manifest into the app bundle, where
    /// App Store Connect reads it.
    @Test func theAppBundleCarriesTheManifest() throws {
        let bundled = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        #expect(bundled.deletingLastPathComponent().standardizedFileURL
            == Bundle.main.bundleURL.standardizedFileURL)
        let checkout = CloudKitStructureTests.repoRoot.appendingPathComponent(Self.manifestPath)
        #expect(try Data(contentsOf: bundled) == Data(contentsOf: checkout))
    }
}
