import SwiftUI

extension Theme {
    /// Pixel Nap in the default palette.
    static var pixelNap: Theme { pixelNap(palette: .fallback) }

    /// Pixel Nap uses the menu-bar cat's pixel identity: cream grounds, ink
    /// borders with a hard, blur-free shadow, square corners, monospaced
    /// labels and an 8 pt spacing rhythm. Dark mode is derived: warm
    /// charcoal grounds with cream ink. The empty state is Night Groom's (the
    /// owner's hybrid pick): the smooth grooming cat as a large, faint
    /// watermark behind the message. Every color comes from `palette`;
    /// everything else is the same in every palette.
    static func pixelNap(palette: PaletteID) -> Theme {
        let colors = palette.colors
        return Theme(
            id: .pixelNap,
            displayName: "Pixel Nap",
            palette: palette,
            ground: colors.ground.color,
            surface: colors.surface.color,
            ink: colors.ink.color,
            inkSecondary: colors.inkSecondary.color,
            accent: colors.accent.color,
            hairline: colors.hairline.color,
            pillFill: colors.pillFill.color,
            artTint: colors.artTint.color,
            warning: colors.warning.color,
            error: colors.error.color,
            titleFont: .system(.title, design: .monospaced, weight: .bold),
            sectionFont: .system(.footnote, design: .monospaced, weight: .bold),
            bodyFont: .body,
            metaFont: .system(.footnote, design: .monospaced, weight: .bold),
            detailFont: .subheadline,
            timestampFont: .system(.footnote, design: .monospaced),
            pillFont: .system(.footnote, design: .monospaced, weight: .bold),
            emptyFont: .system(.body, design: .monospaced, weight: .bold),
            codeFont: .system(.title, design: .monospaced),
            margin: 16,
            rowPadding: 16,
            rowGap: 16,
            innerGap: 8,
            pillInsets: EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8),
            cornerRadius: 0,
            pillCornerRadius: 0,
            borderWidth: 2,
            hardShadow: 4,
            minTouchTarget: 44,
            symbolVariant: .fill,
            symbolWeight: .bold,
            emptyArt: .groomWatermark(height: 340),
            entranceDuration: 0.25,
            entranceBounce: 0,
            entranceOffset: 8
        )
    }
}
