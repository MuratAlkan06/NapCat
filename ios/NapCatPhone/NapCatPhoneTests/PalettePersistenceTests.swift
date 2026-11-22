import Foundation
@testable import NapCatPhone
import SwiftUI
import Testing

/// The chosen palette survives a relaunch (#92): `ReceiverRoot` keeps it with
/// `@AppStorage` under `PaletteID.storageKey`. Each test uses a throwaway
/// defaults suite, never the app's own defaults.
@Suite @MainActor struct PalettePersistenceTests {
    static func withSuite(_ body: (UserDefaults) -> Void) {
        let name = "com.muratalkan.napcat.phone.tests.palette.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: name) else {
            Issue.record("no defaults suite")
            return
        }
        defer { suite.removePersistentDomain(forName: name) }
        body(suite)
    }

    /// The same declaration as `ReceiverRoot`'s, on `suite`.
    static func storage(_ suite: UserDefaults) -> AppStorage<PaletteID> {
        AppStorage(wrappedValue: PaletteID.fallback, PaletteID.storageKey, store: suite)
    }

    /// The stored strings are the contract with every earlier install.
    @Test func theStoredNamesNeverChange() {
        #expect(PaletteID.storageKey == "palette")
        #expect(PaletteID.allCases.map(\.rawValue) == ["nightGroom", "deepCream", "neutral"])
    }

    @Test func aFreshInstallReadsNightGroom() {
        Self.withSuite { suite in
            #expect(Self.storage(suite).wrappedValue == .nightGroom)
            #expect(suite.object(forKey: PaletteID.storageKey) == nil, "reading writes nothing")
        }
    }

    /// A choice written by one launch is read back by the next (a fresh
    /// `AppStorage` over the same defaults).
    @Test(arguments: PaletteID.allCases)
    func aChoicePersistsAcrossLaunches(_ choice: PaletteID) {
        Self.withSuite { suite in
            Self.storage(suite).wrappedValue = choice
            #expect(suite.string(forKey: PaletteID.storageKey) == choice.rawValue)
            #expect(Self.storage(suite).wrappedValue == choice)
        }
    }

    /// A value no palette has (a future build's, or damage) reads as the
    /// default and is left as it is.
    @Test func anUnknownStoredValueReadsAsTheDefault() {
        Self.withSuite { suite in
            suite.set("sepia", forKey: PaletteID.storageKey)
            #expect(Self.storage(suite).wrappedValue == .nightGroom)
            #expect(suite.string(forKey: PaletteID.storageKey) == "sepia")
        }
    }

    /// The root keeps the ONE stored choice and draws everything in it; no
    /// other view keeps its own copy.
    @Test func theRootKeepsTheOneStoredChoiceAndAppliesIt() throws {
        let app = try CloudKitStructureTests.swiftFiles(under: CloudKitStructureTests.appDir)
        let root = try #require(app.first { $0.path.hasSuffix("/NapCatPhoneApp.swift") })
        let code = CloudKitStructureTests.codeOnly(root.text)
        #expect(code.contains("@AppStorage(PaletteID.storageKey) private var palette = PaletteID.fallback"))
        #expect(code.contains(".environment(\\.theme, ThemeID.fallback.theme(palette: palette))"))
        let holders = app.filter { CloudKitStructureTests.codeOnly($0.text).contains("@AppStorage") }.map(\.path)
        #expect(holders == [root.path])
    }
}
