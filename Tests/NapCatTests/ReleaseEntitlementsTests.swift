// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat
import NapCatWire

/// Lints the COMMITTED Resources/NapCat.entitlements (located from this
/// file's path). `make` applies it only when signing with a real identity
/// (`ENTITLEMENTS=Resources/NapCat.entitlements`, the release workflow's
/// Developer ID build); ad-hoc builds never carry it, because AMFI kills an
/// ad-hoc binary that claims restricted entitlements. The plist must grant
/// exactly what the runtime probe looks for, under this bundle's own App ID,
/// in the one CloudKit environment a Developer ID profile provisions — the
/// key set the F3 spike proved with a Developer ID profile (2026-11-20).
struct ReleaseEntitlementsTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)  // Tests/NapCatTests/<this file>
            .deletingLastPathComponent() // NapCatTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    private static func plist(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(relativePath))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private static func entitlements() throws -> [String: Any] {
        try plist("Resources/NapCat.entitlements")
    }

    /// A bundle signed with this plist lights up the CloudKit transport: the
    /// pure decision behind `CloudKitEntitlementProbe.isEntitled` accepts the
    /// committed values of the two keys it reads.
    @Test func theCommittedEntitlementsSatisfyTheRuntimeProbe() throws {
        let entitlements = try Self.entitlements()
        #expect(CloudKitEntitlementProbe.grants(
            services: entitlements[CloudKitEntitlementProbe.servicesEntitlement],
            containers: entitlements[CloudKitEntitlementProbe.containersEntitlement]
        ), "Resources/NapCat.entitlements must grant the CloudKit service and \(AlertWire.containerIdentifier)")
    }

    /// The application identifier is TEAM.<CFBundleIdentifier> — the App ID
    /// the Developer ID profile is issued for. A bundle id change must move
    /// both files together, or the release run's profile check fails.
    @Test func theApplicationIdentifierIsThisBundlesOwn() throws {
        let entitlements = try Self.entitlements()
        let bundleID = try #require(try Self.plist("Resources/Info.plist")["CFBundleIdentifier"] as? String)
        let team = try #require(entitlements["com.apple.developer.team-identifier"] as? String)
        #expect(team.count == 10 && team.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) },
                "the team identifier is a 10-character Apple team ID")
        #expect(entitlements["com.apple.application-identifier"] as? String == "\(team).\(bundleID)")
    }

    /// Exactly the spike-proven keys and values: nothing else is claimed (an
    /// extra restricted key the profile does not grant makes AMFI refuse to
    /// launch the signed app), and the environment is Production — the only
    /// one a Developer ID profile provisions.
    @Test func exactlyTheSpikeProvenKeysAndValues() throws {
        let entitlements = try Self.entitlements()
        #expect(Set(entitlements.keys) == [
            "com.apple.application-identifier",
            "com.apple.developer.team-identifier",
            "com.apple.developer.icloud-services",
            "com.apple.developer.icloud-container-identifiers",
            "com.apple.developer.icloud-container-environment",
        ])
        #expect(entitlements["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"])
        #expect(entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
                == [AlertWire.containerIdentifier])
        #expect(entitlements["com.apple.developer.icloud-container-environment"] as? String == "Production")
    }
}
