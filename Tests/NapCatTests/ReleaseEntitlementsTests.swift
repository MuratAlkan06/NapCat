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

    /// A plain `make` stays unentitled: both variables default to empty, the
    /// ad-hoc command is still exactly `codesign --force -s -`, and inside the
    /// ad-hoc branch either variable stops make with an error. With a real
    /// identity the profile is embedded BEFORE the bundle is signed (codesign
    /// seals it), and codesign gets --entitlements only when one is given.
    @Test func aPlainMakeStaysUnentitledAndAdHocRefusesEntitlements() throws {
        let makefile = try String(contentsOf: Self.repoRoot.appendingPathComponent("Makefile"), encoding: .utf8)
        let lines = makefile.components(separatedBy: "\n")
        func index(_ line: String) -> Int? { lines.firstIndex(of: line) }

        let order = [
            "ENTITLEMENTS ?=",
            "PROVISIONING_PROFILE ?=",
            "ifeq ($(strip $(SIGN_IDENTITY)),-)",
            "CODESIGN := codesign --force -s -",
            "ifneq ($(strip $(ENTITLEMENTS)$(PROVISIONING_PROFILE)),)",
        ].map(index)
        #expect(!order.contains(nil), "Makefile lines missing: \(order)")
        let found = order.compactMap { $0 }
        #expect(found == found.sorted() && Set(found).count == found.count,
                "the defaults, then the ad-hoc branch, then its guard — in that order")
        if let guardLine = found.last {
            #expect(lines[guardLine + 1].hasPrefix("$(error ENTITLEMENTS and PROVISIONING_PROFILE need a real SIGN_IDENTITY"))
            #expect(lines[guardLine + 2] == "endif" && lines[guardLine + 3] == "else",
                    "the guard must sit inside the ad-hoc branch only")
        }

        let embed = "\t$(if $(strip $(PROVISIONING_PROFILE)),install -m 0644 \"$(strip $(PROVISIONING_PROFILE))\" "
            + "$(APP)/Contents/embedded.provisionprofile)"
        let sign = "\t$(CODESIGN)$(if $(strip $(ENTITLEMENTS)), --entitlements \"$(strip $(ENTITLEMENTS))\") $(APP)"
        let embedAt = try #require(index(embed), "the profile is embedded as Contents/embedded.provisionprofile")
        let signAt = try #require(index(sign), "codesign gets --entitlements only when ENTITLEMENTS is set")
        #expect(signAt == embedAt + 1, "embed the profile immediately before signing")
        let assignments = lines.filter { $0.hasPrefix("ENTITLEMENTS") || $0.hasPrefix("PROVISIONING_PROFILE") }
        #expect(assignments == ["ENTITLEMENTS ?=", "PROVISIONING_PROFILE ?="],
                "both variables are assigned once, empty — a plain `make` never entitles")
    }
}
