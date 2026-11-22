import Foundation
import NapCatWire
import Testing

/// The files xcodegen writes from project.yml, read from the checkout. The
/// entitlements cannot import NapCatWire, so this pins them to it: exactly
/// the wire's container, CloudKit and pushes, and the CloudKit environment
/// taken from the one build setting that project.yml defaults to Production.
@Suite struct EntitlementsTests {
    static let projectDir = CloudKitStructureTests.repoRoot.appendingPathComponent("ios/NapCatPhone")

    static func plist(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: projectDir.appendingPathComponent(name))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func theEntitlementsGrantTheWireContainer() throws {
        let entitlements = try Self.plist("NapCatPhone.entitlements")
        #expect(entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
            == [AlertWire.containerIdentifier])
        #expect(entitlements["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"])
        #expect(entitlements["aps-environment"] as? String == "development")
        #expect(Set(entitlements.keys) == [
            "aps-environment",
            "com.apple.developer.icloud-services",
            "com.apple.developer.icloud-container-identifiers",
            "com.apple.developer.icloud-container-environment",
        ])
    }

    /// One dial, explicit: the entitlement reads the build setting, and the
    /// project's default for it is Production (where the Mac writes).
    @Test func theCloudKitEnvironmentIsOneExplicitBuildSetting() throws {
        let entitlements = try Self.plist("NapCatPhone.entitlements")
        #expect(entitlements["com.apple.developer.icloud-container-environment"] as? String
            == "$(NAPCAT_CLOUDKIT_ENVIRONMENT)")
        let spec = try String(contentsOf: Self.projectDir.appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(spec.contains("\n        NAPCAT_CLOUDKIT_ENVIRONMENT: Production\n"))
    }

    /// No background modes (the frozen F3 ADR): the subscription's pushes
    /// are alerts the system renders, never silent wakes. Read from the
    /// built app hosting these tests, so any route that adds one fails.
    @Test func theAppDeclaresNoBackgroundModes() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(Bundle.main.bundleIdentifier == "com.muratalkan.napcat.phone")
        #expect(info["UIBackgroundModes"] == nil)
        let spec = try String(contentsOf: Self.projectDir.appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(!spec.contains("UIBackgroundModes"))
    }
}
