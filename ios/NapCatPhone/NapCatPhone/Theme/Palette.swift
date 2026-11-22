import SwiftUI

/// The receiver's palettes. A palette is colors only: every palette shares
/// Pixel Nap's type, spacing, surfaces, icons, art and motion
/// (`Theme.pixelNap(palette:)`), so switching palettes never moves or
/// resizes anything.
enum PaletteID: String, CaseIterable, Identifiable, Sendable {
    /// The shipped colors: cream and warm charcoal, with a sepia (sand in
    /// dark mode) watermark.
    case nightGroom

    /// The palette a fresh install uses.
    static let fallback: PaletteID = .nightGroom

    var id: Self { self }

    /// The palette's name.
    var displayName: String {
        switch self {
        case .nightGroom: return "Night Groom"
        }
    }

    var colors: Palette {
        switch self {
        case .nightGroom: return .nightGroom
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
}
