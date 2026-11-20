@testable import NapCatPhone
import Testing
import UIKit

/// The phone's severity vocabulary is the Mac panel's, value for value
/// (`PanelSeverity` / `PanelSymbol` / `severityAccessibilityPrefix` in
/// Sources/NapCat/MenuStateModel.swift).
@Suite struct PhoneSeverityTests {
    @Test func theLevelsAreTheMacPanelsFourInOrder() {
        #expect(PhoneSeverity.allCases == [.nominal, .info, .warning, .error])
        #expect(PhoneSeverity.nominal < .info && PhoneSeverity.info < .warning && PhoneSeverity.warning < .error)
    }

    @Test func theGlyphsAreTheMacPanelsGlyphs() {
        #expect(PhoneSeverity.nominal.symbol == nil)
        #expect(PhoneSeverity.info.symbol == "info.circle")
        #expect(PhoneSeverity.warning.symbol == "exclamationmark.triangle.fill")
        #expect(PhoneSeverity.error.symbol == "xmark.octagon.fill")
    }

    @Test func theSpokenPrefixesAreTheMacPanelsPrefixes() {
        #expect(PhoneSeverity.nominal.accessibilityPrefix == nil)
        #expect(PhoneSeverity.info.accessibilityPrefix == "Note")
        #expect(PhoneSeverity.warning.accessibilityPrefix == "Warning")
        #expect(PhoneSeverity.error.accessibilityPrefix == "Error")
    }

    /// Never color alone: anything above nominal has a glyph AND a spoken
    /// prefix, and the glyph exists on this iOS.
    @Test(arguments: PhoneSeverity.allCases.filter { $0 > .nominal })
    func everyNonNominalLevelHasAResolvableGlyphAndAPrefix(_ severity: PhoneSeverity) throws {
        let symbol = try #require(severity.symbol)
        #expect(UIImage(systemName: symbol) != nil)
        #expect(severity.accessibilityPrefix != nil)
    }

    @Test func aLineIsSpokenWithItsSeverityFirst() {
        #expect(PhoneLine(text: "Notifications off", severity: .warning).spoken == "Warning: Notifications off")
        #expect(PhoneLine(text: "Connected", severity: .nominal).spoken == "Connected")
    }
}
