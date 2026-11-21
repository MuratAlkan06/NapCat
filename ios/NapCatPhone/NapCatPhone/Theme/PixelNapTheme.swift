import SwiftUI

extension Theme {
    /// Pixel Nap uses the menu-bar cat's pixel identity: cream grounds, ink
    /// borders with a hard, blur-free shadow, square corners, monospaced
    /// labels and an 8 pt spacing rhythm. Dark mode is derived: warm
    /// charcoal grounds with cream ink. The empty state is Night Groom's (the
    /// owner's hybrid pick): the smooth grooming cat as a large, faint
    /// watermark behind the message, in a warm sepia (sand in dark mode).
    static var pixelNap: Theme {
        Theme(
            id: .pixelNap,
            displayName: "Pixel Nap",
            ground: Color(light: 0xFBFAF7, dark: 0x1A1917),
            surface: Color(light: 0xF1EFE9, dark: 0x272521),
            ink: Color(light: 0x23211D, dark: 0xECE9E3),
            inkSecondary: Color(light: 0x6B665C, dark: 0xADA79C),
            accent: Color(light: 0x2C4896, dark: 0x7EA6EC),
            hairline: Color(light: 0x23211D, dark: 0x8C867B),
            pillFill: Color(light: 0xF1EFE9, dark: 0x272521),
            artTint: Color(light: 0x7D5631, dark: 0xD8C3A0, lightAlpha: 0.09, darkAlpha: 0.08),
            warning: Color(light: 0x8F5300, dark: 0xF2B35D),
            error: Color(light: 0xB3261E, dark: 0xF2877C),
            titleFont: .system(.title, design: .monospaced, weight: .bold),
            sectionFont: .system(.footnote, design: .monospaced, weight: .bold),
            bodyFont: .body,
            metaFont: .system(.footnote, design: .monospaced, weight: .bold),
            detailFont: .subheadline,
            timestampFont: .system(.footnote, design: .monospaced),
            pillFont: .system(.footnote, design: .monospaced, weight: .bold),
            emptyFont: .system(.body, design: .monospaced, weight: .bold),
            margin: 16,
            rowPadding: 16,
            rowGap: 16,
            innerGap: 8,
            pillInsets: EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8),
            cornerRadius: 0,
            pillCornerRadius: 0,
            borderWidth: 2,
            hardShadow: 4,
            symbolVariant: .fill,
            symbolWeight: .bold,
            emptyArt: .groomWatermark(height: 340),
            entranceDuration: 0.25,
            entranceBounce: 0,
            entranceOffset: 8
        )
    }
}
