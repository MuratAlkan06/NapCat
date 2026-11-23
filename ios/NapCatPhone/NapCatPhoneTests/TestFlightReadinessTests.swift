import Foundation
import Testing

/// What App Store Connect reads from an upload (#96). The Info.plist checks
/// read the built app hosting these tests, so they see the generated file
/// itself, not only the spec that generates it.
@Suite struct TestFlightReadinessTests {
    static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    /// Export compliance: the app's only encryption is the system's HTTPS
    /// and CloudKit transport, which is exempt. With the key set to NO,
    /// App Store Connect does not ask the export questions on every upload.
    @Test func theAppDeclaresOnlyExemptEncryption() {
        #expect(Self.info["ITSAppUsesNonExemptEncryption"] as? Bool == false)
    }

    /// Face ID refuses an app that does not say why it asks (F4, CL-3:
    /// Allow on a forwarded prompt asks for a match). The generated
    /// Info.plist carries the reason, in plain words.
    @Test func theAppSaysWhyItAsksForFaceID() throws {
        let reason = try #require(Self.info["NSFaceIDUsageDescription"] as? String)
        #expect(reason == "NapCat asks for Face ID before it sends Allow to your Mac.")
    }

    /// The marketing version is three dot-separated integers. The build
    /// number is one integer of at least 1, raised by 1 for every upload.
    @Test func theVersionNumbersHaveTheUploadFormat() throws {
        func isDigits(_ text: Substring) -> Bool {
            !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
        }
        let marketing = try #require(Self.info["CFBundleShortVersionString"] as? String)
        let parts = marketing.split(separator: ".", omittingEmptySubsequences: false)
        #expect(parts.count == 3 && parts.allSatisfy(isDigits))
        let build = try #require(Self.info["CFBundleVersion"] as? String)
        #expect(isDigits(Substring(build)) && (Int(build) ?? 0) >= 1)
    }

    /// The asset catalog compiler looks the icon set up by this name. The
    /// spec pins it rather than relying on xcodegen's application default.
    @Test func theAppIconSetNameIsPinnedInTheSpec() throws {
        let spec = try String(contentsOf: EntitlementsTests.projectDir.appendingPathComponent("project.yml"),
                              encoding: .utf8)
        #expect(spec.contains("\n        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon\n"))
    }
}
