import Foundation
@testable import NapCatPhone
import SwiftUI
import Testing

/// The color lints every palette passes in light and in dark mode (#92),
/// on the colors as SwiftUI resolves them:
///
/// 1. Opaque: every token but the watermark has alpha 1, so the ratios
///    below are the ones on screen.
/// 2. Text: ink, secondary ink, accent, warning and error reach 4.5:1
///    (WCAG 1.4.3, AA) on the ground, a card and the pill.
/// 3. Borders: the hairline (card and pill borders, the hard shadow)
///    reaches 3:1 (WCAG 1.4.11) on the ground and on a card.
/// 4. Faint watermark: the cat's tint has an alpha above 0 and at most 0.2.
/// 5. Readable over the watermark: ink reaches 4.5:1 over the darkest part
///    of the cat, its line work, where `GroomArt` lays the tint twice
///    (alpha 1-(1-a)^2 over the ground).
///
/// Contrast is the WCAG 2 ratio of relative luminances. Composites are
/// taken in gamma-encoded sRGB, as the variant pass measured them.
enum PaletteLint {
    static let textMinimum = 4.5
    static let borderMinimum = 3.0
    static let watermarkCeiling = 0.2
    static let schemes: [ColorScheme] = [.light, .dark]

    enum Role: String, CaseIterable {
        case ground, surface, ink, inkSecondary, accent, hairline, pillFill, artTint, warning, error

        func token(in palette: Palette) -> ColorToken {
            switch self {
            case .ground: return palette.ground
            case .surface: return palette.surface
            case .ink: return palette.ink
            case .inkSecondary: return palette.inkSecondary
            case .accent: return palette.accent
            case .hairline: return palette.hairline
            case .pillFill: return palette.pillFill
            case .artTint: return palette.artTint
            case .warning: return palette.warning
            case .error: return palette.error
            }
        }

        /// The color the views paint for this role.
        func color(in theme: Theme) -> Color {
            switch self {
            case .ground: return theme.ground
            case .surface: return theme.surface
            case .ink: return theme.ink
            case .inkSecondary: return theme.inkSecondary
            case .accent: return theme.accent
            case .hairline: return theme.hairline
            case .pillFill: return theme.pillFill
            case .artTint: return theme.artTint
            case .warning: return theme.warning
            case .error: return theme.error
            }
        }
    }

    static let textRoles: [Role] = [.ink, .inkSecondary, .accent, .warning, .error]
    static let backgroundRoles: [Role] = [.ground, .surface, .pillFill]

    /// A resolved color: gamma-encoded sRGB components and opacity.
    struct SRGB: Equatable {
        var red: Double, green: Double, blue: Double, opacity: Double

        init(_ color: Color, _ scheme: ColorScheme) {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let resolved = color.resolve(in: environment)
            self.init(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue),
                      opacity: Double(resolved.opacity))
        }

        init(red: Double, green: Double, blue: Double, opacity: Double) {
            self.red = red; self.green = green; self.blue = blue; self.opacity = opacity
        }

        /// `0xRRGGBB`, each component rounded to 8 bits.
        var hex: UInt32 {
            [red, green, blue].reduce(0) { ($0 << 8) | UInt32((min(max($1, 0), 1) * 255).rounded()) }
        }

        /// WCAG 2 relative luminance.
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        /// This color laid at `alpha` over an opaque `ground`.
        func over(_ ground: SRGB, alpha: Double) -> SRGB {
            func mix(_ top: Double, _ bottom: Double) -> Double { top * alpha + bottom * (1 - alpha) }
            return SRGB(red: mix(red, ground.red), green: mix(green, ground.green), blue: mix(blue, ground.blue),
                        opacity: 1)
        }
    }

    static func contrast(_ a: SRGB, _ b: SRGB) -> Double {
        let (high, low) = a.luminance >= b.luminance ? (a.luminance, b.luminance) : (b.luminance, a.luminance)
        return (high + 0.05) / (low + 0.05)
    }

    static func name(_ scheme: ColorScheme) -> String { scheme == .dark ? "dark" : "light" }

    static func ratio(_ value: Double) -> String { String(format: "%.2f:1", value) }

    /// Rule 4 alone. Compared at the resolved color's own (Float)
    /// precision, where the ceiling 0.2 itself reads 0.2000000030.
    static func faintnessFailures(_ palette: Palette, _ scheme: ColorScheme) -> [String] {
        let opacity = Float(SRGB(palette.artTint.color, scheme).opacity)
        guard opacity > 0 && opacity <= Float(watermarkCeiling) else {
            return ["\(name(scheme)) artTint opacity \(opacity) is outside (0, \(watermarkCeiling)]"]
        }
        return []
    }

    /// Every rule. Empty when the palette passes in `scheme`.
    static func failures(_ palette: Palette, _ scheme: ColorScheme) -> [String] {
        let mode = name(scheme)
        func color(_ role: Role) -> SRGB { SRGB(role.token(in: palette).color, scheme) }
        var failures: [String] = []
        for role in Role.allCases where role != .artTint && color(role).opacity != 1 {
            failures.append("\(mode) \(role) is not opaque (\(color(role).opacity))")
        }
        for text in textRoles {
            for background in backgroundRoles {
                let value = contrast(color(text), color(background))
                if value < textMinimum {
                    failures.append("\(mode) \(text) on \(background) \(ratio(value)) < \(ratio(textMinimum))")
                }
            }
        }
        for background in [Role.ground, .surface] {
            let value = contrast(color(.hairline), color(background))
            if value < borderMinimum {
                failures.append("\(mode) hairline on \(background) \(ratio(value)) < \(ratio(borderMinimum))")
            }
        }
        failures += faintnessFailures(palette, scheme)
        let art = color(.artTint)
        let lineWork = art.over(color(.ground), alpha: 1 - pow(1 - art.opacity, 2))
        let overArt = contrast(color(.ink), lineWork)
        if overArt < textMinimum {
            failures.append("\(mode) ink over the watermark's line work \(ratio(overArt)) < \(ratio(textMinimum))")
        }
        return failures
    }
}

@Suite struct PaletteLintTests {
    /// The lints read the colors the views paint: each theme color resolves
    /// to its palette's token, and to that token's own half in each scheme
    /// (so the dark lint really sees dark colors).
    @Test(arguments: PaletteID.allCases, PaletteLint.schemes)
    func theThemePaintsItsPalettesColors(_ id: PaletteID, _ scheme: ColorScheme) {
        let theme = ThemeID.fallback.theme(palette: id)
        for role in PaletteLint.Role.allCases {
            let token = role.token(in: id.colors)
            let painted = PaletteLint.SRGB(role.color(in: theme), scheme)
            #expect(painted == PaletteLint.SRGB(token.color, scheme), "\(id) \(role)")
            #expect(painted.hex == (scheme == .dark ? token.dark : token.light), "\(id) \(scheme) \(role)")
            let alpha = Float(scheme == .dark ? token.darkAlpha : token.lightAlpha)
            #expect(Float(painted.opacity) == alpha, "\(id) \(scheme) \(role)")
        }
    }

    @Test(arguments: PaletteID.allCases, PaletteLint.schemes)
    func everyPalettePassesTheContrastAndFaintnessLints(_ id: PaletteID, _ scheme: ColorScheme) {
        let failures = PaletteLint.failures(id.colors, scheme)
        #expect(failures.isEmpty, "\(id): \(failures)")
    }

    /// The fix Deep Cream carries: its light secondary ink keeps 4.91:1 on
    /// the deeper card (Night Groom's ink there would drop to 4.63:1).
    @Test func deepCreamsSecondaryInkKeepsItsMargin() {
        let card = PaletteLint.SRGB(Palette.deepCream.surface.color, .light)
        let fixed = PaletteLint.contrast(PaletteLint.SRGB(Palette.deepCream.inkSecondary.color, .light), card)
        let unfixed = PaletteLint.contrast(PaletteLint.SRGB(Palette.nightGroom.inkSecondary.color, .light), card)
        #expect(abs(fixed - 4.91) < 0.01, "\(fixed)")
        #expect(abs(unfixed - 4.63) < 0.01, "\(unfixed)")
    }

    /// Each rule can fail: a deliberately failing palette per rule, each
    /// a one-token change to Night Groom, trips that rule and only that one.
    @Test func eachRuleCatchesADeliberatelyFailingPalette() {
        func mutant(_ change: (inout Palette) -> Void) -> Palette {
            var palette = Palette.nightGroom
            change(&palette)
            return palette
        }
        // Rule 2: a washed-out secondary ink (2.59:1 on the card), light only.
        let pale = mutant { $0.inkSecondary.light = 0x9A958B }
        let paleFailures = PaletteLint.failures(pale, .light)
        #expect(paleFailures.count == 3 && paleFailures.allSatisfy { $0.hasPrefix("light inkSecondary on ") },
                "\(paleFailures)")
        #expect(PaletteLint.failures(pale, .dark).isEmpty)
        // Rule 3: a hairline that vanishes into the dark ground.
        let lost = PaletteLint.failures(mutant { $0.hairline.dark = 0x3A3732 }, .dark)
        #expect(lost.count == 2 && lost.allSatisfy { $0.hasPrefix("dark hairline on ") }, "\(lost)")
        // Rule 4: a watermark too strong, and one that is not there.
        let loud = PaletteLint.failures(mutant { $0.artTint.darkAlpha = 0.3 }, .dark)
        #expect(loud.contains { $0.hasPrefix("dark artTint opacity") }, "\(loud)")
        let gone = PaletteLint.failures(mutant { $0.artTint.lightAlpha = 0 }, .light)
        #expect(gone == PaletteLint.faintnessFailures(mutant { $0.artTint.lightAlpha = 0 }, .light) && gone.count == 1)
        // Rule 5: lighter ink still passes on the grounds (6.21:1), but not
        // over a black cat at the ceiling alpha (2.48:1).
        let heavy = PaletteLint.failures(mutant {
            $0.ink.light = 0x5E5E5E
            $0.artTint = ColorToken(light: 0x000000, dark: 0xD8C3A0, lightAlpha: 0.2, darkAlpha: 0.08)
        }, .light)
        #expect(heavy.count == 1 && heavy[0].hasPrefix("light ink over the watermark's line work 2.48:1"), "\(heavy)")
        // Rule 1: a see-through card.
        let glass = PaletteLint.failures(mutant { $0.surface.lightAlpha = 0.5 }, .light)
        #expect(glass == ["light surface is not opaque (0.5)"], "\(glass)")
    }
}
