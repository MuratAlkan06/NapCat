import SwiftUI

/// The receiver's palettes. A palette is colors only: every palette shares
/// Pixel Nap's type, spacing, surfaces, icons, art and motion
/// (`Theme.pixelNap(palette:)`), so switching palettes never moves or
/// resizes anything.
///
/// The raw values are what the app's defaults store under `storageKey`, so
/// they never change.
enum PaletteID: String, CaseIterable, Identifiable, Sendable {
    /// The shipped colors: cream and warm charcoal, with a sepia (sand in
    /// dark mode) watermark.
    case nightGroom
    /// Deeper cream grounds and a warmer night.
    case deepCream
    /// Night Groom with a gray watermark in light mode.
    case neutral

    /// The palette a fresh install uses.
    static let fallback: PaletteID = .nightGroom

    /// The defaults key holding the chosen palette's raw value. As a launch
    /// argument (`-palette deepCream`) it picks the palette for that launch
    /// only, without changing the stored choice.
    static let storageKey = "palette"

    var id: Self { self }

    /// The palette's name.
    var displayName: String {
        switch self {
        case .nightGroom: return "Night Groom"
        case .deepCream: return "Deep Cream"
        case .neutral: return "Neutral"
        }
    }

    var colors: Palette {
        switch self {
        case .nightGroom: return .nightGroom
        case .deepCream: return .deepCream
        case .neutral: return .neutral
        }
    }
}

/// One color token: an sRGB `0xRRGGBB` value and an alpha for each interface
/// style.
struct ColorToken: Equatable, Sendable {
    var light: UInt32
    var dark: UInt32
    var lightAlpha: CGFloat = 1
    var darkAlpha: CGFloat = 1

    /// The token as a color that follows the interface style.
    var color: Color {
        Color(light: light, dark: dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha)
    }
}

/// Every color the receiver paints with. Each role is documented on the
/// `Theme` property of the same name; views read the theme, never a palette.
struct Palette: Equatable, Sendable {
    var ground: ColorToken
    var surface: ColorToken
    var ink: ColorToken
    var inkSecondary: ColorToken
    var accent: ColorToken
    var hairline: ColorToken
    var pillFill: ColorToken
    var artTint: ColorToken
    var warning: ColorToken
    var error: ColorToken
}

extension Palette {
    /// Night Groom: cream grounds, warm charcoal in dark mode, an ink-blue
    /// accent, and the grooming-cat watermark in sepia (sand in dark mode).
    static let nightGroom = Palette(
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
    )

    /// Deep Cream: Night Groom on a deeper cream (light) and a warmer night
    /// (dark). The ground-to-card step is kept in both modes, the watermark
    /// is re-balanced to the new grounds, and the secondary ink is a shade
    /// darker in light mode so it keeps its contrast on the deeper card
    /// (4.91:1). Every other token is Night Groom's.
    static let deepCream: Palette = {
        var palette = Palette.nightGroom
        palette.ground = ColorToken(light: 0xF7F2E8, dark: 0x1D1A15)
        palette.surface = ColorToken(light: 0xEDE7DA, dark: 0x2A2620)
        palette.pillFill = ColorToken(light: 0xEDE7DA, dark: 0x2A2620)
        palette.inkSecondary = ColorToken(light: 0x67625A, dark: 0xADA79C)
        palette.artTint = ColorToken(light: 0x7D5631, dark: 0xD8C3A0, lightAlpha: 0.095, darkAlpha: 0.08)
        return palette
    }()

    /// Neutral: Night Groom with a gray watermark in light mode. Dark mode
    /// is Night Groom's.
    static let neutral: Palette = {
        var palette = Palette.nightGroom
        palette.artTint = ColorToken(light: 0x606060, dark: 0xD8C3A0, lightAlpha: 0.09, darkAlpha: 0.08)
        return palette
    }()
}
