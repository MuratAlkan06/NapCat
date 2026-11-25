@testable import NapCatPhone
import SwiftUI
import Testing

/// The palettes: three, Night Groom by default, each a set of colors and
/// nothing else. The values are the owner-reviewed variant pass's (#92).
@Suite struct PaletteTests {
    @Test func theThreePalettesAreOfferedInOrder() {
        #expect(PaletteID.allCases == [.nightGroom, .deepCream, .neutral])
        #expect(PaletteID.allCases.map(\.displayName) == ["Night Groom", "Deep Cream", "Neutral"])
    }

    @Test func nightGroomIsTheDefault() {
        #expect(PaletteID.fallback == .nightGroom)
        #expect(ThemeID.fallback.theme.palette == .nightGroom)
        #expect(Theme.pixelNap.palette == .nightGroom)
        #expect(EnvironmentValues().theme.palette == .nightGroom)
    }

    @Test(arguments: PaletteID.allCases)
    func eachThemeCarriesItsPalette(_ palette: PaletteID) {
        #expect(ThemeID.fallback.theme(palette: palette).palette == palette)
    }

    /// Night Groom is the color block that shipped before palettes existed
    /// (#93's warm watermark included), unchanged.
    @Test func nightGroomKeepsTheShippedColors() {
        #expect(Palette.nightGroom == Palette(
            ground: ColorToken(light: 0xFBFAF7, dark: 0x1A1917),
            surface: ColorToken(light: 0xF1EFE9, dark: 0x272521),
            ink: ColorToken(light: 0x23211D, dark: 0xECE9E3),
            inkSecondary: ColorToken(light: 0x6B665C, dark: 0xADA79C),
            accent: ColorToken(light: 0x2C4896, dark: 0x7EA6EC),
            hairline: ColorToken(light: 0x23211D, dark: 0x8C867B),
            pillFill: ColorToken(light: 0xF1EFE9, dark: 0x272521),
            artTint: ColorToken(light: 0x7D5631, dark: 0xD8C3A0, lightAlpha: 0.09, darkAlpha: 0.08),
            warning: ColorToken(light: 0x8F5300, dark: 0xF2B35D),
            error: ColorToken(light: 0xB3261E, dark: 0xF2877C)
        ))
    }

    /// Deep Cream (variant pass ios 5 + ios 6, with the secondary-ink fix):
    /// grounds, cards, pill, watermark and light secondary ink change; every
    /// other token is Night Groom's.
    @Test func deepCreamChangesOnlyItsListedTokens() {
        var expected = Palette.nightGroom
        expected.ground = ColorToken(light: 0xF7F2E8, dark: 0x1D1A15)
        expected.surface = ColorToken(light: 0xEDE7DA, dark: 0x2A2620)
        expected.pillFill = ColorToken(light: 0xEDE7DA, dark: 0x2A2620)
        expected.inkSecondary = ColorToken(light: 0x67625A, dark: 0xADA79C)
        expected.artTint = ColorToken(light: 0x7D5631, dark: 0xD8C3A0, lightAlpha: 0.095, darkAlpha: 0.08)
        #expect(Palette.deepCream == expected)
        #expect(Palette.deepCream.ink == Palette.nightGroom.ink)
        #expect(Palette.deepCream.accent == Palette.nightGroom.accent)
        #expect(Palette.deepCream.hairline == Palette.nightGroom.hairline)
        #expect(Palette.deepCream.warning == Palette.nightGroom.warning)
        #expect(Palette.deepCream.error == Palette.nightGroom.error)
    }

    /// Neutral (variant pass ios 3): only the light watermark turns gray.
    @Test func neutralChangesOnlyTheLightWatermark() {
        var expected = Palette.nightGroom
        expected.artTint.light = 0x606060
        #expect(Palette.neutral == expected)
        #expect(Palette.neutral.artTint == ColorToken(light: 0x606060, dark: 0xD8C3A0, lightAlpha: 0.09, darkAlpha: 0.08))
    }

    @Test func thePalettesAreDistinct() {
        let palettes = PaletteID.allCases.map(\.colors)
        for (index, palette) in palettes.enumerated() {
            #expect(!palettes[(index + 1)...].contains(palette))
        }
    }

    /// A palette changes colors only: type, spacing, surfaces, icons, art
    /// and motion are the same in every palette.
    @Test(arguments: PaletteID.allCases)
    func aPaletteChangesColorsOnly(_ palette: PaletteID) {
        let base = ThemeID.fallback.theme
        let theme = ThemeID.fallback.theme(palette: palette)
        #expect(theme.id == base.id && theme.displayName == base.displayName)
        #expect([theme.titleFont, theme.sectionFont, theme.bodyFont, theme.metaFont, theme.detailFont,
                 theme.timestampFont, theme.pillFont, theme.emptyFont, theme.codeFont]
            == [base.titleFont, base.sectionFont, base.bodyFont, base.metaFont, base.detailFont,
                base.timestampFont, base.pillFont, base.emptyFont, base.codeFont])
        #expect([theme.margin, theme.rowPadding, theme.rowGap, theme.innerGap, theme.cornerRadius,
                 theme.pillCornerRadius, theme.borderWidth, theme.hardShadow, theme.minTouchTarget, theme.entranceOffset]
            == [base.margin, base.rowPadding, base.rowGap, base.innerGap, base.cornerRadius,
                base.pillCornerRadius, base.borderWidth, base.hardShadow, base.minTouchTarget, base.entranceOffset])
        #expect(theme.pillInsets == base.pillInsets)
        #expect(theme.symbolVariant == base.symbolVariant && theme.symbolWeight == base.symbolWeight)
        #expect(theme.emptyArt == base.emptyArt)
        #expect(theme.entranceDuration == base.entranceDuration && theme.entranceBounce == base.entranceBounce)
    }
}
